import Foundation
import GoogleCast

/// Uses Google's official Cast Sender SDK, not Android TV's remote control port.
@MainActor
final class CastMediaSender: NSObject, GCKSessionManagerListener, GCKRequestDelegate, GCKRemoteMediaClientListener {
    struct Receiver: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var onState: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlaybackConfirmed: (() -> Void)?
    var onPlaybackIdle: ((String) -> Void)?
    private var sawLoadingState = false
    private var announcedIdle = false
    private var lastPlayerState: GCKMediaPlayerState?
    private var pendingRequest: GCKRequest?
    private var mediaClient: GCKRemoteMediaClient?
    private var retryTask: Task<Void, Never>?
    private var mediaURL: URL?
    private var activeReceiverID: String?
    private var loading = false
    private var listenerRegistered = false
    // Discovery is suspended by iOS when the system screen-sharing picker
    // backgrounds the sender. Keep strong GCKDevice references from selection.
    private var discoveredDevices: [String: GCKDevice] = [:]

    override init() {
        super.init()
    }

    static func configureSDK() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
    }

    func startDiscovery() {
        if !listenerRegistered {
            GCKCastContext.sharedInstance().sessionManager.add(self)
            listenerRegistered = true
        }
        GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
    }

    func availableReceivers() -> [Receiver] {
        let manager = GCKCastContext.sharedInstance().discoveryManager
        var byID: [String: Receiver] = [:]
        for index in 0..<Int(manager.deviceCount) {
            let device = manager.device(at: UInt(index))
            // The SDK can report the same device through multiple discovery paths.
            // Its unique deviceID, not the DNS-SD service instance, identifies it.
            let id = device.deviceID
            guard !id.isEmpty else { continue }
            discoveredDevices[id] = device
            let friendly = device.friendlyName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = friendly.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed Chromecast"
            byID[id] = Receiver(id: id, name: label)
        }
        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Establish the Cast session *before* presenting iOS screen sharing.
    /// ScreenCaptureKit's system picker can temporarily suspend SDK discovery.
    /// Once the video encoder has media, publish() loads it into this session.
    func prepare(receiverID: String) throws {
        startDiscovery()
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        guard let device = discovery.device(withUniqueID: receiverID) ??
                           discoveredDevices[receiverID] else {
            throw MirrorError.castFailed("Your TV is not reachable. Open Screen Mirror again and refresh your devices.")
        }
        discoveredDevices[receiverID] = device
        activeReceiverID = receiverID
        mediaURL = nil
        loading = false
        let manager = GCKCastContext.sharedInstance().sessionManager
        if let current = manager.currentSession {
            if current.device.deviceID == receiverID {
                onState?("Connected to " + (device.friendlyName ?? "your TV"))
                return
            }
            throw MirrorError.castFailed("Another Chromecast session is active. Disconnect it before mirroring.")
        }
        guard manager.startSession(with: device) else {
            throw MirrorError.castFailed("Could not open a Cast session for " + (device.friendlyName ?? "this TV"))
        }
        onState?("Opening Cast session with " + (device.friendlyName ?? "your TV"))
    }

    /// Only send the LOAD once the first HLS segment exists on the local server.
    /// If the Cast SDK is suspended by iOS, didResume will load on return.
    func publish(mediaURL: URL) {
        self.mediaURL = mediaURL
        onState?("HLS playlist available; preparing receiver playback")
        scheduleLoad()
    }

    private func scheduleLoad() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<36 {
                if Task.isCancelled || loading || mediaURL == nil { return }
                if let current = GCKCastContext.sharedInstance().sessionManager.currentSession,
                   current.device.deviceID == activeReceiverID, current.remoteMediaClient != nil {
                    load(in: current)
                    return
                }
                if attempt == 12 {
                    onState?("Waiting for Chromecast media receiver to become ready")
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if !Task.isCancelled && !loading {
                onFailure?("Chromecast media receiver never became ready after 13 seconds.")
            }
        }
    }

    /// Compatibility entry point for code that already has an encoded stream.
    func cast(receiverID: String, mediaURL: URL) throws {
        try prepare(receiverID: receiverID)
        publish(mediaURL: mediaURL)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        onState?("Cast session connected")
        if mediaURL != nil { scheduleLoad() }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKSession) {
        onState?("Cast session resumed")
        if mediaURL != nil { scheduleLoad() }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession,
                        withError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession,
                        withError error: Error?) {
        if let error { onFailure?(error.localizedDescription) }
        else { onState?("Cast session ended") }
    }

    private func load(in session: GCKSession) {
        guard !loading, let mediaURL else { return }
        guard let client = session.remoteMediaClient else {
            onState?("Cast session ready; waiting for media client")
            scheduleLoad()
            return
        }
        loading = true
        sawLoadingState = false
        announcedIdle = false
        lastPlayerState = nil
        if let old = mediaClient { old.remove(self) }
        mediaClient = client
        client.add(self)
        let metadata = GCKMediaMetadata()
        metadata.setString("CastDeck iPhone Screen", forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: mediaURL)
        builder.contentType = "application/x-mpegURL"
        builder.streamType = .live
        builder.metadata = metadata
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        let task = client.loadMedia(with: request.build())
        pendingRequest = task
        task.delegate = self
        onState?("Cast media LOAD sent: " + mediaURL.absoluteString)
    }

    func requestDidComplete(_ request: GCKRequest) {
        onState?("Cast receiver accepted the media LOAD request; waiting for playback")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        onFailure?("Cast media LOAD rejected: " + error.localizedDescription)
    }

    func reloadCompatibilityStream(mediaURL: URL) {
        onState?("Reloading Chromecast with the 1080p H.264 compatibility stream")
        loading = false
        sawLoadingState = false
        announcedIdle = false
        self.mediaURL = mediaURL
        if let current = GCKCastContext.sharedInstance().sessionManager.currentSession,
           current.device.deviceID == activeReceiverID, current.remoteMediaClient != nil {
            load(in: current)
        } else {
            scheduleLoad()
        }
    }

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let status = mediaStatus else {
            onState?("Receiver has not reported a media player yet")
            return
        }
        let state = status.playerState
        let changed = lastPlayerState != state
        lastPlayerState = state
        if state == .loading || state == .buffering || state == .playing {
            sawLoadingState = true
        }
        if state == .idle {
            let reason = status.idleReason
            let detail = "Chromecast returned to IDLE; idleReason=" + String(describing: reason)
                        + " (raw=" + String(reason.rawValue) + ")"
            if changed { onState?(detail) }
            if loading && sawLoadingState && !announcedIdle {
                announcedIdle = true
                onPlaybackIdle?(detail)
            }
        } else {
            if changed { onState?("Receiver player state: " + String(describing: state)) }
        }
        if state == .playing && changed {
            onPlaybackConfirmed?()
        }
    }


    func stop() {
        retryTask?.cancel()
        retryTask = nil
        if let client = mediaClient { client.remove(self) }
        mediaClient = nil
        pendingRequest = nil
        let manager = GCKCastContext.sharedInstance().sessionManager
        manager.currentSession?.remoteMediaClient?.stop()
        manager.endSession()
        mediaURL = nil
        activeReceiverID = nil
        loading = false
        onState?("Stopped casting")
    }
}
