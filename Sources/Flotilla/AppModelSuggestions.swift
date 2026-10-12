import Darwin
import Foundation
import FlotillaCore

/// Creating a stack from Suggestions (DECISIONS Q28): pull, network, volumes, passwords, group.
///
/// **Ordered so a failure leaves as little as possible behind.** The pulls come first: they are
/// slow, they are what fails (a registry hiccup, a disk filling), and they change nothing anyone
/// has to clean up. Only then the network, whose gateway the wiring needs, then volumes, the
/// Keychain and the group. The stack is not started: it is left ready, as decided.
extension AppModel {

    /// What this Mac already has, for the planner to avoid.
    var stackTaken: StackPlanner.Taken { stackTaken(on: .local) }

    /// What a Mac already has, for the planner to avoid — This Mac or a host (the owner, 12
    /// October: stacks on hosts).
    func stackTaken(on host: HostRef) -> StackPlanner.Taken {
        var ports = Set(containers(on: host).flatMap(\.publishedPorts).map(\.hostPort))
        // A group that is not running still claims its ports.
        for member in groups.book.groups.filter({ $0.place == host }).flatMap(\.members) {
            ports.formUnion(member.ports.compactMap(StackPlanner.hostPort(fromPublishSpec:)))
        }
        return StackPlanner.Taken(containerNames: existingContainerNames(on: host).union(groups.book.claimedNames(on: host)),
                                  volumes: Set((volumes(on: host) ?? []).map(\.name)),
                                  networks: Set((networks(on: host) ?? []).map(\.id)),
                                  hostPorts: ports)
    }

    /// A Mac's images, as last seen.
    func images(on host: HostRef) -> [ContainerImage] {
        switch host {
        case .local: images
        case .peer(let fingerprint): hostMode.imageSnapshots[fingerprint]?.items ?? []
        }
    }

    /// How a new stack would be wired right now: by name when a domain is in use for containers.
    var stackWiringDomain: String? { containerDNSDomain }

    /// The same for a Mac. A host's stack is always wired through its network's gateway: that
    /// works on any Mac, where name wiring would depend on the host's own DNS setup.
    func stackWiringDomain(on host: HostRef) -> String? { host.isLocal ? containerDNSDomain : nil }

    /// Brings in what the form needs to plan honestly: the DNS domain, networks and volumes.
    func prepareSuggestions() async {
        await refreshDNS()
        if networksState != .loaded { await refreshNetworks() }
        if volumesState != .loaded { await refreshVolumes() }
    }

    /// The same for a host: its lists, asked again now.
    func prepareSuggestions(on host: HostRef) async {
        guard case .peer(let fingerprint) = host else { return await prepareSuggestions() }
        await hostMode.refreshHost(fingerprint)
    }

    /// Creates the stack. Returns the plan on success, so the caller can say what was made.
    @discardableResult
    func createStack(_ stack: StackSuggestion, choices: StackChoices, on host: HostRef = .local) async -> StackPlan? {
        var made: StackPlan?
        let hostName = hostMode.hostName(host, local: hostLabel)
        await withProgress(
            title: host.isLocal ? "Create “\(choices.name)” from \(stack.title)"
                                : "Create “\(choices.name)” from \(stack.title) on \(hostName)",
            command: stackCommandPreview(stack, choices: choices, on: host),
            work: { [weak self] progress in
                guard let self else { return "" }
                // The host's own CLI, held to `.remotePeer` like every other host action.
                let cli = try self.cli(for: host)

                // 1. Images, which change nothing else.
                for image in stack.images where !images(on: host).contains(where: { $0.reference == image }) {
                    let step = progress.begin("Pulling \(image)")
                    do {
                        _ = try await Task.detached {
                            try cli.pull(image) { update in
                                // The CLI's own progress, so a long pull reads as one.
                                Task { @MainActor in progress.update(step, detail: Self.pullLine(update)) }
                            }
                        }.value
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw StackCreateFailure(step: "Pulling \(image)", made: [],
                                                 underlying: String(describing: error))
                    }
                    progress.finish(step)
                }
                if host.isLocal { await refreshImages() }

                var createdSoFar: [String] = []

                // 2. The network, then its gateway.
                let networkName: String
                switch choices.network {
                case .new: networkName = StackPlanner.networkName(choices.name)
                case .existing(let existing): networkName = existing
                }
                if case .new = choices.network {
                    let step = progress.begin("Creating network \(networkName)")
                    // Gateway wiring writes the gateway's address down, so the network gets a fixed
                    // subnet that a restart cannot move (Q30). Name wiring needs no address.
                    var options = ContainerCLI.NetworkOptions()
                    if stackWiringDomain(on: host) == nil {
                        // From the Mac's own address block (PLAN.md Phase D; Q35), so the stack's
                        // network never overlaps one pushed to or from another Mac. The old pick
                        // from 192.168.100.0/24 upward stays as the fallback for a Mac with no
                        // block free. A host's own interfaces aren't known here; its block is.
                        updateAddressPlan()
                        let used = (networks(on: host) ?? []).compactMap(\.subnet)
                            + (host.isLocal ? Array(HostInterfaces.ipv4Addresses()) : [])
                        options.subnet = pushSubnet(on: host)?.description ?? StackPlanner.freeSubnet(used: used)
                    }
                    let networkOptions = options
                    do {
                        _ = try await Task.detached {
                            try cli.createNetwork(networkName, options: networkOptions)
                        }.value
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw StackCreateFailure(step: "Creating network \(networkName)", made: [],
                                                 underlying: String(describing: error))
                    }
                    createdSoFar.append("network \(networkName)")
                    progress.finish(step)
                }
                if host.isLocal { await refreshNetworks() } else { await refreshContainers(on: host) }

                let wiring: StackWiring
                if let domain = stackWiringDomain(on: host) {
                    wiring = .names(domain: domain)
                } else if let gateway = (networks(on: host) ?? []).first(where: { $0.id == networkName })?.gateway {
                    wiring = .gateway(Readiness.address(fromIPv4: gateway) ?? gateway)
                } else {
                    throw StackCreateFailure(step: "Reading \(networkName)'s gateway", made: createdSoFar,
                                             underlying: "The network has no IPv4 gateway.")
                }

                let plan: StackPlan
                do {
                    plan = try StackPlanner.plan(stack, choices: choices, wiring: wiring,
                                                 usedHostPorts: stackTaken(on: host).hostPorts)
                } catch {
                    throw StackCreateFailure(step: "Planning", made: createdSoFar,
                                             underlying: String(describing: error))
                }

                // 3. Volumes.
                for volume in plan.volumes {
                    let step = progress.begin("Creating volume \(volume)")
                    do {
                        _ = try await Task.detached { try cli.createVolume(volume) }.value
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw StackCreateFailure(step: "Creating volume \(volume)", made: createdSoFar,
                                                 underlying: String(describing: error))
                    }
                    createdSoFar.append("volume \(volume)")
                    progress.finish(step)
                }
                if host.isLocal { await refreshVolumes() }

                // 4. Passwords, generated and kept in the Keychain.
                if !plan.secrets.isEmpty {
                    let step = progress.begin("Saving \(plan.secrets.count) generated passwords to the Keychain")
                    for secret in plan.secrets {
                        let groupID = plan.group.id, name = plan.group.name
                        let value = GroupSecrets.generatePassword()
                        let saved = await Task.detached {
                            KeychainSecrets.set(value, group: groupID, secret: secret,
                                                label: "Flotilla: \(name) — \(secret)")
                        }.value
                        guard saved else {
                            progress.finish(step, detail: "refused", failed: true)
                            throw StackCreateFailure(step: "Saving \(secret) to the Keychain",
                                                     made: createdSoFar,
                                                     underlying: "The Keychain refused it.")
                        }
                    }
                    progress.finish(step)
                }

                // 5. The group, on the Mac it was made on.
                var group = plan.group
                group.host = host.isLocal ? nil : host
                do {
                    try groups.commit(group)
                } catch {
                    throw StackCreateFailure(step: "Saving the group", made: createdSoFar,
                                             underlying: (error as? GroupBook.GroupError)?.description
                                                 ?? String(describing: error))
                }
                recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present",
                                              kind: .group,
                                              subject: host.isLocal ? plan.group.name : "\(plan.group.name) on \(hostName)",
                                              action: "Created from \(stack.title)"))
                made = plan
                let how = switch plan.wiring {
                case .names(let domain): "Its services find each other by name (\(domain))."
                case .gateway(let gateway): "Its services find each other through \(gateway)."
                }
                return "Ready to start. \(how)"
            })
        return made
    }

    /// The panel's command: what will actually run — pulls only for images this Mac lacks.
    private func stackCommandPreview(_ stack: StackSuggestion, choices: StackChoices,
                                     on host: HostRef) -> String {
        var lines = stack.images.filter { image in !images(on: host).contains { $0.reference == image } }
            .map { "container image pull \($0)" }
        if case .new = choices.network {
            lines.append("container network create \(StackPlanner.networkName(choices.name))")
        }
        for service in stack.services {
            for volume in service.volumes {
                lines.append("container volume create "
                             + StackPlanner.volumeName(choices.name, service.role, volume))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Whether anything on this Mac — not only containers — is listening on `port` at 127.0.0.1,
    /// so a suggested port is one that will actually bind. A dev server on :3000 is not a container.
    nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Ports to steer clear of: those containers and groups claim, plus any in the likely range
    /// that something else on this Mac is already listening on.
    func stackUsedPorts(for stack: StackSuggestion, on host: HostRef = .local) async -> Set<Int> {
        let taken = stackTaken(on: host).hostPorts
        // Only This Mac can be asked what else is listening; a host's containers are all we know.
        guard host.isLocal else { return taken }
        let candidates = stack.services.compactMap(\.webPort).flatMap { web -> [Int] in
            let base = web < 1024 ? 8000 + web : web
            return Array(base..<(base + 20))
        }
        let busy = await Task.detached {
            Set(candidates.filter { !AppModel.isPortFree($0) })
        }.value
        return taken.union(busy)
    }
}

/// A stack that could not be finished. Says which step, and what already exists because of it —
/// the same rule as a group that half-starts: the screen should match the machine.
struct StackCreateFailure: Error, CustomStringConvertible {
    let step: String
    let made: [String]
    let underlying: String

    var description: String {
        let head = "\(step) failed. \(underlying)"
        guard !made.isEmpty else { return head + "\n\nNothing was left behind." }
        return head + "\n\nAlready created, and left in place: \(made.joined(separator: ", "))."
    }
}
