import SwiftUI

@main
struct CastDeckApp: App {
    @StateObject private var session = TVSessionModel()
    @AppStorage("appearanceMode") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CastDeckLog.shared.write("app", "CastDeck started")
        CastDeckDiagnostics.shared.configure()
        Task { @MainActor in
            CastDeckAutoReports.shared.schedule()
        }
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await CastDeckAutoReports.shared.flush() }
                    }
                }
        }
    }
}