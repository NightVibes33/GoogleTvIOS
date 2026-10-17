import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: TVSessionModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    DevicePanel()
                    RemotePanel()
                    AppsPanel()
                    statusFooter
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("CastDeck")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Google TV Remote")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.foreground)
            Text("Native iOS · same Wi‑Fi as your Chromecast / Google TV")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.muted)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.status)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.muted)
            if let err = session.lastError {
                Text(err)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
    }
}
