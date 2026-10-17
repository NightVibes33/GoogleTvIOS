import SwiftUI

@main
struct CastDeckApp: App {
    @StateObject private var session = TVSessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}
