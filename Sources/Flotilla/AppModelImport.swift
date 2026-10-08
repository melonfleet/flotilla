import AppKit
import FlotillaCore

/// Importing a `.flotilla` file (DECISIONS Q29): building what the review screen confirmed.
///
/// The deciding is `ConfigurationImport`'s; this runs it, every command through `ContainerCLI` and
/// so through the `Allowlist`. **Nothing is started**: containers are created, groups saved ready
/// to start — the same as a Suggestion. Order matters and is fixed: replacements first, then the
/// pulls (the slow part, and the one that fails), then what other things refer to.
extension AppModel {

    func requestImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.flotillaFileType, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .flotilla file. Nothing is built until you've reviewed it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configurationScreen = .importFile(url)
    }

    /// Opened from Finder (a double-clicked `.flotilla`).
    func openConfigurationFile(_ url: URL) {
        configurationScreen = .importFile(url)
    }

    /// What this Mac has, for the review screen's clash check.
    func importExisting() async -> ConfigurationImport.Existing {
        await refresh()
        await refreshNetworks()
        await refreshVolumes()
        await refreshMachines()
        await refreshClusters()
        await refreshDNS()
        var existing = ConfigurationImport.Existing()
        existing.containers = existingContainerNames.union(groups.book.claimedNames)
        existing.groups = Set(groups.book.groups.map(\.name))
        existing.networks = Set(networks.map(\.id))
        existing.volumes = Set(volumes.map(\.name))
        existing.machines = Set(machines.map(\.id))
        existing.clusters = Set(clusters.map(\.name))
        existing.dnsDomains = Set(dnsDomains.filter(\.resolverInstalled).map(\.name))
        existing.hosts = hostMode.knownFingerprints
        return existing
    }

    /// The answers the review screen collected, beyond the file itself.
    struct ImportChoices {
        /// The file with skips and renames applied.
        var file: ConfigurationFile
        /// Items to delete first, as `ConfigurationImport.Item`s of the **original** names.
        var replacing: [ConfigurationImport.Item]
        /// Secret values by need id (`group/x`, `container/y`), then by secret or variable name.
        var secrets: [String: [String: String]]
        var useDefaultRegistry: Bool
        var useContainerDomain: Bool
    }

    func runImport(_ choices: ImportChoices, source: String) async {
        let file = choices.file
        await withProgress(
            title: "Import “\(source)”",
            command: importPreview(file),
            work: { [weak self] progress in
                guard let self else { return "" }
                var notes: [String] = []
                var built: [String] = []

                // 1. Replacements — the one destructive step, confirmed by name before this ran.
                for item in choices.replacing {
                    let step = progress.begin("Removing the existing \(item.kind.title.lowercased()) \(item.name)")
                    do {
                        try await removeForReplace(item)
                        progress.finish(step)
                    } catch {
                        progress.finish(step, detail: "failed", failed: true)
                        throw ImportFailure(step: "Removing \(item.name)", underlying: error, built: built)
                    }
                }

                // 2. Images.
                await refreshImages()
                for image in ConfigurationImport.images(file) {
                    if !images.contains(where: { ConfigurationExport.aliases($0.reference).contains(image.reference) }) {
                        let step = progress.begin("Pulling \(image.reference)")
                        do {
                            _ = try await Task.detached { [cli] in
                                try cli.pull(image.reference) { update in
                                    Task { @MainActor in progress.update(step, detail: Self.pullLine(update)) }
                                }
                            }.value
                            progress.finish(step)
                        } catch {
                            progress.finish(step, detail: "failed", failed: true)
                            throw ImportFailure(step: "Pulling \(image.reference)", underlying: error, built: built)
                        }
                    }
                }
                await refreshImages()
                // The same tag can point at new bytes since the file was written. Said, not hidden.
                for image in ConfigurationImport.images(file) {
                    guard let wanted = image.digest,
                          let here = images.first(where: { ConfigurationExport.aliases($0.reference).contains(image.reference) })?
                            .configuration.descriptor?.digest, here != wanted else { continue }
                    notes.append("\(image.reference) has changed since the file was made.")
                }

                // 3. Networks, volumes, machines, clusters.
                for network in file.networks {
                    try await step(progress, "Creating network \(network.name)", built: &built,
                                   made: "network \(network.name)") { cli in
                        try cli.createNetwork(network.name, options: .init(isInternal: network.hostOnly,
                                                                           labels: network.labels))
                    }
                }
                for volume in file.volumes {
                    try await step(progress, "Creating volume \(volume.name)", built: &built,
                                   made: "volume \(volume.name)") { cli in
                        try cli.createVolume(volume.name, options: .init(size: volume.size, labels: volume.labels))
                    }
                }
                for machine in file.machines {
                    try await step(progress, "Creating machine \(machine.name)", built: &built,
                                   made: "machine \(machine.name)") { cli in
                        try cli.createMachine(image: machine.image, name: machine.name, cpus: machine.cpus,
                                              memory: machine.memory, homeMount: machine.homeMount?.rawValue)
                    }
                }
                for cluster in file.clusters {
                    try await step(progress, "Creating cluster \(cluster.name) — this takes a few minutes",
                                   built: &built, made: "cluster \(cluster.name)") { cli in
                        try cli.createCluster(name: cluster.name, cpus: cluster.cpus, memory: cluster.memory,
                                              nodeImage: cluster.nodeImage, autoRemove: cluster.disposable)
                    }
                }

                // 4. Containers — created, not started.
                for container in file.containers {
                    let values = choices.secrets["container/\(container.name)"] ?? [:]
                    let env = container.env + container.secretEnv.compactMap { entry in
                        values[entry.name].map { "\(entry.name)=\($0)" }
                    }
                    let options = ContainerCLI.RunOptions(name: container.name, ports: container.ports, env: env,
                                                          volumes: container.volumes, detach: false, rm: false,
                                                          cpus: container.cpus, memory: container.memory,
                                                          network: container.network)
                    try await step(progress, "Creating container \(container.name)", built: &built,
                                   made: "container \(container.name)") { cli in
                        try cli.createContainer(image: container.image, options: options, command: container.command)
                    }
                }

                // 5. Groups — saved ready to start, their passwords into the Keychain.
                for spec in file.groups {
                    let group = ContainerGroup(name: spec.name, network: spec.network,
                                               members: spec.members.map { member in
                                                   GroupMember(name: member.name, image: member.image,
                                                               ports: member.ports, env: member.env,
                                                               volumes: member.volumes, command: member.command,
                                                               cpus: member.cpus, memory: member.memory,
                                                               readyPort: member.readyPort,
                                                               secretEnv: member.secretEnv)
                                               },
                                               notes: spec.notes)
                    let stepID = progress.begin("Saving group \(group.name)")
                    do {
                        try groups.commit(group)
                    } catch {
                        progress.finish(stepID, detail: "failed", failed: true)
                        throw ImportFailure(step: "Saving group \(group.name)", underlying: error, built: built)
                    }
                    for (secret, value) in choices.secrets["group/\(spec.name)"] ?? [:]
                    where !KeychainSecrets.set(value, group: group.id, secret: secret,
                                               label: "Flotilla: \(group.name) — \(secret)") {
                        notes.append("The Keychain refused “\(secret)” for \(group.name); set it on the group's screen.")
                    }
                    progress.finish(stepID)
                }

                // 6. Tags — merged by name; assignments follow what was built.
                if let tagsSpec = file.tags {
                    var idsByName: [String: String] = Dictionary(
                        tags.book.tags.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
                    for definition in tagsSpec.definitions where idsByName[definition.name.lowercased()] == nil {
                        if let tag = tags.createTag(name: definition.name, color: definition.color) {
                            idsByName[definition.name.lowercased()] = tag.id
                        }
                    }
                    for assignment in tagsSpec.assignments {
                        let id = assignment.kind == .group
                            ? (groups.book.groups.first { $0.name == assignment.id }?.id ?? assignment.id)
                            : assignment.id
                        for name in assignment.tags {
                            if let tagID = idsByName[name.lowercased()] {
                                tags.apply(tagID, to: [TagSubject(kind: assignment.kind, id: id)], applied: true)
                            }
                        }
                    }
                }

                // 7. The registry list — never a sign-in.
                if let registriesSpec = file.registries {
                    for entry in registriesSpec.entries where registries.book.registry(id: entry.host) == nil {
                        if let known = KnownRegistry.catalogue.first(where: {
                            KnownRegistry.canonicalHost($0.id) == KnownRegistry.canonicalHost(entry.host)
                        }) {
                            addRegistry(known: known)
                        } else {
                            addRegistry(host: entry.host, name: entry.name ?? "", summary: "",
                                        kind: RegistryKind.inferred(fromHost: entry.host),
                                        usesHTTP: entry.usesHTTP, signInRequired: entry.signInRequired)
                        }
                    }
                    if choices.useDefaultRegistry, let host = registriesSpec.defaultRegistry {
                        setDefaultRegistry(host)
                    }
                    let needSignIn = registriesSpec.entries.filter(\.signInRequired).map(\.host)
                    if !needSignIn.isEmpty {
                        notes.append("Sign in to \(needSignIn.joined(separator: ", ")) in Registries.")
                    }
                }

                // 8. DNS — the administrator prompt, once, for every new domain.
                if let dnsSpec = file.dns, !dnsSpec.domains.isEmpty {
                    let commands = dnsSpec.domains.compactMap {
                        try? ContainerCLI.dnsCreateCommand(domain: $0.name, localhost: $0.localhost).get()
                    }
                    let viaHelper = helperEnabled
                    let stepID = progress.begin("Adding \(commands.count) DNS domain\(commands.count == 1 ? "" : "s")"
                                                + (viaHelper ? "" : " — macOS asks for your password"))
                    let names = dnsSpec.domains.map(\.name)
                    let outcome: AdminCommandRunner.Outcome
                    if viaHelper {
                        // One request per domain, stopping at the first failure as `&&` does.
                        var failure: String?
                        for domain in dnsSpec.domains where failure == nil {
                            failure = await PrivilegedHelper.send(.create(domain: domain.name, localhost: domain.localhost))
                        }
                        outcome = failure.map { .failed($0) } ?? .succeeded
                    } else {
                        outcome = AdminCommandRunner.run(
                            commands, prompt: "Flotilla wants to add the local domains \(names.joined(separator: ", ")) to this Mac’s DNS settings.")
                    }
                    switch outcome {
                    case .succeeded: progress.finish(stepID)
                    case .cancelled:
                        progress.finish(stepID, detail: "cancelled")
                        notes.append("The DNS domains weren't added — you cancelled the password prompt.")
                    case .failed(let message):
                        progress.finish(stepID, detail: "failed", failed: true)
                        notes.append("The DNS domains weren't added: \(message)")
                    }
                }

                await reload()
                await refreshDNS()
                recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .runtime,
                                              subject: source, action: "Configuration imported"))
                // 9. Hosts — rows to pair, never trust (Q34). Nothing connects to them here.
                if !file.hosts.isEmpty {
                    let added = hostMode.importHosts(file.hosts)
                    if added > 0 {
                        notes.append("\(added) host\(added == 1 ? " is" : "s are") in Hosts, waiting to be paired.")
                    }
                }

                return notes.isEmpty ? "Built. Nothing was started." : "Built. " + notes.joined(separator: " ")
            })

        // Last, and outside the panel: renaming containers' domain restarts the runtime, which the
        // review screen warned about when the box was ticked.
        if choices.useContainerDomain, let domain = file.dns?.containerDomain, domain != containerDNSDomain {
            _ = await setContainerDNSDomain(domain)
        }
    }

    private func step(_ progress: OperationProgress, _ title: String, built: inout [String], made: String,
                      _ work: @escaping @Sendable (ContainerCLI) throws -> Void) async throws {
        let id = progress.begin(title)
        do {
            try await Task.detached { [cli] in try work(cli) }.value
            progress.finish(id)
            built.append(made)
        } catch {
            progress.finish(id, detail: "failed", failed: true)
            throw ImportFailure(step: title, underlying: error, built: built)
        }
    }

    private func removeForReplace(_ item: ConfigurationImport.Item) async throws {
        let name = item.name
        switch item.kind {
        case .container:
            try await Task.detached { [cli] in _ = try cli.remove(name, force: true) }.value
        case .group:
            if let group = groups.book.groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                for member in group.memberNames where existingContainerNames.contains(member) {
                    try await Task.detached { [cli] in _ = try cli.remove(member, force: true) }.value
                }
                deleteGroup(group)
            }
        case .network:
            try await Task.detached { [cli] in try cli.removeNetwork(name) }.value
        case .volume:
            try await Task.detached { [cli] in try cli.removeVolume(name) }.value
        case .machine:
            try await Task.detached { [cli] in
                _ = try? cli.stopMachine(name)
                try cli.deleteMachine(name)
            }.value
        case .cluster:
            try await Task.detached { [cli] in try cli.deleteCluster(name) }.value
        case .dnsDomain, .host:
            break
        }
        await refresh()
    }

    /// What will actually run — pulls only for images this Mac lacks.
    private func importPreview(_ file: ConfigurationFile) -> String {
        var lines = ConfigurationImport.images(file)
            .filter { image in !images.contains { ConfigurationExport.aliases($0.reference).contains(image.reference) } }
            .map { "container image pull \($0.reference)" }
        lines += file.networks.map { "container network create \($0.name)" }
        lines += file.volumes.map { "container volume create \($0.name)" }
        lines += file.containers.map { "container create --name \($0.name) … \($0.image)" }
        return lines.joined(separator: "\n")
    }
}

/// An import that stopped part way. Names what was built before it stopped — the screen should
/// match the machine, as for a group that half-starts.
struct ImportFailure: Error, CustomStringConvertible {
    let step: String
    let underlying: Error
    let built: [String]
    var description: String {
        let head = "\(step) failed. \((underlying as? ContainerCLIError)?.description ?? String(describing: underlying))"
        return built.isEmpty
            ? head + "\n\nNothing was built."
            : head + "\n\nAlready built, and left in place: \(built.joined(separator: ", "))."
    }
}
