import Foundation

struct TVDevice: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case googleTV
        case castOnly
    }
    var id: String { host + ":" + String(port) + ":" + kind.rawValue }
    let name: String
    let host: String
    let port: Int
    var kind: Kind = .googleTV

    var supportsRemote: Bool { kind == .googleTV }
}