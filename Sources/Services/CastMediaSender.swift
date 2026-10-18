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
            let friendly = device.friendlyName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = friendly.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed Chromecast"
            byID[id] = Receiver(id: id, name: label)
        }
        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func cast(receiverID: String, mediaURL: URL) throws {
        guard let device = GCKCastContext.sharedInstance().discoveryManager
            .device(withUniqueID: receiverID) else {
            throw MirrorError.castFailed("Receiver is no longer visible to the Google Cast SDK. Refresh the device list.")
        }
        self.mediaURL = mediaURL
        self.activeReceiverID = receiverID
        self.loading = false
        let manager = GCKCastContext.sharedInstance().sessionManager
        if let current = manager.currentSession, current.device.deviceID == receiverID {
            load(in: current)
            return
        }
        guard manager.startSession(with: device) else {
            throw MirrorError.castFailed("Google Cast SDK could not start a session.")
        }
        onState?("Connecting to " + (device.friendlyName ?? "Chromecast"))
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
