import SwiftUI

/// Design tokens — shadcn-inspired calm surfaces for iOS (Mobai-adjacent polish).
enum Theme {
    static let background = Color(red: 0.985, green: 0.986, blue: 0.990)
    static let card = Color.white
    static let foreground = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let muted = Color(red: 0.45, green: 0.45, blue: 0.50)
    static let border = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let accent = Color(red: 0.18, green: 0.48, blue: 0.42) // cast-green, not purple
    static let accentSoft = Color(red: 0.18, green: 0.48, blue: 0.42).opacity(0.12)
    static let destructive = Color(red: 0.86, green: 0.25, blue: 0.25)
    static let remoteShell = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let remoteWell = Color(red: 0.20, green: 0.22, blue: 0.26)
    static let remoteInk = Color(red: 0.94, green: 0.95, blue: 0.96)

    static let radius: CGFloat = 14
    static let radiusLG: CGFloat = 22

    static let titleFont = Font.system(.title2, design: .rounded).weight(.semibold)
    static let bodyFont = Font.system(.body, design: .default)
    static let captionFont = Font.system(.caption, design: .default)
}

struct CardSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
