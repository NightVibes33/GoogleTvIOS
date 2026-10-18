import Foundation
import GoogleCast

/// Uses Google's official Cast Sender SDK, not Android TV's remote control port.
@MainActor
final class CastMediaSender: NSObject, GCKSessionManagerListener {
    struct Receiver: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var onState: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
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
        let manager = GCKCastContext.sharedInstance().sessionManager
        if let current = manager.currentSession,
           current.device.deviceID == activeReceiverID {
            load(in: current)
        } else {
            onState?("Screen stream is ready; finishing connection to Chromecast")
        }
    }

    /// Compatibility entry point for code that already has an encoded stream.
    func cast(receiverID: String, mediaURL: URL) throws {
        try prepare(receiverID: receiverID)
        publish(mediaURL: mediaURL)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        load(in: session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResume session: GCKSession) {
        load(in: session)
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
        loading = true
        let metadata = GCKMediaMetadata()
        metadata.setString("CastDeck iPhone Screen", forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: mediaURL)
        builder.contentType = "application/x-mpegURL"
        builder.streamType = .live
        builder.metadata = metadata
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        guard let remoteClient = session.remoteMediaClient else {
            loading = false
            onFailure?("Connected receiver has no Google Cast media client.")
            return
        }
        remoteClient.loadMedia(with: request.build())
        onState?("Sent live HLS load request to Chromecast")
    }

    func stop() {
        let manager = GCKCastContext.sharedInstance().sessionManager
        manager.currentSession?.remoteMediaClient?.stop()
        manager.endSession()
        mediaURL = nil
        activeReceiverID = nil
        loading = false
        onState?("Stopped casting")
    }
}
