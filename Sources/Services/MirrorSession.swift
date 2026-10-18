import Foundation
import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// UI-facing capture and Cast session lifecycle. The user chooses a receiver and
/// explicitly grants full-display capture from the iOS system picker.
@MainActor
final class MirrorSession: ObservableObject {
    @Published var receivers: [CastMediaSender.Receiver] = []
    @Published var isStarting = false
    @Published var isMirroring = false
    @Published var status = "Choose a Chromecast or Google TV"
    @Published var error: String?
    @Published var events: [String] = []
    @Published var quality4K = false

    private let cast = CastMediaSender()
    private let store = LiveHLSStore()
    private var http: CastHTTPServer?
    private var capture: AnyObject?
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?

    init() {
        CastMediaSender.configureSDK()
        cast.onState = { [weak self] value in
            Task { @MainActor in self?.record(value) }
        }
        cast.onFailure = { [weak self] value in
            Task { @MainActor in
                self?.error = value
                self?.record("Receiver error: " + value)
            }
        }
    }

    func record(_ message: String) {
        status = message
        events.append(Date().formatted(date: .numeric, time: .standard) + "  " + message)
        if events.count > 250 { events.removeFirst(events.count - 250) }
    }

    var diagnosticText: String {
        (["CastDeck screen mirroring diagnostics",
          "Mirroring: \(isMirroring)",
          "Starting: \(isStarting)",
          "Quality: \(quality4K ? "4K HEVC" : "1080p H.264")",
          "HLS segments: \(store.segmentCount)",
          "Status: " + status, ""] + events).joined(separator: "\n")
    }

    func refresh() {
        cast.startDiscovery()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<15 {
                if Task.isCancelled { return }
                receivers = cast.availableReceivers()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    func start(receiverID: String) {
        guard !isStarting, !isMirroring else { return }
        guard #available(iOS 27.0, *) else {
            error = MirrorError.unsupportedOS.localizedDescription
            return
        }
        generation = UUID()
        let current = generation
        isStarting = true
        error = nil
        store.reset()
        record("Starting local HLS server; app audio capture enabled")
        Task {
            do {
                let http = CastHTTPServer(store: store)
                self.http = http
                let urlString = try await http.start()
                guard generation == current, let url = URL(string: urlString) else { return }
                record("Local stream ready: " + urlString)
                let encoder = CastHLSEncoder(store: store, quality4K: quality4K)
                encoder.onError = { [weak self] message in
                    Task { @MainActor in
                        self?.error = message
                        self?.record("HLS encoder: " + message)
                    }
                }
                let engine = IOS27CaptureEngine(encoder: encoder)
                self.capture = engine
                engine.onState = { [weak self] message in
                    Task { @MainActor in self?.record(message) }
                }
                engine.onFailure = { [weak self] message in
                    Task { @MainActor in
                        self?.error = message
                        self?.record(message)
                        self?.isStarting = false
                    }
                }
                engine.presentPicker()
                record("Choose Entire Screen in the iOS capture picker")
                // Do not launch receiver until there's actual encoded audio/video
                // to fetch, avoiding an empty-playlist failure on the Chromecast.
                for _ in 0..<35 {
                    guard generation == current else { return }
                    if store.segmentCount > 0 { break }
                    if engine.cancelled {
                        throw MirrorError.writerFailed("Screen-sharing picker was cancelled")
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                guard generation == current else { return }
                guard store.segmentCount > 0 else {
                    throw MirrorError.writerFailed("No encoded HLS media arrived. Check screen sharing permission and screen recording restrictions.")
                }
                try cast.cast(receiverID: receiverID, mediaURL: url)
                isStarting = false
                isMirroring = true
                record("Sending live " + (quality4K ? "4K HEVC" : "1080p H.264") + " video and AAC device audio")
            } catch {
                guard generation == current else { return }
                self.error = error.localizedDescription
                self.record("Mirror start failed: " + error.localizedDescription)
                self.stop()
            }
        }
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        if #available(iOS 27.0, *), let engine = capture as? IOS27CaptureEngine {
            engine.stop()
        }
        capture = nil
        cast.stop()
        http?.stop()
        http = nil
        isStarting = false
        isMirroring = false
        record("Mirroring stopped")
    }
}

/// Capture implementation available only on iOS 27+. No ReplayKit extension,
/// app group, background relay server, or private screen APIs.
@available(iOS 27.0, *)
@MainActor
final class IOS27CaptureEngine: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    var onState: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let encoder: CastHLSEncoder
    private let output: MirrorFrameOutput
    private var stream: SCStream?
    private(set) var cancelled = false

    init(encoder: CastHLSEncoder) {
        self.encoder = encoder
        self.output = MirrorFrameOutput(encoder: encoder)
        super.init()
    }

    func presentPicker() {
        let picker = SCContentSharingPicker.shared
        let config = SCContentSharingPickerConfiguration()
        config.showsMicrophoneControl = false
        config.showsCameraControl = false
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for existingStream: SCStream?) {
        Task {
            do {
                if let existingStream {
                    try await existingStream.updateContentFilter(filter)
                    onState?("Updated screen-sharing selection")
                    return
                }
                let config = SCStreamConfiguration()
                let bounds = UIScreen.main.nativeBounds
                config.width = Int(bounds.width)
                config.height = Int(bounds.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 6
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: encoder.queue)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: encoder.queue)
                self.stream = stream
                try await stream.startCapture()
                onState?("iPhone full-screen capture and audio started")
            } catch {
                cancelled = true
                onFailure?("Screen capture failed: " + error.localizedDescription)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        cancelled = true
        onFailure?("Screen sharing was cancelled")
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        cancelled = true
        onFailure?("Screen-sharing picker: " + error.localizedDescription)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cancelled = true
        onFailure?("Screen capture ended: " + error.localizedDescription)
    }

    func stop() {
        cancelled = true
        SCContentSharingPicker.shared.remove(self)
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        encoder.stop()
    }
}

@available(iOS 27.0, *)
private final class MirrorFrameOutput: NSObject, SCStreamOutput {
    private let encoder: CastHLSEncoder
    init(encoder: CastHLSEncoder) { self.encoder = encoder; super.init() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            encoder.process(sampleBuffer, audio: false)
        case .audio:
            encoder.process(sampleBuffer, audio: true)
        default: break
        }
    }
}
