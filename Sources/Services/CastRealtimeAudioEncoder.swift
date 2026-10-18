import Foundation
import AVFAudio
import CoreMedia
import AudioToolbox

/// Converts ScreenCaptureKit's live system-audio PCM buffers to 48 kHz
/// stereo AAC-LC access units for encrypted Cast Streaming RTP.
/// Uses in-memory compression; no recordings or temporary audio files.
final class CastRealtimeAudioEncoder {
    var onPacket: ((Data, UInt32) -> Void)?
    var onEvent: ((String) -> Void)?
    private let queue = DispatchQueue(label: "castdeck.cast.audio", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var packetTime: UInt64?
    private var didLogStart = false
    private var active = true

    func process(_ sample: CMSampleBuffer) {
        queue.async { [weak self] in
            self?.encode(sample)
        }
    }

    private func encode(_ sample: CMSampleBuffer) {
        guard active, CMSampleBufferIsValid(sample),
              let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }

        if converter == nil || sourceFormat?.sampleRate != format.sampleRate ||
           sourceFormat?.channelCount != format.channelCount {
            // Cast uses AAC-LC (48k stereo); the receiver advertises the
            // accepted stream index in ANSWER before we start capture.
            guard let destination = AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]), let created = AVAudioConverter(from: format, to: destination) else {
                onEvent?("Could not initialize on-device AAC audio encoder")
                return
            }
            converter = created
            sourceFormat = format
            targetFormat = destination
        }

        guard let converter, let targetFormat,
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(
                                            CMSampleBufferGetNumSamples(sample))) else { return }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(input.frameLength),
            into: input.mutableAudioBufferList)
        guard status == noErr else {
            if !didLogStart { onEvent?("Could not copy system audio PCM from ScreenCaptureKit (\(status))") }
            return
        }
        let compressed = AVAudioCompressedBuffer(format: targetFormat,
                                                packetCapacity: 12,
                                                maximumPacketSize: converter.maximumOutputPacketSize)
        var inputConsumed = false
        var error: NSError?
        let output = converter.convert(to: compressed, error: &error) { _, inputStatus in
            if inputConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error {
            onEvent?("AAC encoding error: " + error.localizedDescription)
            return
        }
        guard output != .error, compressed.byteLength > 0 else { return }
        let packetData = Data(bytes: compressed.data, count: Int(compressed.byteLength))
        guard !packetData.isEmpty else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return }
        let pts = UInt32(truncatingIfNeeded: UInt64(seconds * 48_000))
        if let descriptions = compressed.packetDescriptions,
           compressed.packetCount > 0 {
            for i in 0..<Int(compressed.packetCount) {
                let part = descriptions[i]
                let from = Int(part.mStartOffset)
                let count = Int(part.mDataByteSize)
                guard from >= 0, count > 0, from + count <= packetData.count else { continue }
                onPacket?(packetData.subdata(in: from..<(from+count)),
                          pts &+ UInt32(i * 1024))
            }
        } else {
            onPacket?(packetData, pts)
        }
        if !didLogStart {
            didLogStart = true
            onEvent?("System audio AAC packets encoded in memory, 48 kHz stereo")
        }
    }

    func stop() {
        queue.sync {
            active = false
            converter = nil
            sourceFormat = nil
            targetFormat = nil
        }
    }
}
