import SwiftUI

/// Dedicated receiver picker and capture controls; the remote's original layout
/// remains intact. Google Cast discovery is separate from Android TV remote pairing.
struct MirrorPanel: View {
    @ObservedObject var mirror: MirrorSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReceiver: String?
    @State private var scanStarted = false

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
                        Text("Share your iPhone display and supported audio on your television over local Wi-Fi.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label(mirror.status, systemImage: mirror.isMirroring ? "dot.radiowaves.left.and.right" : "tv")
                            .font(.caption)
                            .foregroundStyle(mirror.isMirroring ? .green : .secondary)
                            .lineLimit(3)
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

                Section("Streaming quality") {
                    Picker("Output resolution", selection: $mirror.quality4K) {
                        Text("1080p").tag(false)
                        Text("4K UHD").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(mirror.isStarting || mirror.isMirroring)
                    Text("4K sends a 3840×2160 encoded stream on compatible receivers. Portrait iPhone content is letterboxed to preserve its proportions. Real detail is limited by your iPhone's screen resolution.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("AAC stereo audio · 192 kb/s · original capture timestamps",
                          systemImage: "speaker.wave.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if mirror.isStarting {
                        HStack {
                            ProgressView()
                            Text("Preparing live stream…")
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
                    Text("Screen sharing requires iOS 27. Protected video/audio may not be capturable. Live HLS adds playback delay, and audio/video quality depends on the receiver and Wi-Fi. No external server is used.")
                }

                Section("Diagnostics") {
                    LabeledContent("HLS segments", value: String(mirror.isMirroring ? "Streaming" : "Idle"))
                    ShareLink(item: mirror.diagnosticText) {
                        Label("Export mirroring log", systemImage: "square.and.arrow.up")
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
