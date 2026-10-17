import SwiftUI

struct DevicePanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @State private var manualIP = ""

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Devices")
                        .font(.headline)
                        .foregroundStyle(Theme.foreground)
                    Spacer()
                    Button {
                        session.scan()
                    } label: {
                        if session.isScanning {
                            ProgressView()
                        } else {
                            Label("Scan", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                    .disabled(session.isScanning)
                }

                if session.devices.isEmpty {
                    Text("No devices yet. Scan, or connect by IP.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    ForEach(session.devices) { device in
                        Button {
                            session.connect(to: device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.foreground)
                                    Text(device.host)
                                        .font(Theme.captionFont)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if session.selected?.id == device.id, session.isConnected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(session.selected?.id == device.id ? Theme.accentSoft : Theme.background)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    TextField("TV IP (e.g. 192.168.4.43)", text: $manualIP)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                    Button("Connect") {
                        let ip = manualIP.trimmingCharacters(in: .whitespaces)
                        guard !ip.isEmpty else { return }
                        session.connect(to: TVDevice(name: "TV", host: ip, port: 6466))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }

                if session.isPairing {
                    Divider()
                    Text("PIN on TV")
                        .font(.subheadline.weight(.semibold))
                    TextField("ABCDEF", text: $session.pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Submit PIN") {
                        session.submitPairingCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                }

                if session.isConnected {
                    Button("Disconnect", role: .destructive) {
                        session.disconnect()
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}
