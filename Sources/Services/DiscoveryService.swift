import Foundation
import Network

/// Bonjour browse for `_androidtvremote2._tcp` (Google TV Remote Service).
final class DiscoveryService: @unchecked Sendable {
    func scan(timeout: TimeInterval) async throws -> [TVDevice] {
        try await withCheckedThrowingContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_androidtvremote2._tcp", domain: nil),
                using: .tcp
            )
            var found: [String: TVDevice] = [:]
            let lock = NSLock()
            var resumed = false

            func finish(_ result: Result<[TVDevice], Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                browser.cancel()
                continuation.resume(with: result)
            }

            browser.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    finish(.failure(error))
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, type, domain, interface) = result.endpoint else { continue }
                    let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                    let conn = NWConnection(to: endpoint, using: .tcp)
                    conn.stateUpdateHandler = { state in
                        if case .ready = state {
                            if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                                let hostStr: String
                                switch host {
                                case let .ipv4(v4): hostStr = "\(v4)"
                                case let .ipv6(v6): hostStr = "\(v6)"
                                case let .name(n, _): hostStr = n
                                @unknown default: hostStr = "\(host)"
                                }
                                let device = TVDevice(
                                    name: name.replacingOccurrences(of: "._androidtvremote2._tcp.local.", with: ""),
                                    host: hostStr,
                                    port: Int(port.rawValue)
                                )
                                lock.lock()
                                found[device.id] = device
                                lock.unlock()
                            }
                            conn.cancel()
                        }
                    }
                    conn.start(queue: .global())
                }
            }

            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                let list = Array(found.values).sorted { $0.name < $1.name }
                lock.unlock()
                finish(.success(list))
            }
        }
    }
}

