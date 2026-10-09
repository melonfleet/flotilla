import Foundation

/// Builds a `.flotilla` file from this Mac's live state and the user's checklist (DECISIONS Q29).
///
/// Pure: the app gathers the lists, this decides what goes in the file and — as importantly —
/// **reports everything it left out**, so the export screen can say so rather than handing back a
/// file that quietly builds something different. Four things are always left out:
///
/// - **Secret values.** A variable that looks like a password becomes a `secretEnv` name; the
///   importer asks for it or generates one. Keychain-held group secrets were names already.
/// - **Folders on this Mac.** A mount of a host folder would name a path under the user's home —
///   their account name — and would not exist on the other Mac anyway.
/// - **The image's own defaults.** A container's environment and command come back from the CLI
///   merged with the image's; only what was chosen on top is written.
/// - **Anything the runtime made itself:** the built-in `default` network, a cluster's node
///   container, a group member listed again as a standalone container.
public enum ConfigurationExport {

    /// What the user ticked.
    public struct Selection: Sendable, Equatable {
        public var containers: Set<String> = []     // container ids
        public var groups: Set<String> = []         // group ids
        public var networks: Set<String> = []
        public var volumes: Set<String> = []
        public var machines: Set<String> = []
        public var clusters: Set<String> = []
        public var tags = false
        public var registries = false
        public var dns = false
        /// Paired hosts, by fingerprint (hex).
        public var hosts: Set<String> = []
        /// The host categories, and the values of the hosts in the file (Q45).
        public var hostCategories = false
        public init() {}
    }

    /// The live state, gathered by the app.
    public struct Inputs: Sendable {
        public var containers: [Container] = []
        public var groups: [ContainerGroup] = []
        public var networks: [ContainerNetwork] = []
        public var volumes: [ContainerVolume] = []
        public var machines: [ContainerMachine] = []
        public var clusters: [K8sNode] = []
        /// `image inspect`, for the defaults to subtract and the digests to record.
        public var images: [ContainerImage] = []
        public var tags = TagBook()
        public var registries = RegistryBook()
        public var defaultRegistry: String?
        public var dnsDomains: [LocalDNSDomain] = []
        public var containerDNSDomain: String?
        /// The admin's host book. Only trusted hosts are written.
        public var hosts: [Peer] = []
        /// The admin's host categories and values, keyed by Hosts row id.
        public var hostCategories = HostCategoryBook()
        public init() {}
    }

    /// One thing left out, and why — shown on the export screen and kept short.
    public struct Omission: Sendable, Equatable, Hashable {
        public let subject: String
        public let reason: String
        public init(subject: String, reason: String) { self.subject = subject; self.reason = reason }
    }

    public struct Result: Sendable {
        public let file: ConfigurationFile
        public let omissions: [Omission]
    }

    // MARK: Building

    public static func build(_ inputs: Inputs, selection: Selection) -> Result {
        var omissions: [Omission] = []
        let defaultsByImage = imageDefaults(inputs.images)
        let digests = imageDigests(inputs.images)

        let networks = inputs.networks
            .filter { selection.networks.contains($0.id) && !$0.isBuiltin }
            .map { network in
                NetworkSpec(name: network.id, hostOnly: network.mode == "hostOnly",
                            subnet: nil,   // the runtime chose it; another Mac's may clash
                            labels: labels(network.labels))
            }

        let volumes = inputs.volumes
            .filter { selection.volumes.contains($0.name) }
            .map { volume in
                VolumeSpec(name: volume.name, size: volume.sizeInBytes.map(sizeString),
                           labels: labels(volume.labels))
            }

        let machines = inputs.machines
            .filter { selection.machines.contains($0.id) }
            .compactMap { machine -> MachineSpec? in
                guard let image = machine.image?.reference else {
                    omissions.append(Omission(subject: "machine \(machine.id)",
                                              reason: "its image isn't known, so it can't be rebuilt"))
                    return nil
                }
                return MachineSpec(name: machine.id, image: image, cpus: machine.cpus,
                                   memory: sizeString(machine.memory),
                                   homeMount: machine.homeMount.flatMap(HomeMountMode.init(rawValue:)))
            }

        let clusterNames = Set(inputs.clusters.map(\.name))
        let clusters = clusterNames.sorted()
            .filter { selection.clusters.contains($0) }
            .map { name -> ClusterSpec in
                let node = inputs.clusters.first { $0.name == name }
                return ClusterSpec(name: name, cpus: node?.cpus, memory: node?.memoryFlag)
            }

        // Group members are described by their group, and a cluster's node by its cluster.
        let memberNames = Set(inputs.groups.flatMap(\.memberNames))
        var containers: [ServiceSpec] = []
        for container in inputs.containers where selection.containers.contains(container.id) {
            if memberNames.contains(container.id) || clusterNames.contains(container.id) { continue }
            let (spec, left) = service(from: container, defaults: defaultsByImage[container.imageReference],
                                       digest: digests[container.imageReference])
            containers.append(spec)
            omissions += left
        }

        var groups: [GroupSpec] = []
        for group in inputs.groups where selection.groups.contains(group.id) {
            var members: [ServiceSpec] = []
            for member in group.members {
                var (env, secretEnv, left) = splitSecrets(member.env, subject: member.name)
                secretEnv = member.secretEnv + secretEnv
                omissions += left
                let named = member.volumes.filter { !$0.hasPrefix("/") }
                for folder in member.volumes where folder.hasPrefix("/") {
                    // The destination, never the source: the source is a path under the user's home.
                    let parts = folder.split(separator: ":", omittingEmptySubsequences: false)
                    let destination = parts.count > 1 ? String(parts[1]) : "a folder"
                    omissions.append(Omission(subject: member.name, reason: folderReason(destination)))
                }
                env = env.sorted()
                members.append(ServiceSpec(name: member.name, image: member.image,
                                           digest: digests[member.image], ports: member.ports,
                                           env: env, secretEnv: secretEnv, volumes: named,
                                           command: member.command, cpus: member.cpus,
                                           memory: member.memory, readyPort: member.readyPort))
            }
            groups.append(GroupSpec(name: group.name, network: group.network, notes: group.notes,
                                    members: members))
        }

        var tags: TagsSpec?
        if selection.tags {
            // Only assignments on things that are in the file, so an import tags what it builds.
            var included: Set<String> = []
            for s in containers { included.insert(TagSubject(kind: .container, id: s.name).storageKey) }
            for g in groups {
                if let id = inputs.groups.first(where: { $0.name == g.name })?.id {
                    included.insert(TagSubject(kind: .group, id: id).storageKey)
                }
            }
            for n in networks { included.insert(TagSubject(kind: .network, id: n.name).storageKey) }
            for v in volumes { included.insert(TagSubject(kind: .volume, id: v.name).storageKey) }
            for m in machines { included.insert(TagSubject(kind: .machine, id: m.name).storageKey) }
            for c in clusters { included.insert(TagSubject(kind: .cluster, id: c.name).storageKey) }

            var assignments: [TagsSpec.Assignment] = []
            for (key, tagIDs) in inputs.tags.assignments.sorted(by: { $0.key < $1.key })
            where included.contains(key) {
                guard let subject = TagSubject(storageKey: key) else { continue }
                // A group is keyed by id on this Mac and by name in the file.
                let id = subject.kind == .group
                    ? (inputs.groups.first { $0.id == subject.id }?.name ?? subject.id) : subject.id
                let names = tagIDs.compactMap { inputs.tags.tag(id: $0)?.name }
                if !names.isEmpty { assignments.append(.init(kind: subject.kind, id: id, tags: names)) }
            }
            tags = TagsSpec(definitions: inputs.tags.tags.map { .init(name: $0.name, color: $0.color) },
                            assignments: assignments)
        }

        var registries: RegistriesSpec?
        if selection.registries {
            registries = RegistriesSpec(
                entries: inputs.registries.all.map { known in
                    let fromCatalogue = !known.isUserAdded
                    return .init(host: known.id, name: fromCatalogue ? nil : known.name,
                                 usesHTTP: known.usesHTTP, signInRequired: known.signInNeed == .required)
                },
                defaultRegistry: inputs.defaultRegistry)
        }

        var dns: DNSSpec?
        if selection.dns {
            dns = DNSSpec(domains: inputs.dnsDomains.filter(\.resolverInstalled)
                            .map { .init(name: $0.name, localhost: $0.hostAliasAddress) },
                          containerDomain: inputs.containerDNSDomain)
        }

        // Hosts as claims to verify (Q34): who and where, and the key to expect — never a key, and
        // never trust. The other admin Mac pairs each one again.
        let hosts = inputs.hosts
            .filter { $0.role == .host && $0.isTrusted && selection.hosts.contains($0.fingerprint.hex) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { peer -> HostSpec in
                var spec = HostSpec(name: String(peer.displayName.prefix(64)), fingerprint: peer.fingerprint.hex)
                if selection.hostCategories {
                    let values = inputs.hostCategories.categories.compactMap { category in
                        inputs.hostCategories.value(of: category.id, for: peer.fingerprint.hex).map { (category.name, $0) }
                    }
                    if !values.isEmpty { spec.categories = Dictionary(uniqueKeysWithValues: values) }
                }
                switch peer.endpoint {
                case .bonjour(let name)?: spec.bonjourName = name
                case .address(let host, let port)?: spec.address = host; spec.port = Int(port)
                case nil: spec.bonjourName = peer.details.computerName
                }
                return spec
            }
        if !hosts.isEmpty {
            omissions.append(Omission(subject: "hosts",
                                      reason: "their trust and keys — each is paired again on the other Mac, and must present the same key"))
        }

        // Categories by name; values only on the hosts in the file. This Mac is never one of them —
        // on the other Mac, "this Mac" is a different machine.
        var hostCategories: [String]?
        if selection.hostCategories {
            hostCategories = inputs.hostCategories.categories.map(\.name)
            let inFile = Set(hosts.map(\.fingerprint))
            let elsewhere = inputs.hostCategories.values.keys.filter { !inFile.contains($0) }
            if !elsewhere.isEmpty {
                omissions.append(Omission(subject: "host categories",
                                          reason: "the values of Macs not in the file, This Mac's included"))
            }
        }

        let file = ConfigurationFile(networks: networks, volumes: volumes, machines: machines,
                                     clusters: clusters, containers: containers, groups: groups,
                                     tags: tags, registries: registries, dns: dns, hosts: hosts,
                                     hostCategories: hostCategories)
        return Result(file: file, omissions: Array(Set(omissions)).sorted { ($0.subject, $0.reason) < ($1.subject, $1.reason) })
    }

    // MARK: One container

    struct Defaults {
        var env: [String]
        var entrypoint: [String]
        var cmd: [String]
    }

    static func imageDefaults(_ images: [ContainerImage]) -> [String: Defaults] {
        var result: [String: Defaults] = [:]
        for image in images {
            guard let config = image.variants?.compactMap({ $0.config?.config }).first else { continue }
            let defaults = Defaults(env: config.Env ?? [], entrypoint: config.Entrypoint ?? [],
                                    cmd: config.Cmd ?? [])
            for name in aliases(image.reference) { result[name] = defaults }
        }
        return result
    }

    static func imageDigests(_ images: [ContainerImage]) -> [String: String] {
        var result: [String: String] = [:]
        for image in images {
            guard let digest = image.configuration.descriptor?.digest else { continue }
            for name in aliases(image.reference) { result[name] = digest }
        }
        return result
    }

    /// The spellings one image goes by: `docker.io/library/postgres:17-alpine` is also
    /// `postgres:17-alpine` and `library/postgres:17-alpine`.
    public static func aliases(_ reference: String) -> [String] {
        var names = [reference]
        if reference.hasPrefix("docker.io/library/") {
            names.append(String(reference.dropFirst("docker.io/library/".count)))
            names.append(String(reference.dropFirst("docker.io/".count)))
        } else if reference.hasPrefix("docker.io/") {
            names.append(String(reference.dropFirst("docker.io/".count)))
        }
        return names
    }

    static func service(from container: Container, defaults: Defaults?,
                        digest: String?) -> (ServiceSpec, [Omission]) {
        var omissions: [Omission] = []
        let configuration = container.configuration
        let name = container.id

        // Environment: what was chosen on top of the image's own.
        let imageEnv = Set(defaults?.env ?? [])
        let chosen = (configuration.initProcess?.environment ?? []).filter { !imageEnv.contains($0) }
        let (env, secretEnv, secretOmissions) = splitSecrets(chosen, subject: name)
        omissions += secretOmissions
        if defaults == nil, !chosen.isEmpty {
            omissions.append(Omission(subject: name, reason: "its image's settings weren't readable, "
                                      + "so the image's own variables may be included"))
        }

        // Command: `container run image ARGS` replaces the image's Cmd and keeps its Entrypoint.
        var command: [String] = []
        let ran = [configuration.initProcess?.executable].compactMap { $0 } + (configuration.initProcess?.arguments ?? [])
        if let defaults {
            let imageRuns = defaults.entrypoint + defaults.cmd
            if ran != imageRuns {
                if ran.starts(with: defaults.entrypoint) {
                    command = Array(ran.dropFirst(defaults.entrypoint.count))
                } else {
                    omissions.append(Omission(subject: name, reason: "it overrides the image's "
                                              + "entrypoint, which a file can't express yet"))
                }
            }
        }

        // Mounts: named volumes by name; a folder on this Mac is left out.
        var volumes: [String] = []
        for mount in configuration.mounts ?? [] {
            if let volume = mount.volumeName {
                volumes.append("\(volume):\(mount.destination)" + (mount.isReadOnly ? ":ro" : ""))
            } else {
                omissions.append(Omission(subject: name, reason: folderReason(mount.destination)))
            }
        }

        // Ports: one mapping each; a range has no single-port spelling here.
        var ports: [String] = []
        for port in configuration.publishedPorts ?? [] {
            guard (port.count ?? 1) == 1 else {
                omissions.append(Omission(subject: name, reason: "a published port range isn't exported"))
                continue
            }
            let address = port.hostAddress.flatMap { $0 == "0.0.0.0" ? nil : $0 }
            let suffix = port.proto.flatMap { $0 == "tcp" ? nil : "/\($0)" } ?? ""
            ports.append((address.map { "\($0):" } ?? "") + "\(port.hostPort):\(port.containerPort)" + suffix)
        }

        let network = configuration.networks?.first?.network
        let spec = ServiceSpec(name: name, image: configuration.image.reference,
                               digest: configuration.image.descriptor?.digest ?? digest,
                               ports: ports, env: env.sorted(), secretEnv: secretEnv,
                               volumes: volumes, command: command,
                               cpus: configuration.resources?.cpus,
                               memory: configuration.resources?.memoryInBytes.map(sizeString),
                               network: network == "default" ? nil : network)
        return (spec, omissions)
    }

    // MARK: Secrets

    /// Words that mark a variable as holding a secret. Whole words of the name (split on `_`),
    /// so `KEYBOARD_LAYOUT` is not one and `API_KEY` is.
    static let secretWords: Set<String> = ["PASSWORD", "PASSWD", "PASS", "PWD", "SECRET", "TOKEN",
                                           "KEY", "APIKEY", "CREDENTIAL", "CREDENTIALS", "PRIVATE"]

    public static func looksSecret(_ variable: String) -> Bool {
        let words = variable.uppercased().split(separator: "_").map(String.init)
        return words.contains { secretWords.contains($0) }
    }

    /// Plain variables kept; secret ones become names, with a secret named after the variable.
    static func splitSecrets(_ env: [String], subject: String) -> ([String], [SecretEnv], [Omission]) {
        var plain: [String] = []
        var secrets: [SecretEnv] = []
        var omissions: [Omission] = []
        for assignment in env {
            let name = assignment.split(separator: "=", maxSplits: 1).first.map(String.init) ?? assignment
            if looksSecret(name) {
                secrets.append(SecretEnv(name: name,
                                         secret: name.lowercased().replacingOccurrences(of: "_", with: "-")))
                omissions.append(Omission(subject: subject,
                                          reason: "\(name)'s value — it looks like a secret; the importer is asked for it"))
            } else {
                plain.append(assignment)
            }
        }
        return (plain, secrets, omissions)
    }

    // MARK: Helpers

    static func folderReason(_ destination: String) -> String {
        "the folder mounted at \(destination) — it's on this Mac, and its path names your account"
    }

    /// Bytes as the CLI's size flags take them: whole gigabytes as `G`, else megabytes.
    static func sizeString(_ bytes: Int64) -> String {
        let mib: Int64 = 1_048_576
        if bytes % (1024 * mib) == 0 { return "\(bytes / (1024 * mib))G" }
        return "\(max(1, bytes / mib))M"
    }

    static func labels(_ labels: [String: String]?) -> [String] {
        (labels ?? [:])
            // The runtime's own bookkeeping is not the user's configuration.
            .filter { !$0.key.hasPrefix("com.apple.") }
            .map { "\($0.key)=\($0.value)" }.sorted()
    }
}
