import SwiftUI
import AVFAudio
import UIKit

/// Live microphone input for Android TV Remote v2 voice search.
/// 8 kHz, 16-bit signed mono PCM goes only to the paired TV's TLS session.
@MainActor
final class TVMicrophoneSession: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "Preparing voice search…"
    @Published private(set) var error: String?

    private var engine: AVAudioEngine?
    private var pendingPCM = Data()
    private var generation = UUID()
    private let chunkSize = 8192

    func start(using tv: TVSessionModel) async {
        guard !isStarting, !isListening else { return }
        guard tv.isConnected else {
            error = "Connect to your TV before using voice search."
            status = "Not connected"
            return
        }
        generation = UUID()
        let id = generation
        isStarting = true
        status = "Allow microphone access"
        error = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            guard generation == id else { return }
            error = "Microphone access is off. Enable CastDeck in Settings → Privacy & Security → Microphone."
            status = "Microphone not available"
            isStarting = false
            CastDeckLog.shared.write("voice", "Microphone permission denied")
            return
        }
        guard generation == id else { return }

        do {
            status = "Connecting microphone to TV…"
            try await tv.beginVoice()
            guard generation == id else {
                tv.endVoice()
                return
            }
            try prepareAndStartCapture(using: tv, generation: id)
            isListening = true
            isStarting = false
            status = "Listening on your iPhone"
            CastDeckLog.shared.write("voice", "Microphone streaming to paired TV started (8 kHz PCM)")
        } catch {
            guard generation == id else { return }
            tv.endVoice()
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.error = error.localizedDescription
            status = "Voice search unavailable"
            isListening = false
            isStarting = false
            CastDeckLog.shared.write("voice", "Could not start voice: " + error.localizedDescription)
        }
    }

    private func prepareAndStartCapture(using tv: TVSessionModel, generation id: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 8_000,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AndroidTVClientError.underlying("Unable to convert iPhone microphone audio to TV format.")
        }

        node.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            // Copy samples while still within the audio callback. Their original
            // storage can be reused by the engine immediately after returning.
            guard let owned = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               frameCapacity: buffer.frameLength) else { return }
            owned.frameLength = buffer.frameLength
            let inputs = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let outputs = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
            for index in 0..<min(inputs.count, outputs.count) {
                guard let source = inputs[index].mData,
                      let dest = outputs[index].mData else { continue }
                memcpy(dest, source, Int(min(inputs[index].mDataByteSize,
                                             outputs[index].mDataByteSize)))
            }
            // Audio conversion occurs on a dedicated serial queue, not the
            // real-time microphone callback or the SwiftUI rendering thread.
            TVMicrophoneConverter.queue.async { [weak self] in
                guard let pcm = TVMicrophoneConverter.convert(
                    owned, converter: converter, format: outputFormat
                ) else { return }
                Task { @MainActor [weak self] in
                    self?.sendPCM(pcm, using: tv, generation: id)
                }
            }
        }
        self.engine = engine
        engine.prepare()
        do { try engine.start() }
        catch {
            node.removeTap(onBus: 0)
            self.engine = nil
            throw error
        }
    }

    private func sendPCM(_ bytes: Data, using tv: TVSessionModel, generation id: UUID) {
        guard generation == id, isListening || isStarting else { return }
        pendingPCM.append(bytes)
        do {
            while pendingPCM.count >= chunkSize {
                let packet = Data(pendingPCM.prefix(chunkSize))
                pendingPCM.removeFirst(chunkSize)
                try tv.sendVoicePCM(packet)
            }
        } catch {
            self.error = error.localizedDescription
            status = "Microphone disconnected"
            CastDeckLog.shared.write("voice", "Microphone transmission failed: " + error.localizedDescription)
            stop(using: tv, retainError: true)
        }
    }

    func stop(using tv: TVSessionModel, retainError: Bool = false) {
        generation = UUID()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // The TV voice protocol expects at least 8 KiB per packet; pad the
        // final partial buffer with silence before sending RemoteVoiceEnd.
        if isListening && !pendingPCM.isEmpty {
            var final = pendingPCM
            final.append(Data(repeating: 0, count: max(0, chunkSize - final.count)))
            try? tv.sendVoicePCM(final)
        }
        pendingPCM.removeAll()
        tv.endVoice()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        isStarting = false
        status = retainError ? "Voice search unavailable" : "Microphone off"
        if !retainError { error = nil }
        CastDeckLog.shared.write("voice", "Microphone stopped; TV voice session closed")
    }
}

/// Conversion is deliberately isolated from the mic's real-time audio thread.
private enum TVMicrophoneConverter {
    static let queue = DispatchQueue(label: "castdeck.microphone.converter", qos: .userInitiated)

    static func convert(_ source: AVAudioPCMBuffer,
                        converter: AVAudioConverter,
                        format: AVAudioFormat) -> Data? {
        let frames = AVAudioFrameCount(
            ceil(Double(source.frameLength) * 8_000 / source.format.sampleRate)
        ) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        var provided = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if provided {
                state.pointee = .noDataNow
                return nil
            }
            provided = true
            state.pointee = .haveData
            return source
        }
        guard error == nil, result != .error,
              output.frameLength > 0,
              let channel = output.int16ChannelData?.pointee else { return nil }
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

struct VoicePanel: View {
    @EnvironmentObject private var tv: TVSessionModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var voice: TVMicrophoneSession

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(voice.isListening ? Color.white : Color.primary)
                .frame(width: 108, height: 108)
                .background(
                    voice.isListening ? Color.indigo : Color.secondary.opacity(0.12),
                    in: Circle()
                )
                .accessibilityLabel(voice.isListening ? "Microphone on" : "Microphone off")

            Text(voice.isListening ? "Speak to your TV" : "Voice Search")
                .font(.title2.bold())
            Text(voice.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if voice.isStarting {
                ProgressView()
            }
            if let error = voice.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Spacer(minLength: 12)
            Button {
                voice.stop(using: tv)
                dismiss()
            } label: {
                Text(voice.isListening ? "Done talking" : "Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .onAppear {
            Task { await voice.start(using: tv) }
        }
        .onDisappear { voice.stop(using: tv) }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
