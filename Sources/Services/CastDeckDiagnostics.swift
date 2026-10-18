import Foundation
import Sentry

/// Production diagnostics are intentionally separate from local verbose logs.
/// Sentry receives only crash metadata and coarse non-sensitive issue codes,
/// never PINs, microphone audio, screen frames, text fields or local log files.
final class CastDeckDiagnostics {
    static let shared = CastDeckDiagnostics()
    private var started = false
    private init() {}

    private var dsn: String {
        (Bundle.main.object(forInfoDictionaryKey: "CastDeckSentryDSN") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSendReports: Bool { dsn.hasPrefix("https://") && dsn.contains("@") }

    var allowed: Bool {
        UserDefaults.standard.bool(forKey: "shareDiagnostics")
    }

    /// Safe at startup and whenever the user changes their privacy preference.
    func configure() {
        guard allowed, canSendReports else {
            if started {
                SentrySDK.close()
                started = false
            }
            return
        }
        guard !started else { return }
        SentrySDK.start { options in
            options.dsn = self.dsn
            options.debug = false
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = 0
            options.beforeSend = { event in
                // Opting out while the app is running prevents any queued
                // event from being forwarded through the SDK.
                guard UserDefaults.standard.bool(forKey: "shareDiagnostics") else {
                    return nil
                }
                return event
            }
        }
        started = true
        CastDeckLog.shared.write("diagnostics", "Anonymous issue reporting is enabled")
    }

    /// Send no message strings, addresses, text contents or identifiable
    /// device attributes. Fixed event categories allow grouping at scale.
    func report(_ kind: String) {
        guard allowed, canSendReports, started else { return }
        let permitted = Set([
            "connection", "pairing", "discovery", "keyboard",
            "voice", "mirroring", "unknown"
        ])
        let category = permitted.contains(kind) ? kind : "unknown"
        _ = SentrySDK.capture(message: "castdeck.\(category).failed")
    }
}
