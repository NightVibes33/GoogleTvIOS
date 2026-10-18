import SwiftUI

enum Theme {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let foreground = Color.primary
    static let muted = Color.secondary
    static let border = Color(uiColor: .separator).opacity(0.34)
    static let accent = Color(red: 0.19, green: 0.58, blue: 0.49)
    static let accentSoft = accent.opacity(0.13)
    static let destructive = Color(red: 0.92, green: 0.29, blue: 0.30)
    static let remoteShell = Color(red: 0.12, green: 0.14, blue: 0.17)
    static let remoteWell = Color(red: 0.21, green: 0.24, blue: 0.28)
    static let remoteInk = Color.white

    static let radius: CGFloat = 20
    static let titleFont = Font.system(.title2, design: .rounded).weight(.bold)
    static let captionFont = Font.system(.caption)
}

struct CardSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}