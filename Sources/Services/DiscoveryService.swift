import Foundation
import Network

/// Bonjour lookup for Android TV Remote v2 and cast-only devices.
final class DiscoveryService {
    private final class State: @unchecked Sendable {
        // All fields are accessed only on the one serial discovery DispatchQueue.
        var found: [String: TVDevice] = [:]
        var browsers: [NWBrowser] = []
        var probes: [NWConnection] = []
        var finished = false

        func cancel() {
            finished = true
            for browser in browsers {
                browser.browseResultsChangedHandler = nil
                browser.stateUpdateHandler = nil
                browser.cancel()
            }
            for probe in probes {
                probe.stateUpdateHandler = nil
                probe.cancel()
            }
            browsers.removeAll()
            probes.removeAll()
        }
    }

    func scan(timeout: TimeInterval = 5) async -> [TVDevice] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "CastDeck.discovery")
            let state = State()

            for (service, kind) in [
                ("_androidtvremote2._tcp", TVDevice.Kind.googleTV),
                ("_googlecast._tcp", TVDevice.Kind.castOnly)
            ] {
                let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: .tcp)
                browser.browseResultsChangedHandler = { results, _ in
                    guard !state.finished else { return }
                    for result in results {
                        guard case .service(let name, let type, let domain, let interface) = result.endpoint else {
                            continue
                        }
                        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                        let probe = NWConnection(to: endpoint, using: .tcp)
                        state.probes.append(probe)
                        probe.stateUpdateHandler = { status in
                            guard !state.finished else { probe.cancel(); return }
                            if case .ready = status {
                                if case .hostPort(let host, _) = probe.currentPath?.remoteEndpoint {
                                    let address: String
                                    switch host {
                                    case .ipv4(let value): address = String(describing: value)
                                    case .ipv6(let value): address = String(describing: value)
                                    case .name(let value, _): address = value
                                    @unknown default: address = String(describing: host)
                                    }
                                    let displayName = name.replacingOccurrences(
                                        of: "._androidtvremote2._tcp.local.", with: ""
                                    )
                                    let device = TVDevice(
                                        name: displayName,
                                        host: address,
                                        port: kind == .googleTV ? 6466 : 8009,
                                        kind: kind
                                    )
                                    if state.found[address]?.supportsRemote != true || device.supportsRemote {
                                        state.found[address] = device
                                    }
                                }
                                probe.cancel()
                            }
                        }
                        probe.start(queue: queue)
                    }
                }
                browser.start(queue: queue)
                state.browsers.append(browser)
            }

            queue.asyncAfter(deadline: .now() + max(1, timeout)) {
                guard !state.finished else { return }
                let result = state.found.values.sorted {
                    if $0.supportsRemote != $1.supportsRemote { return $0.supportsRemote }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                state.cancel()
                continuation.resume(returning: result)
            }
        }
    }
}
