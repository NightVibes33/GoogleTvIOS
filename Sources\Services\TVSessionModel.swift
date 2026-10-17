import Foundation
import SwiftUI
import Network

/// App session: discovery, pairing, commands, hold-to-talk Gemini.
@MainActor
final class TVSessionModel: ObservableObject {
    @Published var devices: [TVDevice] = []
    @Published var selected: TVDevice?
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var isPairing = false
    @Published var status = "Find your Google TV on Wi‑Fi"
    @Published var lastError: String?
    @Published var pairingCode = ""
    @Published var isMicHolding = false

    private let discovery = DiscoveryService()
    private let client = AndroidTVClient()
    private var micTask: Task<Void, Never>?

    func scan() {
        isScanning = true
        status = "Scanning local network…"
        lastError = nil
        Task {
            do {
                let found = try await discovery.scan(timeout: 4)
                devices = found
                status = found.isEmpty
                    ? "No TVs found — enter IP or check Wi‑Fi"
                    : "Found \(found.count) device\(found.count == 1 ? "" : "s")"
            } catch {
                lastError = error.localizedDescription
                status = "Scan failed"
            }
            isScanning = false
        }
    }

    func connect(to device: TVDevice) {
        selected = device
        status = "Connecting to \(device.name)…"
        lastError = nil
        Task {
            do {
                try await client.connect(host: device.host)
                isConnected = true
                isPairing = false
                status = "Connected · \(device.name)"
            } catch AndroidTVClientError.pairingRequired {
                isPairing = true
                isConnected = false
                status = "Enter the PIN shown on your TV"
                do {
                    try await client.startPairing(host: device.host)
                } catch {
                    lastError = error.localizedDescription
                }
            } catch {
                lastError = error.localizedDescription
                status = "Connection failed"
                isConnected = false
            }
        }
    }

    func submitPairingCode() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else {
            lastError = "PIN must be 6 characters (0-9, A-F)"
            return
        }
        status = "Submitting PIN…"
        Task {
            do {
                try await client.finishPairing(code: code)
                if let device = selected {
                    try await client.connect(host: device.host)
                }
                isPairing = false
                isConnected = true
                pairingCode = ""
                status = "Paired & connected"
            } catch {
                lastError = error.localizedDescription
                status = "Pairing failed"
            }
        }
    }

    func send(_ key: TVKey) {
        guard isConnected else {
            status = "Connect a TV first"
            return
        }
        Task {
            do {
                try await client.sendKey(key)
                status = key.rawValue
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func launch(appId: String, name: String) {
        guard isConnected else { return }
        Task {
            do {
                try await client.launchApp(appId)
                status = "Opened \(name)"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Hold mic: SEARCH START_LONG + stream iPhone mic → Gemini/Assistant (same as Windows).
    func micPress() {
        guard isConnected, !isMicHolding else { return }
        isMicHolding = true
        status = "Gemini listening — keep holding…"
        micTask = Task {
            do {
                try await client.holdGeminiVoice { [weak self] in
                    await MainActor.run { self?.isMicHolding == true }
                }
                if !Task.isCancelled {
                    status = "Gemini voice ended"
                }
            } catch {
                lastError = error.localizedDescription
                status = "Mic failed"
            }
            isMicHolding = false
        }
    }

    func micRelease() {
        isMicHolding = false
        micTask?.cancel()
        micTask = nil
        status = "Mic released"
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
        isPairing = false
        status = "Disconnected"
    }
}
