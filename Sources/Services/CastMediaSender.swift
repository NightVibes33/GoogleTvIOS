import Foundation
import GoogleCast

/// Discovery metadata shared by the remote and native Cast Streaming sender.
/// Screen mirroring now uses the Chromecast built-in receiver, not
/// GCKRemoteMediaClient and not HLS media LOAD.
enum CastMediaSender {
    struct Receiver: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @MainActor
    static func configureSDK() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // The system display-capture picker may background our application,
        // but Cast control and RTP must remain running throughout mirroring.
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
    }
}
