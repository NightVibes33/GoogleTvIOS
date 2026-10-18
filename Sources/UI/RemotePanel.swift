import SwiftUI
import UIKit

/// Familiar Google TV handheld layout adapted to fill the iPhone display.
struct RemotePanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("controlMode") private var controlMode = "dpad"
    @State private var showingKeyboard = false
    @State private var showingMicrophone = false
    @StateObject private var microphone = TVMicrophoneSession()

    let dpadSize: CGFloat
    private let remoteSurface = Color(red: 0.22, green: 0.23, blue: 0.25)
    private let keySurface = Color(red: 0.25, green: 0.26, blue: 0.28)

    var body: some View {
        VStack(spacing: 18) {
            if controlMode == "swipe" {
                swipePad
            } else {
                directionalPad
            }

            HStack(spacing: 30) {
                roundKey("arrow.uturn.backward", label: "Back", key: .back)
                Spacer(minLength: 0)
                roundKey("house.fill", label: "Home", key: .home, emphasized: true)
                Spacer(minLength: 0)
                Button { showingMicrophone = true } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(keySurface))
                }
                .buttonStyle(.plain)
                .disabled(!session.isConnected)
                .accessibilityLabel("Use iPhone microphone for TV voice search")
            }
            .padding(.horizontal, 14)

            HStack(spacing: 10) {
                roundKey("speaker.slash.fill", label: "Mute", key: .volumeMute)
                HStack(spacing: 0) {
                    volumeKey("speaker.minus.fill", label: "Volume down", key: .volumeDown)
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 1, height: 28)
                    volumeKey("speaker.plus.fill", label: "Volume up", key: .volumeUp)
                }
                .frame(height: 58)
                .background(Capsule().fill(keySurface))
            }

            HStack(spacing: 18) {
                compactKey("playpause.fill", label: "Play or pause", key: .playPause)
                Spacer()
                Button { showingKeyboard = true } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 54, height: 48)
                }
                .disabled(!session.isConnected)
                .accessibilityLabel("TV keyboard")
                Spacer()
                compactKey("line.3.horizontal", label: "TV menu", key: .menu)
                Spacer()
                compactKey("magnifyingglass", label: "Open TV search", key: .search)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingKeyboard) {
            TextInputPanel().environmentObject(session)
        }
        .sheet(isPresented: $showingMicrophone) {
            VoicePanel(voice: microphone).environmentObject(session)
        }
    }

    private var directionalPad: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [
                        Color(red: 0.27, green: 0.28, blue: 0.30),
                        remoteSurface
                    ], center: .center, startRadius: 8, endRadius: dpadSize * 0.52)
                )
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.065), lineWidth: 1)
                }
            Circle()
                .stroke(.black.opacity(0.14), lineWidth: 1)
                .padding(3)

            direction("chevron.up", label: "Up", key: .up)
                .offset(y: -dpadSize * 0.342)
            direction("chevron.down", label: "Down", key: .down)
                .offset(y: dpadSize * 0.342)
            direction("chevron.left", label: "Left", key: .left)
                .offset(x: -dpadSize * 0.342)
            direction("chevron.right", label: "Right", key: .right)
                .offset(x: dpadSize * 0.342)

            Button { send(.ok) } label: {
                Text("OK")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .frame(width: dpadSize * 0.43, height: dpadSize * 0.43)
                    .background(
                        Circle().fill(Color(red: 0.39, green: 0.40, blue: 0.43))
                    )
                    .overlay {
                        Circle().stroke(.white.opacity(0.06), lineWidth: 1)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!session.isConnected)
            .accessibilityLabel("Select")
        }
        .frame(width: dpadSize, height: dpadSize)
        .accessibilityElement(children: .contain)
    }

    private var swipePad: some View {
        ZStack {
            Circle()
                .fill(remoteSurface)
                .overlay {
                    Circle().stroke(.white.opacity(0.07), lineWidth: 1)
                }
            VStack(spacing: 10) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 30, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.46))
                Text("Swipe to navigate")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Tap to select")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .frame(width: dpadSize, height: dpadSize)
        .contentShape(Circle())
        .frame(maxWidth: .infinity, alignment: .center)
        .onTapGesture { send(.ok) }
        .gesture(
            DragGesture(minimumDistance: 22)
                .onEnded { value in
                    guard session.isConnected else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) {
                        send(dx > 0 ? .right : .left)
                    } else {
                        send(dy > 0 ? .down : .up)
                    }
                }
        )
        .accessibilityLabel("Swipe touchpad. Tap to select.")
    }

    private func direction(_ systemName: String, label: String, key: TVKey) -> some View {
        Button { send(key) } label: {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 62, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
        .accessibilityLabel(label)
    }

    private func roundKey(_ systemName: String, label: String, key: TVKey,
                          emphasized: Bool = false) -> some View {
        Button { send(key) } label: {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: emphasized ? 68 : 58, height: emphasized ? 68 : 58)
                .background(Circle().fill(emphasized ? Color(red: 0.30, green: 0.31, blue: 0.34) : keySurface))
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
        .accessibilityLabel(label)
    }

    private func volumeKey(_ systemName: String, label: String, key: TVKey) -> some View {
        Button { send(key) } label: {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
        .accessibilityLabel(label)
    }

    private func compactKey(_ systemName: String, label: String, key: TVKey) -> some View {
        Button { send(key) } label: {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 54, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
        .accessibilityLabel(label)
    }

    private func send(_ key: TVKey) {
        guard session.isConnected else { return }
        if haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        session.send(key)
    }
}
