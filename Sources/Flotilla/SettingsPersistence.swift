import Foundation
import OSLog
import FlotillaCore

/// Persists the **user tier** of settings to `UserDefaults`, **one key per setting**.
///
/// `SettingsStore` is deliberately Foundation-only and in-memory: it owns precedence
/// (`locked` > user > managed `defaults` > built-in) and nothing else, which is what makes
/// it testable on Linux without a defaults domain. It exposes `userValuesSnapshot()` with a
/// comment saying that tier is "persisted to `UserDefaults` by the app layer" — and the app
/// layer never did. Every setting therefore reset on every launch, which mattered most for
/// appearance: a first-run question that is never remembered is asked forever, which is
/// worse than not asking at all.
///
/// ## One key each, not one blob (changed 2026-09-12)
///
/// This used to write the whole user tier as a single JSON blob under `userSettings`. It worked,
/// and it was the wrong shape for this product: `defaults read dev.melonfleet.Flotilla` showed one
/// opaque `<data>`, `defaults write dev.melonfleet.Flotilla pollIntervalSeconds -int 15` did
/// nothing at all, and a support request could not be answered by reading a plist. For a tool
/// whose users are Mac admins, being invisible to `defaults`, `plutil` and every script they
/// already have is a defect rather than an implementation detail.
///
/// So every setting is now its own key, named exactly as the registry names it, holding a
/// property-list primitive — which is what `SettingValue` was declared as a closed set of plist
/// types *for*. Settings are scriptable, greppable and diffable; a key that is absent means "not
/// chosen", which is why `save` removes keys rather than writing defaults back.
///
/// **Configuration profiles were never affected either way**, and that is worth being precise
/// about: MDM does not write an app's own preference domain, it writes
/// `/Library/Managed Preferences/dev.melonfleet.Flotilla.plist`, which `ManagedPreferencesSource`
/// has always read as two `defaults`/`locked` dictionaries and which outranks everything here.
/// This change is about the *user* tier being inspectable, not about making management possible.
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

    /// The retired blob. Read once, to carry existing preferences over, then removed.
    private static let legacyBlobKey = "userSettings"
    private static let versionKey = "userSettingsSchemaVersion"

    /// `research/FEATURES.md`: *"Schema `version` integer + migration — one field on day one;
    /// saves a corrupt-prefs bug later."* This was omitted when persistence first landed,
    /// which is exactly the mistake that note warns about: without it, the first format
    /// change is indistinguishable from corruption, so every user silently loses their
    /// settings to the fallback path.
    ///
    /// Bump this **only** alongside a migration step in `migrate(_:from:)`.
    ///
    /// 1 = the single JSON blob. 2 = one plist key per setting. The version is still recorded
    /// because per-key storage does not remove the need for migrations — it only removes the
    /// need to decode everything at once to find out whether one is due.
    static let currentSchemaVersion = 2

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
    /// Reads only keys the registry declares, and reads each one **as the kind it is declared
    /// to be**. That is what stops a hand-edited plist turning `pollIntervalSeconds` into a
    /// string the app then has to defend against everywhere: a key of the wrong shape is ignored
    /// and its built-in default applies.
    ///
    /// `UserDefaults`' typed accessors do the reading, so the platform's own coercion applies —
    /// `-int 1` on a boolean key reads as `true`, as it would for any other Mac app. Deliberate:
    /// an admin's muscle memory should work here.
    static func load() -> [String: SettingValue] {
        let store = defaults
        var values = importLegacyBlobIfPresent(into: store)

        for descriptor in SettingsRegistry.all {
            // `object(forKey:)` first: the typed accessors cannot tell "absent" from "false"
            // or from "0", and absent has to stay absent or every default would be overwritten
            // by a value nobody chose.
            guard store.object(forKey: descriptor.name) != nil else { continue }
            guard let value = read(descriptor, from: store) else {
                log.error("Ignoring \(descriptor.name, privacy: .public): not a \(descriptor.kind.rawValue, privacy: .public).")
                continue
            }
            values[descriptor.name] = value
        }

        store.set(currentSchemaVersion, forKey: versionKey)
        return values
    }

    private static func read(_ descriptor: SettingDescriptor, from store: UserDefaults) -> SettingValue? {
        switch descriptor.kind {
        case .bool: .bool(store.bool(forKey: descriptor.name))
        case .int: .int(store.integer(forKey: descriptor.name))
        case .double: .double(store.double(forKey: descriptor.name))
        case .string: store.string(forKey: descriptor.name).map { .string($0) }
        case .stringArray: store.stringArray(forKey: descriptor.name).map { .stringArray($0) }
        }
    }

    /// Carry a pre-2026-09-12 blob over to individual keys, once.
    ///
    /// Individual keys win where both exist: someone who has already run a build that writes them
    /// — or who set one with `defaults write` — has expressed a newer intention than the blob.
    /// The blob is then deleted, so it cannot be resurrected by a later downgrade and quietly
    /// override what has been set since.
    private static func importLegacyBlobIfPresent(into store: UserDefaults) -> [String: SettingValue] {
        guard let data = store.data(forKey: legacyBlobKey) else { return [:] }
        defer { store.removeObject(forKey: legacyBlobKey) }

        let stored = store.object(forKey: versionKey) as? Int ?? 1
        do {
            let decoded = try JSONDecoder().decode([String: SettingValue].self, from: data)
            let migrated = migrate(decoded, from: stored)
            // Written out immediately rather than left in memory: if this launch crashes before
            // anything calls `save`, the preferences have still moved rather than been dropped.
            for descriptor in SettingsRegistry.all {
                guard let value = migrated[descriptor.name],
                      store.object(forKey: descriptor.name) == nil else { continue }
                store.set(value.plistObject, forKey: descriptor.name)
            }
            log.info("Moved \(migrated.count, privacy: .public) stored preferences to individual keys.")
            return migrated
        } catch {
            log.error("Ignoring unreadable stored preferences: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Forward migration of a decoded blob, one step per version. There is nothing to do
    /// between 1 and 2 — the values did not change shape, only where they are written — but the
    /// seam stays, because the next change to a *value* needs it and adding it back later means
    /// deciding what to do with everyone's existing preferences under pressure.
    private static func migrate(
        _ values: [String: SettingValue], from stored: Int
    ) -> [String: SettingValue] {
        guard stored < currentSchemaVersion else { return values }
        // One `case` per version bump, each transforming forward:
        //     if stored < 3 { values = migrateV2ToV3(values) }
        return values
    }

    /// Write the user tier out, one key each.
    ///
    /// A setting the user has not chosen is **removed**, not written with its default. That is
    /// what makes `defaults read dev.melonfleet.Flotilla` a list of decisions rather than a dump
    /// of the whole registry, and it is what lets a managed `defaults` value take effect later:
    /// a user key holding a value identical to the default still outranks the profile.
    static func save(_ values: [String: SettingValue]) {
        let store = defaults
        for descriptor in SettingsRegistry.all {
            if let value = values[descriptor.name] {
                store.set(value.plistObject, forKey: descriptor.name)
            } else {
                store.removeObject(forKey: descriptor.name)
            }
        }
        store.set(currentSchemaVersion, forKey: versionKey)
    }

    /// Forget every **user-set preference**, returning each key to its built-in or managed
    /// default.
    ///
    /// Scoped deliberately. `research/FEATURES.md` requires three *separate* resets and warns
    /// that a settings reset must never move your window — so this touches the preferences
    /// blob and nothing else. It also cannot touch containers, images or volumes, because it
    /// only knows about this one `UserDefaults` key.
    static func clearUserValues() {
        let store = defaults
        for descriptor in SettingsRegistry.all { store.removeObject(forKey: descriptor.name) }
        // The retired blob too, in case a reset is the first thing someone does after upgrading.
        store.removeObject(forKey: legacyBlobKey)
        store.removeObject(forKey: versionKey)
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
