import Foundation
import Network
import AVFoundation
import CoreImage
import ImageIO
import CoreMedia
import UniformTypeIdentifiers
import Darwin

/// Bounded rolling fMP4 HLS data store. No cloud relay or remote uploads.
final class LiveHLSStore: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var initialization: Data?
    private var segments: [(number: Int, data: Data, duration: Double)] = []
    private var index = 0
    private var isFinished = false
    private var activeWriter: ObjectIdentifier?
    private let maxSegments = 12
    private var is4K = false
    private var lastPlaylistDebugCount = -1

    func activate(_ writer: AVAssetWriter) {
        lock.lock(); defer { lock.unlock() }
        activeWriter = ObjectIdentifier(writer)
    }

    func setQuality(is4K: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.is4K = is4K
    }

    var readySegments: Int {
        lock.lock(); defer { lock.unlock() }
        return initialization == nil ? 0 : segments.count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        initialization = nil
        segments = []
        index = 0
        lastPlaylistDebugCount = -1
        isFinished = false
        activeWriter = nil
    }

    func finish() {
        lock.lock(); isFinished = true; lock.unlock()
    }

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        guard activeWriter == ObjectIdentifier(writer) else { return }
        switch segmentType {
        case .initialization:
            initialization = data
            CastDeckLog.shared.write("hls", "Initialization fragment: \(data.count) bytes; codec=" + codecDeclaration())
        case .separable:
            let reported = segmentReport?.trackReports
                .first(where: { $0.mediaType == .video })?.duration.seconds ?? 2.0
            let duration = reported.isFinite && reported > 0 ? reported : 2.0
            segments.append((index, data, duration))
            CastDeckLog.shared.write("hls", "Media fragment #\(index): \(data.count) bytes, duration \(String(format: "%.3f", duration)) s")
            index += 1
            if segments.count > maxSegments { segments.removeFirst(segments.count - maxSegments) }
        @unknown default: break
        }
    }

    private func codecDeclaration() -> String {
        let fallback = is4K ? "hvc1.1.6.L153.B0" : "avc1.640029"
        guard let initialization else { return fallback }
        let audio = initialization.range(of: Data("mp4a".utf8)) == nil ? "" : ",mp4a.40.2"
        if let marker = initialization.range(of: Data("avcC".utf8)) {
            let position = marker.lowerBound
            let data = [UInt8](initialization)
            if position + 7 < data.count {
                let codec = String(format: "avc1.%02X%02X%02X",
                                   data[position + 5], data[position + 6], data[position + 7])
                return codec + audio
            }
        }
        if let marker = initialization.range(of: Data("hvcC".utf8)) {
            let position = marker.lowerBound
            let data = [UInt8](initialization)
            if position + 16 < data.count {
                let level = data[position + 16]
                return "hvc1.1.6.L" + String(level) + ".B0" + audio
            }
        }
        return fallback + audio
    }

    /// Chromecast's Web Receiver uses a master playlist to identify video/audio
    /// codec support before requesting fragments.
    func resource(_ path: String) -> (mime: String, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        if path == "/master.m3u8" {
            // Advertise the codec that AVAssetWriter *actually emitted*
            // instead of guessing a profile that may make Cast's MSE reject
            // an otherwise valid MP4 fragment.
            let codecs = codecDeclaration()
            let bitrate = is4K ? 14_000_000 : 4_500_000
            let dimensions = is4K ? "3840x2160" : "1920x1080"
            let manifest = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-STREAM-INF:BANDWIDTH=\(bitrate),AVERAGE-BANDWIDTH=\(bitrate),RESOLUTION=\(dimensions),FRAME-RATE=30.000,CODECS="\(codecs)"
            live.m3u8

            """
            return ("application/vnd.apple.mpegurl", Data(manifest.utf8))
        }
        if path == "/live.m3u8" {
            // Never announce media fragments until the AVAssetWriter initialization
            // segment is available; otherwise the Cast receiver fails parsing HLS.
            let playable = initialization == nil ? [] : segments
            let firstNumber = playable.first?.number ?? index
            var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n"
            let targetDuration = max(2, Int(ceil((playable.map { $0.duration }.max() ?? 1.0) + 0.1)))
            playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
            playlist += "#EXT-X-MEDIA-SEQUENCE:\(firstNumber)\n"
            playlist += "#EXT-X-START:TIME-OFFSET=-2.0,PRECISE=YES\n"
            if initialization != nil {
                playlist += "#EXT-X-MAP:URI=\"init.mp4\"\n"
                for item in playable {
                    playlist += "#EXTINF:\(String(format: "%.3f", item.duration)),\nsegment-\(item.number).m4s\n"
                }
            }
            if isFinished { playlist += "#EXT-X-ENDLIST\n" }
            if lastPlaylistDebugCount != playable.count {
                lastPlaylistDebugCount = playable.count
                CastDeckLog.shared.write("hls", "Playlist #\(firstNumber): init=\(initialization?.count ?? 0) bytes, \(playable.count) fragments, quality=\(is4K ? "4K" : "1080p")")
            }
            return ("application/vnd.apple.mpegurl", Data(playlist.utf8))
        }
        if path == "/init.mp4", let initialization {
            return ("video/mp4", initialization)
        }
        if path.hasPrefix("/segment-"), path.hasSuffix(".m4s"),
           let number = Int(path.dropFirst("/segment-".count).dropLast(".m4s".count)),
           let item = segments.first(where: { $0.number == number }) {
            return ("video/iso.segment", item.data)
        }
        return nil
    }

    var segmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index
    }
}

/// Minimal LAN-only HTTP server for Cast Default Media Receiver's HLS requests.
final class CastHTTPServer {
    private let queue = DispatchQueue(label: "castdeck.hls.http", qos: .utility)
    private let store: LiveHLSStore
    var onRequest: ((String, Bool) -> Void)?
    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(store: LiveHLSStore) { self.store = store }

    func start() async throws -> String {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var delivered = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !delivered else { return }
                    delivered = true
                    self.port = listener.port?.rawValue ?? 0
                    guard let address = Self.wifiIPv4(), self.port > 0 else {
                        continuation.resume(throwing: MirrorError.noLocalAddress)
                        listener.cancel()
                        return
                    }
                    let url = "http://\(address):\(self.port)/master.m3u8"
                    CastDeckLog.shared.write("mirror", "LAN HLS server bound to " + url)
                    continuation.resume(returning: url)
                case .failed(let error):
                    guard !delivered else { return }
                    delivered = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for client in clients { client.cancel() }
        clients.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        clients.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state, let connection {
                self?.readRequest(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data,
                  let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }
            let method = String(parts[0])
            guard ["GET", "HEAD", "OPTIONS"].contains(method) else {
                connection.cancel()
                return
            }
            let path = String(parts[1].split(separator: "?").first ?? "")
            let resource = method == "OPTIONS" ? nil : self.store.resource(path)
            let rangeHeader = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") })
            var body = method == "OPTIONS" ? Data() : resource?.body ?? Data("Not found".utf8)
            let originalLength = body.count
            var status = method == "OPTIONS" ? "204 No Content" :
                         resource == nil ? "404 Not Found" : "200 OK"
            var rangeField = ""
            if let rangeHeader, resource != nil, rangeHeader.contains("bytes="),
               let numberText = rangeHeader.split(separator: "=").last,
               let startText = numberText.split(separator: "-").first,
               let requestedStart = Int(startText), requestedStart >= 0,
               requestedStart < originalLength {
                let endText = numberText.split(separator: "-").dropFirst().first
                let requestedEnd = endText.flatMap { Int($0) } ?? originalLength - 1
                let upper = min(originalLength - 1, max(requestedStart, requestedEnd))
                body = body.subdata(in: requestedStart..<(upper + 1))
                status = "206 Partial Content"
                rangeField = "Content-Range: bytes \(requestedStart)-\(upper)/\(originalLength)\r\n"
            }
            let mime = resource?.mime ?? "text/plain"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\n"
                       + rangeField
                       + "Cache-Control: no-store, no-cache, must-revalidate\r\n"
                       + "Access-Control-Allow-Origin: *\r\n"
                       + "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
                       + "Access-Control-Allow-Headers: Content-Type, Range, Accept-Encoding\r\n"
                       + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            if method == "GET" { response.append(body) }
            CastDeckLog.shared.write("cast-http", "\(method) \(path) -> \(status) (\(body.count) bytes)")
            if method == "GET" { self.onRequest?(path, resource != nil) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            self.clients.removeAll { $0 === connection }
        }
    }

    /// Return the *actual* Wi-Fi address, never a cellular, VPN, or bridge
    /// address. An earlier version passed sockaddr into inet_ntop instead
    /// of sockaddr_in.sin_addr and produced unreachable URLs like 16.2.0.0.
    private static func wifiIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == "en0",
                  let socket = current.pointee.ifa_addr,
                  Int32(socket.pointee.sa_family) == AF_INET,
                  (Int32(current.pointee.ifa_flags) & IFF_UP) != 0 else { continue }
            let internet = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self)
            var address = internet.pointee.sin_addr
            var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &output, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let result = String(cString: output)
            if result != "0.0.0.0" && !result.hasPrefix("169.254.") {
                return result
            }
        }
        return nil
    }
}

enum MirrorError: LocalizedError {
    case noLocalAddress
    case unsupportedOS
    case missingTV
    case writerFailed(String)
    case castFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLocalAddress: return "No reachable Wi-Fi IPv4 address. Join the same Wi-Fi as the Chromecast."
        case .unsupportedOS: return "Full-device mirroring requires iOS 27 or later."
        case .missingTV: return "Choose a discovered Chromecast or Google TV first."
        case .writerFailed(let message): return "Video/audio encoder: " + message
        case .castFailed(let message): return "Chromecast connection: " + message
        }
    }
}

/// Screen+system audio HLS muxer. Shared capture PTS keeps both tracks on one timeline.
final class CastHLSEncoder {
    let queue = DispatchQueue(label: "castdeck.hls.encoder", qos: .userInitiated)
    private let store: LiveHLSStore
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var quality4K: Bool
    private var failed = false
    private var didFallback = false
    private var lastLandscape: Bool?
    private var lastFrameAt: CMTime?
    var onStatus: ((String) -> Void)?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: CMTime?
    private var outputSize: CGSize {
        quality4K ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)
    }
    var onError: ((String) -> Void)?

    /// Restart the encoder without restarting ScreenCaptureKit capture.
    /// AVAssetWriter delegates can finish delivering old fragments asynchronously,
    /// so the store ignores stale writer callbacks using writer identity.
    func retryAt1080p() {
        queue.async { [weak self] in
            guard let self, self.quality4K, !self.failed else { return }
            self.writer?.cancelWriting()
            self.writer = nil
            self.video = nil
            self.audio = nil
            self.adaptor = nil
            self.startedAt = nil
            self.lastFrameAt = nil
            self.lastLandscape = nil
            self.quality4K = false
            self.didFallback = true
            self.store.reset()
            self.store.setQuality(is4K: false)
            self.onStatus?("Chromecast could not play 4K HEVC; restarting as 1080p H.264")
        }
    }

    init(store: LiveHLSStore, quality4K: Bool) {
        self.store = store
        self.quality4K = quality4K
        store.setQuality(is4K: quality4K)
    }

    func process(_ sample: CMSampleBuffer, audio isAudio: Bool, orientation: CGImagePropertyOrientation = .up) {
        guard !failed, CMSampleBufferIsValid(sample) else { return }
        if writer == nil {
            guard !isAudio else { return }
            do { try configure(firstTimestamp: CMSampleBufferGetPresentationTimeStamp(sample)) }
            catch { reportFailure(error.localizedDescription); return }
        }
        guard let writer, let video, let audio, let adaptor else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid else { return }
        // Never encode the same or an out-of-order screen frame. Audio keeps
        // all source timestamps for A/V synchronization.
        if !isAudio {
            if let lastFrameAt {
                let elapsed = CMTimeSubtract(time, lastFrameAt)
                if CMTimeCompare(elapsed, CMTime(value: 1, timescale: 30)) < 0 {
                    return
                }
            }
            lastFrameAt = time
        }
        if writer.status == .unknown {
            guard !isAudio else { return }
            if !writer.startWriting() {
                let detail = writerFailureDetails(writer)
                if quality4K && !didFallback {
                    didFallback = true
                    quality4K = false
                    store.setQuality(is4K: false)
                    onStatus?("4K could not start (\(detail)). Retrying automatically at 1080p.")
                    writer.cancelWriting()
                    self.writer = nil
                    self.video = nil
                    self.audio = nil
                    self.adaptor = nil
                    do { try configure(firstTimestamp: time) }
                    catch { reportFailure("1080p fallback setup failed: " + error.localizedDescription); return }
                    guard let fallback = self.writer, fallback.startWriting() else {
                        reportFailure("4K failed: \(detail). 1080p failed: " +
                                      (self.writer.map(writerFailureDetails) ?? "writer unavailable"))
                        return
                    }
                    fallback.startSession(atSourceTime: time)
                    startedAt = time
                    lastFrameAt = nil
                    return process(sample, audio: isAudio, orientation: orientation)
                } else {
                    reportFailure(detail)
                    return
                }
            } else {
                writer.startSession(atSourceTime: time)
                startedAt = time
            }
        }
        guard writer.status == .writing, let start = startedAt,
              CMTimeCompare(time, start) >= 0 else { return }

        if isAudio {
            if audio.isReadyForMoreMediaData && !audio.append(sample) {
                reportFailure("Audio append: " + writerFailureDetails(writer))
            }
        } else if video.isReadyForMoreMediaData,
                  let image = CMSampleBufferGetImageBuffer(sample),
                  let pool = adaptor.pixelBufferPool {
            var destination: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
                  let destination else { return }
            // ScreenCaptureKit attaches orientation metadata to iOS frames.
            // Treat the oriented image geometry, not the iPhone's startup
            // orientation, as the source of truth on every frame.
            let oriented = CIImage(cvPixelBuffer: image).oriented(orientation)
            let extent = oriented.extent
            let width = extent.width
            let height = extent.height
            guard width > 0, height > 0 else { return }
            let landscape = width > height
            if lastLandscape != landscape {
                lastLandscape = landscape
                onStatus?(landscape ?
                    "Landscape detected: filling TV screen, slight center crop if needed" :
                    "Portrait detected: preserving full phone screen with side bars")
            }
            let size = outputSize
            let scale = landscape
                ? max(size.width / width, size.height / height)
                : min(size.width / width, size.height / height)
            // Translate oriented buffers to the origin before scaling. For
            // landscape, aspect-fill covers the entire TV without stretching.
            // Portrait remains aspect-fit so the full home screen stays visible.
            let scaled = oriented
                .transformed(by: CGAffineTransform(
                    translationX: -extent.minX, y: -extent.minY
                ))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (size.width - width * scale) / 2,
                    y: (size.height - height * scale) / 2
                ))
            let background = CIImage(color: CIColor.black)
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(scaled.composited(over: background), to: destination)
            if !adaptor.append(destination, withPresentationTime: time) {
                reportFailure("Video append: " + writerFailureDetails(writer))
            }
        }
    }

    private func configure(firstTimestamp: CMTime) throws {
        let size = outputSize
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.shouldOptimizeForNetworkUse = true
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = firstTimestamp
        writer.delegate = store
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality4K ? 12_000_000 : 3_500_000,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 30,
            AVVideoAllowFrameReorderingKey: false
        ]
        if !quality4K {
            // Match the manifest's AVC High@L4.1 profile on older receivers.
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264High41
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: quality4K ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw MirrorError.writerFailed("Hardware video settings unsupported for " + String(Int(size.width)) + "×" + String(Int(size.height)))
        }
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw MirrorError.writerFailed("Unsupported HLS video/audio settings")
        }
        writer.add(video)
        writer.add(audio)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        self.store.activate(writer)
        self.writer = writer
        self.video = video
        self.audio = audio
        self.adaptor = adaptor
    }

    private func reportFailure(_ message: String) {
        guard !failed else { return }
        failed = true
        onError?(message)
    }

    private func writerFailureDetails(_ writer: AVAssetWriter) -> String {
        guard let error = writer.error as NSError? else {
            return "AVAssetWriter did not start (status " + String(writer.status.rawValue) + ")"
        }
        let reason = (error.userInfo[NSUnderlyingErrorKey] as? NSError)
        let underlying = reason.map {
            " | underlying " + $0.domain + " " + String($0.code) + ": " + $0.localizedDescription
        } ?? ""
        return error.domain + " " + String(error.code) + ": " + error.localizedDescription +
               underlying
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let writer = self.writer else { self.store.finish(); return }
            if writer.status == .writing {
                self.video?.markAsFinished()
                self.audio?.markAsFinished()
                writer.finishWriting { [weak self] in self?.store.finish() }
            } else {
                writer.cancelWriting()
                self.store.finish()
            }
            self.writer = nil
        }
    }
}
