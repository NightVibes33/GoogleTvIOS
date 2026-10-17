import Foundation
import AVFoundation

enum AndroidTVClientError: LocalizedError {
    case pairingRequired
    case notConnected
    case micDenied
    case needsMacBridge
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .pairingRequired: return "Pairing required — enter the PIN on your TV"
        case .notConnected: return "Not connected"
        case .micDenied: return "Microphone permission denied"
        case .needsMacBridge:
            return "Open this project in Xcode on a Mac and link AndroidTVRemoteControl (see INTEGRATION.md)"
        case .underlying(let s): return s
        }
    }
}

/// Protocol client for Google TV / Android TV Remote v2.
/// Full TLS pairing + keys are completed in Xcode via SPM `AndroidTVRemoteControl`
/// (see INTEGRATION.md). This type holds the async API the UI already calls.
final class AndroidTVClient: @unchecked Sendable {
    private var host: String?
    private var pairedHosts: Set<String> = []

    /// Injected on Mac after SPM is linked — keeps UI compiling everywhere.
    var bridge: (any AndroidTVBridging)?

    func connect(host: String) async throws {
        self.host = host
        if let bridge {
            try await bridge.connect(host: host)
            return
        }
        // Dev stub: pretend pairing needed first time
        if !pairedHosts.contains(host) {
            throw AndroidTVClientError.pairingRequired
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func startPairing(host: String) async throws {
        self.host = host
        if let bridge {
            try await bridge.startPairing(host: host)
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func finishPairing(code: String) async throws {
        if let bridge {
            try await bridge.finishPairing(code: code)
            if let host { pairedHosts.insert(host) }
            return
        }
        guard code.count == 6 else {
            throw AndroidTVClientError.underlying("Invalid PIN")
        }
        if let host { pairedHosts.insert(host) }
    }

    func sendKey(_ key: TVKey) async throws {
        if let bridge {
            try await bridge.sendKey(key)
            return
        }
        guard host != nil else { throw AndroidTVClientError.notConnected }
        // Stub no-op until SPM bridge is attached on Mac
        _ = key
    }

    func launchApp(_ appId: String) async throws {
        if let bridge {
            try await bridge.launchApp(appId)
            return
        }
        _ = appId
    }

    /// Hold-to-talk: SEARCH START_LONG + iPhone mic PCM @ 8 kHz mono → END_LONG.
    func holdGeminiVoice(whileHolding: @escaping () async -> Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        guard await requestMic() else { throw AndroidTVClientError.micDenied }

        try await sendKey(.searchStartLong)

        if let bridge {
            try await bridge.streamMicPCM(whileHolding: whileHolding)
        } else {
            // Capture locally so permission + UX work; bytes forwarded once bridge exists
            let engine = AVAudioEngine()
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 2048, format: input.inputFormat(forBus: 0)) { _, _ in }
            engine.prepare()
            try engine.start()
            while await whileHolding() {
                try await Task.sleep(nanoseconds: 40_000_000)
                if Task.isCancelled { break }
            }
            input.removeTap(onBus: 0)
            engine.stop()
        }

        try await sendKey(.searchEndLong)
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func disconnect() {
        bridge?.disconnect()
        host = nil
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }
}

protocol AndroidTVBridging: AnyObject {
    func connect(host: String) async throws
    func startPairing(host: String) async throws
    func finishPairing(code: String) async throws
    func sendKey(_ key: TVKey) async throws
    func launchApp(_ appId: String) async throws
    func streamMicPCM(whileHolding: @escaping () async -> Bool) async throws
    func disconnect()
}
