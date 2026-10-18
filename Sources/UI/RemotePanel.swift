import SwiftUI
import UIKit

/// Remote-first, fully tappable Google TV controller. Controls never escape a fixed-size shell.
struct RemotePanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var showingKeyboard = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Remote", systemImage: "apps.iphone")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.isConnected ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(session.isConnected ? "Connected" : "Not connected")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 22) {
                HStack {
                    action("power", "Power", color: Theme.destructive) { send(.power) }
                    Spacer()
                    action("magnifyingglass", "Search") { send(.search) }
                    action("keyboard", "Open keyboard") { showingKeyboard = true }
                    action("gearshape", "TV settings") { send(.settings) }
                }
                .padding(.horizontal, 12)

                dpad

                HStack(spacing: 24) {
                    action("chevron.backward", "Back") { send(.back) }
                    Spacer()
                    action("house.fill", "Home") { send(.home) }
                    Spacer()
                    action("line.3.horizontal", "TV menu") { send(.menu) }
                }
                .padding(.horizontal, 16)

                HStack(spacing: 14) {
                    action("speaker.minus.fill", "Volume down") { send(.volumeDown) }
                    action("speaker.slash.fill", "Mute") { send(.volumeMute) }
                    action("speaker.plus.fill", "Volume up") { send(.volumeUp) }
                    Spacer(minLength: 4)
                    action("playpause.fill", "Play or pause") { send(.playPause) }
                }
                .padding(.horizontal, 5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Theme.remoteShell.gradient)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .disabled(!session.isConnected)
            .opacity(session.isConnected ? 1 : 0.63)
        }
        .sheet(isPresented: $showingKeyboard) {
            TextInputPanel().environmentObject(session)
        }
    }

    private var dpad: some View {
        ZStack {
            Circle()
                .fill(Theme.remoteWell)
                .frame(width: 252, height: 252)
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 1)
                .frame(width: 252, height: 252)

            dpadButton("chevron.up", "Up", .up).offset(y: -84)
            dpadButton("chevron.down", "Down", .down).offset(y: 84)
            dpadButton("chevron.left", "Left", .left).offset(x: -84)
            dpadButton("chevron.right", "Right", .right).offset(x: 84)

            Button { send(.ok) } label: {
                Text("OK")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(Circle().fill(Theme.remoteShell))
                    .overlay(Circle().stroke(.white.opacity(0.13)))
            }
            .accessibilityLabel("Select")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func dpadButton(_ image: String, _ label: String, _ key: TVKey) -> some View {
        Button { send(key) } label: {
            Image(systemName: image)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func action(_ image: String, _ label: String, color: Color = .white,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: image)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Theme.remoteWell))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send(_ key: TVKey) {
        if hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        session.send(key)
    }
}
