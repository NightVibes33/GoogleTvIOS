#if false
// Rename to AndroidTVRemoteBridge.swift and set `#if false` → remove when
// AndroidTVRemoteControl is linked in Xcode. Adjust type names to match the
// package version you resolve from:
// https://github.com/odyshewroman/AndroidTVRemoteControl

import Foundation
import AndroidTVRemoteControl

final class AndroidTVRemoteBridge: AndroidTVBridging {
    private let crypto = CryptoManager()
    private lazy var tls = TLSManager(cryptoManager: crypto)
    private var pairing: PairingManager?
    private var remote: RemoteManager?

    func connect(host: String) async throws {
        let manager = RemoteManager(tlsManager: tls, cryptoManager: crypto)
        remote = manager
        manager.connect(host, "CastDeck iOS", "androidtvremote")
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    func startPairing(host: String) async throws {
        let pm = PairingManager(tlsManager: tls, cryptoManager: crypto)
        pairing = pm
        pm.connect(host, "CastDeck iOS", "androidtvremote")
    }

    func finishPairing(code: String) async throws {
        pairing?.sendSecret(code)
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func sendKey(_ key: TVKey) async throws {
        guard let remote else { throw AndroidTVClientError.notConnected }
        // Map TVKey → library Key / Direction (package-specific)
        switch key {
        case .searchStartLong:
            remote.send(KeyCommand(keyCode: .search, direction: .startLong))
        case .searchEndLong:
            remote.send(KeyCommand(keyCode: .search, direction: .endLong))
        default:
            remote.send(KeyCommand(named: key.rawValue))
        }
    }

    func launchApp(_ appId: String) async throws {
        remote?.send(LaunchCommand(appId: appId))
    }

    func streamMicPCM(whileHolding: @escaping () async -> Bool) async throws {
        // Implement RemoteVoicePayload streaming per package docs / Wiki:
        // https://github.com/Aymkdn/assistant-freebox-cloud/wiki/Google-TV-(aka-Android-TV)-Remote-Control-(v2)
        while await whileHolding() {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func disconnect() {
        remote?.disconnect()
        pairing?.disconnect()
        remote = nil
        pairing = nil
    }
}
#endif
