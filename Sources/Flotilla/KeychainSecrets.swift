import Foundation
import Security

/// Group passwords in the login Keychain (Suggestions, decided 2026-10-06): generated when a stack
/// is created, read at Start, shown on the group with Copy. **Never** in the preferences file,
/// which holds only each secret's name, and never in an export.
///
/// One generic-password item per secret, keyed by group **id** (a rename keeps its passwords) and
/// the secret's name. The label is for people reading Keychain Access.
///
/// A development build is ad-hoc signed, so its signature changes with every rebuild and macOS
/// asks once before a new build reads an item an older one wrote. A Developer ID build has a
/// stable identity and does not.
enum KeychainSecrets {
    static let service = "dev.melonfleet.Flotilla.group-secret"

    private static func account(group: String, secret: String) -> String { "\(group)/\(secret)" }

    static func value(group: String, secret: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(group: group, secret: secret),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Adds or replaces. Returns whether the Keychain took it — a refused write must not be
    /// reported as a saved password.
    @discardableResult
    static func set(_ value: String, group: String, secret: String, label: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(group: group, secret: secret),
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(match as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrLabel as String: label]
                                       as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(group: String, secret: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(group: group, secret: secret),
        ] as CFDictionary)
    }
}
