import SwiftUI

struct AppsPanel: View {
    @EnvironmentObject private var session: TVSessionModel

    private let apps: [(name: String, id: String, color: Color)] = [
        ("YouTube", "com.google.android.youtube.tv", .red),
        ("Netflix", "com.netflix.ninja", .black),
        ("Disney+", "com.disney.disneyplus", Color(red: 0.05, green: 0.1, blue: 0.3)),
        ("Prime", "com.amazon.amazonvideo.livingroom", Color(red: 0, green: 0.66, blue: 0.88)),
    ]

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick launch")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(apps, id: \.id) { app in
                        Button {
                            session.launch(appId: app.id, name: app.name)
                        } label: {
                            Text(app.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(app.color)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.isConnected)
                    }
                }
            }
        }
    }
}
