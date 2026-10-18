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
    private var castFriendlyNames: [String: String] = [:]
    private var seen: Set<String> = []
    private var errors: [String] = []
    private var probes: [String: NWConnection] = [:]
    private var completion: CheckedContinuation<DiscoveryReport, Never>?
    private var update: (([TVDevice], String) -> Void)?
    private var scanID = UUID()

    func scan(timeout: TimeInterval = 9,
              update: @escaping ([TVDevice], String) -> Void) async -> DiscoveryReport {
        let declared = Set(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? [])
        let required: Set<String> = ["_androidtvremote2._tcp", "_googlecast._tcp"]
        let reason = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        if !required.isSubset(of: declared) || reason?.isEmpty != false {
            let message = "Installed IPA is missing NSBonjourServices or NSLocalNetworkUsageDescription. Reinstall a build with the local-network declarations included."
            update([], message)
            return DiscoveryReport(devices: [], servicesFound: 0, resolved: 0, errors: [message])
        }
        finish()
        found = [:]
        castFriendlyNames = [:]
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

    /// One row per physical receiver. A Google TV usually advertises both Cast
    /// and Android TV Remote v2 under *different* service instance names.
    /// Resolve DNS and group by numeric IP; prefer remote capability and Cast's
    /// user-assigned friendly name ("fn") when the device advertises both.
    private var sortedDevices: [TVDevice] {
        let resolved = found.filter { !$0.value.host.isEmpty }
        let grouped = Dictionary(grouping: resolved, by: {
            $0.value.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })
        return grouped.values.compactMap { services -> TVDevice? in
            guard var preferred = services.map { $0.value }.sorted(by: {
                if $0.supportsRemote != $1.supportsRemote { return $0.supportsRemote }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }).first else { return nil }
            if let friendly = services.compactMap({ castFriendlyNames[$0.key] }).first,
               !friendly.isEmpty {
                preferred = TVDevice(name: friendly, host: preferred.host,
                                     port: preferred.port, kind: preferred.kind)
            }
            return preferred
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func serviceKey(_ service: NetService) -> String {
        service.name.lowercased() + "|" + service.type.lowercased()
    }

    private func preferredAddress(_ service: NetService) -> String? {
        // mDNS host names can differ between the Cast and remote2 interfaces.
        // The resolved IPv4 endpoint is a more reliable common identity.
        for address in service.addresses ?? [] {
            let ipv4 = address.withUnsafeBytes { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                let sock = base.assumingMemoryBound(to: sockaddr.self)
                guard Int32(sock.pointee.sa_family) == AF_INET else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let rc = getnameinfo(sock, socklen_t(address.count),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
                return rc == 0 ? String(cString: host) : nil
            }
            if let ipv4 { return ipv4 }
        }
        return service.hostName
    }

    private func updateFriendlyName(_ service: NetService) {
        guard service.type.contains("googlecast"),
              let record = service.txtRecordData() else { return }
        let values = NetService.dictionary(fromTXTRecord: record)
        if let nameData = values["fn"],
           let name = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            castFriendlyNames[serviceKey(service)] = name
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
                resolved: sortedDevices.count,
                errors: errors
            ))
        }
        update = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let kind: TVDevice.Kind = service.type.contains("androidtvremote2") ? .googleTV : .castOnly
        let key = serviceKey(service)
        seen.insert(key)
        // Do not render an unresolved duplicate as a second TV. Once resolved,
        // each physical IP is shown as one item with its strongest capability.
        found[key] = TVDevice(name: service.name, host: "", port: kind == .googleTV ? 6466 : 8009, kind: kind)
        notify("Discovered " + service.name + " (" + service.type + ") — resolving address")
        service.delegate = self
        services[ObjectIdentifier(service)] = service
        service.resolve(withTimeout: 7)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = preferredAddress(sender), !host.isEmpty else {
            notify("Resolved " + sender.name + " without reachable IP/hostname")
            return
        }
        let key = serviceKey(sender)
        let kind: TVDevice.Kind = sender.type.contains("androidtvremote2") ? .googleTV : .castOnly
        updateFriendlyName(sender)
        if kind == .castOnly { sender.startMonitoring() }
        let name = castFriendlyNames[key] ?? sender.name
        found[key] = TVDevice(name: name, host: host,
                              port: kind == .googleTV ? 6466 : 8009, kind: kind)
        notify("Resolved " + name + " at " + host + " — " + String(sortedDevices.count) + " unique TV(s)")
        if kind == .castOnly {
            probeRemote(host: host, name: sender.name, key: key)
        }
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        updateFriendlyName(sender)
        notify("Updated Cast receiver name for " + sender.name)
    }

    private func probeRemote(host: String, name: String, key: String) {
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
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        if code == -72000 && !sortedDevices.isEmpty {
            // iOS may terminate an outstanding Bonjour browser after enough
            // services have resolved. This is not a failed TV search when a
            // reachable TV was already found, and must not mask success.
            notify("Finished discovering " + String(sortedDevices.count) + " TV(s)")
            return
        }
        let error = code == -72008
            ? "Bonjour configuration missing (-72008). Reinstall the corrected IPA with local-network declarations."
            : "Bonjour browser failed (\(code)): " + errorDict.description
        errors.append(error)
        notify(error)
    }
}
