import Foundation
import FlotillaCore
import FlotillaNet

/// DNS across the fleet (PLAN.md Phase D, layer 2; research/FLEET-DNS-D3.md; DECISIONS Q36).
///
/// On a host, an admin's host call is performed here — through this Mac's own DNS helper, never a
/// password prompt nobody is there to answer. On the admin Mac, each host's DNS is read and changed
/// through those calls, and each Mac can be given its own zone, `<its label>.<fleet domain>`.
extension AppModel {

    // MARK: Host side

    /// Performs an admin's host call, already validated by the wire session.
    func performHostCall(_ call: HostCall) async -> Result<String, HostCallFailure> {
        switch call {
        case .hostFacts:
            guard let json = try? JSONEncoder().encode(localHostFacts()) else {
                return .failure(HostCallFailure(.internalError, "This host couldn't describe itself."))
            }
            return .success(String(decoding: json, as: UTF8.self))

        case .dnsStatus:
            await refreshDNS()
            let status = HostDNSStatus(domains: dnsDomains, containerDomain: containerDNSDomain,
                                       helper: Self.helperState(DNSHelper.status))
            guard let json = try? JSONEncoder().encode(status) else {
                return .failure(HostCallFailure(.internalError, "This host couldn't describe its DNS."))
            }
            return .success(String(decoding: json, as: UTF8.self))

        case .dnsCreate(let domain, let localhost):
            if let refusal = helperRefusal { return .failure(refusal) }
            let failure = await DNSHelper.send(.create(domain: domain, localhost: localhost))
            await refreshDNS()
            return failure.map { .failure(HostCallFailure(.internalError, $0)) } ?? .success("")

        case .dnsDelete(let domains):
            if let refusal = helperRefusal { return .failure(refusal) }
            let failure = await DNSHelper.send(.delete(domains))
            await refreshDNS()
            return failure.map { .failure(HostCallFailure(.internalError, $0)) } ?? .success("")

        case .setContainerDNSDomain(let domain):
            switch await setContainerDNSDomain(domain) {
            case nil: return .success("")
            case .failed(let message)?: return .failure(HostCallFailure(.internalError, message))
            case .cancelled?: return .failure(HostCallFailure(.cancelled, "Cancelled."))
            }
        }
    }

    /// A host makes DNS changes only through its helper (Q36): the admin is not at this Mac to
    /// answer a password prompt, and nobody else should be asked.
    private var helperRefusal: HostCallFailure? {
        switch DNSHelper.status {
        case .enabled: nil
        case .awaitingApproval:
            HostCallFailure(.refused, "\(hostLabel)'s DNS helper is waiting to be switched on in System Settings ▸ Login Items.")
        case .notInstalled:
            HostCallFailure(.refused, "\(hostLabel) hasn't installed its DNS helper. Its owner turns it on in Flotilla ▸ Settings ▸ Advanced.")
        case .unavailable:
            HostCallFailure(.refused, "\(hostLabel)'s copy of Flotilla isn't signed, so it can't use a DNS helper.")
        }
    }

    nonisolated static func helperState(_ status: DNSHelper.Status) -> HostDNSStatus.Helper {
        switch status {
        case .enabled: .enabled
        case .awaitingApproval: .awaitingApproval
        case .notInstalled: .notInstalled
        case .unavailable: .unavailable
        }
    }

    // MARK: Admin side — any Mac's DNS

    /// Every Mac's DNS rows, This Mac's first — the DNS section's table.
    var hostedDNS: [HostedDNS] {
        var rows = dnsDomains.map { HostedDNS(domain: $0, host: .local, hostName: hostLabel) }
        let now = Date()
        for (peer, snapshot) in hostMode.fleetDNS {
            let stale = snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil
            rows += snapshot.items.map {
                HostedDNS(domain: $0, host: .peer(peer.fingerprint), hostName: peer.displayName, staleSince: stale)
            }
        }
        return rows
    }

    /// A row by its id — the domain's name on This Mac, `host/name` on a host.
    func hostedDNS(_ id: String) -> HostedDNS? { hostedDNS.first { $0.id == id } }

    /// Whether a change on that Mac goes without a password prompt — always on a host (its helper
    /// or nothing), and on This Mac when its helper is switched on.
    func dnsChangesSkipPassword(on host: HostRef) -> Bool { host.isLocal ? dnsHelperEnabled : true }

    /// "this Mac", or the host's name — for sentences about where a change happens.
    func dnsPlace(_ host: HostRef) -> String { host.isLocal ? "this Mac" : hostMode.hostName(host, local: hostLabel) }

    /// A Mac's DNS rows: This Mac's own, or the last a host sent.
    func dnsDomains(on host: HostRef) -> [LocalDNSDomain] {
        switch host {
        case .local: dnsDomains
        case .peer(let fingerprint): hostMode.dnsSnapshots[fingerprint]?.items ?? []
        }
    }

    /// The domain a Mac names its containers under.
    func containerDNSDomain(on host: HostRef) -> String? {
        switch host {
        case .local: containerDNSDomain
        case .peer(let fingerprint): hostMode.dnsStatus[fingerprint]?.containerDomain
        }
    }

    /// Whether DNS on that Mac can be changed from here, or why not.
    func dnsChangeProblem(on host: HostRef) -> String? {
        guard case .peer(let fingerprint) = host else { return nil }
        if let error = hostMode.dnsSnapshots[fingerprint]?.lastError { return error }
        switch hostMode.dnsStatus[fingerprint]?.helper {
        case .enabled?: return nil
        case .awaitingApproval?: return "Its DNS helper is waiting to be switched on in Login Items there."
        case .notInstalled?: return "Its DNS helper isn't installed. Turn it on in Flotilla ▸ Settings ▸ Advanced on that Mac."
        case .unavailable?: return "Its copy of Flotilla isn't signed, so it can't use a DNS helper."
        case nil: return "Its DNS hasn't been read yet."
        }
    }

    func createDNSDomain(_ domain: String, localhost: String?, on host: HostRef) async -> DNSActionResult? {
        guard case .peer(let fingerprint) = host else { return await createDNSDomain(domain, localhost: localhost) }
        do {
            try await hostMode.dnsCall(.dnsCreate(domain: domain, localhost: localhost), on: fingerprint)
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns,
                                          subject: "\(domain) on \(hostMode.hostName(host, local: hostLabel))", action: "Created"))
            return nil
        } catch {
            return .failed(HostModeController.describe(error))
        }
    }

    func deleteDNSDomains(_ domains: [String], on host: HostRef) async -> DNSActionResult? {
        guard case .peer(let fingerprint) = host else { return await deleteDNSDomains(domains) }
        do {
            try await hostMode.dnsCall(.dnsDelete(domains: domains), on: fingerprint)
            let name = hostMode.hostName(host, local: hostLabel)
            for domain in domains {
                recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns,
                                              subject: "\(domain) on \(name)", action: "Deleted"))
            }
            return nil
        } catch {
            return .failed(HostModeController.describe(error))
        }
    }

    /// On a host: edits its `config.toml` and restarts its runtime, stopping every container there.
    /// Callers confirm first, naming the Mac and the count.
    func setContainerDNSDomain(_ domain: String?, on host: HostRef) async -> DNSActionResult? {
        guard case .peer(let fingerprint) = host else { return await setContainerDNSDomain(domain) }
        do {
            try await hostMode.dnsCall(.setContainerDNSDomain(domain: domain), on: fingerprint)
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns,
                                          subject: (domain ?? "containers") + " on \(hostMode.hostName(host, local: hostLabel))",
                                          action: domain == nil ? "No longer used for containers" : "Used for containers"))
            await hostMode.refreshHost(fingerprint)
            return nil
        } catch {
            return .failed(HostModeController.describe(error))
        }
    }

    /// Running containers a runtime restart on that Mac would stop.
    func runningContainerCount(on host: HostRef) -> Int {
        switch host {
        case .local: runningContainerCount
        case .peer(let fingerprint): hostMode.live[fingerprint]?.containersRunning ?? 0
        }
    }

    // MARK: Admin side — per-host zones (Part B)

    /// The fleet domain, as set on this Mac — or the default if what is stored no longer passes.
    var fleetDNSDomain: String {
        let stored = settingsStore[SettingsKeys.fleetDNSDomain]
        return FleetZones.fleetDomainProblem(stored) == nil ? stored : FleetZones.defaultFleetDomain
    }

    /// Every Mac's zone. This Mac first, then hosts in a fixed order (by key), so a clash between
    /// two names always resolves the same way.
    var fleetZones: [HostRef: String] {
        let macs = [HostRef.local] + trustedHostRefs.sorted { $0.rowID("") < $1.rowID("") }
        // This Mac by its computer name, as hosts are by theirs: "This Mac" is a label in this
        // window, not a name — measured 8 October, it made the zone this-mac.fleet.internal.
        let names = macs.map { mac in
            (id: mac.rowID(""), name: mac.isLocal ? HostModeController.computerName : hostMode.hostName(mac, local: hostLabel))
        }
        let zones = FleetZones.zones(for: names, fleetDomain: fleetDNSDomain)
        return Dictionary(uniqueKeysWithValues: macs.compactMap { mac in zones[mac.rowID("")].map { (mac, $0) } })
    }

    /// What setting up its zone would do on a Mac.
    enum ZoneState: Equatable {
        case done
        /// Steps still needed; `restarts` counts the containers a runtime restart would stop.
        case needed(createResolver: Bool, setContainerDomain: Bool, restarts: Int)
        case unavailable(String)

        var canSetUp: Bool { if case .needed = self { true } else { false } }
    }

    func zoneState(on host: HostRef) -> ZoneState {
        guard let zone = fleetZones[host] else { return .unavailable("Not paired.") }
        if case .peer(let fingerprint) = host, hostMode.live[fingerprint]?.state != .connected {
            return .unavailable("not answering")
        }
        if let problem = dnsChangeProblem(on: host) { return .unavailable(problem) }
        let resolver = dnsDomains(on: host).first { $0.name == zone }?.resolverInstalled == true
        let naming = containerDNSDomain(on: host) == zone
        if resolver && naming { return .done }
        return .needed(createResolver: !resolver, setContainerDomain: !naming,
                       restarts: naming ? 0 : runningContainerCount(on: host))
    }

    /// Sets up each Mac's zone: its resolver domain, then naming its containers there (which
    /// restarts that Mac's runtime). The Macs run at the same time; a panel line each.
    @discardableResult
    func setUpZones(on hosts: [HostRef]) async -> Bool {
        let panel = OperationProgress(title: "Set up DNS zones on \(hosts.count) Mac\(hosts.count == 1 ? "" : "s")",
                                      command: "container system dns create <zone>; [dns] domain = \"<zone>\"")
        activeOperation = panel
        let zones = fleetZones
        // One task per Mac, all on the main actor: each spends its time waiting on its Mac.
        var tasks: [Task<String?, Never>] = []
        for host in hosts {
            guard let zone = zones[host], case .needed(let createResolver, let setDomain, _) = zoneState(on: host) else { continue }
            let name = hostMode.hostName(host, local: hostLabel)
            let step = panel.begin("\(name): \(zone)")
            tasks.append(Task { @MainActor in
                @MainActor func failed(_ result: DNSActionResult) -> String {
                    let why = if case .failed(let message) = result { message } else { "cancelled" }
                    panel.finish(step, detail: why, failed: true)
                    return "\(name): \(why)"
                }
                if createResolver, let result = await self.createDNSDomain(zone, localhost: nil, on: host) {
                    return failed(result)
                }
                if setDomain {
                    panel.update(step, detail: "restarting container…")
                    if let result = await self.setContainerDNSDomain(zone, on: host) { return failed(result) }
                }
                panel.finish(step, detail: "web.\(zone)")
                return nil
            })
        }
        var failures: [String] = []
        for task in tasks { if let failure = await task.value { failures.append(failure) } }
        guard failures.isEmpty else {
            panel.fail("Not every zone was set up.\n\n" + failures.joined(separator: "\n"))
            return false
        }
        panel.succeed("Each Mac names its containers in its own zone")
        return true
    }
}

/// One DNS domain on one Mac (PLAN.md Phase D, layer 2).
struct HostedDNS: Identifiable {
    let domain: LocalDNSDomain
    let host: HostRef
    let hostName: String
    /// A host's row that is older than a fresh answer: shown, with its age, rather than hidden.
    var staleSince: Date? = nil

    /// The domain on This Mac — unchanged, so tags and links made before D3 still match — and
    /// `host/name` on a host.
    var id: String { host.rowID(domain.name) }
    var name: String { domain.name }
    var nameSortKey: String { domain.nameSortKey }
    var kindSortKey: String { domain.kindSortKey }
    var statusSortKey: Int { domain.statusSortKey }
}
