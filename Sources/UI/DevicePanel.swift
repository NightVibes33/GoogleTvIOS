import SwiftUI
import UIKit

struct DevicePanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualIP = ""
    @State private var troubleshooting = false
    @FocusState private var ipFocused: Bool

    /// The connected receiver lives only under "My TV", never again in
    /// "Nearby TVs". A hostname can change to a resolved IPv4 during scanning.
    private var nearbyDevices: [TVDevice] {
        guard session.isConnected, let connected = session.selected else {
            return session.devices
        }
        let sameName = session.devices.filter {
            $0.name.localizedCaseInsensitiveCompare(connected.name) == .orderedSame
        }
        return session.devices.filter { device in
            if device.host == connected.host { return false }
            // If Bonjour uses the numeric IP and the saved TV uses .local,
            // matching a unique friendly name also identifies the same TV.
            if sameName.count == 1 && device.name.localizedCaseInsensitiveCompare(connected.name) == .orderedSame {
                return false
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { session.scan() } label: {
                        HStack(spacing: 12) {
                            Label(session.isScanning ? "Searching for TVs…" : "Find nearby TVs",
                                  systemImage: "arrow.clockwise")
                            Spacer()
                            if session.isScanning { ProgressView() }
                        }
                    }
                    .disabled(session.isScanning)
                } footer: {
                    Text("Keep your TV and iPhone connected to the same Wi-Fi.")
                }

                if let selected = session.selected {
                    Section("My TV") {
                        HStack {
                            Image(systemName: "tv.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(selected.name)
                                    .font(.headline)
                                Text(session.isConnected ? "Connected" : "Ready to connect")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.isConnected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if session.isConnecting { ProgressView() }
                        }
                        if session.isConnected {
                            Button("Disconnect", role: .destructive) { session.disconnect() }
                        } else if selected.supportsRemote && !session.isConnecting && !session.isPairing {
                            Button("Reconnect") { session.connect(to: selected) }
                        }
                    }
                }

                Section {
                    if nearbyDevices.isEmpty {
                        ContentUnavailableView(
                            session.isConnected ? "No other TVs found" : "Looking for your TV",
                            systemImage: "tv",
                            description: Text(session.isScanning ?
                                "Searching for other televisions…" :
                                session.isConnected ? "You're already connected to your TV." :
                                "No TV found yet. Scan again or enter its IP address below.")
                        )
                    }
                    ForEach(nearbyDevices) { device in
                        if device.supportsRemote {
                            Button {
                                session.connect(to: device)
                                ipFocused = false
                            } label: {
                                deviceRow(device, tappable: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            deviceRow(device, tappable: false)
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby televisions")
                        Spacer()
                        Text("\(nearbyDevices.count) available")
                            .textCase(nil)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Each physical television is shown once. Google TV devices support remote control; Cast-only receivers are available from Screen Mirror on the remote.")
                }

                Section {
                    DisclosureGroup(isExpanded: $troubleshooting) {
                        Text("If your TV does not appear, you can connect using its local IP address.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("TV IP address", text: $manualIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($ipFocused)
                            .submitLabel(.go)
                            .onSubmit(connectManual)
                        Button("Connect using IP", action: connectManual)
                            .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        } label: {
                            Label("Check iPhone network access", systemImage: "wifi")
                        }
                        Text("If your TV doesn't appear, check that both devices are on the same Wi-Fi.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } label: {
                        Label("Can't find your TV?", systemImage: "questionmark.circle")
                    }
                }

                if session.isPairing {
                    Section("Pair with Google TV") {
                        Text("Find the code on your TV screen. It contains six characters from 0–9 and A–F.")
                            .font(.subheadline)
                        TextField("Six-character TV code", text: $session.pairingCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .font(.system(.title3, design: .monospaced))
                        Button("Verify pairing code") {
                            session.submitPairingCode()
                        }
                        .disabled(session.isConnecting || session.pairingCode.count != 6)
                    }
                }

                if session.isConnecting {
                    HStack {
                        ProgressView()
                        Text(session.status)
                    }
                }
                if let error = session.lastError {
                    Section("Connection details") {
                        Label(ConsumerHelp.message(for: error), systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Your TVs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if session.devices.isEmpty && !session.isScanning { session.scan() }
        }
        .presentationDragIndicator(.visible)
    }

    private func deviceRow(_ device: TVDevice, tappable: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.supportsRemote ? "tv.fill" : "display")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(device.supportsRemote ? Theme.accent : Color.secondary)
                .frame(width: 48, height: 48)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(device.supportsRemote ? "Google TV · Remote + Cast" : "Chromecast · Screen mirroring")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if session.isConnected && session.selected?.host == device.host {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Connected")
            } else if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Screen mirroring available")
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func connectManual() {
        let host = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains(" "),
              !host.contains("://") else {
            session.lastError = "Enter only the TV IP address or hostname."
            return
        }
        ipFocused = false
        session.connect(to: TVDevice(name: host, host: host, port: 6466))
    }
}