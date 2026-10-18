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
                    Label("Mirror your iPhone screen", systemImage: "rectangle.on.rectangle.angled")
                        .font(.headline)
                    Text("Send your iPhone display and supported app audio directly to a Chromecast on the same Wi-Fi. iOS will ask what to share before capture begins.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(mirror.status, systemImage: mirror.isMirroring ? "airplayvideo" : "waveform.path")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Google Cast receivers") {
                    Button {
                        mirror.refresh()
                    } label: {
                        Label("Refresh Chromecast list", systemImage: "arrow.clockwise")
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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text("Google Cast receiver")
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
                }

                Section("Streaming quality") {
                    Picker("Output resolution", selection: $mirror.quality4K) {
                        Text("1080p · H.264").tag(false)
                        Text("4K · HEVC").tag(true)
                    }
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
                            Label("Start screen mirroring", systemImage: "play.rectangle.on.rectangle")
                        }
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
        .presentationDragIndicator(.visible)
    }
}
