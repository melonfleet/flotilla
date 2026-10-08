import Foundation

/// Importing a `.flotilla` file (DECISIONS Q29): what is in it, what clashes with this Mac, and the
/// file as it will actually be built once the user has decided each clash.
///
/// Pure. The review screen shows `items`, the user resolves every clash (the owner's choice: per
/// item — skip, rename or replace), and `resolve` returns the file with skips removed and every
/// rename carried through to whatever refers to it. The app then runs it, each command through the
/// `Allowlist` as usual. Nothing here touches the Mac.
public enum ConfigurationImport {

    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case network, volume, machine, cluster, container, group, dnsDomain, host

        public var title: String {
            switch self {
            case .network: "Network"
            case .volume: "Volume"
            case .machine: "Machine"
            case .cluster: "Cluster"
            case .container: "Container"
            case .group: "Group"
            case .dnsDomain: "DNS domain"
            case .host: "Host"
            }
        }
    }

    public enum Resolution: Sendable, Equatable, Hashable {
        case create
        case skip
        case rename(String)
        /// Delete what is here, then build the file's. For a volume that deletes its data.
        case replace
    }

    public struct Item: Identifiable, Sendable, Equatable, Hashable {
        public let kind: Kind
        public let name: String
        /// Something with this name is already on this Mac.
        public let clashes: Bool
        /// What identifies it when the name does not: a host's fingerprint, since two Macs can
        /// share a name.
        public var key: String? = nil
        public var id: String { "\(kind.rawValue)/\(key ?? name)" }

        /// Whether "replace" is offered. A DNS domain that exists is the same domain — there is
        /// nothing to replace it with — and a host already in the book is the same Mac.
        public var canReplace: Bool { kind != .dnsDomain && kind != .host }
        public var canRename: Bool { kind != .dnsDomain && kind != .host }
    }

    /// What this Mac already has.
    public struct Existing: Sendable, Equatable {
        /// Every container name, and every name a group has claimed for a member.
        public var containers: Set<String> = []
        public var groups: Set<String> = []
        public var networks: Set<String> = []
        public var volumes: Set<String> = []
        public var machines: Set<String> = []
        public var clusters: Set<String> = []
        public var dnsDomains: Set<String> = []
        /// Fingerprints (hex) of every host this Mac knows, in any state, or has imported already.
        public var hosts: Set<String> = []
        public init() {}

        func names(_ kind: Kind) -> Set<String> {
            switch kind {
            case .network: networks
            case .volume: volumes
            case .machine: machines
            case .cluster: clusters
            case .container: containers
            case .group: groups
            case .dnsDomain: dnsDomains
            case .host: hosts
            }
        }

        func has(_ kind: Kind, _ name: String) -> Bool {
            // Container and group names compare case-insensitively, as `GroupBook` does.
            names(kind).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    // MARK: Items

    public static func items(_ file: ConfigurationFile, existing: Existing) -> [Item] {
        var items: [Item] = []
        func add(_ kind: Kind, _ name: String, clashes: Bool? = nil) {
            items.append(Item(kind: kind, name: name, clashes: clashes ?? existing.has(kind, name)))
        }
        file.networks.forEach { add(.network, $0.name) }
        file.volumes.forEach { add(.volume, $0.name) }
        file.machines.forEach { add(.machine, $0.name) }
        file.clusters.forEach { add(.cluster, $0.name) }
        file.containers.forEach { add(.container, $0.name) }
        for group in file.groups {
            // A group clashes on its own name or on any of its members' — a container name is
            // global on a Mac, so two `db`s cannot both exist.
            let memberClash = group.members.contains { existing.has(.container, $0.name) }
            add(.group, group.name, clashes: existing.has(.group, group.name) || memberClash)
        }
        file.dns?.domains.forEach { add(.dnsDomain, $0.name) }
        for host in file.hosts {
            items.append(Item(kind: .host, name: host.name,
                              clashes: existing.hosts.contains(host.fingerprint.lowercased()),
                              key: host.fingerprint.lowercased()))
        }
        return items
    }

    /// New things are created; a clash starts **undecided**, and Import waits for an answer.
    /// A DNS domain that already exists needs nothing done, so it is skipped without asking.
    public static func initialResolutions(_ items: [Item]) -> [String: Resolution] {
        var resolutions: [String: Resolution] = [:]
        for item in items {
            if !item.clashes { resolutions[item.id] = .create }
            else if item.kind == .dnsDomain || item.kind == .host { resolutions[item.id] = .skip }
        }
        return resolutions
    }

    /// A free name for a rename: `name-2`, `name-3`…
    public static func suggestedRename(_ item: Item, existing: Existing, file: ConfigurationFile) -> String {
        var taken = existing.names(item.kind)
        if item.kind == .group { taken.formUnion(file.groups.map(\.name)) }
        return ResourceSuggestions.uniqueName(item.name, taken: taken)
    }

    /// Why Import cannot go ahead yet, item by item.
    public static func problems(_ items: [Item], resolutions: [String: Resolution],
                                existing: Existing) -> [String: String] {
        var problems: [String: String] = [:]
        var newNames: [Kind: [String]] = [:]
        for item in items {
            switch resolutions[item.id] {
            case nil:
                problems[item.id] = "Already on this Mac — choose skip, rename or replace."
            case .rename(let raw)?:
                let name = raw.trimmingCharacters(in: .whitespaces)
                if item.kind == .group {
                    if name.isEmpty || name.count > 64 { problems[item.id] = "Give it a name." }
                } else if !Allowlist.accepts(name, as: .identifier) {
                    problems[item.id] = ValueShape.identifier.rule
                }
                if existing.has(item.kind, name) { problems[item.id] = "“\(name)” is taken too." }
                newNames[item.kind, default: []].append(name.lowercased())
            default:
                break
            }
        }
        // Two renames to the same new name.
        for (kind, names) in newNames {
            let doubled = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
            for item in items where item.kind == kind {
                if case .rename(let name)? = resolutions[item.id], doubled.contains(name.lowercased()) {
                    problems[item.id] = "Two things can't be renamed to the same name."
                }
            }
        }
        return problems
    }

    // MARK: Resolving

    /// The file as it will be built: skipped things removed (references to a skipped network or
    /// volume keep pointing at the one already here — that is what skipping means), and every
    /// rename carried through to what refers to it.
    public static func resolve(_ file: ConfigurationFile, resolutions: [String: Resolution],
                               existing: Existing) -> ConfigurationFile {
        var out = file
        func resolution(_ kind: Kind, _ name: String) -> Resolution {
            resolutions["\(kind.rawValue)/\(name)"] ?? .create
        }
        func renamed(_ kind: Kind, _ name: String) -> String {
            if case .rename(let new) = resolution(kind, name) { return new.trimmingCharacters(in: .whitespaces) }
            return name
        }
        func kept(_ kind: Kind, _ name: String) -> Bool { resolution(kind, name) != .skip }

        // Networks and volumes first: everything else refers to them.
        out.networks = file.networks.filter { kept(.network, $0.name) }.map {
            var n = $0; n.name = renamed(.network, $0.name); return n
        }
        out.volumes = file.volumes.filter { kept(.volume, $0.name) }.map {
            var v = $0; v.name = renamed(.volume, $0.name); return v
        }
        func remount(_ volumes: [String]) -> [String] {
            volumes.map { mount in
                var parts = mount.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard let source = parts.first, file.volumes.contains(where: { $0.name == source }) else { return mount }
                parts[0] = renamed(.volume, source)
                return parts.joined(separator: ":")
            }
        }
        func renetwork(_ network: String?) -> String? {
            guard let network, file.networks.contains(where: { $0.name == network }) else { return network }
            return renamed(.network, network)
        }

        out.machines = file.machines.filter { kept(.machine, $0.name) }.map {
            MachineSpec(name: renamed(.machine, $0.name), image: $0.image, cpus: $0.cpus,
                        memory: $0.memory, homeMount: $0.homeMount)
        }
        out.clusters = file.clusters.filter { kept(.cluster, $0.name) }.map {
            var c = $0; c.name = renamed(.cluster, $0.name); return c
        }
        out.containers = file.containers.filter { kept(.container, $0.name) }.map {
            var s = $0
            s.name = renamed(.container, $0.name)
            s.volumes = remount($0.volumes)
            s.network = renetwork($0.network)
            return s
        }

        // Groups: a renamed group whose members clash renames those members too, and rewrites
        // any value that names one — `WORDPRESS_DB_HOST=wordpress-db:3306` must follow.
        var takenContainers = existing.containers.union(out.containers.map(\.name))
        out.groups = []
        for group in file.groups where kept(.group, group.name) {
            var g = group
            g.name = renamed(.group, group.name)
            g.network = renetwork(group.network)
            var memberRenames: [String: String] = [:]
            if case .rename = resolution(.group, group.name) {
                for member in group.members where existing.has(.container, member.name) {
                    let new = ResourceSuggestions.uniqueName(member.name, taken: takenContainers)
                    memberRenames[member.name] = new
                    takenContainers.insert(new)
                }
            }
            g.members = group.members.map { member in
                var m = member
                m.name = memberRenames[member.name] ?? member.name
                m.volumes = remount(member.volumes)
                m.env = member.env.map { rewrite($0, renames: memberRenames) }
                return m
            }
            g.notes = group.notes.map { rewrite($0, renames: memberRenames) }
            out.groups.append(g)
            takenContainers.formUnion(g.members.map(\.name))
        }

        // Tags follow what they are on; an assignment to something skipped goes with it.
        if var tags = file.tags {
            tags.assignments = tags.assignments.compactMap { assignment in
                let kind: Kind? = switch assignment.kind {
                case .network: .network
                case .volume: .volume
                case .machine: .machine
                case .cluster: .cluster
                case .container: .container
                case .group: .group
                default: nil
                }
                guard let kind else { return nil }
                guard kept(kind, assignment.id) else { return nil }
                var a = assignment
                a.id = renamed(kind, assignment.id)
                return a
            }
            out.tags = tags
        }

        if var dns = file.dns {
            dns.domains = dns.domains.filter { kept(.dnsDomain, $0.name) }
            out.dns = dns
        }
        out.hosts = file.hosts.filter { kept(.host, $0.fingerprint.lowercased()) }
        return out
    }

    /// Replaces whole names only: `db` in `db:5432` or `postgres://db/app`, not in `dbadmin`.
    static func rewrite(_ text: String, renames: [String: String]) -> String {
        guard !renames.isEmpty else { return text }
        var out = text
        for (old, new) in renames.sorted(by: { $0.key.count > $1.key.count }) {
            var result = ""
            var rest = Substring(out)
            while let range = rest.range(of: old) {
                let before = range.lowerBound == rest.startIndex ? nil : rest[rest.index(before: range.lowerBound)]
                let after = range.upperBound == rest.endIndex ? nil : rest[range.upperBound]
                let isWord: (Character?) -> Bool = { c in
                    guard let c else { return false }
                    // Not `.`: it ends a name — `db.flotilla` names `db`, and so does `db.` at the
                    // end of a sentence in a note.
                    return c.isLetter || c.isNumber || c == "-" || c == "_"
                }
                result += rest[..<range.lowerBound]
                result += (isWord(before) || isWord(after)) ? old : new
                rest = rest[range.upperBound...]
            }
            out = result + rest
        }
        return out
    }

    // MARK: What import needs from the user

    /// A password the file names but cannot carry.
    public struct SecretNeed: Identifiable, Sendable, Equatable {
        public enum Owner: Sendable, Equatable { case group(String), container(String) }
        public let owner: Owner
        /// For a group, its secret names (one Keychain item each, shared by members); for a
        /// container, its variables.
        public let names: [String]
        public var id: String {
            switch owner {
            case .group(let name): "group/\(name)"
            case .container(let name): "container/\(name)"
            }
        }
    }

    public static func secretNeeds(_ file: ConfigurationFile) -> [SecretNeed] {
        var needs: [SecretNeed] = []
        for container in file.containers where !container.secretEnv.isEmpty {
            needs.append(SecretNeed(owner: .container(container.name), names: container.secretEnv.map(\.name)))
        }
        for group in file.groups {
            var seen = Set<String>()
            let names = group.members.flatMap(\.secretEnv).map(\.secret).filter { seen.insert($0).inserted }
            if !names.isEmpty { needs.append(SecretNeed(owner: .group(group.name), names: names)) }
        }
        return needs
    }

    /// Every image the file uses, once each, with the digest recorded at export if there was one.
    public static func images(_ file: ConfigurationFile) -> [(reference: String, digest: String?)] {
        var seen = Set<String>()
        var images: [(String, String?)] = []
        for service in file.containers + file.groups.flatMap(\.members) where seen.insert(service.image).inserted {
            images.append((service.image, service.digest))
        }
        for machine in file.machines where seen.insert(machine.image).inserted {
            images.append((machine.image, nil))
        }
        return images
    }
}
