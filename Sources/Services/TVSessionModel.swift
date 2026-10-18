import Foundation
import SwiftUI

@MainActor
final class TVSessionModel: ObservableObject {
    @Published var devices: [TVDevice] = []
    @Published var selected: TVDevice?
    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isPairing = false
    @Published var status = "Choose a Google TV to connect"
    @Published var lastError: String?
    @Published var pairingCode = ""
    @Published var discoveryDetails = "Not scanned yet"
    @Published private(set) var logs: [String] = []

    private let discovery = DiscoveryService()
    private let client = AndroidTVClient()
    private var connectionTask: Task<Void, Never>?
    private var requestID = UUID()
    private var didAttemptAutoConnect = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "lastDevice"),
           let tv = try? JSONDecoder().decode(TVDevice.self, from: data) {
            selected = tv
            status = "Ready to reconnect to " + tv.name
        }
        client.onConnectionLost = { [weak self] reason in
            guard let self, self.isConnected else { return }
            self.isConnected = false
            self.status = "Connection lost"
            self.lastError = reason
            self.record("Remote disconnected: " + reason)
        }
    }

    func record(_ line: String) {
        logs.append(Date().formatted(date: .numeric, time: .standard) + "  " + line)
        CastDeckLog.shared.write("remote", line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    var diagnosticText: String {
        (["CastDeck diagnostics (no PINs or private keys)",
          "Selected device: " + (selected?.name ?? "none"),
          "State: " + status,
          "Connected: " + String(isConnected),
          "Discovery: " + discoveryDetails,
          ""] + logs).joined(separator: "\n")
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        status = "Looking for devices on Wi-Fi…"
        record("Starting Bonjour discovery")
        Task {
            let result = await discovery.scan(timeout: 9) { [weak self] found, message in
                guard let self else { return }
                self.devices = found
                self.discoveryDetails = message
                self.record("Bonjour: " + message)
            }
            devices = result.devices
            isScanning = false
            discoveryDetails = "\(result.devices.count) unique TV(s) from \(result.servicesFound) Bonjour service(s)"
            if let previouslySelected = selected,
               let updated = result.devices.first(where: {
                    $0.host == previouslySelected.host && $0.supportsRemote == previouslySelected.supportsRemote
               }) {
                selected = updated
                if !isConnected, !isConnecting,
                   !isPairing, !didAttemptAutoConnect,
                   UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
                    didAttemptAutoConnect = true
                    connect(to: updated)
                    return
                }
            }
            if result.devices.contains(where: { !$0.host.isEmpty }) {
                status = "Found \(result.devices.count) unique TV(s) — choose a TV"
            } else if let error = result.errors.first {
                lastError = error
                status = "Discovery failed — see connection details"
            } else if result.servicesFound > 0 {
                status = "TV advertised, but its address could not be resolved"
            } else {
                status = "No Bonjour services found — check Wi-Fi, permissions, or enter TV IP"
            }
            record("Discovery finished: " + discoveryDetails)
        }
    }

    func connect(to device: TVDevice) {
        guard device.supportsRemote else {
            lastError = "This is a cast-only Chromecast. It does not support the Google TV directional remote. Use casting controls for this receiver."
            status = "Cast-only device"
            record("Rejected unsupported cast-only remote: " + device.name)
            return
        }
        connectionTask?.cancel()
        client.disconnect()
        requestID = UUID()
        let id = requestID
        selected = device
        isConnected = false
        isPairing = false
        isConnecting = true
        pairingCode = ""
        lastError = nil
        status = "Connecting to " + device.name + "…"
        record("Connecting to " + device.host)
        connectionTask = Task {
            do {
                try await client.connect(host: device.host)
                guard id == requestID else { return }
                connected(device)
            } catch {
                guard id == requestID, !Task.isCancelled else { return }
                record("Initial remote handshake: " + error.localizedDescription)
                status = "Requesting a pairing code…"
                do {
                    try await client.startPairing(host: device.host)
                    guard id == requestID else { return }
                    isPairing = true
                    isConnecting = false
                    status = "Enter the six-character code shown on your Google TV"
                    record("TV displayed a pairing code")
                } catch {
                    guard id == requestID else { return }
                    isPairing = false
                    isConnecting = false
                    status = "Connection failed"
                    lastError = error.localizedDescription
                    record("Pairing could not start: " + error.localizedDescription)
                }
            }
        }
    }

    func submitPairingCode() {
        guard isPairing, let device = selected else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "0123456789ABCDEF").contains($0)
        }) else {
            lastError = "Enter the six hexadecimal characters (0–9, A–F) shown on the TV."
            return
        }
        isConnecting = true
        lastError = nil
        status = "Verifying code with TV…"
        let id = requestID
        connectionTask = Task {
            do {
                try await client.finishPairing(code: code)
                guard id == requestID else { return }
                record("PIN verified by TV")
                try await client.connect(host: device.host)
                guard id == requestID else { return }
                connected(device)
            } catch {
                guard id == requestID else { return }
                isConnecting = false
                isPairing = false
                pairingCode = ""
                status = "Pairing failed — reconnect to retry"
                lastError = error.localizedDescription
                record("PIN verification failed: " + error.localizedDescription)
            }
        }
    }

    private func connected(_ device: TVDevice) {
        isConnected = true
        isConnecting = false
        isPairing = false
        pairingCode = ""
        lastError = nil
        status = "Connected to " + device.name
        if let saved = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(saved, forKey: "lastDevice")
        }
        record("Remote handshake confirmed by TV")
    }

    func send(_ key: TVKey) {
        guard isConnected else { return }
        Task {
            do {
                try await client.sendKey(key)
                // Keep protocol keycodes in diagnostics, not the consumer UI.
                record("Sent " + key.rawValue)
            } catch {
                isConnected = false
                lastError = error.localizedDescription
                status = "Remote command failed"
                record("Command failed: " + error.localizedDescription)
            }
        }
    }

    func beginVoice() async throws {
        guard isConnected else { throw AndroidTVClientError.notConnected }
        try await client.beginVoice()
        record("TV acknowledged new voice session")
    }

    func sendVoicePCM(_ bytes: Data) throws {
        guard isConnected else { throw AndroidTVClientError.notConnected }
        try client.sendVoicePCM(bytes)
    }

    func endVoice() {
        client.endVoice()
    }

    func sendText(_ text: String) {
        guard isConnected else { return }
        Task {
            do {
                try await client.sendText(text)
                record("Sent keyboard input (" + String(text.count) + " characters)")
            } catch {
                lastError = error.localizedDescription
                record("Keyboard command failed: " + error.localizedDescription)
            }
        }
    }

    func launch(appId: String, name: String) {
        guard isConnected else { return }
        Task {
            do {
                try await client.launchApp(appId)
                status = "Sent " + name + " shortcut"
                record("Deep-link sent for " + name)
            } catch {
                lastError = error.localizedDescription
                record("Shortcut failed: " + error.localizedDescription)
            }
        }
    }

    func disconnect() {
        requestID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        client.disconnect()
        isConnected = false
        isPairing = false
        isConnecting = false
        pairingCode = ""
        status = "Disconnected"
        record("Disconnected by user")
    }
}
