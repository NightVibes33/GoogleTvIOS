import Foundation

struct TVDevice: Identifiable, Hashable, Codable {
    var id: String { "\(host):\(port)" }
    let name: String
    let host: String
    let port: Int
}
