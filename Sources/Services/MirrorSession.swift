import Foundation
import SwiftUI
import AVFoundation
import ImageIO

#if !targetEnvironment(simulator)
import ScreenCaptureKit
#endif

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
    private var encoderFailure: String?
    private var castFailure: String?
    private var receiverReportedPlaying = false
    private var videoSegmentRequested = false
    private var activeEncoder: CastHLSEncoder?
    private var currentMediaURL: URL?
    private var fallbackInProgress = false
    private var isRetryingCompatibility = false
    private var refreshTask: Task<Void, Never>?

    init() {
        CastMediaSender.configureSDK()
        cast.onState = { [weak self] value in
            Task { @MainActor in self?.record(value) }
        }
        cast.onFailure = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.castFailure = value
                self.error = value
                self.record("Chromecast playback error: " + value)
                if self.isMirroring || self.isStarting {
                    self.stop()
                    self.error = value
                    self.record("Screen mirroring could not play: " + value)
                }
            }
        }
        cast.onPlaybackIdle = { [weak self] detail in
            Task { @MainActor in self?.handleIdlePlayback(detail) }
        }
        cast.onPlaybackConfirmed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.receiverReportedPlaying = true
                self.record("Chromecast reported PLAYING; verifying video segment requests")
                self.confirmPlaybackIfReady()
            }
        }
    }

    private func handleIdlePlayback(_ detail: String) {
        guard isStarting || isMirroring else { return }
        record(detail)
        guard quality4K, !fallbackInProgress, let encoder = activeEncoder,
              let originalURL = currentMediaURL else {
            // If a compatibility attempt has already been sent, this idle
            // transition indicates both codecs failed. Do not display success.
            if !fallbackInProgress || isRetryingCompatibility {
                let reason = "Chromecast could not decode or play the HLS stream. " + detail
                stop()
                error = reason
                record("Playback failed: " + reason)
            }
            return
        }
        fallbackInProgress = true
        receiverReportedPlaying = false
        videoSegmentRequested = false
        record("4K playback failed. Retrying automatically at 1080p H.264.")
        encoder.retryAt1080p()
        quality4K = false
        let attempt = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<65 {
                guard self.generation == attempt, !Task.isCancelled else { return }
                if self.store.readySegments >= 2 { break }
                if let failure = self.encoderFailure {
                    self.stop()
                    self.error = failure
                    self.record("1080p encoder failed: " + failure)
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard self.generation == attempt else { return }
            guard self.store.readySegments >= 2 else {
                let reason = "1080p retry did not produce HLS media."
                self.stop()
                self.error = reason
                self.record(reason)
                return
            }
            // New query parameter avoids stale Chromecast manifest caching.
            var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "mode", value: "compatibility1080")]
            self.isRetryingCompatibility = true
            self.cast.reloadCompatibilityStream(mediaURL: components?.url ?? originalURL)
            self.record("1080p H.264 stream is ready; Chromecast retry LOAD sent")
        }
    }

    private func confirmPlaybackIfReady() {
        guard isStarting, receiverReportedPlaying, videoSegmentRequested else { return }
        isStarting = false
        isMirroring = true
        error = nil
        record("Confirmed: Chromecast is playing and has fetched a video segment")
    }

    func record(_ message: String) {
        status = message
        events.append(Date().formatted(date: .numeric, time: .standard) + "  " + message)
        CastDeckLog.shared.write("mirror", message)
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
                let found = cast.availableReceivers()
                // Screen-sharing UI can suspend Cast discovery. Preserve the
                // last known picker selection instead of clearing it on an
                // empty transient SDK response.
                if !found.isEmpty { receivers = found }
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
        encoderFailure = nil
        castFailure = nil
        receiverReportedPlaying = false
        videoSegmentRequested = false
        fallbackInProgress = false
        isRetryingCompatibility = false
        activeEncoder = nil
        currentMediaURL = nil
        store.reset()
        record("Starting local HLS server; app audio capture enabled")
        Task {
            do {
                let http = CastHTTPServer(store: store)
                http.onRequest = { [weak self] path, success in
                    Task { @MainActor in
                        guard let self, self.generation == current, success else { return }
                        if path == "/init.mp4" { self.record("Chromecast requested MP4 initialization data") }
                        if path.hasPrefix("/segment-") {
                            if !self.videoSegmentRequested {
                                self.record("Chromecast fetched video segment: " + path)
                            }
                            self.videoSegmentRequested = true
                            self.confirmPlaybackIfReady()
                        }
                    }
                }
                self.http = http
                let urlString = try await http.start()
                guard generation == current, let url = URL(string: urlString) else { return }
                record("Local stream ready: " + urlString)
                currentMediaURL = url
                // The iOS system capture picker can background this app,
                // suspending Google Cast discovery. Start the Cast session
                // now while the receiver is still present in the SDK.
                try cast.prepare(receiverID: receiverID)
                guard generation == current else { return }
                record("Chromecast connection requested before screen picker")
                let encoder = CastHLSEncoder(store: store, quality4K: quality4K)
                activeEncoder = encoder
                encoder.onStatus = { [weak self] message in
                    Task { @MainActor in self?.record(message) }
                }
                encoder.onError = { [weak self] message in
                    Task { @MainActor in
                        self?.encoderFailure = message
                        self?.error = message
                        self?.record("HLS encoder failed: " + message)
                    }
                }
                #if !targetEnvironment(simulator)
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
                for _ in 0..<40 {
                    guard generation == current else { return }
                    if let encoderFailure {
                        throw MirrorError.writerFailed(encoderFailure)
                    }
                    if let castFailure {
                        throw MirrorError.castFailed(castFailure)
                    }
                    if store.readySegments >= 2 { break }
                    if engine.cancelled {
                        throw MirrorError.writerFailed("Screen sharing ended before video was ready")
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                guard generation == current else { return }
                if let castFailure { throw MirrorError.castFailed(castFailure) }
                guard store.readySegments >= 2 else {
                    throw MirrorError.writerFailed("HLS stream did not produce two ready fragments. Check capture and encoding logs.")
                }
                cast.publish(mediaURL: url)
                #else
                throw MirrorError.writerFailed("ScreenCaptureKit is unavailable in the iOS simulator. Install the IPA on a physical iPhone.")
                #endif
                record("Live HLS ready with two short fragments; waiting for Chromecast PLAYING confirmation")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 55_000_000_000)
                    guard let self, self.generation == current, self.isStarting, !self.isMirroring else { return }
                    let reason = "TV opened Cast but did not both fetch video and report PLAYING. Check the HLS, init.mp4 and LOAD events in Files logs."
                    self.stop()
                    self.error = reason
                    self.record("Mirror timed out: " + reason)
                }
            } catch {
                guard generation == current else { return }
                self.error = error.localizedDescription
                self.stop()
                self.record("Could not start mirroring: " + error.localizedDescription)
            }
        }
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        #if !targetEnvironment(simulator)
        if #available(iOS 27.0, *), let engine = capture as? IOS27CaptureEngine {
            engine.stop()
        }
        #endif
        capture = nil
        activeEncoder = nil
        currentMediaURL = nil
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
#if !targetEnvironment(simulator)
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
        var config = SCContentSharingPickerConfiguration()
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
                if existingStream != nil {
                    onState?("To change shared content, stop and restart mirroring.")
                    return
                }
                let config = SCStreamConfiguration()
                // Do not lock capture to nativeBounds in portrait. Leave
                // stream dimensions controlled by ScreenCaptureKit so frames
                // can reflect live portrait/landscape changes.
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
            // iOS 27 includes CGImagePropertyOrientation metadata even when
            // ScreenCaptureKit's pixel buffer has a constant physical shape.
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
            let number = attachments?.first?[.videoOrientation] as? NSNumber
            let orientation = number.flatMap {
                CGImagePropertyOrientation(rawValue: $0.uint32Value)
            } ?? .up
            encoder.process(sampleBuffer, audio: false, orientation: orientation)
        case .audio:
            encoder.process(sampleBuffer, audio: true)
        default: break
        }
    }
}

#endif
