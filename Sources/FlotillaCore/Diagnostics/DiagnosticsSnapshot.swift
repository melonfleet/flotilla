import Foundation

/// Everything Flotilla knows about its own state, redacted and ready to be handed to
/// someone else.
///
/// The snapshot is assembled from values passed in, not read from the environment:
/// `FlotillaCore` has no business calling `ProcessInfo`/`Bundle` (and on Linux it
/// would report the test runner anyway). The app layer supplies `app`/`system`, which
/// also makes the whole thing deterministic to test.
public struct DiagnosticsSnapshot: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var app: AppInfo
    public var system: SystemInfo
    public var runtime: RuntimeInfo?
    public var preflight: PreflightResult?
    public var hosts: [HostSummary]
    /// Effective settings, sensitive keys dropped and string values redacted.
    public var settings: [String: SettingValue]
    /// Keys currently enforced by a configuration profile — the first thing to check
    /// when a user reports "the app won't let me change X".
    public var lockedSettings: [String]
    public var notifications: NotificationSettings
    public var recentErrors: [ErrorLogEntry]

    public struct AppInfo: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var build: String?
        public var bundleIdentifier: String
        public var mode: RunMode
        /// True when a configuration profile supplies any value at all.
        public var isManaged: Bool

        public init(
            name: String = "Flotilla", version: String, build: String? = nil,
            bundleIdentifier: String = SettingsSchema.domain,
            mode: RunMode, isManaged: Bool
        ) {
            self.name = name
            self.version = version
            self.build = build
            self.bundleIdentifier = bundleIdentifier
            self.mode = mode
            self.isManaged = isManaged
        }
    }

    public struct SystemInfo: Codable, Sendable, Equatable {
        public var osName: String
        public var osVersion: String
        public var architecture: String
        /// e.g. `Mac14,6`. A model identifier, not a serial number — deliberately
        /// not the machine UUID, which would identify the Mac.
        public var modelIdentifier: String?

        public init(osName: String, osVersion: String, architecture: String, modelIdentifier: String? = nil) {
            self.osName = osName
            self.osVersion = osVersion
            self.architecture = architecture
            self.modelIdentifier = modelIdentifier
        }
    }

    public struct RuntimeInfo: Codable, Sendable, Equatable {
        public var cliVersion: String?
        public var apiServerVersion: String?
        public var systemStatus: String?
        public var containerCount: Int?
        public var runningContainerCount: Int?
        public var imageCount: Int?
        public var volumeCount: Int?
        public var networkCount: Int?

        public init(
            cliVersion: String? = nil, apiServerVersion: String? = nil, systemStatus: String? = nil,
            containerCount: Int? = nil, runningContainerCount: Int? = nil, imageCount: Int? = nil,
            volumeCount: Int? = nil, networkCount: Int? = nil
        ) {
            self.cliVersion = cliVersion
            self.apiServerVersion = apiServerVersion
            self.systemStatus = systemStatus
            self.containerCount = containerCount
            self.runningContainerCount = runningContainerCount
            self.imageCount = imageCount
            self.volumeCount = volumeCount
            self.networkCount = networkCount
        }
    }

    /// A fleet host, reduced to what's diagnostically useful.
    ///
    /// Carries **no hostname, address, Bonjour name, nickname or certificate
    /// fingerprint** — those are the identifiers that make a bundle traceable to a
    /// network and a person, and none of them help debug "why did this host stop
    /// responding". `id` is Flotilla's own local record identifier.
    public struct HostSummary: Codable, Sendable, Equatable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case local, remote
        }

        public var id: String
        public var kind: Kind
        public var isReachable: Bool
        public var osVersion: String?
        public var containerVersion: String?
        public var runningContainers: Int?
        public var totalContainers: Int?
        public var lastSeen: Date?
        /// Whether this host was added by hand rather than found over Bonjour —
        /// relevant because manual hosts are the ones that cross subnets.
        public var wasAddedManually: Bool?

        public init(
            id: String, kind: Kind, isReachable: Bool, osVersion: String? = nil,
            containerVersion: String? = nil, runningContainers: Int? = nil,
            totalContainers: Int? = nil, lastSeen: Date? = nil, wasAddedManually: Bool? = nil
        ) {
            self.id = id
            self.kind = kind
            self.isReachable = isReachable
            self.osVersion = osVersion
            self.containerVersion = containerVersion
            self.runningContainers = runningContainers
            self.totalContainers = totalContainers
            self.lastSeen = lastSeen
            self.wasAddedManually = wasAddedManually
        }
    }

    public init(
        schemaVersion: Int = DiagnosticsSchema.version,
        generatedAt: Date,
        app: AppInfo,
        system: SystemInfo,
        runtime: RuntimeInfo? = nil,
        preflight: PreflightResult? = nil,
        hosts: [HostSummary] = [],
        settings: [String: SettingValue] = [:],
        lockedSettings: [String] = [],
        notifications: NotificationSettings = .defaults,
        recentErrors: [ErrorLogEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.app = app
        self.system = system
        self.runtime = runtime
        self.preflight = preflight
        self.hosts = hosts
        self.settings = settings
        self.lockedSettings = lockedSettings
        self.notifications = notifications
        self.recentErrors = recentErrors
    }
}

public enum DiagnosticsSchema {
    public static let version = 1
}

extension DiagnosticsSnapshot {
    /// Build a snapshot from live state, redacting on the way in.
    ///
    /// This is the only supported constructor for a bundle-bound snapshot: it drops
    /// sensitive settings, scrubs every error message and free-text field, and caps
    /// the error log. Constructing a `DiagnosticsSnapshot` by hand is fine for tests
    /// and for the in-app "About" panel, but `SupportBundleBuilder` audits whatever
    /// it is given regardless.
    public static func capture(
        at generatedAt: Date,
        app: AppInfo,
        system: SystemInfo,
        settings: SettingsStore,
        runtime: RuntimeInfo? = nil,
        preflight: PreflightResult? = nil,
        hosts: [HostSummary] = [],
        errorLog: ErrorLog? = nil,
        redactor: Redactor = .standard
    ) -> DiagnosticsSnapshot {
        let errorCap = settings[SettingsKeys.diagnosticsErrorLogCap]
        let errors = (errorLog?.recent(errorCap) ?? []).map { entry in
            var redacted = entry
            redacted.message = redactor.redact(entry.message)
            redacted.subsystem = redactor.redact(entry.subsystem)
            return redacted
        }

        var redactedRuntime = runtime
        redactedRuntime?.cliVersion = runtime?.cliVersion.map(redactor.redact)
        redactedRuntime?.apiServerVersion = runtime?.apiServerVersion.map(redactor.redact)

        return DiagnosticsSnapshot(
            generatedAt: generatedAt,
            app: app,
            system: system,
            runtime: redactedRuntime,
            preflight: preflight.map { $0.redacted(with: redactor) },
            hosts: hosts,
            settings: redactor.redactSettings(settings.effectiveValues()),
            lockedSettings: settings.lockedKeyNames(),
            notifications: settings.notificationSettings(),
            recentErrors: errors
        )
    }
}

extension PreflightResult {
    /// The `path` and `reason` payloads are the ones that carry filesystem paths,
    /// e.g. a `container` binary found under `~/bin`.
    func redacted(with redactor: Redactor) -> PreflightResult {
        switch self {
        case .ok(let version, let path): .ok(version: version, path: redactor.redact(path))
        case .missing: .missing
        case .tooOld(let found, let required): .tooOld(found: found, required: required)
        case .unusable(let reason): .unusable(reason: redactor.redact(reason))
        }
    }
}
