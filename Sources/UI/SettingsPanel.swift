import SwiftUI

/// Consumer-facing preferences: everyday controls first, diagnostics tucked away.
struct SettingsPanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("autoScan") private var autoScan = true
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("controlMode") private var controlMode = "dpad"
    @State private var showingDevices = false
    @State private var showDiagnostics = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingDevices = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tv.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.indigo)
                                .frame(width: 42, height: 42)
                                .background(Color.indigo.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.selected?.name ?? "Connect a TV")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(session.isConnected ? "Ready to control" : "Tap to choose your TV")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if session.isConnected {
                        Button("Disconnect TV", role: .destructive) {
                            session.disconnect()
                        }
                    }
                } header: { Text("My television") }

                Section("Remote") {
                    Picker("Touch controls", selection: $controlMode) {
                        Text("Directional pad").tag("dpad")
                        Text("Swipe to navigate").tag("swipe")
                    }
                    Toggle("Button feedback", isOn: $haptics)
                    Toggle("Reconnect automatically", isOn: $autoReconnect)
                    Toggle("Find TVs automatically", isOn: $autoScan)
                }

                Section {
                    DisclosureGroup(isExpanded: $showDiagnostics) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("To find saved logs, open Files → Browse → On My iPhone → CastDeck → Logs.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            LabeledContent("Discovered TVs", value: "\(session.devices.count)")
                            LabeledContent("Network", value: session.isConnected ? "Connected" : "Not connected")
                            Text("Logs are stored only on this iPhone. Pairing codes and private keys are never written.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        ShareLink(item: CastDeckLog.shared.currentLogURL) {
                            Label("Share current log file", systemImage: "square.and.arrow.up")
                        }
                        ShareLink(item: session.diagnosticText) {
                            Label("Share connection summary", systemImage: "doc.text")
                        }
                    } label: {
                        Label("Help & diagnostics", systemImage: "questionmark.circle")
                    }
                } footer: {
                    Text("Connection troubleshooting and log files are available here whenever you need them.")
                }

                Section {
                    LabeledContent("App", value: "CastDeck")
                    LabeledContent("Version", value: version)
                    Text("A simple remote for compatible Google TV and Chromecast devices. Not affiliated with Google.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingDevices) {
                DevicePanel().environmentObject(session)
            }
        }
        .presentationDragIndicator(.visible)
    }
}
