import Foundation

enum AndroidTVClientError: LocalizedError {
    case pairingRequired
    case notConnected
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .pairingRequired: return "Pairing required"
        case .notConnected: return "Not connected to a TV"
        case .underlying(let message): return message
        }
    }
}

/// Android TV Remote v2 entry point. Never report success without the real transport.
@MainActor
final class AndroidTVClient {
    private var bridge: AndroidTVRemoteBridge?
    var onConnectionLost: ((String) -> Void)?
    var onKeyboardRequested: ((String) -> Void)?
    var onKeyboardStatus: ((Bool, String) -> Void)?

    private func transport() throws -> AndroidTVRemoteBridge {
        if let bridge { return bridge }
        let created = try AndroidTVRemoteBridge()
        created.onConnectionLost = { [weak self] message in self?.onConnectionLost?(message) }
        created.onKeyboardRequested = { [weak self] label in self?.onKeyboardRequested?(label) }
        created.onKeyboardStatus = { [weak self] active, label in
            self?.onKeyboardStatus?(active, label)
        }
        bridge = created
        return created
    }

    func connect(host: String) async throws {
        try await transport().connect(host: host)
    }

    func startPairing(host: String) async throws {
        try await transport().startPairing(host: host)
    }

    func finishPairing(code: String) async throws {
        try await transport().finishPairing(code: code)
    }

    func sendKey(_ key: TVKey) async throws {
        try await transport().sendKey(key)
    }

    func sendText(_ text: String) async throws {
        try await transport().sendText(text)
    }

    func launchApp(_ appId: String) async throws {
        try await transport().launchApp(appId)
    }

    func beginVoice() async throws {
        try await transport().beginVoice()
    }

    func sendVoicePCM(_ samples: Data) throws {
        guard let bridge else { throw AndroidTVClientError.notConnected }
        try bridge.sendVoicePCM(samples)
    }

    func endVoice() {
        bridge?.endVoice()
    }

    func disconnect() {
        bridge?.disconnect()
    }
}
