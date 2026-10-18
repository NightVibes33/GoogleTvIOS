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
        // The sender SDK selects which receiver to launch from discovery criteria.
// Use the built-in Cast Streaming receiver, not the Default Media Receiver.
        let criteria = GCKDiscoveryCriteria(applicationID: "0F5096E8")
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // The system display-capture picker may background our application,
        // but Cast control and RTP must remain running throughout mirroring.
        options.suspendSessionsWhenBackgrounded = false
        // Do not send Google's default Cast discovery analytics independently
        // of CastDeck's explicit, opt-in support reporting preference.
        options.disableAnalyticsLogging = true
        GCKCastContext.setSharedInstanceWith(options)
    }
}
