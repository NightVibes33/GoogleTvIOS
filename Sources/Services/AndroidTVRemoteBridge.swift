import Foundation
import AndroidTVRemoteControl
import Security

/// Concrete TLS Android TV Remote v2 transport. No simulated success paths.
@MainActor
final class AndroidTVRemoteBridge: AndroidTVBridging {
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
            remote.connect(host, timeout: 12)
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
            pairing.connect(host, "CastDeck Remote", "iPhone", timeout: 12)
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
        }
        remote.send(KeyPress(button))
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
        resetPending()
        pairing.stateChanged = nil
        remote.stateChanged = nil
        pairing.disconnect()
        remote.disconnect()
        connected = false
        awaitingPIN = false
        host = nil
    }

    private func completeConnect(_ result: Result<Void, Error>) {
        guard let continuation = pendingConnect else { return }
        pendingConnect = nil
        continuation.resume(with: result)
    }
    private func completePairing(_ result: Result<Void, Error>) {
        guard let continuation = pendingPairing else { return }
        pendingPairing = nil
        continuation.resume(with: result)
    }
    private func completePIN(_ result: Result<Void, Error>) {
        guard let continuation = pendingPIN else { return }
        pendingPIN = nil
        continuation.resume(with: result)
    }
    private func resetPending() {
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
