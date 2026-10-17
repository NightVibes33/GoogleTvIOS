import SwiftUI

struct RemotePanel: View {
    @EnvironmentObject private var session: TVSessionModel

    var body: some View {
        CardSurface {
            VStack(spacing: 18) {
                HStack {
                    Text("Remote")
                        .font(.headline)
                    Spacer()
                    Text(session.isConnected ? "Linked" : "Offline")
                        .font(Theme.captionFont)
                        .foregroundStyle(session.isConnected ? Theme.accent : Theme.muted)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .fill(Theme.remoteShell)
                        .frame(width: 220, height: 420)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

                    VStack(spacing: 18) {
                        HStack(spacing: 28) {
                            remoteCircle("power", color: Theme.destructive) { session.send(.power) }
                            HoldMicButton()
                        }

                        dpad

                        HStack(spacing: 48) {
                            remoteCircle("chevron.backward") { session.send(.back) }
                            remoteCircle("house.fill") { session.send(.home) }
                        }

                        HStack(spacing: 36) {
                            volumeColumn
                            remoteCircle("speaker.slash.fill") { session.send(.volumeMute) }
                        }

                        remoteCircle("playpause.fill", size: 52) { session.send(.playPause) }
                    }
                    .padding(.vertical, 28)
                }
                .frame(maxWidth: .infinity)

                Text("Hold 🎙 for Gemini · release to stop")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(session.isConnected ? 1 : 0.55)
        .allowsHitTesting(session.isConnected)
    }

    private var dpad: some View {
        ZStack {
            Circle()
                .stroke(Theme.remoteWell, lineWidth: 2)
                .frame(width: 150, height: 150)
            VStack(spacing: 8) {
                remoteChevron("chevron.up") { session.send(.up) }
                HStack(spacing: 28) {
                    remoteChevron("chevron.left") { session.send(.left) }
                    Button { session.send(.ok) } label: {
                        Text("OK")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.remoteInk)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Theme.remoteWell))
                    }
                    remoteChevron("chevron.right") { session.send(.right) }
                }
                remoteChevron("chevron.down") { session.send(.down) }
            }
        }
    }

    private var volumeColumn: some View {
        VStack(spacing: 6) {
            Button { session.send(.volumeUp) } label: {
                Text("+")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.remoteInk)
                    .frame(width: 44, height: 40)
            }
            Text("VOL")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.muted)
            Button { session.send(.volumeDown) } label: {
                Text("−")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.remoteInk)
                    .frame(width: 44, height: 40)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.remoteWell)
        )
    }

    private func remoteCircle(_ system: String, color: Color = Theme.remoteInk, size: CGFloat = 44, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.remoteWell))
        }
    }

    private func remoteChevron(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.remoteInk)
                .frame(width: 36, height: 28)
        }
    }
}

struct HoldMicButton: View {
    @EnvironmentObject private var session: TVSessionModel

    var body: some View {
        Image(systemName: session.isMicHolding ? "mic.fill" : "mic")
            .font(.body.weight(.semibold))
            .foregroundStyle(session.isMicHolding ? .white : Theme.remoteInk)
            .frame(width: 52, height: 52)
            .background(Circle().fill(session.isMicHolding ? Theme.destructive : Theme.remoteWell))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !session.isMicHolding { session.micPress() }
                    }
                    .onEnded { _ in
                        session.micRelease()
                    }
            )
            .accessibilityLabel("Hold for Gemini")
    }
}
