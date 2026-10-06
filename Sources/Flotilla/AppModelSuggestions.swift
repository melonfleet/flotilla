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
    var stackTaken: StackPlanner.Taken {
        var ports = Set(containers.flatMap(\.publishedPorts).map(\.hostPort))
        // A group that is not running still claims its ports.
        for member in groups.book.groups.flatMap(\.members) {
            ports.formUnion(member.ports.compactMap(StackPlanner.hostPort(fromPublishSpec:)))
        }
        return StackPlanner.Taken(containerNames: existingContainerNames.union(groups.book.claimedNames),
                                  volumes: Set(volumes.map(\.name)),
                                  networks: Set(networks.map(\.id)),
                                  hostPorts: ports)
    }

    /// How a new stack would be wired right now: by name when a domain is in use for containers.
    var stackWiringDomain: String? { containerDNSDomain }

    /// Brings in what the form needs to plan honestly: the DNS domain, networks and volumes.
    func prepareSuggestions() async {
        await refreshDNS()
        if networksState != .loaded { await refreshNetworks() }
        if volumesState != .loaded { await refreshVolumes() }
    }

    /// Creates the stack. Returns the plan on success, so the caller can say what was made.
    @discardableResult
    func createStack(_ stack: StackSuggestion, choices: StackChoices) async -> StackPlan? {
        var made: StackPlan?
        await withProgress(
            title: "Create “\(choices.name)” from \(stack.title)",
            command: stackCommandPreview(stack, choices: choices),
            work: { [weak self] progress in
                guard let self else { return "" }

                // 1. Images, which change nothing else.
                for image in stack.images where !images.contains(where: { $0.reference == image }) {
                    let step = progress.begin("Pulling \(image)")
                    do {
                        _ = try await Task.detached { [cli] in
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
                await refreshImages()

                var createdSoFar: [String] = []

                // 2. The network, then its gateway.
                let networkName: String
                switch choices.network {
                case .new: networkName = StackPlanner.networkName(choices.name)
                case .existing(let existing): networkName = existing
                }
                if case .new = choices.network {
                    let step = progress.begin("Creating network \(networkName)")
                    do {
                        _ = try await Task.detached { [cli] in
                            try cli.createNetwork(networkName, options: .init())
                        }.value
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw StackCreateFailure(step: "Creating network \(networkName)", made: [],
                                                 underlying: String(describing: error))
                    }
                    createdSoFar.append("network \(networkName)")
                    progress.finish(step)
                }
                await refreshNetworks()

                let wiring: StackWiring
                if let domain = stackWiringDomain {
                    wiring = .names(domain: domain)
                } else if let gateway = networks.first(where: { $0.id == networkName })?.gateway {
                    wiring = .gateway(Readiness.address(fromIPv4: gateway) ?? gateway)
                } else {
                    throw StackCreateFailure(step: "Reading \(networkName)'s gateway", made: createdSoFar,
                                             underlying: "The network has no IPv4 gateway.")
                }

                let plan: StackPlan
                do {
                    plan = try StackPlanner.plan(stack, choices: choices, wiring: wiring,
                                                 usedHostPorts: stackTaken.hostPorts)
                } catch {
                    throw StackCreateFailure(step: "Planning", made: createdSoFar,
                                             underlying: String(describing: error))
                }

                // 3. Volumes.
                for volume in plan.volumes {
                    let step = progress.begin("Creating volume \(volume)")
                    do {
                        _ = try await Task.detached { [cli] in try cli.createVolume(volume) }.value
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw StackCreateFailure(step: "Creating volume \(volume)", made: createdSoFar,
                                                 underlying: String(describing: error))
                    }
                    createdSoFar.append("volume \(volume)")
                    progress.finish(step)
                }
                await refreshVolumes()

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

                // 5. The group.
                do {
                    try groups.commit(plan.group)
                } catch {
                    throw StackCreateFailure(step: "Saving the group", made: createdSoFar,
                                             underlying: (error as? GroupBook.GroupError)?.description
                                                 ?? String(describing: error))
                }
                recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present",
                                              kind: .group, subject: plan.group.name,
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
    private func stackCommandPreview(_ stack: StackSuggestion, choices: StackChoices) -> String {
        var lines = stack.images.filter { image in !images.contains { $0.reference == image } }
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
    func stackUsedPorts(for stack: StackSuggestion) async -> Set<Int> {
        let taken = stackTaken.hostPorts
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
