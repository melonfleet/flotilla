import Foundation
import FlotillaCore

/// Pushing This Mac's networks and volumes to its hosts (PLAN.md Phase D, layer 1; DECISIONS Q35).
/// The deciding is `FleetPush`'s and `AddressPlan`'s; this gathers what each Mac has and runs the
/// creates, each through the `Allowlist` on both sides as every remote command is.
extension AppModel {

    // MARK: What each Mac has

    /// A Mac's networks, or `nil` when they are not known — not loaded yet, or a host that has
    /// never answered. A host that stopped answering keeps its last list, as its rows do.
    func networks(on host: HostRef) -> [ContainerNetwork]? {
        switch host {
        case .local: networksState == .loaded ? networks : nil
        case .peer(let fingerprint):
            hostMode.networkSnapshots[fingerprint].flatMap { $0.fetchedAt == nil ? nil : $0.items }
        }
    }

    func volumes(on host: HostRef) -> [ContainerVolume]? {
        switch host {
        case .local: volumesState == .loaded ? volumes : nil
        case .peer(let fingerprint):
            hostMode.volumeSnapshots[fingerprint].flatMap { $0.fetchedAt == nil ? nil : $0.items }
        }
    }

    var trustedHostRefs: [HostRef] { hostMode.trustedHosts.map { .peer($0.fingerprint) } }

    /// How a network of This Mac's sits across the hosts — for the On hosts column.
    func spread(of network: ContainerNetwork) -> FleetPush.Spread {
        let definition = FleetPush.definition(of: network)
        var spread = FleetPush.Spread()
        for host in trustedHostRefs { spread.add(FleetPush.status(of: definition, on: networks(on: host))) }
        return spread
    }

    func spread(of volume: ContainerVolume) -> FleetPush.Spread {
        let definition = FleetPush.definition(of: volume)
        var spread = FleetPush.Spread()
        for host in trustedHostRefs { spread.add(FleetPush.status(of: definition, on: volumes(on: host))) }
        return spread
    }

    // MARK: Address blocks

    /// Gives every Mac without a `/20` one, avoiding this Mac's interfaces and every subnet any Mac
    /// already uses. Called from a screen's task and before a push — never while a view draws,
    /// since it changes what the views observe.
    func updateAddressPlan() {
        var avoid = HostInterfaces.ipv4Ranges()
        for mac in [HostRef.local] + trustedHostRefs {
            avoid += (networks(on: mac) ?? []).compactMap { $0.subnet.flatMap(IPv4Block.init) }
        }
        hostMode.updateAddressPlan(avoiding: avoid)
    }

    /// A Mac's `/20`, if it has been given one. Read-only, so a view may ask.
    func addressBlock(for host: HostRef) -> IPv4Block? {
        hostMode.addressBlocks[HostModeController.blockKey(host)]
    }

    /// The subnet a pushed network would get on `host`: the first free `/24` in that Mac's block.
    func pushSubnet(on host: HostRef) -> IPv4Block? {
        guard let block = addressBlock(for: host) else { return nil }
        let used = (networks(on: host) ?? []).compactMap { $0.subnet.flatMap(IPv4Block.init) }
        return AddressPlan.subnet(in: block, used: used)
    }

    // MARK: Pushing

    func pushNetwork(_ definition: NetworkSpec, to hosts: [HostRef]) async {
        updateAddressPlan()
        await push(title: "Push network \u{201C}\(definition.name)\u{201D}", kind: .network, name: definition.name,
                   hosts: hosts) { [self] host in
            guard let subnet = pushSubnet(on: host) else {
                throw PushProblem("no free subnet is left in its address block")
            }
            let options = ContainerCLI.NetworkOptions(subnet: subnet.description, isInternal: definition.hostOnly,
                                                      labels: definition.labels)
            return ("on \(subnet)", { try $0.createNetwork(definition.name, options: options) })
        }
    }

    func pushVolume(_ definition: VolumeSpec, to hosts: [HostRef]) async {
        let options = ContainerCLI.VolumeOptions(size: definition.size, labels: definition.labels)
        await push(title: "Push volume \u{201C}\(definition.name)\u{201D}", kind: .volume, name: definition.name,
                   hosts: hosts) { _ in ("empty", { try $0.createVolume(definition.name, options: options) }) }
    }

    /// One create per host, one line each in the panel, a failure on one never stopping the rest.
    private func push(title: String, kind: ActivityKind, name: String, hosts: [HostRef],
                      prepare: (HostRef) throws -> (detail: String, run: @Sendable (ContainerCLI) throws -> CommandResult))
        async {
        let panel = OperationProgress(title: title, command: hosts.count == 1
                                      ? "1 host" : "\(hosts.count) hosts")
        activeOperation = panel
        var done: [String] = [], failed: [String] = []
        for host in hosts {
            let hostName = hostMode.hostName(host, local: hostLabel)
            let step = panel.begin("Creating on \(hostName)")
            do {
                let (detail, run) = try prepare(host)
                let remote = try cli(for: host)
                _ = try await Task.detached { try run(remote) }.value
                panel.finish(step, detail: detail)
                done.append(hostName)
                recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: kind,
                                              subject: "\(name) on \(hostName)", action: "Pushed"))
            } catch {
                let reason = (error as? PushProblem)?.reason ?? HostModeController.describe(error)
                panel.finish(step, detail: reason, failed: true)
                failed.append("\(hostName): \(reason)")
            }
            if case .peer(let fingerprint) = host { await hostMode.refreshHost(fingerprint) }
        }
        if failed.isEmpty {
            panel.succeed("\(name) is on \(done.count) more Mac\(done.count == 1 ? "" : "s")")
        } else {
            panel.fail((done.isEmpty ? "Not pushed anywhere." : "Pushed to \(done.joined(separator: ", ")), but not to:")
                       + "\n\n" + failed.joined(separator: "\n"))
        }
    }
}

private struct PushProblem: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
