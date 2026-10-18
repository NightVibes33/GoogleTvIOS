import SwiftUI
import UIKit

struct DevicePanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualIP = ""
    @FocusState private var ipFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { session.scan() } label: {
                        HStack {
                            Label("Scan local network", systemImage: "arrow.clockwise")
                            Spacer()
                            if session.isScanning { ProgressView() }
                        }
                    }
                    .disabled(session.isScanning)
                    Text(session.discoveryDetails)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open Local Network permissions", systemImage: "gearshape")
                    }
                } footer: {
                    Text("Keep the TV on and on the same Wi-Fi. If the list is empty, allow Local Network for CastDeck in iPhone Settings, disable guest-network isolation, or enter the TV IP below.")
                }

                if let selected = session.selected {
                    Section("My TV") {
                        HStack {
                            Image(systemName: "tv.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(selected.name)
                                    .font(.headline)
                                Text(selected.host)
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
                    if session.devices.isEmpty {
                        ContentUnavailableView(
                            "Looking for your TV",
                            systemImage: "tv",
                            description: Text(session.isScanning ?
                                "Finding TVs on your Wi-Fi network…" :
                                "No TV resolved yet. Scan again or enter its IP address below.")
                        )
                    }
                    ForEach(session.devices) { device in
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
                        Text("\(session.devices.count) found")
                            .textCase(nil)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Each physical television is shown once. Google TV devices support remote control; Cast-only receivers are available from Screen Mirror on the remote.")
                }

                Section {
                    HStack {
                        TextField("TV IP address or hostname", text: $manualIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($ipFocused)
                            .submitLabel(.go)
                            .onSubmit(connectManual)
                        Button("Connect", action: connectManual)
                            .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Connect manually")
                } footer: {
                    Text("Manual entry uses the Android TV Remote v2 service on TCP port 6466.")
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
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect to TV")
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
                Text(device.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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