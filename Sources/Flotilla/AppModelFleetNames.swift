import Foundation
import FlotillaCore
import FlotillaNet

/// Names across Macs (PLAN.md Phase D, layer 2, Part C; research/FLEET-DNS-D3.md; DECISIONS Q37).
///
/// Every Mac keeps a table of the other Macs' zones and answers from it on 127.0.0.1:7869; its DNS
/// helper keeps a resolver file per other zone pointing there. The admin Mac builds the table from
/// what it already polls and sends each host its copy; a host only ever applies what it is sent.
extension AppModel {

    // MARK: Every Mac

    /// Makes this Mac answer from `table` — its own zone left to the runtime — and its resolver files
    /// match. `nil` or empty turns names across Macs off here. Returns why it is not fully working.
    @discardableResult
    func applyFleetNames(_ table: FleetNameTable?) async -> String? {
        hostMode.setFleetTable(table)
        let mine = table?.excluding(zone: containerDNSDomain)
        hostMode.fleetResponder.update(mine)
        let zones = (mine?.zones.map(\.zone) ?? []).sorted()
        var problem: String?
        // Nothing to look up and no files of ours to remove: no helper needed — measured 8 October,
        // a host with no other zone to answer was told its (older) helper had to be updated.
        if zones.isEmpty, !Self.hasFleetResolverFiles() { hostMode.syncedFleetZones = [] }
        if zones != hostMode.syncedFleetZones {
            let request: HelperRequest = zones.isEmpty
                ? .removeFleetResolvers
                : .syncFleetResolvers(fleetDomain: mine?.fleetDomain ?? "", zones: zones)
            if helperEnabled {
                problem = await PrivilegedHelper.send(request)
            } else if !zones.isEmpty {
                problem = "\(hostLabel)'s Flotilla Helper isn't switched on, so it can't look up other Macs' names."
            }
            if problem == nil || zones.isEmpty { hostMode.syncedFleetZones = zones }
        }
        if problem == nil { problem = hostMode.fleetResponder.lastError }
        hostMode.fleetNamesProblem = problem
        return problem
    }

    /// Whether any `/etc/resolver/flotilla.*` file exists — the directory is world-readable.
    nonisolated static func hasFleetResolverFiles() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: DNSResolverFile.directory)) ?? []
        return names.contains { FleetResolvers.zone(fromFilename: $0) != nil }
    }

    /// At launch: answer from the last table straight away. The resolver files are already in place.
    func restoreFleetNames() {
        guard let table = hostMode.fleetTable else { return }
        hostMode.fleetResponder.update(table.excluding(zone: containerDNSDomain))
    }

    // MARK: The admin Mac

    var fleetNamesEnabled: Bool { settingsStore[SettingsKeys.fleetNamesEnabled] }

    /// Every Mac whose zone is really set up — its runtime names containers there — with the address
    /// `viewer` reaches it at and its containers' names. `viewer` is the Mac the table is for: This
    /// Mac's own address differs by which host is looking.
    func fleetNameTable(for viewer: HostRef) -> FleetNameTable {
        let zones = fleetZones
        var entries: [FleetNameTable.Zone] = []
        for (mac, zone) in zones.sorted(by: { $0.value < $1.value }) where containerDNSDomain(on: mac) == zone {
            let address: String?
            let containers: [Container]
            switch mac {
            case .local:
                // This Mac as `viewer` reaches it: the local end of that host's connection.
                guard case .peer(let fingerprint) = viewer else { continue }
                address = hostMode.remoteHost(for: fingerprint)?.ipv4Addresses.local
                containers = self.containers
            case .peer(let fingerprint):
                address = hostMode.remoteHost(for: fingerprint)?.ipv4Addresses.remote
                containers = hostMode.containerSnapshots[fingerprint]?.items ?? []
            }
            guard let address else { continue }
            let names = containers.compactMap { container -> FleetNameTable.Name? in
                guard FleetNameTable.isLabel(container.id) else { return nil }
                return .init(name: container.id, ports: container.state.isRunning ? Self.reachablePorts(container) : [])
            }
            entries.append(.init(zone: zone, address: address, names: names))
        }
        return FleetNameTable(fleetDomain: fleetDNSDomain, zones: entries)
    }

    /// Host ports another Mac can reach: not those published on loopback only.
    nonisolated static func reachablePorts(_ container: Container) -> [Int] {
        container.publishedPorts.filter { port in
            guard let address = port.hostAddress, !address.isEmpty else { return true }
            return !(address.hasPrefix("127.") || address == "::1" || address == "localhost")
        }.map(\.hostPort).sorted()
    }

    /// Rebuilds the table and sends each host its copy when it changed. With the setting off, every
    /// Mac that was sent a table is sent an empty one, which turns names across Macs off there.
    func updateFleetNames() async {
        guard !hostMode.trustedHosts.isEmpty else { return }
        let enabled = fleetNamesEnabled && FleetResolvers.fleetDomainProblem(fleetDNSDomain) == nil
        let empty = FleetNameTable(fleetDomain: fleetDNSDomain, zones: [])
        await applyFleetNames(enabled ? fleetNameTable(for: .local) : nil)
        for peer in hostMode.trustedHosts {
            let fingerprint = peer.fingerprint
            guard hostMode.live[fingerprint]?.state == .connected,
                  let remote = hostMode.remoteHost(for: fingerprint) else { continue }
            let table = enabled ? fleetNameTable(for: .peer(fingerprint)) : empty
            guard hostMode.sentFleetTables[fingerprint] != table else { continue }
            if !enabled, hostMode.sentFleetTables[fingerprint] == nil { continue }
            do {
                _ = try await remote.call(.setFleetNames(table))
                hostMode.sentFleetTables[fingerprint] = table
                hostMode.noteFleetNamesResult(fingerprint, nil)
            } catch {
                hostMode.noteFleetNamesResult(fingerprint, HostModeController.describe(error))
                // A host that refused because of its helper still answers; send again on a change.
                if case .failed? = error as? RemoteHostError { hostMode.sentFleetTables[fingerprint] = table }
            }
        }
    }
}
