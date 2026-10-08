import Foundation

/// The two-tier managed payload (`DECISIONS.md` Q4), modelled after Rancher Desktop's
/// `…profile.defaults` / `…profile.locked` split.
///
/// On macOS this comes from `/Library/Managed Preferences/dev.melonfleet.Flotilla.plist`,
/// delivered by a Jamf Custom Settings payload, as two nested dictionaries:
///
/// ```xml
/// <key>defaults</key> <dict><key>pollIntervalSeconds</key><integer>15</integer></dict>
/// <key>locked</key>   <dict><key>mode</key><string>host</string></dict>
/// ```
///
/// `FlotillaCore` never reads that file itself — reading it means `CFPreferences`,
/// which is Apple-only and would break the Linux build we verify against. The macOS
/// implementation lives in the app target; core takes this protocol.
public protocol ManagedPreferencesSource: Sendable {
    /// Admin-suggested seed values. Outrank the built-in defaults, and the user may
    /// still change them.
    var managedDefaults: [String: SettingValue] { get }
    /// Admin-enforced values. Outrank everything, permanently; the UI must render
    /// these as locked rather than as a control that silently does nothing.
    var lockedValues: [String: SettingValue] { get }
}

/// The unmanaged case — a machine with no configuration profile. Also the right
/// default for the client app on a personal laptop.
public struct UnmanagedPreferences: ManagedPreferencesSource {
    public init() {}
    public var managedDefaults: [String: SettingValue] { [:] }
    public var lockedValues: [String: SettingValue] { [:] }
}

/// In-memory managed source: the test fake, and also what the app uses once it has
/// snapshotted the real managed domain at launch (managed prefs only change on
/// profile install, so a snapshot is honest and keeps the store synchronous).
public struct StaticManagedPreferences: ManagedPreferencesSource, Sendable, Equatable {
    public let managedDefaults: [String: SettingValue]
    public let lockedValues: [String: SettingValue]

    public init(defaults: [String: SettingValue] = [:], locked: [String: SettingValue] = [:]) {
        self.managedDefaults = defaults
        self.lockedValues = locked
    }
}

/// Wire/plist shape of the managed payload, so the macOS reader and the
/// "export current settings as a deployment profile" flow share one format.
public struct ManagedPayload: Codable, Sendable, Equatable, ManagedPreferencesSource {
    public var schemaVersion: Int
    public var defaults: [String: SettingValue]
    public var locked: [String: SettingValue]

    public init(
        schemaVersion: Int = SettingsSchema.version,
        defaults: [String: SettingValue] = [:],
        locked: [String: SettingValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.defaults = defaults
        self.locked = locked
    }

    public var managedDefaults: [String: SettingValue] { defaults }
    public var lockedValues: [String: SettingValue] { locked }
}
