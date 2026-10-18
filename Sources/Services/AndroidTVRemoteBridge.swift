import Foundation
import AndroidTVRemoteControl
import Security

/// Concrete TLS Android TV Remote v2 transport. No simulated success paths.
@MainActor
final class AndroidTVRemoteBridge {
    private let crypto: CryptoManager
    private let tls: TLSManager
    private let pairing: PairingManager
    private let remote: RemoteManager
    private let identity: SecIdentity
    private let certificate: SecCertificate

    private var host: String?
    private var connected = false
    private var awaitingPIN = false
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var pendingPairing: CheckedContinuation<Void, Error>?
    private var pendingPIN: CheckedContinuation<Void, Error>?
    private var operationID = 0
    private var voiceBuffer = Data()
    private var pendingVoice: CheckedContinuation<UInt32, Error>?
    private var voiceSession: UInt32?
    private var voiceSequence = 0
    var onConnectionLost: ((String) -> Void)?

    init() throws {
        let local = try ClientCertificateStore.load()
        identity = local.identity
        certificate = local.certificate

        let crypto = CryptoManager()
        crypto.clientPublicCertificate = {
            guard let key = SecCertificateCopyKey(local.certificate) else {
                return .Error(.noClientPublicCertificate)
            }
            return .Result(key)
        }
        let tls = TLSManager {
            let items: [[String: Any]] = [[kSecImportItemIdentity as String: local.identity]]
            return .Result(items as CFArray)
        }
        tls.secTrustClosure = { trust in
            crypto.serverPublicCertificate = {
                guard let key = SecTrustCopyKey(trust) else { return .Error(.secTrustCopyKeyError) }
                return .Result(key)
            }
        }
        self.crypto = crypto
        self.tls = tls
        pairing = PairingManager(tls, crypto)
        remote = RemoteManager(
            tls,
            CommandNetwork.DeviceInfo("CastDeck", "iPhone", "1.0", "CastDeck", "1")
        )
    }

    func connect(host: String) async throws {
        guard !host.isEmpty else { throw AndroidTVClientError.underlying("Enter a valid TV address.") }
        resetPending()
        self.host = host
        connected = false
        voiceBuffer.removeAll()
        voiceSession = nil
        remote.receiveData = { [weak self] data, error in
            guard let data, error == nil else { return }
            Task { @MainActor [weak self] in
                self?.receiveVoiceBytes(data)
            }
        }
        let id = operationID
        remote.stateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id else { return }
                switch state {
                case .paired:
                    self.connected = true
                    self.completeConnect(.success(()))
                case .error(let error):
                    self.connected = false
                    self.completeConnect(.failure(AndroidTVClientError.underlying(error.localizedDescription)))
                    self.onConnectionLost?(error.localizedDescription)
                default:
                    break
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingConnect = continuation
            remote.connect(host)
            scheduleTimeout(id: id, seconds: 13, phase: "TV connection")
        }
    }

    func startPairing(host: String) async throws {
        resetPending()
        self.host = host
        awaitingPIN = false
        let id = operationID
        pairing.stateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id else { return }
                switch state {
                case .waitingCode:
                    self.awaitingPIN = true
                    self.completePairing(.success(()))
                case .successPaired:
                    self.awaitingPIN = false
                    self.completePIN(.success(()))
                case .error(let error):
                    self.awaitingPIN = false
                    let failure = AndroidTVClientError.underlying(error.localizedDescription)
                    self.completePairing(.failure(failure))
                    self.completePIN(.failure(failure))
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingPairing = continuation
            pairing.connect(host, "CastDeck Remote", "iPhone")
            scheduleTimeout(id: id, seconds: 13, phase: "PIN pairing")
        }
    }

    func finishPairing(code: String) async throws {
        guard awaitingPIN else { throw AndroidTVClientError.underlying("TV is not ready for a PIN. Reconnect and try again.") }
        let id = operationID
        try await withCheckedThrowingContinuation { continuation in
            pendingPIN = continuation
            pairing.sendSecret(code)
            scheduleTimeout(id: id, seconds: 12, phase: "PIN verification")
        }
        pairing.disconnect()
    }

    func sendKey(_ key: TVKey) async throws {
        guard connected else { throw AndroidTVClientError.notConnected }
        let button: Key
        switch key {
        case .power: button = .KEYCODE_POWER
        case .back: button = .KEYCODE_BACK
        case .home: button = .KEYCODE_HOME
        case .up: button = .KEYCODE_DPAD_UP
        case .down: button = .KEYCODE_DPAD_DOWN
        case .left: button = .KEYCODE_DPAD_LEFT
        case .right: button = .KEYCODE_DPAD_RIGHT
        case .ok: button = .KEYCODE_DPAD_CENTER
        case .volumeUp: button = .KEYCODE_VOLUME_UP
        case .volumeDown: button = .KEYCODE_VOLUME_DOWN
        case .volumeMute: button = .KEYCODE_VOLUME_MUTE
        case .playPause: button = .KEYCODE_MEDIA_PLAY_PAUSE
        case .search: button = .KEYCODE_SEARCH
        case .menu: button = .KEYCODE_MENU
        case .settings: button = .KEYCODE_SETTINGS
        case .delete: button = .KEYCODE_DEL
        case .enter: button = .KEYCODE_ENTER
        }
        remote.send(KeyPress(button))
    }

    /// Search asks Android TV Remote Service to begin a microphone session.
    /// The television must answer with RemoteVoiceBegin and a session ID.
    /// Never claim voice is active until this handshake completes.
    func beginVoice() async throws {
        guard connected else { throw AndroidTVClientError.notConnected }
        guard voiceSession == nil, pendingVoice == nil else {
            throw AndroidTVClientError.underlying("Microphone session is already active.")
        }
        voiceBuffer.removeAll()
        voiceSequence += 1
        let request = voiceSequence
        let sessionID: UInt32 = try await withCheckedThrowingContinuation { continuation in
            pendingVoice = continuation
            remote.send(KeyPress(.KEYCODE_SEARCH))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.voiceSequence == request else { return }
                self.failVoice(AndroidTVClientError.underlying(
                    "The TV did not accept microphone input. Check Google Assistant/voice search support on the TV."
                ))
            }
        }
        guard connected else { throw AndroidTVClientError.notConnected }
        voiceSession = sessionID
        remote.send(TVVoiceWire.begin(sessionID: sessionID))
    }

    /// Receiver-compatible PCM 16-bit, 8 kHz, mono. The caller groups samples
    /// into 8192–20480-byte chunks as recommended by Android TV Remote v2.
    func sendVoicePCM(_ samples: Data) throws {
        guard connected, let sessionID = voiceSession else {
            throw AndroidTVClientError.underlying("No active TV voice session.")
        }
        guard (8 * 1024...20 * 1024).contains(samples.count),
              samples.count.isMultiple(of: 2) else {
            throw AndroidTVClientError.underlying("Invalid microphone audio packet size.")
        }
        // Raw audio never appears in logs.
        remote.send(TVVoiceWire.payload(sessionID: sessionID, audio: samples))
    }

    func endVoice() {
        voiceSequence += 1
        failVoice(CancellationError())
        if let sessionID = voiceSession, connected {
            remote.send(TVVoiceWire.end(sessionID: sessionID))
        }
        voiceSession = nil
        voiceBuffer.removeAll()
    }

    private func receiveVoiceBytes(_ bytes: Data) {
        guard pendingVoice != nil else { return }
        voiceBuffer.append(bytes)
        if voiceBuffer.count > 128 * 1024 {
            voiceBuffer.removeAll()
            failVoice(AndroidTVClientError.underlying("Malformed TV microphone response."))
            return
        }
        while let message = TVVoiceWire.nextMessage(from: &voiceBuffer) {
            if let sessionID = TVVoiceWire.voiceBeginSessionID(in: message) {
                let pending = pendingVoice
                pendingVoice = nil
                pending?.resume(returning: sessionID)
                return
            }
        }
    }

    private func failVoice(_ error: Error) {
        let pending = pendingVoice
        pendingVoice = nil
        pending?.resume(throwing: error)
    }

    func sendText(_ value: String) async throws {
        guard connected else { throw AndroidTVClientError.notConnected }
        guard !value.isEmpty, value.unicodeScalars.count <= 200 else {
            throw AndroidTVClientError.underlying("Enter 1–200 characters.")
        }
        // The upstream API supports Android KeyPress commands but has no text-input payload.
        // Validate every character before transmitting any events.
        let keys: [Key] = try value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 65...90: return Key(rawValue: UInt(scalar.value - 65 + 29))!
            case 97...122: return Key(rawValue: UInt(scalar.value - 97 + 29))!
            case 48...57: return Key(rawValue: UInt(scalar.value - 48 + 7))!
            case 32: return .KEYCODE_SPACE
            case 10, 13: return .KEYCODE_ENTER
            default: throw AndroidTVClientError.underlying(
                "Keyboard currently supports A–Z, 0–9, spaces and new lines."
            )
            }
        }
        for key in keys { remote.send(KeyPress(key)) }
    }

    func launchApp(_ appId: String) async throws {
        guard connected else { throw AndroidTVClientError.notConnected }
        // This package supports Android TV deep links, not arbitrary Android package launches.
        let url: String
        switch appId {
        case "youtube": url = "https://www.youtube.com/tv"
        case "netflix": url = "https://www.netflix.com/title"
        default: throw AndroidTVClientError.underlying("No verified deep link for this shortcut.")
        }
        remote.send(DeepLink(url))
    }

    func disconnect() {
        endVoice()
        resetPending()
        pairing.stateChanged = nil
        remote.stateChanged = nil
        remote.receiveData = nil
        pairing.disconnect()
        remote.disconnect()
        connected = false
        awaitingPIN = false
        host = nil
    }

    private func completeConnect(_ result: Swift.Result<Void, Error>) {
        guard let continuation = pendingConnect else { return }
        pendingConnect = nil
        continuation.resume(with: result)
    }
    private func completePairing(_ result: Swift.Result<Void, Error>) {
        guard let continuation = pendingPairing else { return }
        pendingPairing = nil
        continuation.resume(with: result)
    }
    private func completePIN(_ result: Swift.Result<Void, Error>) {
        guard let continuation = pendingPIN else { return }
        pendingPIN = nil
        continuation.resume(with: result)
    }
    private func resetPending() {
        endVoice()
        operationID += 1
        completeConnect(.failure(CancellationError()))
        completePairing(.failure(CancellationError()))
        completePIN(.failure(CancellationError()))
        pairing.disconnect()
        remote.disconnect()
    }
    private func scheduleTimeout(id: Int, seconds: UInt64, phase: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, self.operationID == id else { return }
            let error = AndroidTVClientError.underlying("\(phase) timed out. Check the TV and local Wi-Fi.")
            self.completeConnect(.failure(error))
            self.completePairing(.failure(error))
            self.completePIN(.failure(error))
        }
    }
}
