import SwiftUI
import FlotillaCore

/// The user's registry list, persisted to the preference domain.
///
/// The same shape and the same argument as `TagStore`: the rules live in `RegistryBook` in
/// `FlotillaCore` where they can be tested, this adds observation and storage, and it is written
/// plist-native so an admin can read it.
///
/// ```
/// defaults read dev.melonfleet.Flotilla registries
/// ```
///
/// **Definitions are not stored — hosts are.** A row whose host is in `KnownRegistry.catalogue`
/// is rehydrated from the catalogue on every launch, so improving a registry's guidance, fixing
/// a token URL or adding a browse page reaches lists that already exist. Only what the catalogue
/// cannot know is written down: the host, the kind, the name someone chose, and the scheme. The
/// alternative — freezing the whole definition into the plist — would mean the first user to add
/// GHCR keeps that day's wording for ever.
///
/// **No credential of any kind is stored here.** Passwords live in the Keychain, written by
/// `container registry login`; Flotilla neither stores nor reads them.
@MainActor
@Observable
final class RegistryStore {

    private(set) var book: RegistryBook

    @ObservationIgnored
    private let defaults: UserDefaults?

    static let key = "registries"

    /// Loads the list, seeding a first run with Docker Hub and GHCR.
    ///
    /// **Absent and empty are different**, which is why this reads `object(forKey:)` first: a
    /// user who removed every registry has an *empty* list, and re-seeding on `isEmpty` would
    /// hand them back on the next launch. The same distinction `TagStore` draws, for the same
    /// reason.
    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        if let defaults, let raw = defaults.array(forKey: Self.key) as? [[String: String]] {
            book = RegistryBook(registries: raw.compactMap(Self.rehydrate))
        } else {
            book = .starter
            // Written back straight away, so "absent means first run" stops being true after the
            // first launch rather than after the first edit. A nil store (tests, previews)
            // writes nothing and keeps the starter list in memory.
            persist()
        }
    }

    /// One stored row back into a definition.
    ///
    /// A malformed entry is skipped, not defaulted. The plist is hand-editable, so this is a
    /// real input: a row with no host is a row whose Sign In can only fail.
    private static func rehydrate(_ entry: [String: String]) -> KnownRegistry? {
        guard let host = entry["host"], Allowlist.accepts(host, as: .registryHost) else {
            return nil
        }
        // A catalogue registry is taken from the catalogue, not from the plist — see the note on
        // this type. Only a name the user chose survives the round trip.
        if let known = KnownRegistry.catalogue.first(where: {
            KnownRegistry.canonicalHost($0.id) == KnownRegistry.canonicalHost(host)
        }) {
            return known
        }
        return KnownRegistry(id: host,
                             name: entry["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host,
                             summary: entry["summary"] ?? "",
                             isUserAdded: true,
                             kind: entry["kind"].flatMap(RegistryKind.init(rawValue:)),
                             usesHTTP: entry["scheme"] == "http")
    }

    var lastError: String?

    var all: [KnownRegistry] { book.all }
    /// Catalogue entries not yet in the list — what the Add form offers.
    var addable: [KnownRegistry] { book.addable }

    /// Adds a registry the catalogue already describes.
    @discardableResult
    func add(known: KnownRegistry) -> KnownRegistry? {
        do {
            let added = try book.add(known: known)
            persist()
            return added
        } catch {
            lastError = (error as? RegistryBook.RegistryError)?.description
                ?? String(describing: error)
            return nil
        }
    }

    /// Adds one the catalogue does not know.
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

    /// Takes a registry out of the list. Does not sign out — see `RegistryBook.remove(host:)`.
    func remove(host: String) {
        do { try book.remove(host: host); persist() }
        catch {
            lastError = (error as? RegistryBook.RegistryError)?.description
                ?? String(describing: error)
        }
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(book.registries.map {
            ["host": $0.id, "name": $0.name, "summary": $0.summary,
             "kind": $0.kind.rawValue, "scheme": $0.usesHTTP ? "http" : "https"]
        }, forKey: Self.key)
        // The retired keys from the two designs this replaced. Removed rather than left behind:
        // a stale `hiddenRegistries` in someone's plist is a fact about a feature that no longer
        // exists, and `defaults read` should not show it.
        defaults.removeObject(forKey: "userRegistries")
        defaults.removeObject(forKey: "hiddenRegistries")
    }
}
