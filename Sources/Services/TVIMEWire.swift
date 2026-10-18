import Foundation

/// Google TV Remote v2 on-TV IME messages. The TV controls field counters;
/// the phone edits only the currently focused field. Never log field values.
enum TVIMEWire {
    struct Context: Equatable {
        var imeCounter = 0
        var fieldCounter = 0
        var label = ""
        var hasFocusedField = false
    }

    struct Update {
        var imeCounter: Int?
        var fieldCounter: Int?
        var label: String?
        var showKeyboard = false
        var fieldActive = false
    }

    private static func varint(_ value: UInt64) -> Data {
        var n = value
        var result = Data()
        repeat {
            var b = UInt8(n & 127)
            n >>= 7
            if n != 0 { b |= 128 }
            result.append(b)
        } while n != 0
        return result
    }

    private static func integer(_ field: UInt64, _ value: Int) -> Data {
        var result = varint(field << 3)
        result.append(varint(UInt64(max(0, value))))
        return result
    }

    private static func bytes(_ field: UInt64, _ value: Data) -> Data {
        var result = varint((field << 3) | 2)
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    static func frame(_ body: Data) -> Data {
        var framed = varint(UInt64(body.count))
        framed.append(body)
        return framed
    }

    /// RemoteMessage.remote_ime_batch_edit = field 21.
    /// Follow androidtvremote2's RemoteEditInfo(insert=1, text_field_status).
    static func text(_ value: String, context: Context) -> Data {
        let position = max(0, value.utf16.count - 1)
        var textObject = integer(1, position)
        textObject.append(integer(2, position))
        textObject.append(bytes(3, Data(value.utf8)))
        var edit = integer(1, 1)
        edit.append(bytes(2, textObject))
        var batch = integer(1, context.imeCounter)
        batch.append(integer(2, context.fieldCounter))
        batch.append(bytes(3, edit))
        return bytes(21, batch)
    }

    private static func scan(_ data: Data) -> [(Int, Data, UInt64?)] {
        var found: [(Int, Data, UInt64?)] = []
        var offset = 0
        while offset < data.count {
            guard let tag = readVarint(data, position: &offset) else { break }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = readVarint(data, position: &offset) else { return found }
                found.append((field, Data(), value))
            case 2:
                guard let size = readVarint(data, position: &offset),
                      size <= UInt64(data.count - offset) else { return found }
                let end = offset + Int(size)
                found.append((field, Data(data[offset..<end]), nil))
                offset = end
            case 1:
                guard offset + 8 <= data.count else { return found }
                offset += 8
            case 5:
                guard offset + 4 <= data.count else { return found }
                offset += 4
            default: return found
            }
        }
        return found
    }

    private static func readVarint(_ data: Data, position: inout Int) -> UInt64? {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard position < data.count else { return nil }
            let b = data[position]
            position += 1
            if shift < 63 { result |= UInt64(b & 127) << shift }
            else if b > 1 { return nil }
            if b & 128 == 0 { return result }
        }
        return nil
    }

    static func updates(in message: Data) -> [Update] {
        var updates: [Update] = []
        for (field, payload, _) in scan(message) {
            switch field {
            case 21:
                let fields = scan(payload)
                var update = Update()
                update.imeCounter = fields.first(where: { $0.0 == 1 })?.2.map(Int.init)
                update.fieldCounter = fields.first(where: { $0.0 == 2 })?.2.map(Int.init)
                update.fieldActive = true
                updates.append(update)
            case 22:
                var update = Update()
                update.showKeyboard = true
                update.fieldActive = true
                if let status = scan(payload).first(where: { $0.0 == 2 })?.1 {
                    let nested = scan(status)
                    update.fieldCounter = nested.first(where: { $0.0 == 1 })?.2.map(Int.init)
                    if let label = nested.first(where: { $0.0 == 6 })?.1 {
                        update.label = String(data: label, encoding: .utf8)
                    }
                }
                updates.append(update)
            case 20:
                var update = Update()
                update.fieldActive = true
                if let status = scan(payload).first(where: { $0.0 == 2 })?.1 {
                    let nested = scan(status)
                    update.fieldCounter = nested.first(where: { $0.0 == 1 })?.2.map(Int.init)
                    if let label = nested.first(where: { $0.0 == 6 })?.1 {
                        update.label = String(data: label, encoding: .utf8)
                    }
                }
                updates.append(update)
            default: break
            }
        }
        return updates
    }
}
