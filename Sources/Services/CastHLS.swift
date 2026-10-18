import Foundation
import Network
import AVFoundation
import CoreImage
import CoreMedia
import UniformTypeIdentifiers
import Darwin

/// Bounded rolling fMP4 HLS data store. No cloud relay or remote uploads.
final class LiveHLSStore: NSObject, AVAssetWriterDelegate {
    private let lock = NSLock()
    private var initialization: Data?
    private var segments: [(number: Int, data: Data)] = []
    private var index = 0
    private var isFinished = false
    private let maxSegments = 8

    func reset() {
        lock.lock(); defer { lock.unlock() }
        initialization = nil
        segments = []
        index = 0
        isFinished = false
    }

    func finish() {
        lock.lock(); isFinished = true; lock.unlock()
    }

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        switch segmentType {
        case .initialization:
            initialization = data
        case .separable:
            segments.append((index, data))
            index += 1
            if segments.count > maxSegments { segments.removeFirst(segments.count - maxSegments) }
        @unknown default: break
        }
    }

    func resource(_ path: String) -> (mime: String, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        if path == "/live.m3u8" {
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:3\n"
            text += "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.number ?? index)\n"
            if initialization != nil { text += "#EXT-X-MAP:URI=\"init.mp4\"\n" }
            for item in segments {
                text += "#EXTINF:2.0,\nsegment-\(item.number).m4s\n"
            }
            if isFinished { text += "#EXT-X-ENDLIST\n" }
            return ("application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if path == "/init.mp4", let initialization { return ("video/mp4", initialization) }
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
                    continuation.resume(returning: "http://\(address):\(self.port)/live.m3u8")
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
                  let line = request.components(separatedBy: "\r\n").first,
                  line.hasPrefix("GET "),
                  let urlPart = line.split(separator: " ").dropFirst().first else {
                connection.cancel()
                return
            }
            let path = String(urlPart.split(separator: "?").first ?? "")
            let response = self.store.resource(path)
            let body = response?.body ?? Data("Not found".utf8)
            let mime = response?.mime ?? "text/plain"
            let code = response == nil ? "404 Not Found" : "200 OK"
            let head = "HTTP/1.1 \(code)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store, no-cache, must-revalidate\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var packet = Data(head.utf8)
            packet.append(body)
            connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
            self.clients.removeAll { $0 === connection }
        }
    }

    /// Chromecast must reach the host through a LAN address, not 127.0.0.1.
    private static func wifiIPv4() -> String? {
        var first: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = ptr {
            let item = current.pointee
            if let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: item.ifa_name)
                let flags = Int32(item.ifa_flags)
                if (flags & IFF_LOOPBACK) == 0 && (flags & IFF_UP) != 0 {
                    var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    _ = inet_ntop(AF_INET, UnsafeRawPointer(addr), &address, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: address)
                    if name == "en0" { return ip }
                    if first == nil { first = ip }
                }
            }
            ptr = item.ifa_next
        }
        return first
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
    private let quality4K: Bool
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: CMTime?
    private var outputSize: CGSize {
        quality4K ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)
    }
    var onError: ((String) -> Void)?

    init(store: LiveHLSStore, quality4K: Bool) {
        self.store = store
        self.quality4K = quality4K
    }

    func process(_ sample: CMSampleBuffer, audio isAudio: Bool) {
        guard CMSampleBufferIsValid(sample) else { return }
        if writer == nil {
            guard !isAudio else { return }
            do { try configure() }
            catch { onError?(error.localizedDescription); return }
        }
        guard let writer, let video, let audio, let adaptor else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid else { return }
        if writer.status == .unknown {
            guard !isAudio else { return }
            guard writer.startWriting() else {
                onError?(writer.error?.localizedDescription ?? "Unable to start HLS writer")
                return
            }
            writer.startSession(atSourceTime: time)
            startedAt = time
        }
        guard writer.status == .writing, let start = startedAt,
              CMTimeCompare(time, start) >= 0 else { return }

        if isAudio {
            if audio.isReadyForMoreMediaData && !audio.append(sample) {
                onError?(writer.error?.localizedDescription ?? "Audio append failed")
            }
        } else if video.isReadyForMoreMediaData,
                  let image = CMSampleBufferGetImageBuffer(sample),
                  let pool = adaptor.pixelBufferPool {
            var destination: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
                  let destination else { return }
            let w = CGFloat(CVPixelBufferGetWidth(image))
            let h = CGFloat(CVPixelBufferGetHeight(image))
            let size = outputSize
            let scale = min(size.width / w, size.height / h)
            let scaled = CIImage(cvPixelBuffer: image)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (size.width - w * scale) / 2,
                    y: (size.height - h * scale) / 2
                ))
            let background = CIImage(color: CIColor.black)
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(scaled.composited(over: background), to: destination)
            if !adaptor.append(destination, withPresentationTime: time) {
                onError?(writer.error?.localizedDescription ?? "Video append failed")
            }
        }
    }

    private func configure() throws {
        let size = outputSize
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.delegate = store
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: quality4K ? 18_000_000 : 6_000_000,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoAllowFrameReorderingKey: false
        ]
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
        self.writer = writer
        self.video = video
        self.audio = audio
        self.adaptor = adaptor
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
