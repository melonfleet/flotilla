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

    /// **Default on, and a toggle rather than a three-way picker.**
    ///
    /// Hiding the Dock icon maps to `NSApplication.ActivationPolicy.accessory`, which also removes
    /// Flotilla from ⌘-Tab — so the menu-bar item becomes the only way back to a window. For an app
    /// whose *main window is the product* (`DECISIONS.md` Q2 — the popover is a glance), that is a
    /// deliberate choice to offer, not a default to hand someone.
    ///
    /// `requiresRestart` is false because it is not: `AppDelegate.applyPresentation` switches the
    /// activation policy live.
    ///
    /// It replaced `presentation`
    /// (`menuBar`/`dock`/`both`), which offered a choice macOS cannot make: the activation policy
    /// has two states, so `dock` and `both` both mapped to `.regular` and were indistinguishable
    /// in every observable way. Two of the three options did the same thing.
    ///
    /// The menu-bar item is always shown, which is why there is no setting for it: it is how you
    /// reach the app when the Dock icon is hidden, and a preference that can remove the only
    /// remaining way in is a preference for locking yourself out.
    public static let showDockIcon = SettingsKey<Bool>(
        "showDockIcon", default: true,
        summary: "Show Flotilla in the Dock. The menu bar item is always shown."
    )

    /// Applies to **single** deletes. Deleting more than one thing at a time always asks, and no
    /// setting turns that off — see `DeletePolicy`.
    ///
    /// The summary names all five kinds because it now governs all five. It previously listed four
    /// and was read by three: Containers and Machines ignored it and confirmed unconditionally, so
    /// switching it off silently did nothing on those screens.
    public static let confirmDestructiveActions = SettingsKey<Bool>(
        "confirmDestructiveActions", default: true,
        summary: "Confirm before deleting one container, image, volume, network or machine. "
            + "Deleting several at once always asks."
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

    /// Read by `AppModel.containerExecutable`, which is what the container terminal and the machine
    /// console launch. An **override**: when it names an executable file, that file is used; when it
    /// does not, `Preflight.locateBinary` decides. So a wrong value degrades to detection rather
    /// than breaking the app, and the Settings row says which one is in force.
    ///
    /// This is not the audit's SEC-01 hole in another costume. That was `/usr/bin/env`, a `PATH`
    /// lookup the *environment* controlled; this is an absolute path the **user** typed into their
    /// own copy of the app, and someone who can edit these preferences can already replace the
    /// binary the default path points at.
    public static let containerBinaryPath = SettingsKey<String>(
        "containerBinaryPath", default: "",
        summary: "Where the `container` binary is. Leave empty to detect it automatically."
    )

    /// **Default `.always`, changed from `.ask` on 2026-08-23.**
    ///
    /// `ServiceAutostartPolicy` documents `.ask` as the safe default, on the grounds that starting a
    /// launchd service unasked is the same class of thing as the silent privileged install
    /// `DECISIONS.md` rejects. That reasoning does not survive contact with what this actually does:
    /// `container system start` starts a **user-level** service the user installed themselves, it
    /// needs no authorisation, and the owner asked for exactly this after a macOS update left the
    /// service stopped and the app claiming the CLI was not installed.
    ///
    /// The setting was inert either way — the app auto-started unconditionally and never read this
    /// key — so `.ask` was documentation of an intention, not a description of behaviour. It is now
    /// read, and the default matches what already shipped rather than silently changing it.
    /// Auto-starts are attempted **once per launch** and recorded in the activity feed.
    public static let autoStartContainerService = SettingsKey<ServiceAutostartPolicy>(
        "autoStartContainerService", default: .always,
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

    /// **Not built.** Its only reader is the diagnostics snapshot, which reports the setting back
    /// to whoever set it — a mirror, not a consumer. Selecting `host` or `both` opens no listener,
    /// because Phase 2 has not been written and is explicitly out of scope.
    public static let mode = SettingsKey<RunMode>(
        "mode", default: .client, scope: .host, requiresRestart: true,
        availability: SettingAvailability.notBuilt(reason: "Host mode arrives in Phase 2. Nothing listens on a port and no peer can connect today."),
        summary: "Run as a client, as a host peer, or both."
    )

    public static let hostListenPort = SettingsKey<Int>(
        "hostListenPort", default: 7443, scope: .host, requiresRestart: true,
        availability: SettingAvailability.notBuilt(reason: "Host mode arrives in Phase 2. Nothing listens on a port and no peer can connect today."),
        summary: "TCP port host mode listens on for mTLS peers."
    )

    public static let bonjourEnabled = SettingsKey<Bool>(
        "bonjourEnabled", default: true, scope: .host, requiresRestart: true,
        availability: SettingAvailability.notBuilt(reason: "Host mode arrives in Phase 2. Nothing listens on a port and no peer can connect today."),
        summary: "Advertise this host over Bonjour. Manual host-add works regardless."
    )

    /// **Not built**, and worth being explicit about why the wording matters: there is no TLS
    /// identity in the Keychain, so this labels nothing. A summary describing how key material is
    /// protected, attached to a feature that does not exist, reads as a security guarantee.
    public static let identityKeychainLabel = SettingsKey<String>(
        "identityKeychainLabel", default: "Flotilla Identity", scope: .host,
        availability: SettingAvailability.notBuilt(reason: "Host mode arrives in Phase 2. Nothing listens on a port and no peer can connect today."),
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

    /// **Not built.** The four update keys use Sparkle's own `SU…` names, which was forward
    /// planning; Sparkle is not a dependency and `DECISIONS.md` keeps it out for now. Defaulting
    /// this to `true` while nothing checks is the most misleading combination available, so the row
    /// is disabled and says so.
    public static let automaticUpdateChecks = SettingsKey<Bool>(
        "SUEnableAutomaticChecks", default: true,
        availability: SettingAvailability.notBuilt(reason: "Flotilla has no updater yet, so nothing checks for updates."),
        summary: "Let Sparkle check for Flotilla updates automatically."
    )

    public static let automaticallyDownloadUpdates = SettingsKey<Bool>(
        "SUAutomaticallyUpdate", default: false,
        availability: SettingAvailability.notBuilt(reason: "Flotilla has no updater yet, so nothing checks for updates."),
        summary: "Download updates in the background without asking."
    )

    public static let updateCheckIntervalSeconds = SettingsKey<Int>(
        "SUScheduledCheckInterval", default: 86_400,
        availability: SettingAvailability.notBuilt(reason: "Flotilla has no updater yet, so nothing checks for updates."),
        summary: "Seconds between Sparkle update checks."
    )

    public static let updateChannel = SettingsKey<UpdateChannel>(
        "updateChannel", default: .stable,
        availability: SettingAvailability.notBuilt(reason: "Flotilla has no updater yet, so nothing checks for updates."),
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
        SettingsKeys.showDockIcon.descriptor,
        SettingsKeys.confirmDestructiveActions.descriptor,
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
    ///
    /// **Excludes settings nothing reads yet.** Handing an administrator a key they can push to a
    /// fleet, which the app then ignores, is the same dishonesty as the toggle that did nothing —
    /// and worse in one respect: the person deceived is not the person at the keyboard, so there is
    /// nobody positioned to notice. `hostListenPort` in a profile would have looked like it hardened
    /// a fleet's listener; there is no listener.
    ///
    /// A managed value for an unbuilt key is still *accepted* rather than rejected, because failing
    /// a profile is worse than ignoring one entry — and the Settings row shows both "Managed by your
    /// organization" and the not-yet-available reason, so it is visible where someone can act on it.
    public static var manageable: [SettingDescriptor] {
        all.filter { $0.isManageable && $0.availability.isAvailable }
    }

    /// Declared but not yet acted on. Exists so documentation can list them deliberately rather
    /// than an audit rediscovering them.
    public static var notBuilt: [SettingDescriptor] {
        all.filter { !$0.availability.isAvailable }
    }

    public static func inScope(_ scope: SettingScope) -> [SettingDescriptor] {
        all.filter { $0.scope == scope }
    }
}
