import Foundation
import AVFoundation
import VideoToolbox
import CoreImage
import CoreMedia
import ImageIO

/// Encode screen frames directly with VideoToolbox (no MP4 files, HLS
/// segments, HTTP server or temporary screen recordings).
final class CastRealtimeEncoder {
    var onEvent: ((String) -> Void)?
    var onFrame: ((Data, UInt32, Bool) -> Void)?
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let codec: CMVideoCodecType
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let framePool: CVPixelBufferPool
    private var lastOrientation: Bool?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var forceKeyframe = false
    private let renderQueue = DispatchQueue(label: "castdeck.cast.encoder", qos: .userInitiated)
    private var active = true
    private var encoderRecoveryCount = 0
    private let maximumEncoderRecoveries = 3

    init(quality4K: Bool) throws {
        width = quality4K ? 3840 : 1920
        height = quality4K ? 2160 : 1080
        codec = quality4K ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolOptions: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 5
        ]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolOptions as CFDictionary,
                                             attributes as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let pool else {
            throw RealtimeMirrorError.capture("Could not allocate a reusable video buffer pool.")
        }
        framePool = pool
        try configureSession()
    }

    private func configureSession() throws {
        var output: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sample in
            guard let refcon, status == noErr, let sample else { return }
            let sender = Unmanaged<CastRealtimeEncoder>.fromOpaque(refcon).takeUnretainedValue()
            sender.handleEncoded(sample)
        }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                width: Int32(width), height: Int32(height),
                                                codecType: codec,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: callback,
                                                refcon: Unmanaged.passUnretained(self).toOpaque(),
                                                compressionSessionOut: &output)
        guard status == noErr, let output else {
            throw RealtimeMirrorError.capture("Unable to initialize hardware screen encoder (\(status)).")
        }
        session = output
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(output, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 30))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 30 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate,
            NSNumber(value: codec == kCMVideoCodecType_HEVC ? 11_000_000 : 3_500_000))
        if codec == kCMVideoCodecType_H264 {
            set(kVTCompressionPropertyKey_ProfileLevel,
                kVTProfileLevel_H264_High_4_1)
        }
        let preparation = VTCompressionSessionPrepareToEncodeFrames(output)
        guard preparation == noErr else {
            VTCompressionSessionInvalidate(output)
            session = nil
            throw RealtimeMirrorError.capture("Unable to prepare hardware encoder (\(preparation)).")
        }
        onEvent?("VideoToolbox configured " + String(width) + "×" + String(height) +
                 " real-time video (30 fps, no frame reordering)")
    }

    func encode(_ buffer: CVPixelBuffer, pts: CMTime,
                orientation: CGImagePropertyOrientation) {
        renderQueue.async { [weak self] in
            guard let self, self.active, let session = self.session else { return }
            if let last = self.lastPTS {
                let step = CMTimeSubtract(pts, last)
                if CMTimeCompare(step, CMTime(value: 1, timescale: 30)) < 0 { return }
            }
            self.lastPTS = pts
            if self.firstPTS == nil { self.firstPTS = pts }
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return }
            let landscape = extent.width > extent.height
            if self.lastOrientation != landscape {
                self.lastOrientation = landscape
                self.onEvent?(landscape ? "Landscape: fitting real-time video to full TV screen" :
                                      "Portrait: preserving the entire iPhone display")
            }
            // Reuse IOSurface-backed video buffers instead of allocating
            // new multi-megabyte frames at 30 fps. VideoToolbox keeps its
            // reference until hardware encoding finishes.
            var dest: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                     self.framePool, &dest)
                  == kCVReturnSuccess, let dest else {
                self.onEvent?("Video buffer pool is temporarily exhausted")
                return
            }
            let scale = landscape
                ? max(CGFloat(self.width) / extent.width, CGFloat(self.height) / extent.height)
                : min(CGFloat(self.width) / extent.width, CGFloat(self.height) / extent.height)
            let transform = image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (CGFloat(self.width) - extent.width * scale) / 2,
                    y: (CGFloat(self.height) - extent.height * scale) / 2
                ))
            let black = CIImage(color: .black)
                .cropped(to: CGRect(x: 0, y: 0, width: self.width, height: self.height))
            self.context.render(transform.composited(over: black), to: dest)
            let extra: [CFString: Any]? = self.forceKeyframe
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
            self.forceKeyframe = false
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: dest,
                                                         presentationTimeStamp: pts,
                                                         duration: .invalid,
                                                         frameProperties: extra as CFDictionary?,
                                                         sourceFrameRefcon: nil,
                                                         infoFlagsOut: nil)
            if status != noErr { self.recoverEncoder(status: status) }
        }
    }

    // Called on the serial render queue after a failed encode.
    private func recoverEncoder(status: OSStatus) {
        guard active else { return }
        onEvent?("VideoToolbox encode error \(status); resetting encoder")
        if let old = session {
            session = nil
            VTCompressionSessionInvalidate(old)
        }
        guard encoderRecoveryCount < maximumEncoderRecoveries else {
            active = false
            onEvent?("Encoder failed after repeated recovery attempts; restart mirroring")
            return
        }
        encoderRecoveryCount += 1
        lastPTS = nil
        firstPTS = nil
        forceKeyframe = true
        do {
            try configureSession()
            onEvent?("Video encoder recovered (\(encoderRecoveryCount)/\(maximumEncoderRecoveries))")
        } catch {
            active = false
            onEvent?("Encoder recovery failed: " + error.localizedDescription)
        }
    }

    func requestKeyframe() {
        renderQueue.async { [weak self] in self?.forceKeyframe = true }
    }

    private func handleEncoded(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return }
        guard CMBlockBufferGetDataLength(block) > 0 else { return }
        let total = CMBlockBufferGetDataLength(block)
        var data = Data(count: total)
        let copy = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                       dataLength: total, destination: $0.baseAddress!)
        }
        guard copy == kCMBlockBufferNoErr else { return }
        let flags = CMSampleBufferGetSampleAttachmentsArray(sample,
                                                             createIfNecessary: false)
                        as? [[CFString: Any]]
        let sync = flags?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let key = !sync
        var annexB = Data()
        let startCode = Data([0,0,0,1])
        if key {
            // The receiver starts decoding on IDR. Include the decoder
            // configuration on *each* keyframe so late joins and picture-loss
            // recovery can recover without waiting for an out-of-band SPS/PPS.
            let hevc = codec == kCMVideoCodecType_HEVC
            for index in 0..<(hevc ? 3 : 2) {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var nalLength: Int32 = 0
                let status: OSStatus
                if hevc {
                    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: &count,
                        nalUnitHeaderLengthOut: &nalLength)
                } else {
                    status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: &count,
                        nalUnitHeaderLengthOut: &nalLength)
                }
                if status == noErr, let pointer, size > 0 {
                    annexB.append(startCode)
                    annexB.append(pointer, count: size)
                }
            }
        }
        let source = [UInt8](data)
        var offset = 0
        while offset + 4 <= source.count {
            let n = Int(source[offset]) << 24 | Int(source[offset + 1]) << 16 |
                    Int(source[offset + 2]) << 8 | Int(source[offset + 3])
            offset += 4
            guard n > 0, n <= source.count - offset else { break }
            annexB.append(startCode)
            annexB.append(contentsOf: source[offset..<(offset + n)])
            offset += n
        }
        guard !annexB.isEmpty else { return }
        let seconds = CMTimeGetSeconds(sample.presentationTimeStamp)
        guard seconds.isFinite && seconds >= 0 else { return }
        let timestamp = UInt32(truncatingIfNeeded: UInt64(seconds * 90_000))
        onFrame?(annexB, timestamp, key)
    }

    func stop() {
        renderQueue.sync {
            active = false
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }
}
