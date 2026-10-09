import SwiftUI
import OSLog
import FlotillaCore

/// The admin's host categories and each host's value in them (`HostCategoryBook`), persisted to
/// the preference domain — on this Mac only, like tags; nothing is sent to a host.
///
/// Plist-native, one key per concern, the same rule `TagStore` follows:
///
/// ```
/// defaults read dev.melonfleet.Flotilla hostCategories
/// defaults read dev.melonfleet.Flotilla hostCategoryValues
/// ```
@MainActor
@Observable
final class HostCategoryStore {
    @ObservationIgnored
    private let log = Logger(subsystem: SettingsPersistence.domain, category: "host-categories")
    @ObservationIgnored
    private let defaults: UserDefaults?

    private(set) var book: HostCategoryBook

    static let categoriesKey = "hostCategories"
    static let valuesKey = "hostCategoryValues"

    /// Seeds the starter categories on first run only: someone who deletes all three keeps none.
    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        if let defaults, let stored = defaults.object(forKey: Self.categoriesKey) {
            let categories = Self.decode([HostCategory].self, from: stored) ?? []
            let values = defaults.object(forKey: Self.valuesKey)
                .flatMap { Self.decode([String: [String: String]].self, from: $0) } ?? [:]
            book = HostCategoryBook(categories: categories, values: values)
        } else {
            book = .starter
            persist()
        }
    }

    var categories: [HostCategory] { book.categories }

    func value(_ category: HostCategory, for host: String) -> String? { book.value(of: category.id, for: host) }

    // MARK: Writing

    @discardableResult
    func addCategory(named name: String) -> HostCategory? {
        defer { persist() }
        return book.addCategory(named: name)
    }

    func rename(_ category: HostCategory, to name: String) { if book.rename(category.id, to: name) { persist() } }

    func remove(_ category: HostCategory) { book.removeCategory(category.id); persist() }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        book.moveCategories(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setValue(_ value: String?, of category: HostCategory, for hosts: [String]) {
        book.setValue(value, of: category.id, for: hosts)
        persist()
    }

    func renameValue(_ old: String, to new: String, in category: HostCategory) {
        book.renameValue(old, to: new, in: category.id)
        persist()
    }

    func forgetHost(_ host: String) { book.forgetHost(host); persist() }

    // MARK: Storage

    private func persist() {
        guard let defaults else { return }
        do {
            defaults.set(try Self.native(book.categories), forKey: Self.categoriesKey)
            defaults.set(try Self.native(book.values), forKey: Self.valuesKey)
        } catch {
            log.error("Couldn't save host categories: \(String(describing: error), privacy: .public)")
        }
    }

    /// A Codable value as the plist object `defaults` stores — arrays and dictionaries, not a blob.
    private static func native<T: Encodable>(_ value: T) throws -> Any {
        let data = try PropertyListEncoder().encode(value)
        return try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
