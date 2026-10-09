import Foundation
import Security
import FlotillaCore

/// The `PeerBook`, persisted plist-native in the app's preference domain under `peerBook` — content,
/// not configuration, like tags and groups, and never through `SettingsStore`. It holds
/// fingerprints and what each Mac said about itself; it holds no secret.
public struct PeerBookStore: @unchecked Sendable {
    public static let key = "peerBook"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// An unreadable book loads as empty rather than crashing — and is left in place, not
    /// overwritten, until something is saved, so a newer Flotilla's book survives an older one.
    public func load() -> PeerBook {
        guard let data = defaults.data(forKey: Self.key),
              let book = try? PropertyListDecoder().decode(PeerBook.self, from: data) else { return PeerBook() }
        return book
    }

    public func save(_ book: PeerBook) throws {
        defaults.set(try PropertyListEncoder().encode(book), forKey: Self.key)
    }
}

/// The fleet enrolment key, on each side.
///
/// - **Admin Mac:** the current key lives in the Keychain — it is a secret — and `rotate` replaces
///   it, which stops new enrolments with the old one without touching hosts already enrolled.
/// - **Host:** the key arrives in a configuration profile as the managed preference
///   `enrolmentKey`, or is pasted by the owner and kept in the Keychain. A managed key wins, and the
///   app shows it as set by the organisation.
public struct EnrolmentKeyStore: @unchecked Sendable {
    public static let managedKey = "enrolmentKey"
    let service: String
    let defaults: UserDefaults

    public static let standard = EnrolmentKeyStore(service: "dev.melonfleet.Flotilla.enrolment-key")

    public init(service: String, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    // MARK: Admin

    /// The admin's current key, if one has been generated.
    public func adminKey() -> EnrolmentKey? {
        read(account: "admin").flatMap { try? EnrolmentKey(text: $0) }
    }

    /// Generates a new key for this admin and stores it, replacing any previous one.
    @discardableResult
    public func rotate(for admin: PeerFingerprint) throws -> EnrolmentKey {
        let key = EnrolmentKey.generate(for: admin)
        try write(key.text, account: "admin", label: "flotilla fleet enrolment key")
        return key
    }

    // MARK: Host

    public enum Source: Sendable, Equatable { case profile, pasted }

    /// The key this host enrols with, and where it came from. A malformed managed value is
    /// reported rather than ignored, so a typo in a profile is visible on the host.
    public func hostKey() -> (key: EnrolmentKey, source: Source)? {
        if defaults.objectIsForced(forKey: Self.managedKey), let text = defaults.string(forKey: Self.managedKey),
           let key = try? EnrolmentKey(text: text) {
            return (key, .profile)
        }
        return read(account: "host").flatMap { try? EnrolmentKey(text: $0) }.map { ($0, .pasted) }
    }

    /// Why the profile's key could not be used, if a profile sets one that does not parse.
    public func managedKeyProblem() -> String? {
        guard defaults.objectIsForced(forKey: Self.managedKey) else { return nil }
        guard let text = defaults.string(forKey: Self.managedKey) else {
            return "The configuration profile's enrolmentKey isn't text."
        }
        do { _ = try EnrolmentKey(text: text); return nil } catch { return "\(error)" }
    }

    /// The owner pasted a key on this host. Validated before it is kept.
    public func setPastedHostKey(_ text: String) throws {
        let key = try EnrolmentKey(text: text)
        try write(key.text, account: "host", label: "flotilla fleet enrolment key")
    }

    public func removePastedHostKey() { delete(account: "host") }

    /// Removes both stored keys — for tests, and for leaving a fleet.
    public func removeAll() {
        delete(account: "admin")
        delete(account: "host")
    }

    // MARK: Keychain

    private func read(account: String) -> String? {
        DeviceIdentityStore.keychainLock.lock()
        defer { DeviceIdentityStore.keychainLock.unlock() }
        var result: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String, label: String) throws {
        DeviceIdentityStore.keychainLock.lock()
        defer { DeviceIdentityStore.keychainLock.unlock() }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw DeviceIdentityStore.IdentityError.keychain(update, "save the enrolment key")
        }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        // Readable after first unlock, so a headless host that auto-logs-in can enrol unattended.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityStore.IdentityError.keychain(status, "save the enrolment key")
        }
    }

    private func delete(account: String) {
        DeviceIdentityStore.keychainLock.lock()
        defer { DeviceIdentityStore.keychainLock.unlock() }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
