import SwiftUI

/// The screen itself is the remote: no tab bar, dashboard cards, or scrolling handset.
struct RootView: View {
    @EnvironmentObject private var session: TVSessionModel
    @AppStorage("autoScan") private var autoScan = true
    @State private var devicePicker = false
    @State private var settings = false
    @State private var showingMirror = false
    @StateObject private var mirror = RealtimeMirrorSession()
    @State private var scanned = false

    private let background = Color(red: 0.105, green: 0.112, blue: 0.124)

    var body: some View {
        GeometryReader { geometry in
            let padSize = min(294, max(202, min(geometry.size.width - 48, geometry.size.height * 0.37)))
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(session.isConnected ? "Connected" : session.isConnecting ? "Connecting…" : "Not connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.64))
                    Spacer()
                    if session.isScanning { ProgressView().tint(.white) }
                    if session.isPairing {
                        Button("Enter TV code") { devicePicker = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 8)

                RemotePanel(dpadSize: padSize)

                Spacer(minLength: 8)

                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $devicePicker) {
            DevicePanel().environmentObject(session)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $settings) {
            SettingsPanel().environmentObject(session)
        }
        .sheet(isPresented: $showingMirror) {
            MirrorPanel(mirror: mirror)
        }
        .onAppear {
            guard !scanned else { return }
            scanned = true
            if autoScan { session.scan() }
            if session.selected == nil { devicePicker = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { devicePicker = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tv")
                        .font(.system(size: 17, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.selected?.name ?? "Choose a TV")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        Text(session.isConnected ? "Connected" : "Tap to connect")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.57))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a television")
            Spacer()
            Button {
                showingMirror = true
            } label: {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(mirror.isMirroring ? .green : .white.opacity(0.86))
                    .frame(width: 42, height: 44)
            }
            .accessibilityLabel("Screen mirror to Chromecast")

            Button {
                settings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Remote settings")

            Button {
                session.send(.power)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .disabled(!session.isConnected)
            .accessibilityLabel("TV power")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = session.lastError {
                Button {
                    devicePicker = true
                } label: {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.65))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
            } else if !session.isConnected {
                Button {
                    devicePicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                        Text(session.isScanning ? "Searching for your TV…" : "Select TV to enable remote")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text("CastDeck")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(minHeight: 34)
    }
}
