import Foundation
import Network

/// Finds Android TV Remote v2 receivers and cast-only receivers separately.
/// Older Chromecasts expose Cast protocol but do not implement the Android TV D-pad API.
final class DiscoveryService {
    func scan(timeout: TimeInterval = 5) async -> [TVDevice] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "CastDeck.discovery")
            var found: [String: TVDevice] = [:]
            var browsers: [NWBrowser] = []
            var probes: [NWConnection] = []
            var finished = false

            for (service, kind) in [
                ("_androidtvremote2._tcp", TVDevice.Kind.googleTV),
                ("_googlecast._tcp", TVDevice.Kind.castOnly)
            ] {
                let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: .tcp)
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case .service(let name, let type, let domain, let interface) = result.endpoint else {
                            continue
                        }
                        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                        let probe = NWConnection(to: endpoint, using: .tcp)
                        probes.append(probe)
                        probe.stateUpdateHandler = { state in
                            guard !finished else { probe.cancel(); return }
                            if case .ready = state {
                                if case .hostPort(let host, _) = probe.currentPath?.remoteEndpoint {
                                    let address: String
                                    switch host {
                                    case .ipv4(let value): address = String(describing: value)
                                    case .ipv6(let value): address = String(describing: value)
                                    case .name(let value, _): address = value
                                    @unknown default: address = String(describing: host)
                                    }
                                    let display = name.replacingOccurrences(
                                        of: "._androidtvremote2._tcp.local.", with: ""
                                    )
                                    let item = TVDevice(
                                        name: display,
                                        host: address,
                                        port: kind == .googleTV ? 6466 : 8009,
                                        kind: kind
                                    )
                                    if found[address]?.supportsRemote != true || item.supportsRemote {
                                        found[address] = item
                                    }
                                }
                                probe.cancel()
                            }
                        }
                        probe.start(queue: queue)
                    }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
            queue.asyncAfter(deadline: .now() + max(1, timeout)) {
                guard !finished else { return }
                finished = true
                browsers.forEach { $0.cancel() }
                probes.forEach { $0.cancel() }
                continuation.resume(returning: found.values.sorted {
                    if $0.supportsRemote != $1.supportsRemote { return $0.supportsRemote }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                })
            }
        }
    }
}