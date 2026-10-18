import SwiftUI

struct AppsPanel: View {
    @EnvironmentObject private var session: TVSessionModel
    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 12) {
                Label("TV shortcuts", systemImage: "square.grid.2x2.fill")
                    .font(.headline)
                Text("Send a supported deep link to the selected TV. Apps available depend on the receiver.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    shortcut("YouTube", icon: "play.rectangle.fill", color: .red, id: "youtube")
                    shortcut("Netflix", icon: "play.square.fill", color: .black, id: "netflix")
                }
            }
        }
    }
    private func shortcut(_ title: String, icon: String, color: Color, id: String) -> some View {
        Button {
            session.launch(appId: id, name: title)
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!session.isConnected)
    }
}