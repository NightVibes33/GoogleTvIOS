import Foundation

/// Only short actionable copy reaches the ordinary remote UI.
/// Transport diagnostics stay in Files logs and private support reports.
enum ConsumerHelp {
    static func message(for detail: String) -> String {
        let text = detail.lowercased()
        if text.contains("pair") || text.contains("code") {
            return "That code didn't work. Check the code on your TV and try again."
        }
        if text.contains("microphone") || text.contains("voice") {
            return "Voice search isn't available right now. Try again."
        }
        if text.contains("keyboard") || text.contains("ime") || text.contains("text field") {
            return "Select a text box on your TV to start typing."
        }
        if text.contains("permission") || text.contains("network access") {
            return "Allow CastDeck to access your local network in iPhone Settings."
        }
        if text.contains("capture") || text.contains("screen sharing") {
            return "Screen sharing stopped. Tap Mirror to try again."
        }
        if text.contains("codec") || text.contains("hevc") || text.contains("4k") {
            return "Your TV couldn't play that quality. Try HD instead."
        }
        if text.contains("cast") || text.contains("stream") || text.contains("rtp") {
            return "Your TV couldn't start mirroring. Check Wi-Fi and try again."
        }
        if text.contains("timeout") || text.contains("timed out") ||
           text.contains("network") || text.contains("connect") {
            return "Couldn't reach your TV. Check Wi-Fi and try again."
        }
        return "Something didn't work. Please try again."
    }

    static func category(for detail: String) -> String {
        let text = detail.lowercased()
        if text.contains("pair") || text.contains("code") { return "pairing" }
        if text.contains("keyboard") || text.contains("ime") { return "keyboard" }
        if text.contains("microphone") || text.contains("voice") { return "voice" }
        if text.contains("cast") || text.contains("hls") || text.contains("rtp") ||
           text.contains("mirror") || text.contains("stream") { return "mirroring" }
        if text.contains("network") || text.contains("connection") { return "connection" }
        return "unknown"
    }
}
