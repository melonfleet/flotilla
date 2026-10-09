import Foundation

// A `.flotilla` file, version 2: Flotilla's configuration — what to **build**, never content
// (DECISIONS Q29). One format for a shared group and a whole-Mac export, so the two are the same
// kind of file. Version 1 (`Flotillafile`: machines and containers only) still reads, through the
// same entry point.
//
// The rules `Flotillafile` set for v1 hold for every section here, because a `.flotilla` file is
// untrusted input from someone else's Mac:
//
// - **Parsing only.** Nothing here runs anything, reads another file or follows a URL. Import is a
//   review screen the user confirms, and every command still crosses `Allowlist` then.
// - **Unknown keys are refused**, not ignored: a key the author believed was applied and was not
//   is worse than an outright refusal.
// - **Every value is checked** against the same vocabulary the `Allowlist` uses for the CLI, and
//   every list, string and the file itself are bounded before anything is walked.
// - **No secret ever appears in a file.** A variable that holds one is a `secretEnv` entry: a
//   name, never a value. Writing one is impossible through `encoded()` — there is no field to put
//   it in.

// MARK: - Model

public struct NetworkSpec: Sendable, Equatable, Codable {
    public var name: String
    /// `--internal` — Apple calls it host-only.
    public var hostOnly: Bool
    public var subnet: String?
    public var labels: [String]

    public init(name: String, hostOnly: Bool = false, subnet: String? = nil, labels: [String] = []) {
        self.name = name
        self.hostOnly = hostOnly
        self.subnet = subnet
        self.labels = labels
    }
}

/// A volume's **definition**. Created empty on import — the data is content, and content is the
/// future migration feature's job, not this one's.
public struct VolumeSpec: Sendable, Equatable, Codable {
    public var name: String
    public var size: String?
    public var labels: [String]

    public init(name: String, size: String? = nil, labels: [String] = []) {
        self.name = name
        self.size = size
        self.labels = labels
    }
}

public struct ClusterSpec: Sendable, Equatable, Codable {
    public var name: String
    public var cpus: Int?
    public var memory: String?
    public var nodeImage: String?
    public var disposable: Bool

    public init(name: String, cpus: Int? = nil, memory: String? = nil, nodeImage: String? = nil,
                disposable: Bool = false) {
        self.name = name
        self.cpus = cpus
        self.memory = memory
        self.nodeImage = nodeImage
        self.disposable = disposable
    }
}

/// A container, standalone or inside a group. One shape for both, so a group member and a
/// container are written the same way.
public struct ServiceSpec: Sendable, Equatable, Codable {
    public var name: String
    public var image: String
    /// The image's digest when exported, so the importer can pull the same bytes.
    public var digest: String?
    public var ports: [String]
    public var env: [String]
    /// Variables whose values were secrets: names only. The importer asks for each, or generates.
    public var secretEnv: [SecretEnv]
    /// Named volumes only — a folder on the sender's Mac is never written (`omitted` says so).
    public var volumes: [String]
    public var command: [String]
    public var cpus: Int?
    public var memory: String?
    /// Standalone containers only; a group's members take the group's.
    public var network: String?
    /// Group members only (Q21 amended).
    public var readyPort: Int?

    public init(name: String, image: String, digest: String? = nil, ports: [String] = [],
                env: [String] = [], secretEnv: [SecretEnv] = [], volumes: [String] = [],
                command: [String] = [], cpus: Int? = nil, memory: String? = nil,
                network: String? = nil, readyPort: Int? = nil) {
        self.name = name
        self.image = image
        self.digest = digest
        self.ports = ports
        self.env = env
        self.secretEnv = secretEnv
        self.volumes = volumes
        self.command = command
        self.cpus = cpus
        self.memory = memory
        self.network = network
        self.readyPort = readyPort
    }
}

public struct GroupSpec: Sendable, Equatable, Codable {
    public var name: String
    public var network: String?
    public var notes: [String]
    public var members: [ServiceSpec]

    public init(name: String, network: String? = nil, notes: [String] = [], members: [ServiceSpec]) {
        self.name = name
        self.network = network
        self.notes = notes
        self.members = members
    }
}

/// Written by raw value (`container`, `volume`…), as tag assignments are stored.
extension ActivityKind: Codable {}

public struct TagsSpec: Sendable, Equatable, Codable {
    public struct Definition: Sendable, Equatable, Codable {
        public var name: String
        public var color: TagColor
        public init(name: String, color: TagColor) { self.name = name; self.color = color }
    }
    /// Which thing carries which tags, by tag **name** — ids are this Mac's and mean nothing on
    /// another.
    public struct Assignment: Sendable, Equatable, Codable {
        public var kind: ActivityKind
        public var id: String
        public var tags: [String]
        public init(kind: ActivityKind, id: String, tags: [String]) {
            self.kind = kind; self.id = id; self.tags = tags
        }
    }
    public var definitions: [Definition]
    public var assignments: [Assignment]

    public init(definitions: [Definition] = [], assignments: [Assignment] = []) {
        self.definitions = definitions
        self.assignments = assignments
    }
}

/// The registry **list**. Never a sign-in (Q20): the importer says which need signing in.
public struct RegistriesSpec: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var host: String
        /// Only for one the catalogue does not know; a catalogue host brings its own.
        public var name: String?
        public var usesHTTP: Bool
        public var signInRequired: Bool
        public init(host: String, name: String? = nil, usesHTTP: Bool = false,
                    signInRequired: Bool = false) {
            self.host = host; self.name = name; self.usesHTTP = usesHTTP
            self.signInRequired = signInRequired
        }
    }
    public var entries: [Entry]
    /// What Flotilla's Pull form completes a bare name against.
    public var defaultRegistry: String?

    public init(entries: [Entry] = [], defaultRegistry: String? = nil) {
        self.entries = entries
        self.defaultRegistry = defaultRegistry
    }
}

public struct DNSSpec: Sendable, Equatable, Codable {
    public struct Domain: Sendable, Equatable, Codable {
        public var name: String
        /// Set for a host alias.
        public var localhost: String?
        public init(name: String, localhost: String? = nil) { self.name = name; self.localhost = localhost }
    }
    public var domains: [Domain]
    /// The one containers are named under.
    public var containerDomain: String?

    public init(domains: [Domain] = [], containerDomain: String? = nil) {
        self.domains = domains
        self.containerDomain = containerDomain
    }
}

/// A paired host, written as **a claim to verify** (DECISIONS Q34): its name, how to reach it, and
/// the fingerprint of the key it should present. Never a key, and never trust — on the importing
/// Mac it is a row to pair, and pairing is refused if the host presents a different key.
public struct HostSpec: Sendable, Equatable, Codable {
    public var name: String
    /// The Bonjour name it advertises, when it was found that way.
    public var bonjourName: String?
    /// Its address and port, when it was added by address.
    public var address: String?
    public var port: Int?
    /// SHA-256 of its public key, as 64 hex characters.
    public var fingerprint: String
    /// Its value in each of the admin's host categories, by category **name** — `{"Rack": "R1"}`.
    /// Every name is one listed in the file's `hostCategories`.
    public var categories: [String: String]?

    public init(name: String, bonjourName: String? = nil, address: String? = nil, port: Int? = nil,
                fingerprint: String, categories: [String: String]? = nil) {
        self.name = name
        self.bonjourName = bonjourName
        self.address = address
        self.port = port
        self.fingerprint = fingerprint
        self.categories = categories
    }
}

public struct ConfigurationFile: Sendable, Equatable {
    public static let currentVersion = 2
    public static let fileExtension = "flotilla"

    public var networks: [NetworkSpec]
    public var volumes: [VolumeSpec]
    public var machines: [MachineSpec]
    public var clusters: [ClusterSpec]
    public var containers: [ServiceSpec]
    public var groups: [GroupSpec]
    public var tags: TagsSpec?
    public var registries: RegistriesSpec?
    public var dns: DNSSpec?
    /// Paired hosts, as claims to verify (Q34). Optional in the file, so a file without them is
    /// still read by a Flotilla that predates them.
    public var hosts: [HostSpec]
    /// The admin's host categories, by name and in order (Site, Rack, VLAN…) — how Hosts can be
    /// grouped (Q45). Each host's values travel on its `HostSpec`.
    public var hostCategories: [String]?

    public init(networks: [NetworkSpec] = [], volumes: [VolumeSpec] = [], machines: [MachineSpec] = [],
                clusters: [ClusterSpec] = [], containers: [ServiceSpec] = [], groups: [GroupSpec] = [],
                tags: TagsSpec? = nil, registries: RegistriesSpec? = nil, dns: DNSSpec? = nil,
                hosts: [HostSpec] = [], hostCategories: [String]? = nil) {
        self.hosts = hosts
        self.hostCategories = hostCategories
        self.networks = networks
        self.volumes = volumes
        self.machines = machines
        self.clusters = clusters
        self.containers = containers
        self.groups = groups
        self.tags = tags
        self.registries = registries
        self.dns = dns
    }

    public var isEmpty: Bool {
        networks.isEmpty && volumes.isEmpty && machines.isEmpty && clusters.isEmpty
            && containers.isEmpty && groups.isEmpty && tags == nil && registries == nil && dns == nil
            && hosts.isEmpty && hostCategories == nil
    }
}

extension MachineSpec: Codable {
    enum CodingKeys: String, CodingKey { case name, image, cpus, memory, homeMount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  image: try c.decode(String.self, forKey: .image),
                  cpus: try c.decodeIfPresent(Int.self, forKey: .cpus),
                  memory: try c.decodeIfPresent(String.self, forKey: .memory),
                  homeMount: try c.decodeIfPresent(String.self, forKey: .homeMount)
                      .flatMap(HomeMountMode.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(image, forKey: .image)
        try c.encodeIfPresent(cpus, forKey: .cpus)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(homeMount?.rawValue, forKey: .homeMount)
    }
}

// MARK: - Errors

public enum ConfigurationFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileTooLarge(bytes: Int, limit: Int)
    case malformedJSON(String)
    case missingVersion
    case unsupportedVersion(found: Int, supported: Int)
    case unknownField(context: String, field: String)
    case wrongType(context: String, detail: String)
    case invalidValue(context: String, field: String, value: String, rule: String)
    case tooManyEntries(context: String, limit: Int)
    case duplicateName(context: String, name: String)
    /// A version-1 file's own refusal, passed through unchanged.
    case version1(FlotillafileError)

    public var description: String {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            "The file is \(bytes) bytes, over the \(limit) byte limit."
        case .malformedJSON(let reason):
            "The file isn't valid JSON: \(reason)"
        case .missingVersion:
            "The file has no 'version' — it isn't a flotilla file."
        case .unsupportedVersion(let found, let supported):
            "The file is version \(found); this flotilla reads up to version \(supported). Update flotilla to open it."
        case .unknownField(let context, let field):
            "\(context) has an unknown field '\(field)'."
        case .wrongType(let context, let detail):
            "\(context): \(detail)"
        case .invalidValue(let context, let field, let value, let rule):
            "\(context): '\(value)' isn't a valid \(field). \(rule)"
        case .tooManyEntries(let context, let limit):
            "\(context) has more than \(limit) entries."
        case .duplicateName(let context, let name):
            "\(context) has more than one '\(name)'."
        case .version1(let error):
            error.description
        }
    }
}

// MARK: - Limits

extension ConfigurationFile {
    public struct Limits: Sendable, Equatable {
        public var maxFileBytes = 2_097_152
        public var maxEntries = 128          // per top-level list
        public var maxMembers = 16           // per group
        public var maxNotes = 16
        public var maxNoteLength = 512
        public var maxTags = 64
        public var maxAssignments = 512
        public static let `default` = Limits()
        public init() {}
    }
}

// MARK: - Writing

extension ConfigurationFile {
    /// The file, as JSON: version first, keys sorted, pretty-printed — a person can read it, and
    /// two exports of the same Mac diff cleanly.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Envelope(file: self))
    }

    private struct Envelope: Encodable {
        let file: ConfigurationFile
        enum CodingKeys: String, CodingKey {
            case version, networks, volumes, machines, clusters, containers, groups, tags, registries, dns, hosts
            case hostCategories
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ConfigurationFile.currentVersion, forKey: .version)
            if !file.networks.isEmpty { try c.encode(file.networks, forKey: .networks) }
            if !file.volumes.isEmpty { try c.encode(file.volumes, forKey: .volumes) }
            if !file.machines.isEmpty { try c.encode(file.machines, forKey: .machines) }
            if !file.clusters.isEmpty { try c.encode(file.clusters, forKey: .clusters) }
            if !file.containers.isEmpty { try c.encode(file.containers, forKey: .containers) }
            if !file.groups.isEmpty { try c.encode(file.groups, forKey: .groups) }
            try c.encodeIfPresent(file.tags, forKey: .tags)
            try c.encodeIfPresent(file.registries, forKey: .registries)
            try c.encodeIfPresent(file.dns, forKey: .dns)
            if !file.hosts.isEmpty { try c.encode(file.hosts, forKey: .hosts) }
            try c.encodeIfPresent(file.hostCategories, forKey: .hostCategories)
        }
    }
}

// MARK: - Reading

extension ConfigurationFile {
    /// Reads a `.flotilla` file of any supported version, validating everything.
    public static func parse(_ data: Data, limits: Limits = .default) throws -> ConfigurationFile {
        guard data.count <= limits.maxFileBytes else {
            throw ConfigurationFileError.fileTooLarge(bytes: data.count, limit: limits.maxFileBytes)
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw ConfigurationFileError.malformedJSON(error.localizedDescription) }
        guard let object = root as? [String: Any] else {
            throw ConfigurationFileError.malformedJSON("Expected an object at the top level.")
        }
        // Typed, not `object["version"] as? Int`: on Darwin a JSON `true` bridges to `1` and a
        // `1` passes as a `Bool`, so the untyped tree cannot tell them apart.
        struct Probe: Decodable { let version: Int? }
        guard let version = (try? JSONDecoder().decode(Probe.self, from: data))?.version else {
            throw ConfigurationFileError.missingVersion
        }
        if version == 1 {
            do {
                let v1 = try Flotillafile.parse(data)
                return ConfigurationFile(machines: v1.machines,
                                         containers: v1.containers.map(ServiceSpec.init))
            } catch let error as FlotillafileError {
                throw ConfigurationFileError.version1(error)
            }
        }
        guard version == currentVersion else {
            throw ConfigurationFileError.unsupportedVersion(found: version, supported: currentVersion)
        }

        try Schema.file.screen(object, context: "File")

        let file: ConfigurationFile
        do {
            file = try JSONDecoder().decode(Decoded.self, from: data).file
        } catch let DecodingError.typeMismatch(_, context) {
            throw ConfigurationFileError.wrongType(context: path(context), detail: context.debugDescription)
        } catch let DecodingError.valueNotFound(_, context) {
            throw ConfigurationFileError.wrongType(context: path(context), detail: context.debugDescription)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ConfigurationFileError.wrongType(context: path(context),
                                                   detail: "missing required field '\(key.stringValue)'")
        } catch let DecodingError.dataCorrupted(context) {
            throw ConfigurationFileError.wrongType(context: path(context), detail: context.debugDescription)
        }
        try file.validate(limits: limits)
        return file
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.isEmpty ? "File" : context.codingPath.map(\.stringValue).joined(separator: ".")
    }

    /// Every list optional in the file and empty in the model.
    private struct Decoded: Decodable {
        let file: ConfigurationFile
        enum CodingKeys: String, CodingKey {
            case networks, volumes, machines, clusters, containers, groups, tags, registries, dns, hosts
            case hostCategories
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = ConfigurationFile(
                networks: try c.decodeIfPresent([NetworkSpec].self, forKey: .networks) ?? [],
                volumes: try c.decodeIfPresent([VolumeSpec].self, forKey: .volumes) ?? [],
                machines: try c.decodeIfPresent([MachineSpec].self, forKey: .machines) ?? [],
                clusters: try c.decodeIfPresent([ClusterSpec].self, forKey: .clusters) ?? [],
                containers: try c.decodeIfPresent([ServiceSpec].self, forKey: .containers) ?? [],
                groups: try c.decodeIfPresent([GroupSpec].self, forKey: .groups) ?? [],
                tags: try c.decodeIfPresent(TagsSpec.self, forKey: .tags),
                registries: try c.decodeIfPresent(RegistriesSpec.self, forKey: .registries),
                dns: try c.decodeIfPresent(DNSSpec.self, forKey: .dns),
                hosts: try c.decodeIfPresent([HostSpec].self, forKey: .hosts) ?? [],
                hostCategories: try c.decodeIfPresent([String].self, forKey: .hostCategories))
        }
    }

    // MARK: Unknown-key screening

    /// The allowed keys at every level. Walks key names only, so it is not exposed to how
    /// `JSONSerialization` bridges numbers; the typed decode checks types.
    indirect enum Schema: Sendable {
        case object([String: Schema])
        case array(Schema)
        case leaf

        func screen(_ value: Any, context: String) throws {
            switch self {
            case .leaf:
                return
            case .array(let element):
                guard let array = value as? [Any] else { return }
                for (index, item) in array.enumerated() {
                    try element.screen(item, context: "\(context)[\(index)]")
                }
            case .object(let fields):
                guard let object = value as? [String: Any] else { return }
                for (key, child) in object {
                    guard let schema = fields[key] else {
                        throw ConfigurationFileError.unknownField(context: context, field: key)
                    }
                    try schema.screen(child, context: "\(context).\(key)")
                }
            }
        }

        static func leaves(_ keys: [String]) -> [String: Schema] {
            Dictionary(uniqueKeysWithValues: keys.map { ($0, Schema.leaf) })
        }

        static let secretEnv = Schema.array(.object(leaves(["name", "secret"])))

        static let service = Schema.object(leaves(["name", "image", "digest", "ports", "env",
                                                   "volumes", "command", "cpus", "memory",
                                                   "network", "readyPort"])
                                           .merging(["secretEnv": secretEnv]) { $1 })

        static let file = Schema.object([
            "version": .leaf,
            "networks": .array(.object(leaves(["name", "hostOnly", "subnet", "labels"]))),
            "volumes": .array(.object(leaves(["name", "size", "labels"]))),
            "machines": .array(.object(leaves(["name", "image", "cpus", "memory", "homeMount"]))),
            "clusters": .array(.object(leaves(["name", "cpus", "memory", "nodeImage", "disposable"]))),
            "containers": .array(service),
            "groups": .array(.object(leaves(["name", "network", "notes"])
                                        .merging(["members": .array(service)]) { $1 })),
            "tags": .object(["definitions": .array(.object(leaves(["name", "color"]))),
                             "assignments": .array(.object(leaves(["kind", "id", "tags"])))]),
            "registries": .object(["entries": .array(.object(leaves(["host", "name", "usesHTTP",
                                                                      "signInRequired"]))),
                                   "defaultRegistry": .leaf]),
            "dns": .object(["domains": .array(.object(leaves(["name", "localhost"]))),
                            "containerDomain": .leaf]),
            // A host's categories are keyed by the owner's own names, so not screened by key here;
            // validation checks each against `hostCategories`.
            "hosts": .array(.object(leaves(["name", "bonjourName", "address", "port", "fingerprint", "categories"]))),
            "hostCategories": .array(.leaf),
        ])
    }
}

// MARK: - Validation

extension ConfigurationFile {
    func validate(limits: Limits) throws {
        func count(_ n: Int, _ context: String, _ limit: Int) throws {
            guard n <= limit else { throw ConfigurationFileError.tooManyEntries(context: context, limit: limit) }
        }
        func check(_ ok: Bool, _ context: String, _ field: String, _ value: String, _ rule: String) throws {
            guard ok else {
                throw ConfigurationFileError.invalidValue(context: context, field: field, value: value, rule: rule)
            }
        }
        func shaped(_ value: String, _ shape: ValueShape, _ context: String, _ field: String) throws {
            try check(Allowlist.accepts(value, as: shape), context, field, value, shape.rule)
        }
        func unique(_ names: [String], _ context: String) throws {
            var seen = Set<String>()
            for name in names where !seen.insert(name.lowercased()).inserted {
                throw ConfigurationFileError.duplicateName(context: context, name: name)
            }
        }

        try count(networks.count, "networks", limits.maxEntries)
        try unique(networks.map(\.name), "networks")
        for (i, network) in networks.enumerated() {
            let context = "networks[\(i)]"
            try shaped(network.name, .identifier, context, "name")
            if let subnet = network.subnet { try shaped(subnet, .cidr, context, "subnet") }
            try count(network.labels.count, "\(context).labels", 8)
            for label in network.labels { try shaped(label, .keyValue, context, "label") }
        }

        try count(volumes.count, "volumes", limits.maxEntries)
        try unique(volumes.map(\.name), "volumes")
        for (i, volume) in volumes.enumerated() {
            let context = "volumes[\(i)]"
            try shaped(volume.name, .identifier, context, "name")
            if let size = volume.size { try shaped(size, .memorySize, context, "size") }
            try count(volume.labels.count, "\(context).labels", 8)
            for label in volume.labels { try shaped(label, .keyValue, context, "label") }
        }

        // Machines reuse version 1's validation, through a round trip of its own format.
        try count(machines.count, "machines", limits.maxEntries)
        try unique(machines.map(\.name), "machines")
        for (i, machine) in machines.enumerated() {
            let context = "machines[\(i)]"
            try shaped(machine.name, .identifier, context, "name")
            try shaped(machine.image, .imageReference, context, "image")
            if let cpus = machine.cpus { try check((1...1024).contains(cpus), context, "cpus", "\(cpus)", ValueShape.count.rule) }
            if let memory = machine.memory { try shaped(memory, .memorySize, context, "memory") }
        }

        try count(clusters.count, "clusters", limits.maxEntries)
        try unique(clusters.map(\.name), "clusters")
        for (i, cluster) in clusters.enumerated() {
            let context = "clusters[\(i)]"
            try shaped(cluster.name, .identifier, context, "name")
            if let cpus = cluster.cpus { try check((1...1024).contains(cpus), context, "cpus", "\(cpus)", ValueShape.count.rule) }
            if let memory = cluster.memory { try shaped(memory, .memorySize, context, "memory") }
            if let image = cluster.nodeImage { try shaped(image, .taggedImageReference, context, "nodeImage") }
        }

        func service(_ s: ServiceSpec, _ context: String) throws {
            try shaped(s.name, .identifier, context, "name")
            try shaped(s.image, .imageReference, context, "image")
            if let digest = s.digest {
                let hex = digest.dropFirst("sha256:".count)
                try check(digest.hasPrefix("sha256:") && hex.count == 64
                            && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          context, "digest", digest, "Expected sha256: followed by 64 lowercase hex digits.")
            }
            try count(s.ports.count, "\(context).ports", 16)
            for port in s.ports { try shaped(port, .portMapping, context, "port") }
            try count(s.env.count + s.secretEnv.count, "\(context).env", 24)
            for assignment in s.env { try shaped(assignment, .envAssignment, context, "env") }
            for entry in s.secretEnv {
                try shaped(entry.name + "=x", .envAssignment, context, "secretEnv name")
                try shaped(entry.secret, .identifier, context, "secretEnv secret")
            }
            try count(s.volumes.count, "\(context).volumes", 16)
            for volume in s.volumes {
                // Named volumes only: a host folder in someone else's file is never mounted.
                let source = volume.split(separator: ":").first.map(String.init) ?? ""
                try check(!source.hasPrefix("/"), context, "volume", volume,
                          "A shared file can't mount a folder on this Mac; only named volumes.")
                // Version 1's own check: `Allowlist.accepts` judges a mount against a policy,
                // and this is a file, not an invocation — the policy applies at run time.
                try check(Flotillafile.isMountSpec(volume), context, "volume", volume, ValueShape.mountSpec.rule)
            }
            try count(s.command.count, "\(context).command", 64)
            for token in s.command { try shaped(token, .commandToken, context, "command") }
            if let cpus = s.cpus { try check((1...1024).contains(cpus), context, "cpus", "\(cpus)", ValueShape.count.rule) }
            if let memory = s.memory { try shaped(memory, .memorySize, context, "memory") }
            if let network = s.network { try shaped(network, .identifier, context, "network") }
            if let port = s.readyPort {
                try check((1...65535).contains(port), context, "readyPort", "\(port)", "Expected a port from 1 to 65535.")
            }
        }

        try count(containers.count, "containers", limits.maxEntries)
        for (i, s) in containers.enumerated() { try service(s, "containers[\(i)]") }

        try count(groups.count, "groups", limits.maxEntries)
        try unique(groups.map(\.name), "groups")
        for (i, group) in groups.enumerated() {
            let context = "groups[\(i)]"
            try check(!group.name.trimmingCharacters(in: .whitespaces).isEmpty && group.name.count <= 64,
                      context, "name", group.name, "Expected a name of 1 to 64 characters.")
            if let network = group.network { try shaped(network, .identifier, context, "network") }
            try count(group.notes.count, "\(context).notes", limits.maxNotes)
            for note in group.notes {
                try check(note.count <= limits.maxNoteLength && !note.contains(where: \.isNewline),
                          context, "note", String(note.prefix(40)), "Notes are single lines of up to 512 characters.")
            }
            try count(group.members.count, "\(context).members", limits.maxMembers)
            for (j, member) in group.members.enumerated() { try service(member, "\(context).members[\(j)]") }
        }
        // A container name is global on a Mac, so it is unique across the whole file.
        try unique(containers.map(\.name) + groups.flatMap { $0.members.map(\.name) }, "containers and group members")

        if let tags {
            try count(tags.definitions.count, "tags.definitions", limits.maxTags)
            try unique(tags.definitions.map(\.name), "tags")
            let names = Set(tags.definitions.map(\.name))
            for (i, definition) in tags.definitions.enumerated() {
                try check(!definition.name.trimmingCharacters(in: .whitespaces).isEmpty && definition.name.count <= 40,
                          "tags.definitions[\(i)]", "name", definition.name, "Expected 1 to 40 characters.")
            }
            try count(tags.assignments.count, "tags.assignments", limits.maxAssignments)
            for (i, assignment) in tags.assignments.enumerated() {
                let context = "tags.assignments[\(i)]"
                try check(!assignment.id.isEmpty && assignment.id.count <= 512, context, "id", assignment.id,
                          "Expected 1 to 512 characters.")
                for tag in assignment.tags {
                    try check(names.contains(tag), context, "tag", tag, "Every tag used must be defined in tags.definitions.")
                }
            }
        }

        if let registries {
            try count(registries.entries.count, "registries.entries", 64)
            try unique(registries.entries.map(\.host), "registries")
            for (i, entry) in registries.entries.enumerated() {
                try shaped(entry.host, .registryHost, "registries.entries[\(i)]", "host")
                if let name = entry.name {
                    try check(name.count <= 64, "registries.entries[\(i)]", "name", name, "Expected up to 64 characters.")
                }
            }
            if let host = registries.defaultRegistry { try shaped(host, .registryHost, "registries", "defaultRegistry") }
        }

        if let dns {
            try count(dns.domains.count, "dns.domains", 32)
            try unique(dns.domains.map(\.name), "dns.domains")
            for (i, domain) in dns.domains.enumerated() {
                try shaped(domain.name, .dnsDomain, "dns.domains[\(i)]", "name")
                try check(LocalDNS.reservedProblem(domain.name) == nil, "dns.domains[\(i)]", "name", domain.name,
                          LocalDNS.reservedProblem(domain.name) ?? "")
                if let ip = domain.localhost { try shaped(ip, .ipv4Address, "dns.domains[\(i)]", "localhost") }
            }
            if let domain = dns.containerDomain { try shaped(domain, .dnsDomain, "dns", "containerDomain") }
        }

        // Hosts are claims, but still checked: a fingerprint that is not one, a name a person
        // could not have given, or an address with a path or spaces in it is refused here.
        try count(hosts.count, "hosts", 64)
        try unique(hosts.map(\.fingerprint), "hosts")
        for (i, host) in hosts.enumerated() {
            let context = "hosts[\(i)]"
            let printable: (String) -> Bool = { text in
                !text.isEmpty && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            try check(printable(host.name) && host.name.count <= 64, context, "name", host.name,
                      "Expected 1 to 64 printable characters.")
            try check(PeerFingerprint(hex: host.fingerprint) != nil, context, "fingerprint", host.fingerprint,
                      "Expected 64 hexadecimal characters.")
            if let bonjour = host.bonjourName {
                try check(printable(bonjour) && bonjour.utf8.count <= 63, context, "bonjourName", bonjour,
                          "Expected 1 to 63 bytes of printable text.")
            }
            if let address = host.address {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:[]%"))
                try check(!address.isEmpty && address.count <= 253
                          && address.unicodeScalars.allSatisfy { allowed.contains($0) },
                          context, "address", address, "Expected a host name or IP address.")
                try check((1...65535).contains(host.port ?? 0), context, "port", "\(host.port ?? 0)",
                          "Expected a port from 1 to 65535.")
            }
            try check(host.bonjourName != nil || host.address != nil, context, "address", "",
                      "Expected a Bonjour name or an address.")
            if let categories = host.categories {
                try count(categories.count, "\(context).categories", 32)
                let listed = Set(hostCategories ?? [])
                for (name, value) in categories.sorted(by: { $0.key < $1.key }) {
                    try check(listed.contains(name), context, "categories", name,
                              "Every category used must be listed in hostCategories.")
                    try check(printable(value) && value.count <= HostCategoryBook.maxValueLength,
                              "\(context).categories", name, value,
                              "Expected 1 to \(HostCategoryBook.maxValueLength) printable characters.")
                }
            }
        }

        if let hostCategories {
            try count(hostCategories.count, "hostCategories", 32)
            try check(Set(hostCategories.map { $0.lowercased() }).count == hostCategories.count,
                      "hostCategories", "name", hostCategories.joined(separator: ", "), "Expected each name once.")
            let book = HostCategoryBook()
            for (i, name) in hostCategories.enumerated() {
                try check(!name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                          && book.problem(withName: name) == nil && name == name.trimmingCharacters(in: .whitespaces),
                          "hostCategories[\(i)]", "name", name,
                          book.problem(withName: name) ?? "Expected 1 to \(HostCategoryBook.maxNameLength) printable characters.")
            }
        }
    }
}

extension ServiceSpec {
    /// A version-1 `containers` entry.
    public init(_ spec: ContainerSpec) {
        self.init(name: spec.name, image: spec.image, ports: spec.ports, env: spec.env,
                  volumes: spec.volumes, cpus: spec.cpus, memory: spec.memory)
    }
}


// MARK: - Lenient reading, tidy writing
//
// A shared file is often written or trimmed by hand, so every list and flag is optional when read
// — absent means empty or false — and left out when written if it is empty or false. Synthesised
// `Codable` would require every key, refusing a hand-written `{"name": "web", "image": "nginx"}`.

private extension KeyedDecodingContainer {
    func list<T: Decodable>(_ key: Key) throws -> [T] { try decodeIfPresent([T].self, forKey: key) ?? [] }
    func flag(_ key: Key) throws -> Bool { try decodeIfPresent(Bool.self, forKey: key) ?? false }
}

private extension KeyedEncodingContainer {
    mutating func list<T: Encodable>(_ value: [T], _ key: Key) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }
    mutating func flag(_ value: Bool, _ key: Key) throws { if value { try encode(true, forKey: key) } }
}

extension NetworkSpec {
    enum CodingKeys: String, CodingKey { case name, hostOnly, subnet, labels }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), hostOnly: try c.flag(.hostOnly),
                  subnet: try c.decodeIfPresent(String.self, forKey: .subnet), labels: try c.list(.labels))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.flag(hostOnly, .hostOnly)
        try c.encodeIfPresent(subnet, forKey: .subnet)
        try c.list(labels, .labels)
    }
}

extension VolumeSpec {
    enum CodingKeys: String, CodingKey { case name, size, labels }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  size: try c.decodeIfPresent(String.self, forKey: .size), labels: try c.list(.labels))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(size, forKey: .size)
        try c.list(labels, .labels)
    }
}

extension ClusterSpec {
    enum CodingKeys: String, CodingKey { case name, cpus, memory, nodeImage, disposable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  cpus: try c.decodeIfPresent(Int.self, forKey: .cpus),
                  memory: try c.decodeIfPresent(String.self, forKey: .memory),
                  nodeImage: try c.decodeIfPresent(String.self, forKey: .nodeImage),
                  disposable: try c.flag(.disposable))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(cpus, forKey: .cpus)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(nodeImage, forKey: .nodeImage)
        try c.flag(disposable, .disposable)
    }
}

extension ServiceSpec {
    enum CodingKeys: String, CodingKey {
        case name, image, digest, ports, env, secretEnv, volumes, command, cpus, memory, network, readyPort
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  image: try c.decode(String.self, forKey: .image),
                  digest: try c.decodeIfPresent(String.self, forKey: .digest),
                  ports: try c.list(.ports), env: try c.list(.env), secretEnv: try c.list(.secretEnv),
                  volumes: try c.list(.volumes), command: try c.list(.command),
                  cpus: try c.decodeIfPresent(Int.self, forKey: .cpus),
                  memory: try c.decodeIfPresent(String.self, forKey: .memory),
                  network: try c.decodeIfPresent(String.self, forKey: .network),
                  readyPort: try c.decodeIfPresent(Int.self, forKey: .readyPort))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(image, forKey: .image)
        try c.encodeIfPresent(digest, forKey: .digest)
        try c.list(ports, .ports)
        try c.list(env, .env)
        try c.list(secretEnv, .secretEnv)
        try c.list(volumes, .volumes)
        try c.list(command, .command)
        try c.encodeIfPresent(cpus, forKey: .cpus)
        try c.encodeIfPresent(memory, forKey: .memory)
        try c.encodeIfPresent(network, forKey: .network)
        try c.encodeIfPresent(readyPort, forKey: .readyPort)
    }
}

extension GroupSpec {
    enum CodingKeys: String, CodingKey { case name, network, notes, members }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  network: try c.decodeIfPresent(String.self, forKey: .network),
                  notes: try c.list(.notes), members: try c.list(.members))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(network, forKey: .network)
        try c.list(notes, .notes)
        try c.list(members, .members)
    }
}

extension TagsSpec {
    enum CodingKeys: String, CodingKey { case definitions, assignments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(definitions: try c.list(.definitions), assignments: try c.list(.assignments))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.list(definitions, .definitions)
        try c.list(assignments, .assignments)
    }
}

extension RegistriesSpec.Entry {
    enum CodingKeys: String, CodingKey { case host, name, usesHTTP, signInRequired }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(host: try c.decode(String.self, forKey: .host),
                  name: try c.decodeIfPresent(String.self, forKey: .name),
                  usesHTTP: try c.flag(.usesHTTP), signInRequired: try c.flag(.signInRequired))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encodeIfPresent(name, forKey: .name)
        try c.flag(usesHTTP, .usesHTTP)
        try c.flag(signInRequired, .signInRequired)
    }
}

extension RegistriesSpec {
    enum CodingKeys: String, CodingKey { case entries, defaultRegistry }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try c.list(.entries),
                  defaultRegistry: try c.decodeIfPresent(String.self, forKey: .defaultRegistry))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.list(entries, .entries)
        try c.encodeIfPresent(defaultRegistry, forKey: .defaultRegistry)
    }
}

extension DNSSpec {
    enum CodingKeys: String, CodingKey { case domains, containerDomain }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(domains: try c.list(.domains),
                  containerDomain: try c.decodeIfPresent(String.self, forKey: .containerDomain))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.list(domains, .domains)
        try c.encodeIfPresent(containerDomain, forKey: .containerDomain)
    }
}
