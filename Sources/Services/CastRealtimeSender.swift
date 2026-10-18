import Foundation
import GoogleCast

/// Talks to Chromecast's *built-in* real-time mirroring receiver (0F5096E8).
/// In contrast with Cast Media Receiver, this has no media LOAD or HLS URL.
@MainActor
final class CastRealtimeSender: NSObject, GCKSessionManagerListener {
    typealias Receiver = CastMediaSender.Receiver
    static let appID = "0F5096E8"

    var onEvent: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onNegotiated: (() -> Void)?
    var onVideoPacket: (() -> Void)?
    var onKeyframeNeeded: (() -> Void)?

    private let discovery = GCKCastContext.sharedInstance().discoveryManager
    private let manager = GCKCastContext.sharedInstance().sessionManager
    private var cached: [String: GCKDevice] = [:]
    private var activeReceiverID: String?
    private var channel: CastMirrorChannel?
    private(set) var transport: CastRealtimeWire?
    private var sessionHost = ""
    private var desired4K = false
    private var negotiating = false
    private var configured = false
    private(set) var negotiated4K = false

    override init() {
        super.init()
        manager.add(self)
    }

    func refresh() -> [Receiver] {
        discovery.startDiscovery()
        var result = [String: Receiver]()
        for i in 0..<Int(discovery.deviceCount) {
            let device = discovery.device(at: UInt(i))
            cached[device.deviceID] = device
            result[device.deviceID] = Receiver(id: device.deviceID,
                name: device.friendlyName ?? "Chromecast")
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(receiverID: String, quality4K: Bool) throws {
        guard let device = discovery.device(withUniqueID: receiverID) ?? cached[receiverID] else {
            throw RealtimeMirrorError.receiver("Your Chromecast isn't visible. Refresh nearby TVs.")
        }
        activeReceiverID = receiverID
        sessionHost = device.ipAddress
        desired4K = quality4K
        negotiated4K = false
        configured = false
        negotiating = true
        transport?.stop()
        transport = nil
        onEvent?("Opening built-in Chromecast mirroring receiver " + Self.appID)
        if let previous = manager.currentCastSession {
            if previous.device.deviceID != receiverID {
                throw RealtimeMirrorError.receiver("Stop the previous Cast session before mirroring to another TV.")
            }
            attach(to: previous)
            return
        }
        // The Cast SDK's session options allow choosing the built-in streaming
        // receiver instead of its Default Media Receiver for this session.
        let options: GCKSessionOptions = ["gck_applicationID": Self.appID]
        guard manager.startSession(with: device, sessionOptions: options) else {
            throw RealtimeMirrorError.receiver("Could not launch the Chromecast mirroring receiver.")
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        if let cast = session as? GCKCastSession, cast.device.deviceID == activeReceiverID {
            onEvent?("Chromecast mirroring app connected")
            attach(to: cast)
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKSession) {
        if let cast = session as? GCKCastSession, cast.device.deviceID == activeReceiverID {
            onEvent?("Chromecast mirroring session resumed")
            attach(to: cast)
        }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession,
                        withError error: Error) {
        onFailure?("Built-in mirroring receiver launch failed: " + error.localizedDescription)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession,
                        withError error: Error?) {
        guard negotiating || transport != nil else { return }
        onFailure?("Chromecast real-time mirroring session ended" +
                   (error.map { ": " + $0.localizedDescription } ?? ""))
    }

    private func attach(to session: GCKCastSession) {
        guard !configured else { return }
        configured = true
        let channel = CastMirrorChannel(namespace: "urn:x-cast:com.google.cast.webrtc")
        self.channel = channel
        channel.onConnected = { [weak self] in self?.sendOffer() }
        channel.onMessage = { [weak self] json in self?.handleMessage(json) }
        session.add(channel)
        if channel.isWritable { sendOffer() }
        onEvent?("Connected to Chromecast real-time control namespace")
    }

    private var streamOffer: CastRealtimeWire.Offer?
    private var streamAudioOffer: CastRealtimeWire.Offer?
    private(set) var audioNegotiated = false
    private func sendOffer() {
        guard negotiating, let channel else { return }
        let offer = CastRealtimeWire.Offer.video(codec: desired4K ? "hevc" : "h264")
        streamOffer = offer
        let audio = CastRealtimeWire.Offer.audio()
        streamAudioOffer = audio
        let size = desired4K ? (3840, 2160) : (1920, 1080)
        let payload: [String: Any] = [
            "type": "OFFER",
            "seqNum": 1,
            "offer": [
                "castMode": "mirroring",
                "supportedStreams": [
                    offer.json(width: size.0, height: size.1,
                               bitrate: desired4K ? 11_000_000 : 3_500_000),
                    audio.audioJSON()
                ]
            ]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let message = String(data: data, encoding: .utf8) else { return }
            var error: GCKError?
            if !channel.sendTextMessage(message, error: &error) {
                throw RealtimeMirrorError.receiver(error?.localizedDescription ?? "OFFER could not be sent")
            }
            onEvent?("Sent real-time " + (desired4K ? "4K HEVC" : "1080p H.264") +
                     " OFFER; waiting for receiver-selected RTP parameters")
        } catch {
            onFailure?("Cast Streaming OFFER failed: " + error.localizedDescription)
        }
    }

    private func handleMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if root["type"] as? String != "ANSWER" { return }
        guard negotiating, let offer = streamOffer else { return }
        let accepted = (root["result"] as? String)?.lowercased() == "ok"
        guard accepted, let answer = root["answer"] as? [String: Any] else {
            let reason = (root["error"] as? [String: Any])?["description"] as? String ?? "Receiver rejected the codec"
            if desired4K {
                onEvent?("Chromecast rejected 4K; retrying real-time 1080p H.264: " + reason)
                desired4K = false
                sendOffer()
            } else {
                onFailure?("Chromecast rejected real-time H.264 streaming: " + reason)
            }
            return
        }
        guard let udp = answer["udpPort"] as? Int, (1...65535).contains(udp),
              let indexes = answer["sendIndexes"] as? [Int], indexes.contains(0),
              !sessionHost.isEmpty else {
            onFailure?("Chromecast answered without an acceptable video RTP stream.")
            return
        }
        negotiating = false
        negotiated4K = desired4K
        audioNegotiated = indexes.contains(1)
        if !audioNegotiated {
            onEvent?("TV declined AAC system audio; video can still mirror")
        }
        let transport = CastRealtimeWire(
            offer: offer, audioOffer: audioNegotiated ? streamAudioOffer : nil)
        transport.onEvent = { [weak self] message in
            Task { @MainActor in self?.onEvent?(message) }
        }
        transport.onPacketLoss = { [weak self] in
            Task { @MainActor in self?.onKeyframeNeeded?() }
        }
        transport.onReady = { [weak self] in
            Task { @MainActor in
                self?.onEvent?("Chromecast RTP ready; starting live capture")
                self?.onNegotiated?()
            }
        }
        self.transport = transport
        transport.connect(host: sessionHost, udpPort: UInt16(udp))
        onEvent?("Chromecast accepted " + (desired4K ? "HEVC" : "H.264") +
                 "; UDP port " + String(udp) + ", RTP SSRC " + String(offer.ssrc))
    }

    func sendVideo(_ frame: Data, pts: UInt32, keyFrame: Bool) {
        transport?.sendFrame(frame, timestamp: pts, keyFrame: keyFrame)
    }

    func sendAudio(_ packet: Data, pts: UInt32) {
        guard audioNegotiated else { return }
        transport?.sendAudio(packet, timestamp: pts)
    }

    func stop() {
        negotiating = false
        configured = false
        transport?.stop()
        transport = nil
        if let channel, let session = manager.currentCastSession {
            session.remove(channel)
        }
        channel = nil
        activeReceiverID = nil
        streamOffer = nil
        streamAudioOffer = nil
        audioNegotiated = false
        manager.endSession()
        onEvent?("Stopped real-time Chromecast streaming")
    }

    deinit {}
}

final class CastMirrorChannel: GCKCastChannel {
    var onConnected: (() -> Void)?
    var onMessage: ((String) -> Void)?

    override func didConnect() { onConnected?() }
    override func didReceiveTextMessage(_ message: String) { onMessage?(message) }
}

enum RealtimeMirrorError: LocalizedError {
    case receiver(String)
    case capture(String)
    var errorDescription: String? {
        switch self {
        case .receiver(let text): return text
        case .capture(let text): return text
        }
    }
}
