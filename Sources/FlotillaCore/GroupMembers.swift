import Foundation

/// How a library service becomes a `GroupMember` — the one place that does it.
///
/// A stack builds its members here (`StackPlanner.plan`), and so does a group's "Add Service"
/// when several suggestions or images are picked at once. Two copies of the volume naming, the
/// secret mapping and the ready port are two copies that drift apart; this is the only one.
public enum GroupMembers {
    /// A member and the named volumes its mounts create, in mount order.
    public struct Built: Equatable, Sendable {
        public var member: GroupMember
        public var volumeNames: [String]
    }

    /// The mapping itself. Ports and env arrive already decided: a stack fills its templates and
    /// picks its published ports, a pick probes for free ones. What is shared is the rest —
    /// each volume is `<member>-<suffix>` mounted at its path, the secrets and the ready port
    /// pass through untouched.
    public static func member(named name: String, image: String, ports: [String], env: [String],
                              secretEnv: [SecretEnv], volumes: [StackVolume], command: [String],
                              readyPort: Int?) -> Built {
        let names = volumes.map { "\(name)-\($0.suffix)" }
        let mounts = zip(names, volumes).map { "\($0):\($1.path)" }
        // The recipe's owners travel with the mount they belong to: the mount text alone would
        // leave a picked Grafana's fresh volume root-owned and unwritable (Kyle, 20 October).
        var owners: [String: VolumeOwner] = [:]
        for (mount, volume) in zip(mounts, volumes) { owners[mount] = volume.volumeOwner }
        return Built(member: GroupMember(name: name, image: image, ports: ports, env: env,
                                         volumes: mounts, command: command,
                                         readyPort: readyPort, secretEnv: secretEnv,
                                         volumeOwners: owners),
                     volumeNames: names)
    }

    /// One service chosen in "Add Service": a library container, or an image on this Mac that may
    /// match one.
    public struct Pick: Equatable, Sendable {
        /// What the member runs. For a library container, its own image; for a local image, that
        /// image's reference — even when a library entry supplies the rest.
        public var image: String
        public var baseName: String
        /// The ports, env, volumes and secrets to start from. `nil` for an image with no match.
        public var container: LibraryContainer?
        public var readyPort: Int?

        public init(image: String, baseName: String, container: LibraryContainer? = nil,
                    readyPort: Int? = nil) {
            self.image = image; self.baseName = baseName; self.container = container
            self.readyPort = readyPort
        }

        public init?(entry: LibraryEntry) {
            guard entry.kind == .container, let container = entry.container else { return nil }
            self.init(image: container.image, baseName: container.name, container: container)
        }

        /// An image already on this Mac. A library *container* entry for the same repository **and
        /// the same major version** supplies ports, env and volumes (`SuggestionLibrary.recipe`); a
        /// stack's service does not (it needs its siblings).
        public init(localImage reference: String, in library: SuggestionLibrary) {
            let match = library.recipe(forImage: reference)?.container
            self.init(image: reference, baseName: match?.name ?? GroupMembers.defaultName(forImage: reference),
                      container: match)
        }
    }

    /// The major version a reference's tag names: `postgres:18.6` → 18, `postgres:17-alpine` → 17,
    /// `prom/prometheus:v3.13.4` → 3. Nil for `latest`, no tag, a digest-only reference, or any tag
    /// that doesn't start with a number — none of those says which release it is.
    public static func majorVersion(of reference: String) -> Int? {
        let named = reference.prefix { $0 != "@" }
        guard let colon = named.lastIndex(of: ":"),
              named.lastIndex(of: "/").map({ colon > $0 }) ?? true else { return nil }
        var tag = named[named.index(after: colon)...]
        if tag.first == "v" || tag.first == "V" { tag = tag.dropFirst() }
        let digits = tag.prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : Int(digits.prefix(9))
    }

    /// The group form's pending "Add Service": picks are prepared asynchronously (port probes, a
    /// peer's lists), and only the request still current may place the result. Leaving the picker,
    /// or opening Blank Service, withdraws it — otherwise a slow peer's single pick would replace the
    /// blank service being typed, and several would be appended after the picker had closed
    /// (Kyle, 20 October). One at a time: a second Add while the first prepares is ignored.
    public struct PickRequests: Equatable, Sendable {
        public private(set) var current: UUID?

        public init() {}

        /// A new request, or nil while one is still preparing.
        public mutating func begin() -> UUID? {
            guard current == nil else { return nil }
            let id = UUID()
            current = id
            return id
        }

        /// The picker was left: whatever is preparing places nothing.
        public mutating func withdraw() { current = nil }

        public func isCurrent(_ id: UUID) -> Bool { current == id }

        /// The request is done; a later one it no longer owns is left alone.
        public mutating func finish(_ id: UUID) { if current == id { current = nil } }
    }

    /// `docker.io/library/postgres:18.6` → `postgres`; always a valid container name.
    public static func defaultName(forImage reference: String) -> String {
        var last = String(reference.prefix { $0 != "@" }.split(separator: "/").last ?? "")
        if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
        var out = ""
        for character in last.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber { out.append(character) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "service" : String(out.prefix(48))
    }

    /// The Keychain secret for one variable of one member. Per member, unlike a stack's shared
    /// `db-password`: two picked databases must not silently share a password nobody chose.
    public static func secretName(member: String, variable: String) -> String {
        "\(member)-\(variable.lowercased().replacingOccurrences(of: "_", with: "-"))"
    }

    /// Members for several picks, in order, each clear of the others and of what is already there.
    ///
    /// - Names move past `takenNames` and `existing` (case-insensitively, as the group form
    ///   compares them) with `ResourceSuggestions.uniqueName`, and past any name whose volumes
    ///   would collide with `takenVolumes` — a volume named after an existing one would hand that
    ///   data to the image.
    /// - Host ports go through `SuggestionPorts.publishSpecs`, avoiding `usedHostPorts`, every
    ///   `existing` member's published ports and the earlier picks.
    public static func members(for picks: [Pick], existing: [GroupMember],
                               takenNames: Set<String> = [], takenVolumes: Set<String> = [],
                               usedHostPorts: Set<Int> = [],
                               isPortFree: (Int) -> Bool = { _ in true }) -> [GroupMember] {
        var names = Set(takenNames.union(existing.map(\.name)).map { $0.lowercased() })
        var volumes = takenVolumes.union(existing.flatMap(\.volumes).compactMap { mount in
            mount.split(separator: ":").first.map(String.init).flatMap { $0.hasPrefix("/") ? nil : $0 }
        })
        var ports = usedHostPorts.union(existing.flatMap(\.ports).compactMap(StackPlanner.hostPort(fromPublishSpec:)))
        var made: [GroupMember] = []
        for pick in picks {
            let source = pick.container
            let suffixes = source?.volumes.map(\.suffix) ?? []
            let base = pick.baseName.lowercased()
            var name = ResourceSuggestions.uniqueName(base, taken: names)
            while suffixes.contains(where: { volumes.contains("\(name)-\($0)") }) {
                names.insert(name)
                name = ResourceSuggestions.uniqueName(base, taken: names)
            }
            let published = source.map {
                SuggestionPorts.publishSpecs(for: $0, avoiding: ports, isPortFree: isPortFree).specs
            } ?? []
            let built = member(
                named: name, image: pick.image, ports: published, env: source?.env ?? [],
                secretEnv: (source?.secretEnv ?? []).map {
                    SecretEnv(name: $0, secret: secretName(member: name, variable: $0))
                },
                volumes: (source?.volumes ?? []).map {
                    StackVolume(suffix: $0.suffix, path: $0.path, volumeOwner: $0.volumeOwner)
                },
                command: source?.command ?? [], readyPort: pick.readyPort)
            names.insert(name)
            volumes.formUnion(built.volumeNames)
            ports.formUnion(published.compactMap(StackPlanner.hostPort(fromPublishSpec:)))
            made.append(built.member)
        }
        return made
    }
}
