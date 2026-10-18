import SwiftUI
import AVFoundation
import CoreMedia
import ImageIO
#if !targetEnvironment(simulator)
import ScreenCaptureKit
#endif

/// Consumer-facing live mirroring session using the built-in Chromecast
/// streaming receiver. No embedded HTTP server, HLS playlist or MP4 fragments.
@MainActor
final class RealtimeMirrorSession: ObservableObject {
    @Published var receivers: [CastRealtimeSender.Receiver] = []
    @Published var isStarting = false
    @Published var isMirroring = false
    @Published var quality4K = false
    @Published var status = "Choose a Chromecast"
    @Published var error: String?
    @Published var events: [String] = []
    @Published private(set) var videoFrames = 0

    private var sender: CastRealtimeSender?
    private var encoder: CastRealtimeEncoder?
    private var audioEncoder: CastRealtimeAudioEncoder?
    private var capture: AnyObject?
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?

    init() {
        CastMediaSender.configureSDK()
    }

    var diagnosticText: String {
        (["CastDeck native Cast Streaming diagnostics",
          "Mirroring: \(isMirroring)",
          "Starting: \(isStarting)",
          "Selected quality: \(quality4K ? "4K HEVC" : "1080p H.264")",
          "Encoded real-time RTP frames: \(videoFrames)",
          "No HLS files or HTTP server",
          "Status: " + status, ""] + events).joined(separator: "\n")
    }

    private func log(_ text: String) {
        status = text
        events.append(Date().formatted(date: .numeric, time: .standard) + "  " + text)
        if events.count > 250 { events.removeFirst(events.count - 250) }
        CastDeckLog.shared.write("cast-realtime", text)
    }

    func refresh() {
        if sender == nil { sender = CastRealtimeSender() }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                let found = sender?.refresh() ?? []
                if !found.isEmpty { receivers = found }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    func start(receiverID: String) {
        guard !isStarting, !isMirroring else { return }
        guard #available(iOS 27.0, *) else {
            error = "Native iPhone screen sharing requires iOS 27 or later."
            return
        }
        generation = UUID()
        let current = generation
        error = nil
        videoFrames = 0
        isStarting = true
        log("Connecting to built-in Chromecast real-time mirroring receiver")
        if sender == nil { sender = CastRealtimeSender() }
        guard let sender else { return }
        sender.onEvent = { [weak self] text in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.log(text)
            }
        }
        sender.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.stop()
                self.error = message
                self.log("Native Cast Streaming failed: " + message)
            }
        }
        sender.onKeyframeNeeded = { [weak self] in
            self?.encoder?.requestKeyframe()
        }
        sender.onNegotiated = { [weak self] in
            guard let self, self.generation == current else { return }
            self.log("Cast Streaming receiver negotiated; starting iPhone screen capture")
            do {
                let encoder = try CastRealtimeEncoder(quality4K: sender.negotiated4K)
                self.encoder = encoder
                let audio = sender.audioNegotiated ? CastRealtimeAudioEncoder() : nil
                self.audioEncoder = audio
                audio?.onPacket = { data, pts in
                    sender.sendAudio(data, pts: pts)
                }
                audio?.onEvent = { [weak self] text in
                    Task { @MainActor in self?.log(text) }
                }
                encoder.onEvent = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        self.log(message)
                    }
                }
                encoder.onFrame = { [weak self] bytes, timestamp, keyFrame in
                    guard let self else { return }
                    sender.sendVideo(bytes, pts: timestamp, keyFrame: keyFrame)
                    Task { @MainActor in
                        guard self.generation == current else { return }
                        self.videoFrames += 1
                        if self.videoFrames == 1 {
                            self.isMirroring = true
                            self.isStarting = false
                            self.log("Real-time encoded screen frames are being sent to Chromecast")
                        }
                    }
                }
                #if !targetEnvironment(simulator)
                let capture = IOS27RealtimeCapture(encoder: encoder, audioEncoder: audio)
                self.capture = capture
                capture.onState = { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        self.log(text)
                    }
                }
                capture.onFailure = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        self.stop()
                        self.error = message
                        self.log("iPhone capture ended: " + message)
                    }
                }
                capture.presentPicker()
                self.log("Choose Entire Screen in the iOS sharing picker")
                #else
                self.stop()
                self.error = "ScreenCaptureKit requires a physical iPhone."
                #endif
            } catch {
                self.stop()
                self.error = error.localizedDescription
                self.log(error.localizedDescription)
            }
        }
        do {
            try sender.start(receiverID: receiverID, quality4K: quality4K)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.generation == current, self.isStarting else { return }
                self.stop()
                self.error = "Chromecast did not finish the real-time streaming handshake. See Files → CastDeck → Logs."
                self.log("Cast Streaming OFFER/ANSWER or iOS capture timed out")
            }
        } catch {
            stop()
            self.error = error.localizedDescription
            log(error.localizedDescription)
        }
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        #if !targetEnvironment(simulator)
        if #available(iOS 27.0, *), let capture = capture as? IOS27RealtimeCapture {
            capture.stop()
        }
        #endif
        capture = nil
        encoder?.stop()
        encoder = nil
        audioEncoder?.stop()
        audioEncoder = nil
        sender?.stop()
        isStarting = false
        isMirroring = false
        log("Stopped native Chromecast mirroring")
    }
}

#if !targetEnvironment(simulator)
@available(iOS 27.0, *)
@MainActor
final class IOS27RealtimeCapture: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private let encoder: CastRealtimeEncoder
    private let audioEncoder: CastRealtimeAudioEncoder?
    private let output: RealtimeFrameOutput
    private var stream: SCStream?
    var onState: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stopped = false

    init(encoder: CastRealtimeEncoder, audioEncoder: CastRealtimeAudioEncoder?) {
        self.encoder = encoder
        self.audioEncoder = audioEncoder
        self.output = RealtimeFrameOutput(encoder: encoder, audioEncoder: audioEncoder)
        super.init()
    }

    func presentPicker() {
        let picker = SCContentSharingPicker.shared
        var settings = SCContentSharingPickerConfiguration()
        settings.showsCameraControl = false
        settings.showsMicrophoneControl = false
        picker.defaultConfiguration = settings
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for existingStream: SCStream?) {
        guard !stopped else { return }
        Task {
            do {
                guard existingStream == nil else { return }
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                if audioEncoder != nil {
                    try stream.addStreamOutput(output, type: .audio,
                                               sampleHandlerQueue: output.queue)
                }
                self.stream = stream
                try await stream.startCapture()
                onState?("iPhone display capture started; no recording saved")
            } catch {
                onFailure?("Screen capture failed: " + error.localizedDescription)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if !stopped && stream == nil { onFailure?("Screen-sharing permission was cancelled") }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        if !stopped { onFailure?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !stopped { onFailure?("Screen capture ended: " + error.localizedDescription) }
    }

    func stop() {
        stopped = true
        SCContentSharingPicker.shared.remove(self)
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
    }
}

@available(iOS 27.0, *)
private final class RealtimeFrameOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "castdeck.realtime.capture", qos: .userInitiated)
    private let encoder: CastRealtimeEncoder
    private let audioEncoder: CastRealtimeAudioEncoder?
    init(encoder: CastRealtimeEncoder, audioEncoder: CastRealtimeAudioEncoder?) {
        self.encoder = encoder
        self.audioEncoder = audioEncoder
        super.init()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio {
            audioEncoder?.process(sampleBuffer)
            return
        }
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let metadata = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let orientationNumber = metadata?.first?[.videoOrientation] as? NSNumber
        let orientation = orientationNumber.flatMap {
            CGImagePropertyOrientation(rawValue: $0.uint32Value)
        } ?? .up
        encoder.encode(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                       orientation: orientation)
    }
}
#endif
