import Foundation
import Network

/// Bonjour browsing and resolution are separate steps. Never require a TCP connection
/// just to display an advertised receiver in the device picker.
struct DiscoveryReport {
    var devices: [TVDevice]
    var servicesFound: Int
    var resolved: Int
    var errors: [String]
}

@MainActor
final class DiscoveryService: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browsers: [NetServiceBrowser] = []
    private var services: [ObjectIdentifier: NetService] = [:]
    private var found: [String: TVDevice] = [:]
    private var seen: Set<String> = []
    private var errors: [String] = []
    private var probes: [String: NWConnection] = [:]
    private var completion: CheckedContinuation<DiscoveryReport, Never>?
    private var update: (([TVDevice], String) -> Void)?
    private var scanID = UUID()

    func scan(timeout: TimeInterval = 9,
              update: @escaping ([TVDevice], String) -> Void) async -> DiscoveryReport {
        finish()
        found = [:]
        seen = []
        errors = []
        self.update = update
        scanID = UUID()
        let id = scanID
        return await withCheckedContinuation { continuation in
            completion = continuation
            for type in ["_androidtvremote2._tcp.", "_googlecast._tcp."] {
                let browser = NetServiceBrowser()
                browser.delegate = self
                browsers.append(browser)
                browser.searchForServices(ofType: type, inDomain: "local.")
                update(sortedDevices, "Searching " + type)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(3, timeout) * 1_000_000_000))
                guard let self, self.scanID == id else { return }
                self.finish()
            }
        }
    }

    private var sortedDevices: [TVDevice] {
        found.values.sorted {
            if $0.supportsRemote != $1.supportsRemote { return $0.supportsRemote }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func notify(_ message: String) {
        update?(sortedDevices, message)
    }

    private func finish() {
        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()
        for service in services.values {
            service.delegate = nil
            service.stop()
        }
        services.removeAll()
        for probe in probes.values {
            probe.stateUpdateHandler = nil
            probe.cancel()
        }
        probes.removeAll()
        if let continuation = completion {
            completion = nil
            continuation.resume(returning: DiscoveryReport(
                devices: sortedDevices,
                servicesFound: seen.count,
                resolved: found.values.filter { !$0.host.isEmpty }.count,
                errors: errors
            ))
        }
        update = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let kind: TVDevice.Kind = service.type.contains("androidtvremote2") ? .googleTV : .castOnly
        let key = service.name.lowercased()
        let record = service.name + "|" + service.type
        seen.insert(record)
        let previous = found[key]
        if previous == nil || (kind == .googleTV && previous?.kind == .castOnly) {
            found[key] = TVDevice(name: service.name, host: previous?.host ?? "",
                                  port: kind == .googleTV ? 6466 : 8009, kind: kind)
        }
        notify("Found Bonjour service " + service.name + " (" + service.type + ")")
        service.delegate = self
        services[ObjectIdentifier(service)] = service
        service.resolve(withTimeout: 7)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName, !hostname.isEmpty else {
            notify("Resolved " + sender.name + " without hostname")
            return
        }
        let key = sender.name.lowercased()
        let kind: TVDevice.Kind = sender.type.contains("androidtvremote2") ? .googleTV : .castOnly
        let previous = found[key]
        let effectiveKind: TVDevice.Kind = previous?.kind == .googleTV ? .googleTV : kind
        found[key] = TVDevice(name: sender.name, host: hostname,
                              port: effectiveKind == .googleTV ? 6466 : 8009,
                              kind: effectiveKind)
        notify("Resolved " + sender.name + " to " + hostname)

        // Google TV receivers may advertise the Cast service but not the remote2
        // service. Probe their TCP 6466 port to detect real remote-v2 support.
        if kind == .castOnly && effectiveKind == .castOnly {
            probeRemote(host: hostname, name: sender.name)
        }
    }

    private func probeRemote(host: String, name: String) {
        let key = name.lowercased()
        guard probes[key] == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: 6466) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        probes[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self] in
                guard let self, let connection, self.probes[key] === connection else { return }
                switch state {
                case .ready:
                    if var current = self.found[key], current.kind == .castOnly {
                        current.kind = .googleTV
                        current.port = 6466
                        self.found[key] = current
                        self.notify("Remote v2 port 6466 reachable on " + name)
                    }
                    self.probes[key] = nil
                    connection.cancel()
                case .failed, .cancelled:
                    self.probes[key] = nil
                    connection.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let connection, self.probes[key] === connection else { return }
            self.probes[key] = nil
            connection.cancel()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let error = "Could not resolve " + sender.name + ": " + errorDict.description
        errors.append(error)
        notify(error)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let error = "Bonjour browser failed: " + errorDict.description
        errors.append(error)
        notify(error)
    }
}
