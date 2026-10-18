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
                Text("When you enable automatic diagnostics in Settings, CastDeck sends only predefined failure types, occurrence counts and app version over HTTPS. No work is needed from you when something goes wrong.")
                Text("The reporting service groups these anonymous summaries into issues in a private GitHub repository, accessible only to authorized maintainers.")
                Text("Raw logs, TV names, IP addresses, screen content, microphone recordings, typed text, pairing codes and private keys are never automatically uploaded.")
                Text("You can disable reports at any time. Disabling also clears pending reports from your iPhone. Reporting is unavailable until the publisher finishes configuring the secure service.")
            }

            Section("Your saved logs") {
                Text("Connection and mirroring logs are saved locally in the Files app under On My iPhone → CastDeck → Logs.")
                Text("These detailed files stay on your iPhone. They can contain local network details and are not included in automatic diagnostics.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
