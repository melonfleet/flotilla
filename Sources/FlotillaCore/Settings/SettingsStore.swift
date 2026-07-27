import Foundation

/// Which tier supplied the value the app is actually using. The UI renders `.locked`
/// as a disabled control with a "Managed by your organization" footnote — never a
/// control that silently does nothing (research pattern #5).
public enum SettingSource: String, Codable, Sendable {
    case locked          // managed, enforced — wins over everything
    case user            // set in the Settings UI
    case managedDefault  // managed seed the user may still change
    case builtIn         // the declared default in SettingsRegistry
}

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    case locked(String)
    case unknownKey(String)
    case typeMismatch(key: String, expected: SettingKind, found: SettingKind)
    case disallowedValue(key: String, value: String)

    public var description: String {
        switch self {
        case .locked(let k):
            "‘\(k)’ is managed by a configuration profile and cannot be changed here."
        case .unknownKey(let k):
            "‘\(k)’ is not a known Flotilla setting."
        case .typeMismatch(let k, let expected, let found):
            "‘\(k)’ expects \(expected.rawValue) but the value is \(found.rawValue)."
        case .disallowedValue(let k, let v):
            "‘\(v)’ is not a valid value for ‘\(k)’."
        }
    }
}

/// The settings store: typed reads, precedence, and the export/import/reset surface.
///
/// **Precedence, highest wins** (`DECISIONS.md` Q4):
/// ```
/// locked (managed, immutable)
///   > user value
///     > defaults (managed seed the user may change)
///       > built-in default
/// ```
///
/// The managed `defaults` tier is evaluated live rather than copied into the user
/// domain on first run. Same observable behaviour, minus a copy that can go stale —
/// and it keeps "reset to defaults" meaning *back to the admin's seed*, not back to
/// the built-in, which is what an admin who shipped a seed expects.
///
/// Reference-typed and lock-guarded so client mode, host mode and the poller can
/// share one instance. `@unchecked Sendable` is carried by the lock, not by luck:
/// every access to `userValues`/`observers` goes through it.
public final class SettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let managed: any ManagedPreferencesSource
    private var userValues: [String: SettingValue]
    private var observers: [UUID: @Sendable (String) -> Void] = [:]

    public init(
        managed: any ManagedPreferencesSource = UnmanagedPreferences(),
        userValues: [String: SettingValue] = [:]
    ) {
        self.managed = managed
        self.userValues = userValues
    }

    // MARK: - Reading

    public subscript<V>(key: SettingsKey<V>) -> V { value(for: key) }

    public func value<V>(for key: SettingsKey<V>) -> V {
        let descriptor = key.descriptor
        lock.lock()
        defer { lock.unlock() }
        let raw = resolveLocked(descriptor).value
        // A resolved value always matches the declared kind (managed and imported
        // values are validated on the way in), so the fallback is unreachable in
        // practice — but returning the declared default beats trapping in the UI.
        return V(settingValue: raw) ?? key.defaultValue
    }

    /// Which tier the current value came from — drives the padlock and the
    /// "Managed by your organization" label.
    public func source<V>(of key: SettingsKey<V>) -> SettingSource {
        source(ofKeyNamed: key.name) ?? .builtIn
    }

    public func source(ofKeyNamed name: String) -> SettingSource? {
        guard let descriptor = SettingsRegistry.descriptor(named: name) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return resolveLocked(descriptor).source
    }

    public func isLocked<V>(_ key: SettingsKey<V>) -> Bool { isLocked(keyNamed: key.name) }

    public func isLocked(keyNamed name: String) -> Bool {
        guard let descriptor = SettingsRegistry.descriptor(named: name), descriptor.isManageable
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let value = managed.lockedValues[name] else { return false }
        return descriptor.accepts(value)
    }

    /// Every registered key with its effective value. Used by the settings export,
    /// the diagnostics snapshot, and (Phase 3) the fleet drift view.
    public func effectiveValues() -> [String: SettingValue] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: SettingsRegistry.all.map {
            ($0.name, resolveLocked($0).value)
        })
    }

    /// Names of keys currently enforced by a profile, sorted for stable output.
    public func lockedKeyNames() -> [String] {
        SettingsRegistry.all.map(\.name).filter { isLocked(keyNamed: $0) }.sorted()
    }

    /// Caller must hold `lock`.
    private func resolveLocked(_ descriptor: SettingDescriptor) -> (value: SettingValue, source: SettingSource) {
        if descriptor.isManageable,
           let locked = managed.lockedValues[descriptor.name], descriptor.accepts(locked) {
            return (locked, .locked)
        }
        if let user = userValues[descriptor.name], descriptor.accepts(user) {
            return (user, .user)
        }
        if descriptor.isManageable,
           let seed = managed.managedDefaults[descriptor.name], descriptor.accepts(seed) {
            return (seed, .managedDefault)
        }
        return (descriptor.defaultValue, .builtIn)
    }

    // MARK: - Writing

    public func set<V>(_ newValue: V, for key: SettingsKey<V>) throws {
        try setRaw(newValue.settingValue, forKeyNamed: key.name)
    }

    /// Untyped setter for the places that genuinely only have a name — the Wire
    /// `setSettings` message and settings import. Validates against the registry, so
    /// it is not a hole in the typing: unknown or wrong-shaped keys are rejected.
    public func setRaw(_ newValue: SettingValue, forKeyNamed name: String) throws {
        guard let descriptor = SettingsRegistry.descriptor(named: name) else {
            throw SettingsError.unknownKey(name)
        }
        guard newValue.kind == descriptor.kind else {
            throw SettingsError.typeMismatch(key: name, expected: descriptor.kind, found: newValue.kind)
        }
        guard descriptor.accepts(newValue) else {
            throw SettingsError.disallowedValue(key: name, value: String(describing: newValue))
        }
        guard !isLocked(keyNamed: name) else { throw SettingsError.locked(name) }

        lock.lock()
        userValues[name] = newValue
        let handlers = Array(observers.values)
        lock.unlock()
        handlers.forEach { $0(name) }
    }

    /// Drop the user's value for one key; it falls back to the managed seed, then
    /// the built-in default.
    public func reset<V>(_ key: SettingsKey<V>) { reset(keyNamed: key.name) }

    public func reset(keyNamed name: String) {
        lock.lock()
        userValues.removeValue(forKey: name)
        let handlers = Array(observers.values)
        lock.unlock()
        handlers.forEach { $0(name) }
    }

    /// Reset **preferences only**. This is one of three separate, separately
    /// confirmed reset actions (the others being "forget all hosts and trust" and
    /// "reset window layout"): a settings reset must never touch container, image or
    /// volume data. It also cannot clear the managed domain — locked and seeded
    /// values survive, and the UI must say so.
    public func resetAll() {
        lock.lock()
        let names = Array(userValues.keys)
        userValues.removeAll()
        let handlers = Array(observers.values)
        lock.unlock()
        for name in names { handlers.forEach { $0(name) } }
    }

    /// The user-set tier only — what gets persisted to `UserDefaults` by the app layer.
    public func userValuesSnapshot() -> [String: SettingValue] {
        lock.lock()
        defer { lock.unlock() }
        return userValues
    }

    // MARK: - Change notification

    /// Minimal observation so the SwiftUI layer can republish without polling.
    /// Handlers run outside the lock, so a handler may safely read the store.
    public func observeChanges(_ handler: @escaping @Sendable (String) -> Void) -> SettingsObservation {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return SettingsObservation(id: id) { [weak self] id in
            guard let self else { return }
            lock.lock()
            observers.removeValue(forKey: id)
            lock.unlock()
        }
    }
}

/// Cancels its registration when released.
public final class SettingsObservation: Sendable {
    private let id: UUID
    private let cancel: @Sendable (UUID) -> Void

    init(id: UUID, cancel: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.cancel = cancel
    }

    deinit { cancel(id) }
}

// MARK: - Convenience accessors

extension SettingsStore {
    /// `nil` until first-run onboarding (or a managed profile) has answered.
    /// Distinct from `.auto`, which is a real choice the user made.
    public var chosenAppearance: AppearanceMode? { self[SettingsKeys.appearance].chosen }

    /// What to render with right now, whether or not the question has been answered.
    public var effectiveAppearance: AppearanceMode { self[SettingsKeys.appearance].effective }

    public var needsAppearanceOnboarding: Bool { !self[SettingsKeys.appearance].isChosen }

    public func chooseAppearance(_ mode: AppearanceMode) throws {
        try set(AppearancePreference(mode), for: SettingsKeys.appearance)
    }

    /// Mandatory categories ignore the stored value: a user can silence pull
    /// notifications, but not genuine errors (Docker's one good notification rule).
    public func isEnabled(_ category: NotificationCategory) -> Bool {
        if category.isMandatory { return true }
        return self[SettingsKeys.notification(category)]
    }

    public func setNotification(_ category: NotificationCategory, enabled: Bool) throws {
        guard !category.isMandatory else { throw SettingsError.locked(SettingsKeys.notification(category).name) }
        try set(enabled, for: SettingsKeys.notification(category))
    }

    /// Snapshot of every category's effective state, for the notifications pane.
    public func notificationSettings() -> NotificationSettings {
        NotificationSettings(enabled: Dictionary(uniqueKeysWithValues:
            NotificationCategory.allCases.map { ($0, isEnabled($0)) }
        ))
    }
}
