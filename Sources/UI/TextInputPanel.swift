import SwiftUI

/// Uses the iPhone's ordinary system keyboard with Google TV Remote v2 IME.
/// Edits are sent as the person types, not staged in a developer-style command form.
struct TextInputPanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var previous = ""
    @State private var notice: String?
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "keyboard")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)

                Text("Type on your TV")
                    .font(.title2.bold())

                Text(session.tvKeyboardAvailable ?
                     "Your iPhone keyboard types directly into the selected TV field." :
                     "First select a search box or text field on your TV.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                TextField("Start typing…", text: $text)
                    .focused($keyboardFocused)
                    .textInputAutocapitalization(.sentences)
                    .textContentType(.none)
                    .autocorrectionDisabled(false)
                    .submitLabel(.done)
                    .font(.title3)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 14))
                    .disabled(!session.isConnected || !session.tvKeyboardAvailable)
                    .onChange(of: text) { _, updated in
                        transmitChange(updated)
                    }
                    .onSubmit {
                        session.send(.enter)
                        dismiss()
                    }

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 18) {
                    Button {
                        session.send(.delete)
                        if !text.isEmpty {
                            text.removeLast()
                            previous = text
                        }
                    } label: {
                        Label("Delete", systemImage: "delete.left")
                    }
                    Button {
                        session.send(.enter)
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!session.isConnected)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .navigationTitle("TV Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if session.tvKeyboardAvailable { keyboardFocused = true }
        }
        .onChange(of: session.tvKeyboardAvailable) { _, available in
            if available { keyboardFocused = true }
        }
    }

    private func transmitChange(_ updated: String) {
        defer { previous = updated }
        guard session.isConnected, session.tvKeyboardAvailable else { return }
        if updated.hasPrefix(previous) {
            let insertion = String(updated.dropFirst(previous.count))
            if !insertion.isEmpty {
                session.sendText(insertion)
                notice = nil
            }
        } else if previous.hasPrefix(updated) {
            for _ in 0..<(previous.count - updated.count) {
                session.send(.delete)
            }
            notice = nil
        } else {
            // UIKit composition, cursor movement and edits in the middle
            // cannot safely be mapped to the TV cursor without receiving
            // its selection range. Never duplicate the whole input.
            notice = "For changes in the middle, use your TV's cursor controls."
        }
    }
}
