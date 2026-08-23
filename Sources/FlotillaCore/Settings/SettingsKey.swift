import Foundation

/// Where a setting applies. The fleet is what makes this necessary: every comparable
/// app has exactly one settings scope ("this Mac"), Flotilla has three.
public enum SettingScope: String, Codable, Sendable, CaseIterable {
    /// The client app on this machine (appearance, confirmations, updates).
    case app
    /// This process acting as a host peer (listen port, Bonjour).
    case host
    /// Has a fleet-wide default plus a per-remote-host override (poll intervals).
    case perHost
}

/// Whether a managed profile may supply this key. Keys that are `.local` are never
/// read from the managed domain, so an MDM payload can't reach into, say, UI state.
public enum ManagedPolicy: String, Codable, Sendable {
    /// Admin may seed (`defaults`) and/or enforce (`locked`) this key.
    case manageable
    /// User-only; managed values for this key are ignored.
    case local
}

/// A single setting, declared exactly once. The Settings UI, the export format, the
/// Jamf key list and the diagnostics dump are all generated from these declarations —
/// there is no second copy of "the list of settings" anywhere.
/// Whether the app behind a setting exists yet.
///
/// The 2026-08-20 audit's strongest finding was a category, not a bug: several settings persisted,
/// survived a relaunch and changed nothing, because the feature they configure has not been built.
/// A stored preference with no consumer is worse than a missing feature — it is a *claim* that the
/// feature is there, and the only way to discover otherwise is to depend on it.
///
/// So availability is declared on the key, in the registry, next to the summary. The control is
/// disabled and states the reason; `Scripts/check-settings-consumers.sh` requires every `.available`
/// key to have a real consumer in the app; and a key cannot quietly become inert, because making it
/// inert means deleting its consumer, which fails that check.
public enum SettingAvailability: Sendable, Equatable, Codable {
    /// Wired to something that reads it.
    case available
    /// Declared, persisted, and not yet acted on. `reason` is shown to the user verbatim, so it
    /// must say what is missing rather than apologise.
    case notBuilt(reason: String)

    public var isAvailable: Bool { self == .available }
    public var unbuiltReason: String? {
        if case .notBuilt(let reason) = self { return reason }
        return nil
    }
}

public struct SettingsKey<Value: SettingRepresentable>: Sendable {
    public let name: String
    public let defaultValue: Value
    public let scope: SettingScope
    public let managed: ManagedPolicy
    /// The `container` service (or the app) must restart before this takes effect.
    /// Surfaced at the control, per research anti-pattern #4.
    public let requiresRestart: Bool
    /// Never exported and never written into a diagnostics bundle.
    public let isSensitive: Bool
    /// Whether anything reads this yet. See `SettingAvailability`.
    public let availability: SettingAvailability
    public let summary: String

    public init(
        _ name: String,
        default defaultValue: Value,
        scope: SettingScope = .app,
        managed: ManagedPolicy = .manageable,
        requiresRestart: Bool = false,
        isSensitive: Bool = false,
        availability: SettingAvailability = .available,
        summary: String
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.scope = scope
        self.managed = managed
        self.requiresRestart = requiresRestart
        self.isSensitive = isSensitive
        self.availability = availability
        self.summary = summary
    }

    /// Type-erased view, for the places that must iterate the whole registry.
    public var descriptor: SettingDescriptor {
        SettingDescriptor(
            name: name,
            kind: Value.settingKind,
            defaultValue: defaultValue.settingValue,
            allowedValues: Value.allowedRawValues,
            scope: scope,
            managed: managed,
            requiresRestart: requiresRestart,
            isSensitive: isSensitive,
            availability: availability,
            summary: summary
        )
    }
}

/// The erased form of a `SettingsKey`. Carries everything the UI, exporter and
/// validator need without knowing the static type.
public struct SettingDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let kind: SettingKind
    public let defaultValue: SettingValue
    public let allowedValues: [String]?
    public let scope: SettingScope
    public let managed: ManagedPolicy
    public let requiresRestart: Bool
    public let isSensitive: Bool
    public let availability: SettingAvailability
    public let summary: String

    public var id: String { name }
    public var isManageable: Bool { managed == .manageable }

    /// A value is acceptable for this key only if the shape matches and, for enums,
    /// the raw value is one of the declared cases. Used for both managed values and
    /// imported files — a bad plist should be ignored, not crash or coerce.
    public func accepts(_ value: SettingValue) -> Bool {
        guard value.kind == kind else { return false }
        guard let allowed = allowedValues else { return true }
        guard case .string(let raw) = value else { return false }
        return allowed.contains(raw)
    }
}
