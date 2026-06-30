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

        public struct ImageRef: Codable, Sendable {
            public var reference: String
            public var descriptor: Descriptor?
        }
        public struct Resources: Codable, Sendable {
            public var cpus: Int?
            public var memoryInBytes: Int64?
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

extension JSONDecoder {
    /// Shared decoder for `container` JSON. Keys already match (camelCase), so no
    /// key strategy is needed.
    public static var flotilla: JSONDecoder { JSONDecoder() }
}
