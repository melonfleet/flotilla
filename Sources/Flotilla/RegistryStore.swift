import SwiftUI
import FlotillaCore

/// The registries the user has added, persisted to the preference domain.
///
/// The same shape and the same argument as `TagStore`: the rules live in `RegistryBook` in
/// `FlotillaCore` where they can be tested, this adds observation and storage, and it is written
/// plist-native so an admin can read it.
///
/// ```
/// defaults read dev.melonfleet.Flotilla userRegistries
/// ```
///
/// **Only the user's own registries are stored here, and never a credential.** The built-in
/// catalogue is code, not preferences — a stale copy of it in someone's plist would outlive the
/// list it was copied from. Passwords live in the Keychain, written by `container registry
/// login`; Flotilla neither stores nor reads them.
@MainActor
@Observable
final class RegistryStore {

    private(set) var book: RegistryBook

    @ObservationIgnored
    private let defaults: UserDefaults?

    static let key = "userRegistries"
    /// Built-in registries the user removed from the list. A separate plist key, because these
    /// are hosts rather than definitions and folding them into the same array would mean a row
    /// whose only content is "not this one".
    static let hiddenKey = "hiddenRegistries"

    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        let raw = defaults?.array(forKey: Self.key) as? [[String: String]] ?? []
        // A malformed entry is skipped, not defaulted. The plist is hand-editable, so this is a
        // real input: a row with no host is a row whose Sign In can only fail.
        let added: [KnownRegistry] = raw.compactMap { entry in
            guard let host = entry["host"], Allowlist.accepts(host, as: .registryHost)
            else { return nil }
            return KnownRegistry(id: host,
                                 name: entry["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host,
                                 summary: entry["summary"] ?? "",
                                 isUserAdded: true,
                                 kind: entry["kind"].flatMap(RegistryKind.init(rawValue:)),
                                 usesHTTP: entry["scheme"] == "http")
        }
        let hidden = Set((defaults?.stringArray(forKey: Self.hiddenKey) ?? [])
            .map(KnownRegistry.canonicalHost))
        book = RegistryBook(userAdded: added, hidden: hidden)
    }

    var lastError: String?

    var all: [KnownRegistry] { book.all }

    @discardableResult
    func add(host: String, name: String, summary: String = "",
             kind: RegistryKind? = nil, usesHTTP: Bool = false) -> KnownRegistry? {
        do {
            let registry = try book.add(host: host, name: name, summary: summary,
                                        kind: kind, usesHTTP: usesHTTP)
            persist()
            return registry
        } catch {
            lastError = (error as? RegistryBook.RegistryError)?.description
                ?? String(describing: error)
            return nil
        }
    }

    /// Removes a registry from the list. A built-in is hidden and can be added back; one of the
    /// user's own is deleted. Neither signs out — see `RegistryBook.remove(host:)`.
    func remove(host: String) {
        do { try book.remove(host: host); persist() }
        catch {
            lastError = (error as? RegistryBook.RegistryError)?.description
                ?? String(describing: error)
        }
    }

    /// Puts a removed built-in back.
    func restore(host: String) {
        do { try book.restore(host: host); persist() }
        catch {
            lastError = (error as? RegistryBook.RegistryError)?.description
                ?? String(describing: error)
        }
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(book.userAdded.map {
            ["host": $0.id, "name": $0.name, "summary": $0.summary,
             "kind": $0.kind.rawValue, "scheme": $0.usesHTTP ? "http" : "https"]
        }, forKey: Self.key)
        defaults.set(book.hidden.sorted(), forKey: Self.hiddenKey)
    }
}
