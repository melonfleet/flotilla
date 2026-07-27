import Foundation

/// Schema versioning for the settings store, per research pattern #12 (Rancher's
/// `"version": 18`). One integer on day one; a migration hook later beats a
/// corrupt-prefs bug report.
public enum SettingsSchema {
    public static let version = 1
    /// The preference / managed-preference domain (`DECISIONS.md`, settled).
    public static let domain = "dev.melonfleet.Flotilla"
}

/// Every Flotilla setting, declared once.
///
/// Adding a setting means adding a `SettingsKey` here **and** listing its descriptor
/// in `SettingsRegistry.all`; `registryIsComplete` in the tests fails if you forget,
/// so the UI, the export format and the Jamf key list can never drift from the code.
public enum SettingsKeys {

    // MARK: General

    public static let appearance = SettingsKey<AppearancePreference>(
        "appearance", default: .notChosen,
        summary: "Colour scheme. Chosen during first run; `notChosen` means onboarding hasn't asked yet."
    )

    public static let launchAtLogin = SettingsKey<Bool>(
        "launchAtLogin", default: false,
        summary: "Register Flotilla as a login item (SMAppService)."
    )

    public static let presentation = SettingsKey<AppPresentation>(
        "presentation", default: .menuBar,
        requiresRestart: true,
        summary: "Show Flotilla in the menu bar, the Dock, or both."
    )

    public static let confirmDestructiveActions = SettingsKey<Bool>(
        "confirmDestructiveActions", default: true,
        summary: "Confirm before deleting a container, image, volume or network."
    )

    public static let confirmBulkActions = SettingsKey<Bool>(
        "confirmBulkActions", default: true,
        summary: "Confirm before an action that hits more than one container or host."
    )

    // MARK: Polling
    //
    // Per-host scope: a mini on Wi-Fi should not be polled like the local machine,
    // and a menu-bar app that spawns a Process every second is visible in Activity
    // Monitor and on battery.

    public static let pollIntervalSeconds = SettingsKey<Int>(
        "pollIntervalSeconds", default: 5, scope: .perHost,
        summary: "Seconds between `container ls` refreshes. 0 disables polling."
    )

    public static let statsPollIntervalSeconds = SettingsKey<Int>(
        "statsPollIntervalSeconds", default: 10, scope: .perHost,
        summary: "Seconds between `container stats` samples. 0 disables stats polling."
    )

    // MARK: `container` CLI integration

    public static let containerBinaryPath = SettingsKey<String>(
        "containerBinaryPath", default: "/usr/local/bin/container",
        summary: "Path to the `container` binary. Preflight records what it detected here."
    )

    public static let autoStartContainerService = SettingsKey<ServiceAutostartPolicy>(
        "autoStartContainerService", default: .ask,
        summary: "Whether to run `container system start` when the API service is down."
    )

    // MARK: Defaults for new containers
    //
    // These mirror `[container] cpus/memory` in config.toml and are applied as
    // `-c`/`-m` flags on `container run`. There is deliberately no CPU/RAM slider
    // pane: `container` runs one micro-VM per container, so there is no shared host
    // VM to size.

    public static let defaultContainerCPUs = SettingsKey<Int>(
        "defaultContainerCPUs", default: 4,
        summary: "Default `--cpus` for new containers."
    )

    public static let defaultContainerMemoryMB = SettingsKey<Int>(
        "defaultContainerMemoryMB", default: 1024,
        summary: "Default `--memory` (MB) for new containers."
    )

    public static let defaultRegistryDomain = SettingsKey<String>(
        "defaultRegistryDomain", default: "docker.io",
        summary: "Registry used for unqualified image references (mirrors `[registry] domain`)."
    )

    // MARK: Logs

    public static let logTailLines = SettingsKey<Int>(
        "logTailLines", default: 200,
        summary: "Lines requested by default when opening logs (`container logs -n`)."
    )

    public static let logBufferLineCap = SettingsKey<Int>(
        "logBufferLineCap", default: 5_000,
        summary: "Maximum log lines held in memory per container before the oldest are dropped."
    )

    public static let logShowTimestamps = SettingsKey<Bool>(
        "logShowTimestamps", default: true,
        summary: "Show timestamps in the log viewer."
    )

    // MARK: Host mode
    //
    // Present in Phase 1 even though the transport lands in Phase 2, because
    // `reference/jamf-config-profile.md` requires these keys to be managed-readable
    // from the start.

    public static let mode = SettingsKey<RunMode>(
        "mode", default: .client, scope: .host, requiresRestart: true,
        summary: "Run as a client, as a host peer, or both."
    )

    public static let hostListenPort = SettingsKey<Int>(
        "hostListenPort", default: 7443, scope: .host, requiresRestart: true,
        summary: "TCP port host mode listens on for mTLS peers."
    )

    public static let bonjourEnabled = SettingsKey<Bool>(
        "bonjourEnabled", default: true, scope: .host, requiresRestart: true,
        summary: "Advertise this host over Bonjour. Manual host-add works regardless."
    )

    public static let identityKeychainLabel = SettingsKey<String>(
        "identityKeychainLabel", default: "Flotilla Identity", scope: .host,
        summary: "Keychain label of the TLS identity. The key material itself never leaves the Keychain."
    )

    /// SHA-256 fingerprints of peers this machine will talk to. Marked sensitive:
    /// it is an identifier list, so it is excluded from exports and diagnostics.
    /// (The private key is never here at all — it lives in the Keychain.)
    public static let peerAllowlist = SettingsKey<[String]>(
        "peerAllowlist", default: [], scope: .host, isSensitive: true,
        summary: "SHA-256 fingerprints of peers allowed to connect. Never exported."
    )

    public static let trustAnchorFingerprints = SettingsKey<[String]>(
        "trustAnchorFingerprints", default: [], scope: .host, isSensitive: true,
        summary: "SHA-256 fingerprints of trusted CA anchors. Never exported."
    )

    // MARK: Updates
    //
    // Sparkle's own key names on purpose: they then live in our preference domain
    // and become lockable by the Phase 6 profile for free (Docker's `disableUpdate`
    // equivalent), instead of us wrapping them in custom keys Sparkle ignores.

    public static let automaticUpdateChecks = SettingsKey<Bool>(
        "SUEnableAutomaticChecks", default: true,
        summary: "Let Sparkle check for Flotilla updates automatically."
    )

    public static let automaticallyDownloadUpdates = SettingsKey<Bool>(
        "SUAutomaticallyUpdate", default: false,
        summary: "Download updates in the background without asking."
    )

    public static let updateCheckIntervalSeconds = SettingsKey<Int>(
        "SUScheduledCheckInterval", default: 86_400,
        summary: "Seconds between Sparkle update checks."
    )

    public static let updateChannel = SettingsKey<UpdateChannel>(
        "updateChannel", default: .stable,
        summary: "Which appcast to follow."
    )

    // MARK: Diagnostics
    //
    // There is no telemetry setting because there is no telemetry: no analytics, no
    // crash upload, no phone-home. Diagnostics are collected locally, only when the
    // user opts in, and only leave the machine if the user hands someone the bundle.

    public static let diagnosticsEnabled = SettingsKey<Bool>(
        "diagnosticsEnabled", default: false,
        summary: "Keep a local rolling error log so a support bundle has something in it."
    )

    public static let diagnosticsErrorLogCap = SettingsKey<Int>(
        "diagnosticsErrorLogCap", default: 500,
        summary: "Maximum error-log entries retained for the support bundle."
    )

    // MARK: Notifications (per category)

    /// One key per category, derived from the enum rather than hand-written, so a
    /// new category cannot be added without a setting to control it.
    /// Mandatory categories still get a key so the UI can render it as a disabled
    /// "always on" row; `SettingsStore.isEnabled(_:)` ignores the stored value.
    public static func notification(_ category: NotificationCategory) -> SettingsKey<Bool> {
        SettingsKey<Bool>(
            "notifications.\(category.rawValue)",
            default: category.defaultEnabled,
            summary: category.summary
        )
    }
}

/// The type-erased view of the registry: what the Settings UI iterates, what export
/// validates against, and what the Jamf key list is generated from.
public enum SettingsRegistry {
    public static let all: [SettingDescriptor] = [
        SettingsKeys.appearance.descriptor,
        SettingsKeys.launchAtLogin.descriptor,
        SettingsKeys.presentation.descriptor,
        SettingsKeys.confirmDestructiveActions.descriptor,
        SettingsKeys.confirmBulkActions.descriptor,
        SettingsKeys.pollIntervalSeconds.descriptor,
        SettingsKeys.statsPollIntervalSeconds.descriptor,
        SettingsKeys.containerBinaryPath.descriptor,
        SettingsKeys.autoStartContainerService.descriptor,
        SettingsKeys.defaultContainerCPUs.descriptor,
        SettingsKeys.defaultContainerMemoryMB.descriptor,
        SettingsKeys.defaultRegistryDomain.descriptor,
        SettingsKeys.logTailLines.descriptor,
        SettingsKeys.logBufferLineCap.descriptor,
        SettingsKeys.logShowTimestamps.descriptor,
        SettingsKeys.mode.descriptor,
        SettingsKeys.hostListenPort.descriptor,
        SettingsKeys.bonjourEnabled.descriptor,
        SettingsKeys.identityKeychainLabel.descriptor,
        SettingsKeys.peerAllowlist.descriptor,
        SettingsKeys.trustAnchorFingerprints.descriptor,
        SettingsKeys.automaticUpdateChecks.descriptor,
        SettingsKeys.automaticallyDownloadUpdates.descriptor,
        SettingsKeys.updateCheckIntervalSeconds.descriptor,
        SettingsKeys.updateChannel.descriptor,
        SettingsKeys.diagnosticsEnabled.descriptor,
        SettingsKeys.diagnosticsErrorLogCap.descriptor,
    ] + NotificationCategory.allCases.map { SettingsKeys.notification($0).descriptor }

    private static let byName: [String: SettingDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func descriptor(named name: String) -> SettingDescriptor? { byName[name] }

    /// Descriptors an MDM profile may carry, for generating the Jamf payload docs.
    public static var manageable: [SettingDescriptor] { all.filter(\.isManageable) }

    public static func inScope(_ scope: SettingScope) -> [SettingDescriptor] {
        all.filter { $0.scope == scope }
    }
}
