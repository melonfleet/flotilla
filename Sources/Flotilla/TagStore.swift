import SwiftUI
import OSLog
import FlotillaCore

/// The app's live `TagBook`, persisted to the preference domain.
///
/// **Observable here, pure in the core.** `TagBook` holds every rule — legal names, what a
/// delete takes with it, whether an id may be assigned — and is Foundation-only so the test
/// target can pin them on Linux. This class adds the two things that cannot live there:
/// SwiftUI observation, so a pill redraws the moment a menu item is picked, and storage.
///
/// ## Why not `SettingsStore`
///
/// Tags are the user's *content*, not their configuration. `SettingsStore` owns a closed
/// registry where every key is declared once, carries a managed policy, appears in the Settings
/// UI and the Jamf key list, and has a `check-settings-consumers.sh` entry — all of which is
/// correct for "poll interval" and meaningless for "the seven tags you made". More concretely:
/// a managed profile may seed or lock any `manageable` key, and an admin pushing a tag list over
/// someone's own tags is not a capability worth building.
///
/// It is written to the same domain by the same rules `SettingsPersistence` argues for, though:
/// **plist-native, one key per concern, readable with `defaults read`.** Not a JSON blob — that
/// is the shape that file moved away from, for users who are Mac admins and expect to be able to
/// look.
///
/// ```
/// defaults read dev.melonfleet.Flotilla tagDefinitions
/// defaults read dev.melonfleet.Flotilla tagAssignments
/// ```
@MainActor
@Observable
final class TagStore {

    /// Carries no tag names and no subject ids — a tag can be called anything and a subject id
    /// is a container name, so this records that a read or write failed, never what was in it.
    /// The same rule `SettingsPersistence.log` follows.
    @ObservationIgnored
    private let log = Logger(subsystem: SettingsPersistence.domain, category: "tags")

    private(set) var book: TagBook

    /// Written on every mutation. Injected so tests and previews can hold a store that touches
    /// nothing; the app passes its real domain.
    @ObservationIgnored
    private let defaults: UserDefaults?

    static let definitionsKey = "tagDefinitions"
    static let assignmentsKey = "tagAssignments"

    /// Loads from the domain, seeding the starter tags on genuine first run.
    ///
    /// **Absent and empty are different**, which is the whole reason this reads `object(forKey:)`
    /// first. A user who deletes all seven starter tags has an *empty* list, and seeding on
    /// `isEmpty` would hand them straight back on the next launch — a preference that cannot be
    /// expressed is worse than one that is not offered.
    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        if let defaults, defaults.object(forKey: Self.definitionsKey) != nil {
            book = Self.read(from: defaults)
        } else {
            book = .starter
            // Write the starter set straight back, so "absent means first run" stops being true
            // after the first launch rather than after the first edit. A nil store (tests,
            // previews) writes nothing and keeps the starter set in memory.
            persist()
        }
    }

    /// `.standard` when we are the bundle that owns the domain, an explicit suite otherwise —
    /// the same reasoning, and the same AppKit warning avoided, as `SettingsPersistence.defaults`.
    static func standardDefaults() -> UserDefaults? {
        if Bundle.main.bundleIdentifier == SettingsPersistence.domain { return .standard }
        return UserDefaults(suiteName: SettingsPersistence.domain)
    }

    // MARK: Reading

    func tags(on subject: TagSubject) -> [Tag] { book.tags(on: subject) }
    func tags(on kind: ActivityKind, _ id: String) -> [Tag] {
        book.tags(on: TagSubject(kind: kind, id: id))
    }

    var allTags: [Tag] { book.tags }

    func isTagged(_ subject: TagSubject, with tagID: String) -> Bool {
        book.isTagged(subject, with: tagID)
    }

    // MARK: Writing

    /// The last refusal, for the one caller that can provoke one from a text field. Menu
    /// toggling cannot fail — the ids come from `book.tags` — so this stays nil in normal use.
    var lastError: String?

    @discardableResult
    func createTag(name: String, color: TagColor) -> Tag? {
        do {
            let tag = try book.createTag(name: name, color: color)
            persist()
            return tag
        } catch {
            lastError = (error as? TagBook.TagError)?.description ?? String(describing: error)
            return nil
        }
    }

    func rename(_ tagID: String, to name: String) {
        do { try book.rename(tagID, to: name); persist() }
        catch { lastError = (error as? TagBook.TagError)?.description ?? String(describing: error) }
    }

    func recolour(_ tagID: String, to color: TagColor) {
        do { try book.recolour(tagID, to: color); persist() }
        catch { lastError = (error as? TagBook.TagError)?.description ?? String(describing: error) }
    }

    func deleteTag(_ tagID: String) {
        book.deleteTag(tagID)
        persist()
    }

    func toggle(_ tagID: String, on subject: TagSubject) {
        do { try book.toggleTag(tagID, on: subject); persist() }
        catch { lastError = (error as? TagBook.TagError)?.description ?? String(describing: error) }
    }

    func clearTags(on subject: TagSubject) {
        book.clearTags(on: subject)
        persist()
    }

    /// Applies a tag to several subjects at once, or takes it off all of them.
    ///
    /// **Applies, rather than toggling each.** With a mixed selection — three rows tagged, three
    /// not — toggling row by row would tag half and untag half, which is nobody's reading of
    /// picking a tag with six rows selected. `BulkTagMenu` decides the direction from the whole
    /// selection: on every row means take it off, otherwise put it on. One `persist()` for the
    /// batch rather than one per subject.
    func apply(_ tagID: String, to subjects: [TagSubject], applied: Bool) {
        for subject in subjects {
            try? book.setTag(tagID, on: subject, to: applied)
        }
        persist()
    }

    /// Creates a tag and puts it on several subjects at once — "New Tag…" from the bulk bar.
    @discardableResult
    func createTag(name: String, color: TagColor, andApplyTo subjects: [TagSubject]) -> Tag? {
        guard let tag = createTag(name: name, color: color) else { return nil }
        apply(tag.id, to: subjects, applied: true)
        return tag
    }

    /// Drops assignments for things that no longer exist. Only ever called from the Tags
    /// manager's explicit **Clean Up**; see `TagBook.removeAssignments(ofKind:notIn:)` for why it
    /// is never automatic.
    @discardableResult
    func cleanUp(live: [ActivityKind: Set<String>]) -> Int {
        var removed = 0
        for (kind, ids) in live {
            removed += book.removeAssignments(ofKind: kind, notIn: ids)
        }
        if removed > 0 { persist() }
        return removed
    }

    // MARK: Storage

    /// Plist-native on purpose: an array of three-string dictionaries and a dictionary of string
    /// arrays are both things `defaults read` prints legibly and `PlistBuddy` can edit.
    private func persist() {
        guard let defaults else { return }
        defaults.set(book.tags.map { ["id": $0.id, "name": $0.name, "color": $0.color.rawValue] },
                     forKey: Self.definitionsKey)
        defaults.set(book.assignments, forKey: Self.assignmentsKey)
    }

    private static func read(from defaults: UserDefaults) -> TagBook {
        let rawTags = defaults.array(forKey: definitionsKey) as? [[String: String]] ?? []
        // A malformed entry is skipped, not defaulted. A tag with no name would render as a
        // blank pill you cannot click — worse than a tag that is simply gone, and the plist is
        // hand-editable, so this is a real input rather than a theoretical one.
        let tags: [Tag] = rawTags.compactMap { entry in
            guard let id = entry["id"], !id.isEmpty,
                  let name = entry["name"], !name.isEmpty,
                  let color = entry["color"].flatMap(TagColor.init(rawValue:))
            else { return nil }
            return Tag(id: id, name: name, color: color)
        }
        let rawAssignments = defaults.dictionary(forKey: assignmentsKey) as? [String: [String]] ?? [:]
        // Ids with no definition are dropped by `TagBook.tags(on:)` anyway; filtering the keys
        // here as well keeps a hand-edited plist from growing an assignment map full of subjects
        // that can never show a pill.
        let known = Set(tags.map(\.id))
        var assignments: [String: [String]] = [:]
        for (key, ids) in rawAssignments {
            guard TagSubject(storageKey: key) != nil else { continue }
            let kept = ids.filter(known.contains)
            if !kept.isEmpty { assignments[key] = kept }
        }
        return TagBook(tags: tags, assignments: assignments)
    }
}
