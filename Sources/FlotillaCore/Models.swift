import Foundation

// Models match the real `container` 1.0.0 `--format json` schema, captured from a
// live install (see Tests/FlotillaCoreTests/Fixtures/*.json). Field names are exact;
// most are optional for resilience across CLI versions. Unknown keys are ignored.

// MARK: - Shared

public struct Descriptor: Codable, Sendable, Equatable {
    public var digest: String?
    public var mediaType: String?
    public var size: Int64?
}

public struct Platform: Codable, Sendable, Equatable {
    public var architecture: String?
    public var os: String?
    public var variant: String?
}

// MARK: - Container  (`container ls --all --format json`, `container inspect`)

public struct Container: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var configuration: Configuration
    public var status: Status

    public struct Configuration: Codable, Sendable, Equatable {
        public var id: String
        public var creationDate: String?
        public var image: ImageRef
        public var platform: Platform?
        public var resources: Resources?
        /// Host→container port mappings from `--publish`. Absent on older output and
        /// `[]` for a container that publishes nothing, so both decode to empty.
        public var publishedPorts: [PublishedPort]?

        public struct ImageRef: Codable, Sendable, Equatable {
            public var reference: String
            public var descriptor: Descriptor?
        }
        public struct Resources: Codable, Sendable, Equatable {
            public var cpus: Int?
            public var memoryInBytes: Int64?
        }

        /// One `--publish` mapping. Captured from real `container ls --format json`
        /// output — note the key is `proto`, not `protocol`, and `hostAddress` is
        /// `0.0.0.0` rather than absent when unbound.
        public struct PublishedPort: Codable, Sendable, Hashable {
            public var containerPort: Int
            public var hostPort: Int
            public var hostAddress: String?
            public var proto: String?
            /// `container` publishes a contiguous range as one entry with a count,
            /// rather than repeating the mapping — so a `count` above 1 means
            /// `hostPort ..< hostPort + count`, and rendering only `hostPort` would
            /// under-report what is exposed.
            public var count: Int?

            public init(
                containerPort: Int, hostPort: Int, hostAddress: String? = nil,
                proto: String? = nil, count: Int? = nil
            ) {
                self.containerPort = containerPort
                self.hostPort = hostPort
                self.hostAddress = hostAddress
                self.proto = proto
                self.count = count
            }

            /// `18080:80/tcp`, or `18080-18082:80-82/tcp` for a published range.
            public var displayText: String {
                let span = max(count ?? 1, 1)
                let hosts = span > 1 ? "\(hostPort)-\(hostPort + span - 1)" : "\(hostPort)"
                let guests = span > 1 ? "\(containerPort)-\(containerPort + span - 1)" : "\(containerPort)"
                let suffix = proto.map { "/\($0)" } ?? ""
                return "\(hosts):\(guests)\(suffix)"
            }
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var state: String
        public var startedDate: String?
        public var networks: [NetworkStatus]?

        public struct NetworkStatus: Codable, Sendable, Equatable {
            public var hostname: String?
            public var ipv4Address: String?
            public var network: String?
        }
    }

    // Convenience for the UI
    public var name: String { configuration.id }
    public var imageReference: String { configuration.image.reference }
    public var isRunning: Bool { status.state.caseInsensitiveCompare("running") == .orderedSame }
    public var ipv4: String? { status.networks?.first?.ipv4Address }

    public var publishedPorts: [Configuration.PublishedPort] { configuration.publishedPorts ?? [] }

    /// Sort key that puts **running first** (DECISIONS.md Q2), which is the table's default
    /// order. A `Bool` would sort false-before-true, i.e. stopped first — exactly backwards —
    /// so this is an explicit rank rather than the obvious-looking `!isRunning`.
    public var sortRank: Int { isRunning ? 0 : 1 }

    /// Sortable form of `creationDate`, which the CLI gives as an ISO-8601 *string*.
    /// ISO-8601 with a fixed offset happens to sort correctly lexicographically, and an
    /// absent date sorts last rather than first — a container whose date we could not read
    /// should not claim to be the oldest thing on the machine.
    public var creationSortKey: String { configuration.creationDate ?? "9999" }

    /// Comma-separated `18080:80/tcp` mappings, or nil when nothing is published — so a
    /// table column can show an unambiguous em dash rather than an empty cell that reads
    /// as missing data.
    public var portSummary: String? {
        let ports = publishedPorts
        guard !ports.isEmpty else { return nil }
        return ports.map(\.displayText).joined(separator: ", ")
    }
}

// MARK: - Image  (`container image list --format json`, `container image inspect`)

public struct ContainerImage: Codable, Identifiable, Sendable {
    public var id: String
    public var configuration: Configuration
    public var variants: [Variant]?

    public struct Configuration: Codable, Sendable {
        public var name: String
        public var creationDate: String?
        public var descriptor: Descriptor?
    }
    public struct Variant: Codable, Sendable {
        public var digest: String?
        public var size: Int64?
        public var platform: Platform?
    }

    public var reference: String { configuration.name }

    /// `docker.io/library/alpine:latest` → `alpine:latest`.
    ///
    /// For narrow table cells. Middle-truncating a full reference produced
    /// `docker.i…ne:latest` — the same string for every row, carrying no information about
    /// what was actually running. The last path component is what distinguishes one image
    /// from another; registry and namespace are near-identical across a fleet. Callers
    /// should keep the full reference available on hover.
    ///
    /// Lives here rather than in the view because the awkward cases are real: a digest
    /// reference would otherwise contribute 64 hex characters, and `host:5000/name` must
    /// not have its registry port mistaken for a tag. That is worth a test, and the
    /// SwiftUI target has none.
    public static func shortReference(_ reference: String) -> String {
        // Split the digest off first, or the last path component swallows all of it.
        let path: String
        let digest: String?
        if let at = reference.firstIndex(of: "@") {
            path = String(reference[reference.startIndex..<at])
            digest = String(reference[reference.index(after: at)...])
        } else {
            path = reference
            digest = nil
        }

        // Splitting on "/" is what keeps a registry port out of the way: in
        // `registry.example:5000/team/tool:2.1` the port is in an earlier component, so the
        // last component's colon is unambiguously the tag.
        let short = path.split(separator: "/").last.map(String.init) ?? path

        guard let digest else { return short }
        // Enough of the digest to recognise, short enough to read — and never dropped
        // entirely, because hiding it would hide that the image is pinned at all.
        let abbreviated = digest.count > 19 ? String(digest.prefix(19)) + "…" : digest
        return "\(short)@\(abbreviated)"
    }

    /// Size of the variant matching the host arch (arm64), else the largest variant.
    public var displaySize: Int64? {
        let arm = variants?.first { $0.platform?.architecture == "arm64" }?.size
        return arm ?? variants?.compactMap(\.size).max()
    }
}

// MARK: - Stats  (`container stats --no-stream --format json`)

public struct ContainerStats: Codable, Identifiable, Sendable {
    public var id: String
    public var cpuUsageUsec: Int64?
    public var memoryUsageBytes: Int64?
    public var memoryLimitBytes: Int64?
    public var networkRxBytes: Int64?
    public var networkTxBytes: Int64?
    public var blockReadBytes: Int64?
    public var blockWriteBytes: Int64?
    public var numProcesses: Int?

    /// NOTE: `cpuUsageUsec` is cumulative — compute a % from the delta between two
    /// samples over wall-clock time. A single-sample CPU % is not meaningful.
    public var memoryPercent: Double? {
        guard let used = memoryUsageBytes, let limit = memoryLimitBytes, limit > 0 else { return nil }
        return Double(used) / Double(limit) * 100
    }
}

// MARK: - System

// MARK: - Disk usage  (`container system df --format json`)

/// Captured from a live `container 1.0.0` install on 2026-07-28. The payload is an object
/// keyed by resource — not the array the list commands return — with the same four counters
/// under each key.
public struct SystemDiskUsage: Codable, Sendable {
    public var containers: Category
    public var images: Category
    public var volumes: Category

    public struct Category: Codable, Sendable, Hashable, Identifiable {
        public var total: Int
        public var active: Int
        public var sizeInBytes: Int64
        public var reclaimable: Int64

        /// Set by `SystemDiskUsage.categories` so a table can identify rows; not part of
        /// the decoded payload, which is keyed rather than labelled.
        public var id: String = ""

        private enum CodingKeys: String, CodingKey {
            case total, active, sizeInBytes, reclaimable
        }

        public init(total: Int, active: Int, sizeInBytes: Int64, reclaimable: Int64, id: String = "") {
            self.total = total
            self.active = active
            self.sizeInBytes = sizeInBytes
            self.reclaimable = reclaimable
            self.id = id
        }

        /// Share of this category's bytes that could be freed. Nil rather than zero when
        /// nothing is stored — "0% reclaimable" and "nothing here" are different answers,
        /// and the CLI's own table prints `0 B (0%)` for both.
        public var reclaimableFraction: Double? {
            guard sizeInBytes > 0 else { return nil }
            return Double(reclaimable) / Double(sizeInBytes)
        }
    }

    /// Row order matching the CLI's own `system df` table, so the app and the terminal
    /// don't disagree about what comes first.
    public var categories: [Category] {
        [labelled(images, "Images"),
         labelled(containers, "Containers"),
         labelled(volumes, "Local Volumes")]
    }

    private func labelled(_ category: Category, _ id: String) -> Category {
        var copy = category
        copy.id = id
        return copy
    }

    public var totalReclaimableBytes: Int64 {
        containers.reclaimable + images.reclaimable + volumes.reclaimable
    }
}

public struct SystemStatus: Codable, Sendable {
    public var status: String
    public var apiServerVersion: String?
    public var appRoot: String?
    public var installRoot: String?

    public var isRunning: Bool { status == "running" }
}

public struct VersionComponent: Codable, Identifiable, Sendable {
    public var appName: String
    public var version: String
    public var buildType: String?
    public var commit: String?

    public var id: String { appName }
}

// MARK: - Volume  (`container volume list --format json`)

// ⚠️ SCHEMA NOT YET CAPTURED. Unlike everything above, no live `container volume list`
// output has been captured into Fixtures/, so the field names here are inferred from
// `reference/container-cli.md` (`volume create -s/--opt size=/--opt journal=/--label`)
// and from the shape the CLI uses elsewhere. Everything but the identifier is optional
// and the identifier accepts either `name` or `id`, so an unexpected schema degrades to
// a sparse row rather than a decode failure. Capture a real fixture and tighten this the
// first time it runs against a live install.
/// A volume, as `container volume list --format json` actually returns it.
///
/// **This model was wrong until 2026-07-30, and its fixture was fabricated.** The old shape
/// was flat (`name`, `format`, `source`, … at the top level) and `volumes.json` had been
/// written to match the model rather than captured from the CLI, so the tests passed while
/// the real payload — `{ "configuration": { … }, "id": … }` — could not decode at all.
/// `name` was non-optional, so the moment a volume existed, decoding *threw* and the Volumes
/// screen showed a runtime error instead of a list. A fixture nobody captured is worse than
/// no fixture: it makes a broken decode look verified.
public struct ContainerVolume: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var configuration: Configuration

    public struct Configuration: Codable, Sendable, Equatable {
        public var name: String
        public var driver: String?
        public var format: String?
        public var source: String?
        public var creationDate: String?
        public var sizeInBytes: Int64?
        public var labels: [String: String]?
        public var options: [String: String]?

        public init(
            name: String, driver: String? = nil, format: String? = nil, source: String? = nil,
            creationDate: String? = nil, sizeInBytes: Int64? = nil,
            labels: [String: String]? = nil, options: [String: String]? = nil
        ) {
            self.name = name
            self.driver = driver
            self.format = format
            self.source = source
            self.creationDate = creationDate
            self.sizeInBytes = sizeInBytes
            self.labels = labels
            self.options = options
        }
    }

    public init(id: String, configuration: Configuration) {
        self.id = id
        self.configuration = configuration
    }

    // Convenience so call sites read the same as before the shape was corrected.
    public var name: String { configuration.name }
    public var format: String? { configuration.format }
    public var source: String? { configuration.source }
    public var driver: String? { configuration.driver }
    public var createdAt: String? { configuration.creationDate }
    public var sizeInBytes: Int64? { configuration.sizeInBytes }
    public var labels: [String: String]? { configuration.labels }
}

// MARK: - Network  (`container network list --format json`)

// ⚠️ SCHEMA NOT YET CAPTURED — same caveat as ContainerVolume. What *is* pinned by a real
// fixture is the network reference seen from the container side
// (`Container.Status.NetworkStatus`, e.g. `network: "default"`), which is why `id` is the
// identifier here: it's the value that joins the two.
//
// Named `ContainerNetwork`, not `Network`, on purpose — matching `ContainerImage`, and
// because a `FlotillaCore.Network` would collide with `import Network` in the Phase 2
// transport code.
/// A network, as `container network list --format json` actually returns it.
///
/// Same story as `ContainerVolume`: the old model was flat and `networks.json` was written to
/// match it rather than captured, so only `id` ever decoded from real output and every row
/// rendered as a bare name with no mode, subnet or gateway. That is exactly what it looked
/// like in use — "I don't see any information".
///
/// Note the subnet and gateway live under **`status`**, not configuration: they are assigned
/// by the network plugin at creation, so they are observed state rather than declared intent.
public struct ContainerNetwork: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var configuration: Configuration
    public var status: Status?

    public struct Configuration: Codable, Sendable, Equatable {
        public var name: String
        public var mode: String?
        public var plugin: String?
        public var creationDate: String?
        public var labels: [String: String]?
        public var options: [String: String]?

        public init(
            name: String, mode: String? = nil, plugin: String? = nil, creationDate: String? = nil,
            labels: [String: String]? = nil, options: [String: String]? = nil
        ) {
            self.name = name
            self.mode = mode
            self.plugin = plugin
            self.creationDate = creationDate
            self.labels = labels
            self.options = options
        }
    }

    public struct Status: Codable, Sendable, Equatable {
        public var ipv4Subnet: String?
        public var ipv4Gateway: String?
        public var ipv6Subnet: String?

        public init(ipv4Subnet: String? = nil, ipv4Gateway: String? = nil, ipv6Subnet: String? = nil) {
            self.ipv4Subnet = ipv4Subnet
            self.ipv4Gateway = ipv4Gateway
            self.ipv6Subnet = ipv6Subnet
        }
    }

    public init(id: String, configuration: Configuration, status: Status? = nil) {
        self.id = id
        self.configuration = configuration
        self.status = status
    }

    public var name: String { configuration.name }
    public var mode: String? { configuration.mode }
    public var plugin: String? { configuration.plugin }
    public var subnet: String? { status?.ipv4Subnet }
    public var gateway: String? { status?.ipv4Gateway }
    public var ipv6Subnet: String? { status?.ipv6Subnet }
    public var labels: [String: String]? { configuration.labels }

    /// A builtin network is one Apple created, not the user — `default` carries
    /// `com.apple.container.resource.role: builtin`. Deleting it is not something to offer
    /// as casually as deleting your own.
    public var isBuiltin: Bool {
        configuration.labels?["com.apple.container.resource.role"] == "builtin"
    }
}

// MARK: - Machine  (`container machine list --format json`, `container machine inspect`)

/// A `container machine` — one of the CLI's own persistent Linux micro-VMs (see
/// `research/MACHINES-SPEC.md`). Not general-purpose VM management; scope is exactly
/// the `container machine` subcommand family.
///
/// **Deliberately FLAT, unlike `Container`.** Modelling this by analogy to `Container`'s
/// `configuration`/`status` nesting is the exact mistake that made `ContainerVolume` throw
/// on every real volume (see that type's history, above). Captured against real
/// `container 1.0.0` output (`Fixtures/machines.json`, `Fixtures/machine-inspect.json`),
/// and the top-level keys really are flat: `id`, `status`, `cpus`, `memory`, `diskSize`,
/// `ipAddress`, `createdDate`, `default`. Also note `status`, not `state` — a different key
/// than `Container.Status.state` for what is conceptually the same thing.
///
/// **One type, not two.** `machine inspect` returns everything `machine list` does, plus
/// five more fields (`containerId`, `homeMount`, `image`, `platform`, `startedDate`,
/// `userSetup`). Modelled here as one `Codable` struct with those five optional, rather
/// than a second `MachineInspect` type — the same choice `Container` already makes for its
/// own list/inspect pair (`ContainerCLI.inspect` decodes the identical `[Container]` shape
/// `ls` does). A second type would duplicate every list-shared field and force call sites
/// to know in advance which shape they are holding; an optional simply reads as "not filled
/// in yet" until an `inspectMachine` call populates it.
public struct ContainerMachine: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var cpus: Int
    /// Bytes. `machine list --format table` renders this in human units; the JSON does not.
    public var memory: Int64
    /// Bytes, same unit note as `memory`.
    public var diskSize: Int64
    public var ipAddress: String?
    public var createdDate: String?
    /// Whether `machine set-default` currently points at this machine. Present on
    /// `machine list` output; **absent** from `machine inspect` (confirmed against
    /// `Fixtures/machine-inspect.json`, which has no `default` key at all) — nil here
    /// means "this endpoint doesn't say," not "not the default." `default` is also a
    /// Swift keyword, hence the rename via `CodingKeys`.
    public var isDefault: Bool?

    // Inspect-only — nil when decoded from `machine list`.
    public var containerId: String?
    /// `ro` or `rw` in the one captured fixture; whether `none`/unset also occurs is not
    /// yet verified (`research/MACHINES-SPEC.md` §6.4).
    public var homeMount: String?
    public var image: MachineImage?
    public var platform: Platform?
    public var startedDate: String?
    public var userSetup: UserSetup?

    public struct MachineImage: Codable, Sendable, Equatable {
        public var reference: String
        public var descriptor: Descriptor?
    }

    /// The host user whose account booted this machine.
    ///
    /// `username` is the HOST USER'S NAME — identity, not machine metadata. The committed
    /// fixture is anonymised to `example` on purpose. **Never log this field, and never let
    /// it reach a diagnostics snapshot or support bundle unredacted.**
    public struct UserSetup: Codable, Sendable, Equatable {
        public var uid: Int
        public var gid: Int
        public var username: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, cpus, memory, diskSize, ipAddress, createdDate
        case isDefault = "default"
        case containerId, homeMount, image, platform, startedDate, userSetup
    }

    public init(
        id: String, status: String, cpus: Int, memory: Int64, diskSize: Int64,
        ipAddress: String? = nil, createdDate: String? = nil, isDefault: Bool? = nil,
        containerId: String? = nil, homeMount: String? = nil, image: MachineImage? = nil,
        platform: Platform? = nil, startedDate: String? = nil, userSetup: UserSetup? = nil
    ) {
        self.id = id
        self.status = status
        self.cpus = cpus
        self.memory = memory
        self.diskSize = diskSize
        self.ipAddress = ipAddress
        self.createdDate = createdDate
        self.isDefault = isDefault
        self.containerId = containerId
        self.homeMount = homeMount
        self.image = image
        self.platform = platform
        self.startedDate = startedDate
        self.userSetup = userSetup
    }

    public var isRunning: Bool { status.caseInsensitiveCompare("running") == .orderedSame }
}

// MARK: - Logs

// `container logs` emits plain text, not JSON, so these are Flotilla's own types
// rather than a decode of CLI output: the CLI gives us bytes, we split and tag them.
// They are Codable because Phase 2 ships them over the Wire from a host peer.

public struct LogLine: Codable, Identifiable, Sendable, Equatable {
    public enum Stream: String, Codable, Sendable {
        case stdout, stderr
    }

    /// Sequence number within the chunk. Log lines are not unique by content, so
    /// identity has to come from position — a `List` keyed on text would glitch on
    /// repeated output.
    public var index: Int
    public var stream: Stream
    public var text: String
    /// When Flotilla received the line. `container logs` has no `--timestamps` flag,
    /// so this is never the container's own clock.
    public var receivedAt: Date?

    public var id: Int { index }

    public init(index: Int, stream: Stream = .stdout, text: String, receivedAt: Date? = nil) {
        self.index = index
        self.stream = stream
        self.text = text
        self.receivedAt = receivedAt
    }
}

/// One bounded fetch of a container's logs. Phase 1 is a bounded fetch only;
/// `--follow` streaming is Phase 4, which is why there's no cursor here yet.
public struct LogChunk: Codable, Sendable, Equatable {
    public var containerID: String
    public var lines: [LogLine]
    /// The `-n` value that was asked for.
    public var requestedLines: Int
    /// True when the requested limit was hit, i.e. older lines exist.
    public var truncated: Bool
    /// `container logs --boot` returns the VM boot log instead of the process output.
    public var isBootLog: Bool

    public init(
        containerID: String, lines: [LogLine], requestedLines: Int,
        truncated: Bool = false, isBootLog: Bool = false
    ) {
        self.containerID = containerID
        self.lines = lines
        self.requestedLines = requestedLines
        self.truncated = truncated
        self.isBootLog = isBootLog
    }

    /// Split raw CLI output into tagged lines. A trailing newline is not an empty
    /// last line.
    public static func from(
        stdout: String, stderr: String = "", containerID: String,
        requestedLines: Int, isBootLog: Bool = false, receivedAt: Date? = nil
    ) -> LogChunk {
        var lines: [LogLine] = []
        func append(_ text: String, _ stream: LogLine.Stream) {
            guard !text.isEmpty else { return }
            var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
            // A trailing newline terminates the last line; it is not an empty one.
            if text.hasSuffix("\n") { pieces.removeLast() }
            for piece in pieces {
                lines.append(LogLine(index: lines.count, stream: stream, text: String(piece), receivedAt: receivedAt))
            }
        }
        append(stdout, .stdout)
        append(stderr, .stderr)
        return LogChunk(
            containerID: containerID, lines: lines, requestedLines: requestedLines,
            truncated: requestedLines > 0 && lines.count >= requestedLines, isBootLog: isBootLog
        )
    }
}

// MARK: - Notifications

/// Notification categories, each with its own toggle (`DECISIONS.md` Q6: notifications
/// ship in Phase 1 with full per-category toggles).
///
/// Docker's one good rule here is that genuine errors are not disableable; unlike
/// Docker we ship no announcement, survey or recommendation categories, because we
/// have nothing to announce.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case containerExited
    case imagePullFinished
    case buildFinished
    case hostOffline
    case error

    public var id: String { rawValue }

    /// Errors are always delivered; the UI shows this row as an "always on" disabled
    /// toggle rather than hiding it.
    public var isMandatory: Bool { self == .error }

    public var defaultEnabled: Bool {
        switch self {
        case .error, .hostOffline: true
        case .containerExited, .imagePullFinished, .buildFinished: false
        }
    }

    public var title: String {
        switch self {
        case .containerExited: "Container exited unexpectedly"
        case .imagePullFinished: "Image pull finished"
        case .buildFinished: "Build finished"
        case .hostOffline: "Host went offline"
        case .error: "Errors"
        }
    }

    public var summary: String {
        switch self {
        case .containerExited: "Notify when a container stops without being asked to."
        case .imagePullFinished: "Notify when `container image pull` completes."
        case .buildFinished: "Notify when a build completes."
        case .hostOffline: "Notify when a fleet host stops responding."
        case .error: "Notify on operation failures. Always on."
        }
    }
}

/// Effective per-category state, resolved from `SettingsStore`. A value type so the
/// notifications pane and a Wire message can carry the same thing.
///
/// Encodes as a flat `{"hostOffline": true, …}` object: Foundation would otherwise
/// encode an enum-keyed dictionary as an array of alternating keys and values, which
/// round-trips but is unreadable in a support bundle.
public struct NotificationSettings: Codable, Sendable, Equatable {
    public var enabled: [NotificationCategory: Bool]

    public init(enabled: [NotificationCategory: Bool] = [:]) {
        self.enabled = enabled
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Bool].self)
        enabled = Dictionary(uniqueKeysWithValues: raw.compactMap { name, on in
            NotificationCategory(rawValue: name).map { ($0, on) }
        })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: enabled.map { ($0.key.rawValue, $0.value) }))
    }

    public static var defaults: NotificationSettings {
        NotificationSettings(enabled: Dictionary(uniqueKeysWithValues:
            NotificationCategory.allCases.map { ($0, $0.defaultEnabled) }
        ))
    }

    public func isEnabled(_ category: NotificationCategory) -> Bool {
        category.isMandatory || (enabled[category] ?? category.defaultEnabled)
    }
}

// MARK: - Preflight

/// Outcome of the `container` CLI preflight check (the CLI owner's `Preflight.swift` returns
/// this; it lives here so the diagnostics snapshot and the Wire layer can carry it
/// without depending on the preflight implementation).
///
/// Versions are carried as strings, not a parsed type, so the comparison logic stays
/// entirely in `Preflight.swift`.
public enum PreflightResult: Codable, Sendable, Equatable {
    /// Installed, new enough, and the API service answered.
    case ok(version: String, path: String)
    /// No `container` binary found. Triggers the guided install offer — which is
    /// always user-authorized, never silent or privileged.
    case missing
    case tooOld(found: String, required: String)
    /// Present but not usable: service down, wrong architecture, unreadable version.
    case unusable(reason: String)

    public var isOK: Bool { if case .ok = self { true } else { false } }

    /// Version string when one could be read, whether or not it was acceptable.
    public var detectedVersion: String? {
        switch self {
        case .ok(let version, _): version
        case .tooOld(let found, _): found
        case .missing, .unusable: nil
        }
    }

    /// One line for the menu bar, the diagnostics snapshot and the log.
    public var summary: String {
        switch self {
        case .ok(let version, _): "container \(version) ready"
        case .missing: "container is not installed"
        case .tooOld(let found, let required): "container \(found) is older than the required \(required)"
        case .unusable(let reason): "container is unusable: \(reason)"
        }
    }
}

extension JSONDecoder {
    /// Shared decoder for `container` JSON. Keys already match (camelCase), so no
    /// key strategy is needed.
    public static var flotilla: JSONDecoder { JSONDecoder() }
}
