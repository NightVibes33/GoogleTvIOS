import Foundation

/// Persistent, rotating text diagnostics. Files are stored in Documents/Logs,
/// so they appear under On My iPhone > CastDeck > Logs.
final class CastDeckLog {
    static let shared = CastDeckLog()
    private let queue = DispatchQueue(label: "castdeck.diagnostics.disk", qos: .utility)
    private let directory: URL
    private let current: URL
    private let maxBytes: UInt64 = 2 * 1024 * 1024
    private let retainedArchives = 3

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Logs", isDirectory: true)
        current = directory.appendingPathComponent("CastDeck-current.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: current.path) {
            FileManager.default.createFile(atPath: current.path, contents: nil)
        }
    }

    var visibleFolderName: String { "On My iPhone / CastDeck / Logs" }
    var currentLogURL: URL { current }

    /// Recent *sanitized excerpts* for opt-in support reports. The complete
    /// rotating log stays on the iPhone. Do not include user input or device
    /// hostnames, IP addresses, tokens, PINs or identifiers in outgoing data.
    func supportExcerpt(maxLines: Int = 80) -> [String] {
        queue.sync { [self] in
            guard let bytes = try? Data(contentsOf: current) else { return [] }
            let tail = Data(bytes.suffix(96 * 1024))
            let lines = String(decoding: tail, as: UTF8.self)
                .split(separator: "\n").suffix(min(maxLines, 80))
            return lines.map { sanitizeForUpload(String($0)) }
        }
    }

    private func sanitizeForUpload(_ input: String) -> String {
        let sensitive = #"(?i)\b(pass(word|code)?|pin|authorization|bearer|token|secret|credential|cookie|private[\s_-]*key|keyboard[\s_-]*text|text[\s_-]*value|clipboard|typed[\s_-]*text|session[\s_-]*id)\b"#
        if input.range(of: sensitive, options: .regularExpression) != nil {
            return "[private diagnostic event omitted]"
        }
        var output = String(input.prefix(380))
        let filters: [(String, String)] = [
            (#"(?i)https?://[^\s"<>]+"#, "[url]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[ip]"),
            (#"(?i)\b(?:[a-f0-9]{0,4}:){2,}[a-f0-9:]{2,}\b"#, "[ipv6]"),
            (#"(?i)\b[a-z0-9._-]+\.local\b"#, "[host]"),
            (#"(?i)\b(?:[a-f0-9]{2}[:-]){5}[a-f0-9]{2}\b"#, "[mac]"),
            (#"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b"#, "[email]"),
            (#"(?i)\b[a-f0-9]{24,}\b"#, "[identifier]"),
            (#"\b[0-9]{6,10}\b"#, "[number]")
        ]
        for (pattern, replacement) in filters {
            output = output.replacingOccurrences(of: pattern, with: replacement,
                                                  options: .regularExpression)
        }
        return String(output.prefix(300))
    }

    func write(_ category: String, _ message: String) {
        // Automatic reporting receives only a fixed failure code derived
        // locally. No literal log line or network address is uploaded.
        Task { @MainActor in
            CastDeckAutoReports.shared.observe(category: category, detail: message)
        }
        // Never record pairing codes, passwords, key material, or raw device credentials.
        let clean = message.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  [\(category)]  \(clean)\n"
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                rotateIfNeeded()
                if !FileManager.default.fileExists(atPath: current.path) {
                    FileManager.default.createFile(atPath: current.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                NSLog("CastDeck local log write failed: %@", String(describing: error))
            }
        }
    }

    private func rotateIfNeeded() {
        let length = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard length >= maxBytes else { return }
        let fm = FileManager.default
        let expired = directory.appendingPathComponent("CastDeck-\(retainedArchives).log")
        try? fm.removeItem(at: expired)
        if retainedArchives > 1 {
            for number in stride(from: retainedArchives - 1, through: 1, by: -1) {
                let old = directory.appendingPathComponent("CastDeck-\(number).log")
                let next = directory.appendingPathComponent("CastDeck-\(number + 1).log")
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: next) }
            }
        }
        try? fm.moveItem(at: current, to: directory.appendingPathComponent("CastDeck-1.log"))
    }
}
