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
                Text("When you enable diagnostics, CastDeck automatically sends the failure type, iPhone model identifier, iOS version, app version/build, UTC time and up to 80 redacted log lines over HTTPS. You do not have to send files manually.")
                Text("The reporting service groups reports in private GitHub issues accessible only to authorized maintainers. Recent redacted log excerpts are sampled rather than attaching every user's full files.")
                Text("Complete raw log files, known network identifiers, URLs, screen content, audio, typed text, pairing codes and credentials are excluded from automatic reports. The app and server both filter sensitive details.")
                Text("You can disable reports at any time. Disabling also clears pending reports from your iPhone. Reporting is unavailable until the publisher finishes configuring the secure service.")
            }

            Section("Your saved logs") {
                Text("Connection and mirroring logs are saved locally in the Files app under On My iPhone → CastDeck → Logs.")
                Text("The complete files stay on your iPhone. When reporting is enabled, only a short filtered excerpt may be included in automatic diagnostics.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
