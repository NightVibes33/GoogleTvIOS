import Foundation

/// Offline-first, privacy-filtered support reports. The app NEVER uploads
/// CastDeck-current.log, voice samples, text entries, PINs, hostnames or IPs.
/// Fixed diagnostic codes are summarized and delivered automatically after
/// the customer opts in. GitHub credentials exist only on our HTTPS gateway.
@MainActor
final class CastDeckAutoReports {
    static let shared = CastDeckAutoReports()
    private let defaults = UserDefaults.standard
    private let storageKey = "diagnostics.pending.v1"
    private let batchKey = "diagnostics.batch-id.v1"
    private let lastFlushKey = "diagnostics.last-sent.v1"
    private var uploading = false
    private var scheduled = false

    private init() {}

    var configured: Bool { endpoint != nil }
    var enabled: Bool { defaults.bool(forKey: "shareDiagnostics") }

    private var endpoint: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "CastDeckTelemetryEndpoint") as? String,
              let url = URL(string: string), url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Only these predefined issue signatures can leave an iPhone.
    private func issueCode(category: String, detail: String) -> String? {
        let text = detail.lowercased()
        switch category {
        case "remote":
            if text.contains("disconnected") || text.contains("receive data error") {
                return "remote.connection.lost"
            }
            if text.contains("handshake") && text.contains("fail") {
                return "remote.handshake.failed"
            }
            if text.contains("browser failed") { return "discovery.bonjour.failed" }
            if text.contains("pairing") && (text.contains("fail") || text.contains("error")) {
                return "remote.pairing.failed"
            }
            if text.contains("keyboard") && (text.contains("fail") || text.contains("rejected")) {
                return "remote.ime.failed"
            }
        case "voice":
            if text.contains("fail") || text.contains("unavailable") ||
               text.contains("transmission") || text.contains("denied") {
                return "remote.voice.failed"
            }
        case "cast-realtime", "mirror":
            if text.contains("offer") && text.contains("fail") {
                return "cast.offer.failed"
            }
            if text.contains("rejected") || text.contains("codec") && text.contains("fail") {
                return "cast.codec.rejected"
            }
            if text.contains("ack timeout") || text.contains("rtcp") && text.contains("timeout") {
                return "cast.rtp.timeout"
            }
            if text.contains("encryption failed") { return "cast.crypto.failed" }
            if text.contains("udp") && text.contains("failed") {
                return "cast.network.failed"
            }
            if text.contains("capture") && (text.contains("failed") || text.contains("ended")) {
                return "cast.capture.failed"
            }
            if text.contains("streaming failed") || text.contains("session ended") {
                return "cast.session.failed"
            }
        case "hls", "cast-http":
            if text.contains("404") { return "legacy.cast.media.missing" }
        default: break
        }
        return nil
    }

    /// This function intentionally accepts a local string but sends only its
    /// allowlisted classification. The string is never serialized or stored.
    func observe(category: String, detail: String) {
        guard enabled else { return }
        guard let code = issueCode(category: category, detail: detail) else { return }
        var counts = pending
        counts[code] = min(1000, (counts[code] ?? 0) + 1)
        defaults.set(counts, forKey: storageKey)
        schedule()
    }

    private var pending: [String: Int] {
        defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }

    func preferencesChanged() {
        if !enabled {
            defaults.removeObject(forKey: storageKey)
            defaults.removeObject(forKey: batchKey)
        } else {
            schedule()
        }
    }

    func schedule() {
        guard enabled, configured, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.scheduled = false
            await self?.flush()
        }
    }

    /// Flush on app foreground/launch and after new failures. If offline, retain
    /// the bounded queue locally and retry later; no user action is required.
    func flush() async {
        guard enabled, let endpoint, !uploading, !pending.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let lastSent = defaults.double(forKey: lastFlushKey)
        // Avoid exhausting free-tier server resources across thousands of TVs.
        guard now - lastSent > 120 else { return }
        uploading = true
        let snapshot = pending
        let batchID = defaults.string(forKey: batchKey) ?? UUID().uuidString
        defaults.set(batchID, forKey: batchKey)
        struct Event: Encodable { let code: String; let count: Int }
        struct Body: Encodable {
            let schema: Int
            let app: String
            let release: String
            let os: String
            let batchID: String
            let events: [Event]
        }
        let body = Body(
            schema: 1, app: "castdeck",
            release: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            os: "ios",
            batchID: batchID,
            events: snapshot.sorted { $0.key < $1.key }.prefix(25)
                .map { Event(code: $0.key, count: $0.value) }
        )
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                uploading = false
                return
            }
            var unsent = pending
            for (code, count) in snapshot {
                let rest = max(0, (unsent[code] ?? 0) - count)
                if rest == 0 { unsent.removeValue(forKey: code) }
                else { unsent[code] = rest }
            }
            defaults.set(unsent, forKey: storageKey)
            defaults.removeObject(forKey: batchKey)
            defaults.set(now, forKey: lastFlushKey)
        } catch {
            // Suppress upload errors from ordinary UI and don't recursively
            // include HTTP failures in the telemetry queue.
        }
        uploading = false
    }
}
