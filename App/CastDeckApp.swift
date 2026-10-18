import SwiftUI

@main
struct CastDeckApp: App {
    @StateObject private var session = TVSessionModel()
    @AppStorage("appearanceMode") private var appearance = "system"

    init() {
        CastDeckLog.shared.write("app", "CastDeck started")
        CastDeckDiagnostics.shared.configure()
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(scheme)
        }
    }
}