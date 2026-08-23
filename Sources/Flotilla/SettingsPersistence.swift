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
    private static let versionKey = "userSettingsSchemaVersion"

    /// `research/FEATURES.md`: *"Schema `version` integer + migration — one field on day one;
    /// saves a corrupt-prefs bug later."* This was omitted when persistence first landed,
    /// which is exactly the mistake that note warns about: without it, the first format
    /// change is indistinguishable from corruption, so every user silently loses their
    /// settings to the fallback path.
    ///
    /// Bump this **only** alongside a migration step in `migrate(_:from:)`.
    static let currentSchemaVersion = 1

    /// `.standard` when we are running as the bundle that owns `domain`, an explicit suite
    /// otherwise.
    ///
    /// Asking for `UserDefaults(suiteName:)` with your *own* bundle identifier is a documented
    /// mistake, and AppKit says so out loud on every launch: "Using your own bundle identifier
    /// as an NSUserDefaults suite name does not make sense and will not work." It returned nil,
    /// so `?? .standard` quietly did the right thing and the domain was correct by luck rather
    /// than by intent — a fallback carrying the real behaviour is one bad edit from silently
    /// moving everyone's preferences.
    ///
    /// The suite branch still matters: run as a bare SwiftPM executable there is no bundle
    /// identifier, and `.standard` would write somewhere we do not own.
    private static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    /// The persisted user tier, or empty on first run.
    ///
    /// A decode failure is deliberately non-fatal: corrupt or older-format preferences fall
    /// back to built-in defaults rather than preventing the app from starting. Settings are
    /// recoverable; a launch failure is not.
    static func load() -> [String: SettingValue] {
        guard let data = defaults.data(forKey: key) else { return [:] }

        // Absent version on existing data means "written before versioning existed", which
        // is schema 1 — not an error. Treating it as unknown would discard the settings of
        // anyone who ran the build between persistence landing and this field being added.
        let stored = defaults.object(forKey: versionKey) as? Int ?? currentSchemaVersion

        // Newer than we understand: keep it and fall back to defaults for this launch
        // rather than "migrating" by guessing, which would overwrite a newer build's
        // preferences with a downgrade's idea of them.
        if stored > currentSchemaVersion {
            log.error("""
                Stored preferences are schema \(stored, privacy: .public), newer than this \
                build understands (\(currentSchemaVersion, privacy: .public)). Using defaults \
                for this launch and leaving them untouched.
                """)
            return [:]
        }

        do {
            let decoded = try JSONDecoder().decode([String: SettingValue].self, from: data)
            return migrate(decoded, from: stored)
        } catch {
            log.error("Ignoring unreadable stored preferences: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Forward migration, one step per version. Nothing to do yet — there is only one
    /// schema — but the seam exists so the first change is a two-line addition rather than
    /// a decision about what to do with everybody's existing preferences.
    private static func migrate(
        _ values: [String: SettingValue], from stored: Int
    ) -> [String: SettingValue] {
        guard stored < currentSchemaVersion else { return values }
        // One `case` per version bump, each transforming forward:
        //     if stored < 2 { values = migrateV1ToV2(values) }
        // Nothing yet — schema 1 is the only version that has ever existed — but the call
        // site and the version field are in place, so the first change is additive.
        return values
    }

    static func save(_ values: [String: SettingValue]) {
        do {
            let encoded = try JSONEncoder().encode(values)
            // Version first: a crash between the two writes must not leave data that claims
            // to be older than it is, which would re-run a migration over already-migrated
            // values.
            defaults.set(currentSchemaVersion, forKey: versionKey)
            defaults.set(encoded, forKey: key)
        } catch {
            log.error("Failed to persist preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget every **user-set preference**, returning each key to its built-in or managed
    /// default.
    ///
    /// Scoped deliberately. `research/FEATURES.md` requires three *separate* resets and warns
    /// that a settings reset must never move your window — so this touches the preferences
    /// blob and nothing else. It also cannot touch containers, images or volumes, because it
    /// only knows about this one `UserDefaults` key.
    static func clearUserValues() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: versionKey)
    }

    /// Forget saved **window geometry** — position, size, and the sidebar split.
    ///
    /// The counterpart to `clearUserValues`, and the reason they are separate: someone whose
    /// window has ended up half off a disconnected display wants it back without losing every
    /// preference they have set, and vice versa.
    ///
    /// AppKit stores frames under `NSWindow Frame <autosave name>` in the app's own domain.
    /// The keys are enumerated rather than named individually because the set grows with each
    /// window the app defines, and a hardcoded list would silently stop covering new ones.
    static func clearWindowState() {
        let app = UserDefaults.standard
        for name in app.dictionaryRepresentation().keys where name.hasPrefix("NSWindow Frame ") {
            app.removeObject(forKey: name)
        }
        // Some SwiftUI scene state lands in the suite rather than the standard domain.
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix("NSWindow Frame ") {
            defaults.removeObject(forKey: name)
        }
    }

    /// A store seeded from disk, plus the observation that keeps disk in step with it.
    ///
    /// The observation token must be retained by the caller — dropping it silently stops
    /// persistence, which would look exactly like the bug this type exists to fix.
    static func makeStore() -> (store: SettingsStore, observation: SettingsObservation) {
        let loaded = load()
        let store = SettingsStore(userValues: loaded)
        let observation = store.observeChanges { _ in
            // Whole snapshot rather than a delta: `reset`/`resetAll` remove keys, and a
            // key-by-key write would leave a removed key still on disk to be reloaded next
            // launch.
            save(store.userValuesSnapshot())
        }

        // Persist a migration immediately, rather than waiting for the user's next edit.
        //
        // `SettingsStore.init` retires old keys in memory, and `SettingsStore` is Foundation-only
        // so it cannot write anything. Without this the retired key stays on disk indefinitely and
        // the migration re-runs on every launch — which was measured, not assumed: after the
        // `presentation` → `showDockIcon` change this Mac still had `{"presentation":"both"}` in
        // its preferences after a clean launch. Correct behaviour, indefinitely derived from a key
        // nothing else understands any more.
        let migrated = store.userValuesSnapshot()
        if migrated.keys != loaded.keys {
            save(migrated)
            log.info("Migrated retired preference keys.")
        }

        return (store, observation)
    }
}
