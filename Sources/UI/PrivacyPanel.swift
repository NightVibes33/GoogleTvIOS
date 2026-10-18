import SwiftUI

/// Accessible, consumer-facing explanation of privacy controls. This page
/// does not expose protocol logs, IP addresses or technical diagnostic codes.
struct PrivacyPanel: View {
    var body: some View {
        List {
            Section {
                Label("Your remote works directly over your home Wi-Fi.",
                      systemImage: "wifi")
                Label("Voice and screen sharing start only when you choose them.",
                      systemImage: "hand.tap")
                Label("Your keyboard input is sent to the selected TV.",
                      systemImage: "keyboard")
            } header: {
                Text("You're in control")
            }

            Section("Help improve CastDeck") {
                Text("If you choose to share crash and issue reports in Settings, CastDeck can send technical information about app failures and the app version to the publisher's diagnostics service.")
                Text("We don't automatically attach your screen, microphone recordings, typed text, pairing codes, private keys, or your detailed Files logs.")
                Text("You can turn this option off in Settings at any time. Automatic reporting is unavailable until the publisher enables the diagnostics service.")
            }

            Section("Your saved logs") {
                Text("Connection and mirroring logs are saved locally in the Files app under On My iPhone → CastDeck → Logs.")
                Text("You decide whether to share those files. They may include local network addresses or TV names, so review them before sending.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
