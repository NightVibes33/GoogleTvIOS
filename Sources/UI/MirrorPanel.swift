import SwiftUI

/// Dedicated receiver picker and capture controls; the remote's original layout
/// remains intact. Google Cast discovery is separate from Android TV remote pairing.
struct MirrorPanel: View {
    @ObservedObject var mirror: RealtimeMirrorSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReceiver: String?
    @State private var scanStarted = false
    @State private var showingDetails = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(
                                    LinearGradient(colors: [.indigo, .blue],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Screen Mirror")
                                    .font(.title2.weight(.bold))
                                Text("iPhone → Chromecast")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("Mirror your iPhone directly to Chromecast over local Wi-Fi. No HLS or screen recordings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label(
                            mirror.isMirroring ? "Sharing with your TV" :
                            mirror.isStarting ? "Preparing your screen…" :
                            mirror.error != nil ? "Could not start sharing" : "Ready to connect",
                            systemImage: mirror.isMirroring ? "checkmark.circle.fill" : "tv"
                        )
                        .font(.subheadline)
                        .foregroundStyle(mirror.isMirroring ? .green : .secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    HStack {
                        Text("Available TVs").font(.headline)
                        Spacer()
                        Button {
                            mirror.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Scan for Chromecast devices")
                    }
                        if mirror.receivers.isEmpty {
                        ContentUnavailableView("Searching for Cast devices",
                                               systemImage: "tv",
                                               description: Text("Both devices must use the same Wi-Fi. Give Google Cast discovery a few seconds."))
                    }
                    ForEach(mirror.receivers) { device in
                        Button {
                            selectedReceiver = device.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tv.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Google Cast · Ready to share")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedReceiver == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .disabled(mirror.isStarting || mirror.isMirroring)
                    }
                } header: {
                    Text("Choose a receiver")
                } footer: {
                    Text("TV names come from each Chromecast's advertised friendly name. Identical discovery records are combined by device ID.")
                }

                Section("Live mirroring quality") {
                    Picker("Output resolution", selection: $mirror.quality4K) {
                        Text("1080p").tag(false)
                        Text("4K · Beta").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(mirror.isStarting || mirror.isMirroring)
                    Label("Rotate iPhone for full-screen video", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Landscape fills your television automatically. Portrait keeps the full phone screen visible. 1080p H.264 is compatible with more TVs; 4K HEVC is negotiated only if your Chromecast accepts it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if mirror.isStarting {
                        HStack {
                            ProgressView()
                            Text("Connecting real-time stream…")
                        }
                        Button("Cancel mirror startup", role: .destructive) { mirror.stop() }
                    } else if mirror.isMirroring {
                        Button(role: .destructive) { mirror.stop() } label: {
                            Label("Stop screen mirroring", systemImage: "stop.circle.fill")
                        }
                    } else {
                        Button {
                            guard let selectedReceiver else { return }
                            mirror.start(receiverID: selectedReceiver)
                        } label: {
                            Label("Start Mirroring", systemImage: "rectangle.on.rectangle.angled")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedReceiver == nil)
                    }
                    if let error = mirror.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Mirroring requires iOS 27. Your iPhone will ask permission before sharing. Some protected video or audio cannot be shared.")
                }

                Section {
                    DisclosureGroup(isExpanded: $showingDetails) {
                        Text(mirror.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Detailed logs are automatically saved to Files → On My iPhone → CastDeck → Logs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ShareLink(item: CastDeckLog.shared.currentLogURL) {
                            Label("Share log file", systemImage: "square.and.arrow.up")
                        }
                        ShareLink(item: mirror.diagnosticText) {
                            Label("Share mirror report", systemImage: "doc.text")
                        }
                    } label: {
                        Label("Having trouble?", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Screen Mirror")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !scanStarted else { return }
            scanStarted = true
            mirror.refresh()
        }
        .onChange(of: mirror.receivers) { _, found in
            // The common one-Chromecast case needs no duplicate device choice.
            if found.count == 1 && selectedReceiver == nil {
                selectedReceiver = found[0].id
            } else if let selectedReceiver,
                      !found.contains(where: { $0.id == selectedReceiver }) {
                self.selectedReceiver = nil
            }
        }
        .presentationDragIndicator(.visible)
    }
}
