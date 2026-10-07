import Foundation

/// Pushing one of This Mac's networks or volumes to other Macs (PLAN.md Phase D, layer 1;
/// DECISIONS Q35): This Mac's item is the definition, and for each host this says what a push
/// would do — and, afterwards, whether the host still matches.
///
/// **A host's differing item is reported, never replaced.** Replacing a volume deletes its data
/// and replacing a network detaches its containers; those are decisions for the owner on that
/// Mac's own row, not a side effect of a push. Volumes travel as empty definitions — no data moves.
public enum FleetPush {
    public enum Status: Sendable, Equatable {
        /// Not there: a push creates it.
        case create
        /// There and the same as the definition.
        case matches
        /// There under the same name but different — each reason in a few words.
        case differs([String])
        /// The host's list is not known: not answering, or not asked yet.
        case unavailable

        public var isCreate: Bool { self == .create }
        public var isDrift: Bool { if case .differs = self { return true }; return false }
    }

    /// The definition a network on This Mac makes. Its subnet is not part of it: each Mac's copy
    /// gets a subnet from that Mac's own block.
    public static func definition(of network: ContainerNetwork) -> NetworkSpec {
        NetworkSpec(name: network.id, hostOnly: network.mode == "hostOnly",
                    labels: ConfigurationExport.labels(network.labels))
    }

    public static func definition(of volume: ContainerVolume) -> VolumeSpec {
        VolumeSpec(name: volume.name, size: volume.sizeInBytes.map(ConfigurationExport.sizeString),
                   labels: ConfigurationExport.labels(volume.labels))
    }

    public static func status(of definition: NetworkSpec, on existing: [ContainerNetwork]?) -> Status {
        guard let existing else { return .unavailable }
        guard let there = existing.first(where: { $0.id == definition.name }) else { return .create }
        var reasons: [String] = []
        let hostOnly = there.mode == "hostOnly"
        if hostOnly != definition.hostOnly {
            reasons.append(hostOnly ? "host-only there, not here" : "host-only here, not there")
        }
        if ConfigurationExport.labels(there.labels) != definition.labels.sorted() { reasons.append("labels differ") }
        return reasons.isEmpty ? .matches : .differs(reasons)
    }

    public static func status(of definition: VolumeSpec, on existing: [ContainerVolume]?) -> Status {
        guard let existing else { return .unavailable }
        guard let there = existing.first(where: { $0.name == definition.name }) else { return .create }
        var reasons: [String] = []
        let thereSize = there.sizeInBytes.map(ConfigurationExport.sizeString)
        if thereSize != definition.size {
            reasons.append("capacity \(definition.size ?? "unknown") here, \(thereSize ?? "unknown") there")
        }
        if ConfigurationExport.labels(there.labels) != definition.labels.sorted() { reasons.append("labels differ") }
        return reasons.isEmpty ? .matches : .differs(reasons)
    }

    /// For the On hosts column: how many of the hosts asked hold it, and how many of those differ.
    public struct Spread: Sendable, Equatable {
        public var present = 0
        public var differing = 0
        public var asked = 0
        public init() {}

        public mutating func add(_ status: Status) {
            switch status {
            case .unavailable: return
            case .create: asked += 1
            case .matches: asked += 1; present += 1
            case .differs: asked += 1; present += 1; differing += 1
            }
        }
    }
}
