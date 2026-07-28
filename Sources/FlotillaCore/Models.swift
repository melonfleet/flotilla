import Foundation

// Models match the real `container` 1.0.0 `--format json` schema, captured from a
// live install (see Tests/FlotillaCoreTests/Fixtures/*.json). Field names are exact;
// most are optional for resilience across CLI versions. Unknown keys are ignored.

// MARK: - Shared

public struct Descriptor: Codable, Sendable {
    public var digest: String?
    public var mediaType: String?
    public var size: Int64?
}

public struct Platform: Codable, Sendable {
    public var architecture: String?
    public var os: String?
    public var variant: String?
}

// MARK: - Container  (`container ls --all --format json`, `container inspect`)

public struct Container: Codable, Identifiable, Sendable {
    public var id: String
    public var configuration: Configuration
    public var status: Status

    public struct Configuration: Codable, Sendable {
        public var id: String
        public var creationDate: String?
        public var image: ImageRef
        public var platform: Platform?
        public var resources: Resources?
        /// Host→container port mappings from `--publish`. Absent on older output and
        /// `[]` for a container that publishes nothing, so both decode to empty.
        public var publishedPorts: [PublishedPort]?

        public struct ImageRef: Codable, Sendable {
            public var reference: String
            public var descriptor: Descriptor?
        }
        public struct Resources: Codable, Sendable {
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

    public struct Status: Codable, Sendable {
        public var state: String
        public var startedDate: String?
        public var networks: [NetworkStatus]?

        public struct NetworkStatus: Codable, Sendable {
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
public struct ContainerVolume: Codable, Identifiable, Sendable {
    public var name: String
    public var format: String?
    public var source: String?
    public var createdAt: String?
    public var sizeInBytes: Int64?
    public var labels: [String: String]?
    public var options: [String: String]?

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, id, format, source, createdAt, sizeInBytes, labels, options
    }

    public init(
        name: String, format: String? = nil, source: String? = nil, createdAt: String? = nil,
        sizeInBytes: Int64? = nil, labels: [String: String]? = nil, options: [String: String]? = nil
    ) {
        self.name = name
        self.format = format
        self.source = source
        self.createdAt = createdAt
        self.sizeInBytes = sizeInBytes
        self.labels = labels
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let identifier = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(
                codingPath: c.codingPath, debugDescription: "Volume has neither `name` nor `id`."
            ))
        }
        name = identifier
        format = try c.decodeIfPresent(String.self, forKey: .format)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        sizeInBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeInBytes)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        options = try c.decodeIfPresent([String: String].self, forKey: .options)
    }

    // Explicit because `CodingKeys` carries the `id` decoding alias, which has no
    // stored property to synthesise from. Re-encodes under `name` only.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(sizeInBytes, forKey: .sizeInBytes)
        try c.encodeIfPresent(labels, forKey: .labels)
        try c.encodeIfPresent(options, forKey: .options)
    }
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
public struct ContainerNetwork: Codable, Identifiable, Sendable {
    public var id: String
    public var state: String?
    public var mode: String?
    public var subnet: String?
    public var gateway: String?
    public var labels: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id, name, state, mode, subnet, gateway, labels
    }

    public init(
        id: String, state: String? = nil, mode: String? = nil,
        subnet: String? = nil, gateway: String? = nil, labels: [String: String]? = nil
    ) {
        self.id = id
        self.state = state
        self.mode = mode
        self.subnet = subnet
        self.gateway = gateway
        self.labels = labels
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let identifier = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .name) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: c.codingPath, debugDescription: "Network has neither `id` nor `name`."
            ))
        }
        id = identifier
        state = try c.decodeIfPresent(String.self, forKey: .state)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        subnet = try c.decodeIfPresent(String.self, forKey: .subnet)
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
    }

    // Explicit for the same reason as `ContainerVolume`: `name` is a decoding alias.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(subnet, forKey: .subnet)
        try c.encodeIfPresent(gateway, forKey: .gateway)
        try c.encodeIfPresent(labels, forKey: .labels)
    }

    /// `container` ships a network called `default`; deleting it isn't a thing the UI
    /// should offer.
    public var isDefault: Bool { id == "default" }
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
