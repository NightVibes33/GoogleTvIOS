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

    func write(_ category: String, _ message: String) {
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
