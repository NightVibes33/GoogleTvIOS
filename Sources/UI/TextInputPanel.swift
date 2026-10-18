import SwiftUI

struct TextInputPanel: View {
    @EnvironmentObject private var session: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Type for the TV", text: $text, axis: .vertical)
                        .focused($focused)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit(sendText)
                    Button("Send to TV") { sendText() }
                        .disabled(!session.isConnected || text.isEmpty || text.count > 200)
                } footer: {
                    Text("Types letters, digits and spaces using Android TV key commands into the currently focused TV field. Other symbols and secure inputs are not supported.")
                }
                Section("Editing keys") {
                    HStack {
                        Button { session.send(.delete) } label: { Label("Delete", systemImage: "delete.left") }
                        Spacer()
                        Button { session.send(.enter) } label: { Label("Enter", systemImage: "return") }
                    }
                    .disabled(!session.isConnected)
                }
            }
            .navigationTitle("TV keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func sendText() {
        guard !text.isEmpty, session.isConnected else { return }
        session.sendText(text)
        text = ""
    }
}
