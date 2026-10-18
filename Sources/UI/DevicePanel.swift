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
                    Section("Current TV") {
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

                Section("Nearby devices") {
                    if session.devices.isEmpty {
                        ContentUnavailableView(
                            "No nearby TVs yet",
                            systemImage: "tv.slash",
                            description: Text(session.isScanning ? "Searching for Google TV and Chromecast…" : "Enter your TV's IP address below, or check Local Network access.")
                        )
                    }
                    ForEach(session.devices) { device in
                        Button {
                            session.connect(to: device)
                            if device.supportsRemote && !session.isPairing { ipFocused = false }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: device.supportsRemote ? "tv.fill" : "airplayvideo")
                                    .font(.title3)
                                    .frame(width: 34)
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.host.isEmpty ? "Resolving network address…" :
                                        device.supportsRemote ? "Google TV remote · " + device.host :
                                        "Chromecast discovered · " + device.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(device.host.isEmpty)
                    }
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