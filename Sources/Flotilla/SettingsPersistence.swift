import Foundation
import OSLog
import FlotillaCore

/// Persists the **user tier** of settings to `UserDefaults`.
///
/// `SettingsStore` is deliberately Foundation-only and in-memory: it owns precedence
/// (`locked` > user > managed `defaults` > built-in) and nothing else, which is what makes
/// it testable on Linux without a defaults domain. It exposes `userValuesSnapshot()` with a
/// comment saying that tier is "persisted to `UserDefaults` by the app layer" — and the app
/// layer never did. Every setting therefore reset on every launch, which mattered most for
/// appearance: a first-run question that is never remembered is asked forever, which is
/// worse than not asking at all.
///
/// Only the user tier is stored. Managed `defaults`/`locked` values come from
/// `/Library/Managed Preferences` and must never be cached here, or a profile that stopped
/// applying would keep silently enforcing its last value.
enum SettingsPersistence {

    /// Structured, and carries no setting *values* — only the fact that a read or write
    /// failed. Preferences can contain user-chosen paths and names, so the log records what
    /// happened, never what was in it.
    private static let log = Logger(subsystem: domain, category: "settings")

    /// Per `DECISIONS.md` Q8, the canonical preference domain. Named explicitly rather than
    /// relying on `UserDefaults.standard`, whose domain for a bare SwiftPM executable is
    /// not the bundle identifier we intend to own.
    static let domain = "dev.melonfleet.Flotilla"

    private static let key = "userSettings"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: domain) ?? .standard
    }

    /// The persisted user tier, or empty on first run.
    ///
    /// A decode failure is deliberately non-fatal: corrupt or older-format preferences fall
    /// back to built-in defaults rather than preventing the app from starting. Settings are
    /// recoverable; a launch failure is not.
    static func load() -> [String: SettingValue] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SettingValue].self, from: data)
        } catch {
            log.error("Ignoring unreadable stored preferences: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    static func save(_ values: [String: SettingValue]) {
        do {
            defaults.set(try JSONEncoder().encode(values), forKey: key)
        } catch {
            log.error("Failed to persist preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A store seeded from disk, plus the observation that keeps disk in step with it.
    ///
    /// The observation token must be retained by the caller — dropping it silently stops
    /// persistence, which would look exactly like the bug this type exists to fix.
    static func makeStore() -> (store: SettingsStore, observation: SettingsObservation) {
        let store = SettingsStore(userValues: load())
        let observation = store.observeChanges { _ in
            // Whole snapshot rather than a delta: `reset`/`resetAll` remove keys, and a
            // key-by-key write would leave a removed key still on disk to be reloaded next
            // launch.
            save(store.userValuesSnapshot())
        }
        return (store, observation)
    }
}
