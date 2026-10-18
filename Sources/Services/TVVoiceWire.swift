import Foundation

/// Minimal Android TV Remote v2 voice protobuf messages on the already-paired
/// TLS transport. Audio is never stored, transcribed, uploaded to the internet,
/// or written to CastDeck's diagnostic files.
enum TVVoiceWire {
    static let maxMessageSize = 65_536

    private static func varint(_ value: UInt64) -> Data {
        var current = value
        var result = Data()
        repeat {
            var byte = UInt8(current & 0x7f)
            current >>= 7
            if current > 0 { byte |= 0x80 }
            result.append(byte)
        } while current > 0
        return result
    }

    private static func fieldVarint(_ field: UInt64, _ value: UInt64) -> Data {
        var data = varint(field << 3)
        data.append(varint(value))
        return data
    }

    private static func fieldBytes(_ field: UInt64, _ bytes: Data) -> Data {
        var data = varint((field << 3) | 2)
        data.append(varint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    private static func frame(field: UInt64, nested: Data) -> Data {
        let body = fieldBytes(field, nested)
        var message = varint(UInt64(body.count))
        message.append(body)
        return message
    }

    static func begin(sessionID: UInt32) -> Data {
        frame(field: 30, nested: fieldVarint(1, UInt64(sessionID)))
    }

    static func payload(sessionID: UInt32, audio: Data) -> Data {
        var nested = fieldVarint(1, UInt64(sessionID))
        nested.append(fieldBytes(2, audio))
        return frame(field: 31, nested: nested)
    }

    static func end(sessionID: UInt32) -> Data {
        frame(field: 32, nested: fieldVarint(1, UInt64(sessionID)))
    }

    private static func readVarint(_ data: Data, index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for bit in stride(from: 0, to: 63, by: 7) {
            guard index < data.count else { return nil }
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << bit
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    /// The TCP stream is not packet-aligned. Consume complete varint-length
    /// frames and leave incomplete frames buffered until the next callback.
    static func nextMessage(from data: inout Data) -> Data? {
        var offset = 0
        guard let length = readVarint(data, index: &offset),
              length <= UInt64(maxMessageSize) else {
            if data.count > maxMessageSize { data.removeAll() }
            return nil
        }
        let count = Int(length)
        guard data.count >= offset + count else { return nil }
        let message = Data(data[offset..<(offset + count)])
        data.removeSubrange(0..<(offset + count))
        return message
    }

    static func voiceBeginSessionID(in message: Data) -> UInt32? {
        var position = 0
        while position < message.count {
            guard let tag = readVarint(message, index: &position) else { return nil }
            let field = tag >> 3
            switch tag & 7 {
            case 0:
                guard readVarint(message, index: &position) != nil else { return nil }
            case 1:
                guard message.count - position >= 8 else { return nil }
                position += 8
            case 2:
                guard let length = readVarint(message, index: &position),
                      length <= UInt64(message.count - position) else { return nil }
                let end = position + Int(length)
                if field == 30 {
                    let nested = Data(message[position..<end])
                    var child = 0
                    while child < nested.count {
                        guard let innerTag = readVarint(nested, index: &child) else { return nil }
                        if innerTag == 8, let id = readVarint(nested, index: &child),
                           id > 0, id <= UInt32.max {
                            return UInt32(id)
                        }
                        switch innerTag & 7 {
                        case 0: guard readVarint(nested, index: &child) != nil else { return nil }
                        case 2:
                            guard let bytes = readVarint(nested, index: &child),
                                  bytes <= UInt64(nested.count - child) else { return nil }
                            child += Int(bytes)
                        case 1: child += 8
                        case 5: child += 4
                        default: return nil
                        }
                    }
                }
                position = end
            case 5:
                guard message.count - position >= 4 else { return nil }
                position += 4
            default:
                return nil
            }
        }
        return nil
    }
}
