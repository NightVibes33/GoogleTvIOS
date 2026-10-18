import Foundation
import Network
import CommonCrypto
import Security

/// Encrypted Cast Streaming RTP (not WebRTC/SRTP, not HTTP/HLS).
/// Implements Cast's RTP frame header, AES-128 CTR, sender reports and
/// the CAST RTCP checkpoint/NACK retransmission channel.
final class CastRealtimeWire {
    struct Offer {
        let ssrc: UInt32
        let key: Data
        let ivMask: Data
        let payloadType: UInt8
        let codec: String
        let delayMS: Int

        static func audio() -> Offer {
            var key = Data(count: 16)
            var mask = Data(count: 16)
            _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            _ = mask.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return Offer(ssrc: UInt32.random(in: 1..<UInt32.max),
                         key: key, ivMask: mask, payloadType: 127,
                         codec: "aac", delayMS: 120)
        }

        func audioJSON() -> [String: Any] {
            ["index": 1, "type": "audio_source", "codecName": "aac",
             "codecParameter": "mp4a.40.2", "rtpProfile": "cast",
             "rtpPayloadType": Int(payloadType), "ssrc": Int(ssrc),
             "targetDelay": delayMS, "timeBase": "1/48000",
             "aesKey": key.hex, "aesIvMask": ivMask.hex,
             "bitRate": 128_000, "sampleRate": 48_000, "channels": 2]
        }

        static func video(codec: String = "h264") -> Offer {
            var key = Data(count: 16)
            var mask = Data(count: 16)
            _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            _ = mask.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return Offer(ssrc: UInt32.random(in: 1..<UInt32.max), key: key, ivMask: mask,
                         payloadType: 96, codec: codec, delayMS: 120)
        }

        func json(width: Int, height: Int, bitrate: Int) -> [String: Any] {
            [
                "index": 0, "type": "video_source", "codecName": codec,
                "codecParameter": codec == "hevc" ? "hev1.1.6.L153.B0" : "avc1.640028",
                "profile": codec == "hevc" ? "main" : "high",
                "level": codec == "hevc" ? "5.1" : "4.1",
                "rtpProfile": "cast", "rtpPayloadType": Int(payloadType),
                "ssrc": Int(ssrc), "targetDelay": delayMS,
                "timeBase": "1/90000", "aesKey": key.hex,
                "aesIvMask": ivMask.hex, "maxFrameRate": "30000/1000",
                "maxBitRate": bitrate,
                "resolutions": [["width": width, "height": height]]
            ]
        }
    }

    enum TransportError: LocalizedError {
        case invalidOffer
        case udpFailed(String)
        case encryptionFailed
        var errorDescription: String? {
            switch self {
            case .invalidOffer: return "Chromecast returned an invalid real-time streaming answer."
            case .udpFailed(let message): return "Real-time Chromecast connection: " + message
            case .encryptionFailed: return "Cast Streaming AES-CTR encryption failed."
            }
        }
    }

    var onEvent: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onPacketLoss: (() -> Void)?
    private let queue = DispatchQueue(label: "castdeck.cast.rtp", qos: .userInitiated)
    let offer: Offer
    let audioOffer: Offer?
    private var audioFrameID: UInt32 = 0
    private var audioSequence: UInt16 = 0
    private var audioSent: [UInt8: [Data]] = [:]
    private var audioPackets: UInt32 = 0
    private var audioOctets: UInt32 = 0
    private var connection: NWConnection?
    private var stateReady = false
    private var frameID: UInt32 = 0
    private var sequence: UInt16 = 0
    private var sent: [UInt8: [Data]] = [:]
    private var lastCheckpoint: UInt8?
    private var sentPackets: UInt32 = 0
    private var sentOctets: UInt32 = 0
    private var lastTimestamp: UInt32 = 0
    private var lastReport = DispatchTime.now()
    private var pendingFrames: [(Data, UInt32, Bool)] = []

    init(offer: Offer, audioOffer: Offer? = nil) {
        self.offer = offer
        self.audioOffer = audioOffer
    }

    func connect(host: String, udpPort: UInt16) {
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: udpPort)!,
                                      using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateReady = true
                self.onEvent?("Cast Streaming RTP UDP connected to \(host):\(udpPort)")
                self.onReady?()
                self.drainPending()
                self.receiveFeedback()
            case .failed(let error):
                self.stateReady = false
                self.onEvent?("RTP connection failed: " + error.localizedDescription)
            case .cancelled:
                self.stateReady = false
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Complete frame payloads, Annex-B H.264 access units, are encrypted
    /// individually and split into <= MTU Cast-RTP packets.
    func sendFrame(_ frame: Data, timestamp: UInt32, keyFrame: Bool) {
        queue.async { [weak self] in
            guard let self, !frame.isEmpty else { return }
            if !self.stateReady {
                if self.pendingFrames.count < 3 {
                    self.pendingFrames.append((frame, timestamp, keyFrame))
                }
                return
            }
            self.sendPrepared(frame, timestamp: timestamp, keyFrame: keyFrame)
        }
    }

    func sendAudio(_ bytes: Data, timestamp: UInt32) {
        guard let audioOffer, !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.stateReady else { return }
            self.sendAudioPrepared(bytes, timestamp: timestamp, offer: audioOffer)
        }
    }

    private func sendAudioPrepared(_ source: Data, timestamp: UInt32, offer: Offer) {
        guard let encrypted = encrypt(frameID: audioFrameID, source: source, key: offer.key, ivMask: offer.ivMask) else {
            return
        }
        let maxChunk = 1450
        let count = max(1, (encrypted.count + maxChunk - 1) / maxChunk)
        guard count <= 65535 else { return }
        var packets: [Data] = []
        for id in 0..<count {
            let from = id * maxChunk
            let to = min(from + maxChunk, encrypted.count)
            var packet = Data(repeating: 0, count: 19)
            packet[0] = 0x80
            packet[1] = offer.payloadType | (id == count-1 ? 0x80 : 0)
            packet.set16(audioSequence, at: 2)
            packet.set32(timestamp, at: 4)
            packet.set32(offer.ssrc, at: 8)
            packet[12] = 0xc0
            packet[13] = UInt8(truncatingIfNeeded: audioFrameID)
            packet.set16(UInt16(id), at: 14)
            packet.set16(UInt16(count-1), at: 16)
            packet[18] = UInt8(truncatingIfNeeded: audioFrameID)
            packet.append(encrypted[from..<to])
            packets.append(packet)
            audioSequence &+= 1
        }
        audioSent[UInt8(truncatingIfNeeded: audioFrameID)] = packets
        if audioSent.count > 96 {
            audioSent.removeValue(forKey: UInt8(truncatingIfNeeded: audioFrameID &- 96))
        }
        for packet in packets {
            connection?.send(content: packet, completion: .contentProcessed { _ in })
            audioPackets &+= 1
            audioOctets &+= UInt32(max(0, packet.count-19))
        }
        audioFrameID &+= 1
        if audioFrameID % 20 == 0 {
            sendSenderReport(timestamp: timestamp, ssrc: offer.ssrc,
                             packets: audioPackets, octets: audioOctets)
        }
    }

    private func drainPending() {
        let frames = pendingFrames
        pendingFrames.removeAll()
        for (frame, time, key) in frames { sendPrepared(frame, timestamp: time, keyFrame: key) }
    }

    private func sendPrepared(_ data: Data, timestamp: UInt32, keyFrame: Bool) {
        guard let encrypted = encrypt(frameID: frameID, source: data,
                                      key: offer.key, ivMask: offer.ivMask) else {
            onEvent?("Cast RTP encryption failed")
            return
        }
        let maxChunk = 1450
        let count = max(1, (encrypted.count + maxChunk - 1) / maxChunk)
        guard count <= UInt16.max else { return }
        var packets: [Data] = []
        for packetID in 0..<count {
            let lower = packetID * maxChunk
            let upper = min(lower + maxChunk, encrypted.count)
            var bytes = Data(repeating: 0, count: 19)
            bytes[0] = 0x80
            bytes[1] = offer.payloadType | (packetID == count - 1 ? 0x80 : 0)
            bytes.set16(sequence, at: 2)
            bytes.set32(timestamp, at: 4)
            bytes.set32(offer.ssrc, at: 8)
            bytes[12] = (keyFrame ? 0x80 : 0) | 0x40
            bytes[13] = UInt8(truncatingIfNeeded: frameID)
            bytes.set16(UInt16(packetID), at: 14)
            bytes.set16(UInt16(count - 1), at: 16)
            bytes[18] = UInt8(truncatingIfNeeded: keyFrame ? frameID : frameID &- 1)
            bytes.append(encrypted[lower..<upper])
            packets.append(bytes)
            sequence &+= 1
        }
        sent[UInt8(truncatingIfNeeded: frameID)] = packets
        // Receiver NACK only addresses the lower 8 bits; retain a bounded
        // window and avoid unbounded memory growth at high frame rates.
        if sent.count > 96 {
            let delete = UInt8(truncatingIfNeeded: frameID &- 96)
            sent.removeValue(forKey: delete)
        }
        for packet in packets {
            connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error { self?.onEvent?("RTP packet send error: " + error.localizedDescription) }
            })
            sentPackets &+= 1
            sentOctets &+= UInt32(max(0, packet.count - 19))
        }
        lastTimestamp = timestamp
        frameID &+= 1
        if frameID % 15 == 0 { sendSenderReport(timestamp: timestamp,
                                                       ssrc: offer.ssrc, packets: sentPackets,
                                                       octets: sentOctets) }
        if frameID == 1 { onEvent?("First Cast Streaming video frame sent") }
    }

    private func sendSenderReport(timestamp: UInt32, ssrc: UInt32,
                                  packets: UInt32, octets: UInt32) {
        let now = Date().timeIntervalSince1970 + 2_208_988_800
        let whole = UInt64(now)
        let fraction = UInt64((now - Double(whole)) * 4_294_967_296)
        var data = Data(repeating: 0, count: 28)
        data[0] = 0x80; data[1] = 200
        data.set16(6, at: 2)
        data.set32(ssrc, at: 4)
        data.set32(UInt32(truncatingIfNeeded: whole), at: 8)
        data.set32(UInt32(truncatingIfNeeded: fraction), at: 12)
        data.set32(timestamp, at: 16)
        data.set32(packets, at: 20)
        data.set32(octets, at: 24)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveFeedback() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, self.stateReady else { return }
            if let data { self.parseRTCP(data) }
            self.receiveFeedback()
        }
    }

    private func parseRTCP(_ packet: Data) {
        var offset = 0
        while offset + 4 <= packet.count {
            let size = 4 + Int(packet.uint16(at: offset + 2)) * 4
            guard size > 0, offset + size <= packet.count else { return }
            let kind = packet[offset + 1]
            let subtype = packet[offset] & 0x1f
            if kind == 206 && subtype == 1 {
                onEvent?("Chromecast requested an IDR keyframe (PLI)")
                onPacketLoss?()
            }
            if (kind == 204 || kind == 206) && subtype == 15 && size >= 20 &&
               packet.subdata(in: (offset + 12)..<(offset + 16)) == Data("CAST".utf8) {
                let checkpoint = packet[offset + 16]
                let lossCount = Int(packet[offset + 17])
                if lastCheckpoint != checkpoint {
                    lastCheckpoint = checkpoint
                    if checkpoint % 60 == 0 {
                        onEvent?("Cast RTCP checkpoint advanced to \(checkpoint)")
                    }
                }
                let mediaSSRC = packet.uint32(at: offset+8)
                let ring = mediaSSRC == audioOffer?.ssrc ? audioSent : sent
                for i in 0..<lossCount {
                    let start = offset + 20 + i * 4
                    guard start + 4 <= offset + size else { break }
                    let target = packet[start]
                    let number = packet.uint16(at: start + 1)
                    let mask = packet[start + 3]
                    guard let framePackets = ring[target] else { continue }
                    if number == UInt16.max {
                        for data in framePackets { connection?.send(content: data, completion: .contentProcessed { _ in }) }
                        continue
                    }
                    let ids = [Int(number)] + (0..<8).compactMap { (mask & (1 << $0)) > 0 ? Int(number) + $0 + 1 : nil }
                    for id in ids where id < framePackets.count {
                        connection?.send(content: framePackets[id], completion: .contentProcessed { _ in })
                    }
                }
            }
            offset += size
        }
    }

    private func encrypt(frameID: UInt32, source: Data, key: Data, ivMask: Data) -> Data? {
        guard key.count == 16, ivMask.count == 16 else { return nil }
        var counter = [UInt8](repeating: 0, count: 16)
        let frameWord = frameID.bigEndian
        withUnsafeBytes(of: frameWord) { bytes in
            for i in 0..<4 { counter[8 + i] = bytes[i] }
        }
        for i in 0..<16 { counter[i] ^= ivMask[i] }
        let bytes = [UInt8](source)
        var output = [UInt8](repeating: 0, count: bytes.count)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            var encrypted = [UInt8](repeating: 0, count: 16)
            var used = 0
            let status: CCCryptorStatus = key.withUnsafeBytes { keyPtr in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), keyPtr.baseAddress, 16, nil,
                        counter, 16, &encrypted, 16, &used)
            }
            guard status == kCCSuccess, used == 16 else { return nil }
            for offset in 0..<min(16, bytes.count - start) {
                output[start + offset] = bytes[start + offset] ^ encrypted[offset]
            }
            for i in stride(from: 15, through: 0, by: -1) {
                counter[i] &+= 1
                if counter[i] != 0 { break }
            }
        }
        return Data(output)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateReady = false
            self.connection?.cancel()
            self.connection = nil
            self.sent.removeAll()
            self.audioSent.removeAll()
            self.pendingFrames.removeAll()
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    mutating func set16(_ n: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: n >> 8)
        self[offset+1] = UInt8(truncatingIfNeeded: n)
    }
    mutating func set32(_ n: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset+i] = UInt8(truncatingIfNeeded: n >> (24-i*8)) }
    }
    func uint16(at index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index+1])
    }
    func uint32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index+1]) << 16 |
        UInt32(self[index+2]) << 8 | UInt32(self[index+3])
    }
}
