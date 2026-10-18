import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("autoScan") private var autoScan = true
    @AppStorage("controlMode") private var controlMode = "dpad"
    @State private var showingDevices = false

    var body: some View {
        NavigationStack {
            Form {
                Section("TV connection") {
                    Button {
                        showingDevices = true
                    } label: {
                        LabeledContent("Select TV", value: session.selected?.name ?? "None")
                    }
                    if session.isConnected {
                        Button("Disconnect", role: .destructive) { session.disconnect() }
                    } else if let tv = session.selected, tv.supportsRemote {
                        Button("Reconnect to " + tv.name) { session.connect(to: tv) }
                    }
                    Label(session.status, systemImage: session.isConnected ? "checkmark.circle.fill" : "wifi")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Remote preferences") {
                    Toggle("Haptic feedback", isOn: $haptics)
                    Toggle("Discover TVs on launch", isOn: $autoScan)
                    Picker("Navigation style", selection: $controlMode) {
                        Text("Direction pad").tag("dpad")
                        Text("Swipe touchpad").tag("swipe")
                    }
                }

                Section("Diagnostics") {
                    ShareLink(item: session.diagnosticText,
                              subject: Text("CastDeck connection diagnostics"),
                              message: Text("Local session events without pairing PINs or private keys")) {
                        Label("Export session log", systemImage: "square.and.arrow.up")
                    }
                    LabeledContent("Discovery", value: session.discoveryDetails)
                    LabeledContent("Connection protocol", value: "Android TV Remote v2")
                    LabeledContent("Remote port", value: "TCP 6466")
                    LabeledContent("Pairing port", value: "TCP 6467")
                    Text("The app logs connection transitions and remote commands locally. It never includes pairing codes or certificate private keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Compatibility") {
                    Text("Directional remote control works with supported Google TV and Android TV devices. Older Chromecasts that only provide Google Cast do not expose this remote protocol.")
                        .font(.footnote)
                    Text("The search button opens the TV's search interface. Streaming your iPhone microphone to Assistant is not supported by the current transport.")
                        .font(.footnote)
                }

                Section("About") {
                    LabeledContent("App", value: "CastDeck")
                    LabeledContent("Version", value: "1.2")
                    Text("Independent open-source Google TV remote. Not affiliated with Google.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingDevices) {
                DevicePanel().environmentObject(session)
            }
        }
    }
}