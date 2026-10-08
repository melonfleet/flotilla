import Foundation

/// A tag's colour, from the fixed palette.
///
/// **Seven colours, and no eighth.** These are Finder's own tag colours, and the constraint is
/// the point: a tag is something you recognise in half a glance across a table of forty rows,
/// which only works while the whole vocabulary fits in visual memory. An open colour well gives
/// you two greens you cannot tell apart at 8pt, and then the pill stops answering the question it
/// was added for. Finder settled this a decade ago and users already know the swatches.
///
/// The raw values are the storage format — they are written to `UserDefaults` and read back by
/// `defaults read dev.melonfleet.Flotilla tagDefinitions`, so they are names a person can read
/// and type, not indices. Renaming one is a migration, not an edit.
public enum TagColor: String, Codable, CaseIterable, Sendable, Hashable {
    case red, orange, yellow, green, blue, purple, grey

    /// Title case for display. Spelled out here rather than capitalised at the call site so the
    /// app and any future export agree on one spelling — and so `grey` cannot become "Gray" on
    /// one screen and "Grey" on another.
    public var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .grey: "Grey"
        }
    }
}

/// One tag: a name, a colour, and a stable identity.
///
/// `id` is **not** the name. Renaming a tag must not detach it from everything it is on, and
/// keying assignments by name would mean exactly that — or, worse, a rename that silently
/// re-tags whatever else happened to be called by the new name. So the id is minted once and
/// never changes, and the name is free to be edited.
public struct Tag: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public var name: String
    public var color: TagColor

    public init(id: String = UUID().uuidString, name: String, color: TagColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// Which resource a tag is on. `ActivityKind` already names the five kinds this app manages and
/// is already the key `BusySet` and the activity feed use, so tags key on the same vocabulary
/// rather than inventing a sixth list of "the things Flotilla has".
///
/// A tag is attached to a **kind and an id**, never to an id alone: a volume called `web` and a
/// container called `web` are different objects, and the activity feed learned that the hard way
/// (`events(for:kind:)` was subject-only, and a container listed a volume's history).
/// Not `Codable`, deliberately: it is never encoded as a struct. `storageKey` **is** its wire
/// form — one readable string, which is what lets the assignment map be a plist dictionary
/// rather than an opaque blob. Making it `Codable` would mean teaching `ActivityKind` to encode
/// itself, widening a core type for a capability nothing needs.
public struct TagSubject: Sendable, Equatable, Hashable {
    public let kind: ActivityKind
    public let id: String

    public init(kind: ActivityKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The storage key. One string so the assignment map is a plain dictionary a plist can hold
    /// and a person can read: `container/web`, `volume/pgdata`.
    ///
    /// `/` is the separator because no `ActivityKind` raw value contains one. Resource ids may
    /// (an image reference is `docker.io/library/nginx:latest`), which is why the split below is
    /// on the **first** separator only.
    public var storageKey: String { "\(kind.rawValue)/\(id)" }

    public init?(storageKey: String) {
        guard let slash = storageKey.firstIndex(of: "/") else { return nil }
        guard let kind = ActivityKind(rawValue: String(storageKey[..<slash])) else { return nil }
        let id = String(storageKey[storageKey.index(after: slash)...])
        guard !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }
}

/// Every tag the user has defined, and everything each one is on.
///
/// **Pure, and deliberately in the core.** Tagging is all rules and no I/O — what a legal name
/// is, what happens to assignments when a tag is deleted, whether two tags may share a name —
/// and this target is the one with a test target, which is the same argument `DeletePolicy` and
/// `ActivityKind` made when they moved here. The app layer adds persistence and colour; nothing
/// here knows what a `Color` is.
///
/// ## What this does not do
///
/// It does not know whether a tagged thing still exists. A container you tagged and then deleted
/// leaves its assignment behind, and that is on purpose: the runtime list is refreshed on a
/// poll, so pruning against it would mean a momentary read failure silently discarding the
/// user's tags. `subjects(withoutKinds:)` and the Tags manager's usage counts read the
/// assignments as written; the manager offers an explicit **Clean Up** for the rest, because
/// deleting someone's data is a decision they make, not a side effect of a poll.
public struct TagBook: Codable, Sendable, Equatable {

    /// Defined tags, in the order they should be offered. Insertion order, not alphabetical:
    /// the predefined set has a deliberate order (the colour wheel), and a user's own tags
    /// arriving at the end is what makes "the one I just made" findable.
    public private(set) var tags: [Tag]

    /// Tag ids per subject, keyed by `TagSubject.storageKey`.
    ///
    /// Ids rather than `Tag` values so a rename or a recolour is one edit rather than a sweep,
    /// and so a stale id is inert rather than a second, divergent definition of a tag.
    public private(set) var assignments: [String: [String]]

    public init(tags: [Tag] = [], assignments: [String: [String]] = [:]) {
        self.tags = tags
        self.assignments = assignments
    }

    // MARK: The starting set

    /// The tags a new install begins with.
    ///
    /// **Predefined, because an empty tag system is a feature nobody finds.** The first time you
    /// right-click a container, "Tags ▸ (nothing here)" teaches you that the menu is empty; a
    /// row of seven ready colours teaches you what tags are for. They are ordinary tags
    /// afterwards — renameable, recolourable, deletable — not a protected tier, so there is no
    /// second class of tag to reason about.
    ///
    /// The names are jobs, not colours. "Red" as a tag name says nothing you cannot already see;
    /// "Production" is the thing you actually wanted to mark. Seven, one per colour, so the
    /// palette is fully demonstrated and no colour looks unavailable.
    public static let starterTags: [Tag] = [
        Tag(id: "starter.production", name: "Production", color: .red),
        Tag(id: "starter.staging", name: "Staging", color: .orange),
        Tag(id: "starter.needs-attention", name: "Needs attention", color: .yellow),
        Tag(id: "starter.healthy", name: "Healthy", color: .green),
        Tag(id: "starter.development", name: "Development", color: .blue),
        Tag(id: "starter.experiment", name: "Experiment", color: .purple),
        Tag(id: "starter.archive", name: "Archive", color: .grey),
    ]

    public static var starter: TagBook { TagBook(tags: starterTags) }

    // MARK: Reading

    public func tag(id: String) -> Tag? { tags.first { $0.id == id } }

    /// The tags on one subject, in the order `tags` defines rather than the order they were
    /// applied — so two rows carrying the same pair of tags draw them the same way round, which
    /// is what makes a column of pills scannable at all.
    ///
    /// Ids with no definition are dropped here rather than rendered as a blank pill. That is the
    /// one place a stale id can reach the screen, and dropping it is why a hand-edited plist
    /// cannot produce a tag with no name.
    public func tags(on subject: TagSubject) -> [Tag] {
        let ids = Set(assignments[subject.storageKey] ?? [])
        return tags.filter { ids.contains($0.id) }
    }

    public func isTagged(_ subject: TagSubject, with tagID: String) -> Bool {
        assignments[subject.storageKey]?.contains(tagID) == true
    }

    /// How many subjects carry this tag. Drives the manager's usage column and the warning on
    /// delete — "Delete" and "Delete, removing it from 12 things" are different decisions.
    public func usageCount(of tagID: String) -> Int {
        assignments.values.count { $0.contains(tagID) }
    }

    /// Every subject carrying this tag. Used by the manager to say *what* a tag is on, and by
    /// the section filters.
    public func subjects(taggedWith tagID: String) -> [TagSubject] {
        assignments
            .filter { $0.value.contains(tagID) }
            .compactMap { TagSubject(storageKey: $0.key) }
            .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    /// Subjects whose kind is in `kinds` — the live inventory a caller can check against when it
    /// wants to know which assignments no longer point at anything.
    public func subjects(ofKind kind: ActivityKind) -> [TagSubject] {
        assignments.keys
            .compactMap { TagSubject(storageKey: $0) }
            .filter { $0.kind == kind && !(assignments[$0.storageKey] ?? []).isEmpty }
            .sorted { $0.id < $1.id }
    }

    // MARK: Defining tags

    /// The longest a tag name may be.
    ///
    /// A pill sits in a table column beside a name and a state; past roughly this length it
    /// stops being a pill and starts being a second name column. Enforced here rather than by
    /// truncating in the view, so the stored value is the value the user sees.
    public static let maximumNameLength = 32

    public enum TagError: Error, Equatable, CustomStringConvertible {
        case emptyName
        case nameTooLong(Int)
        case duplicateName(String)
        case unknownTag(String)

        public var description: String {
            switch self {
            case .emptyName:
                "A tag needs a name."
            case .nameTooLong(let limit):
                "A tag name can be at most \(limit) characters."
            case .duplicateName(let name):
                "There is already a tag called ‘\(name)’."
            case .unknownTag(let id):
                "‘\(id)’ is not a tag that exists."
            }
        }
    }

    /// Trims and validates a proposed name. Comparison is case- and diacritic-insensitive,
    /// because "Prod" and "prod" as two separate tags is not a distinction anybody means to
    /// draw — it is a typo that has become permanent.
    private func validate(name raw: String, excluding excluded: String?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagError.emptyName }
        guard name.count <= Self.maximumNameLength else {
            throw TagError.nameTooLong(Self.maximumNameLength)
        }
        let clash = tags.contains {
            $0.id != excluded
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
        }
        guard !clash else { throw TagError.duplicateName(name) }
        return name
    }

    /// Whether a proposed name would be accepted, without throwing. The create field uses this
    /// to explain itself *before* the button is pressed — this app's standing rule that a
    /// refused control must say why it is refusing.
    public func problem(withName raw: String, excluding excluded: String? = nil) -> String? {
        do { _ = try validate(name: raw, excluding: excluded); return nil }
        catch let error as TagError { return error.description }
        catch { return String(describing: error) }
    }

    @discardableResult
    public mutating func createTag(name: String, color: TagColor) throws -> Tag {
        let tag = Tag(name: try validate(name: name, excluding: nil), color: color)
        tags.append(tag)
        return tag
    }

    public mutating func rename(_ tagID: String, to name: String) throws {
        guard let index = tags.firstIndex(where: { $0.id == tagID }) else {
            throw TagError.unknownTag(tagID)
        }
        tags[index].name = try validate(name: name, excluding: tagID)
    }

    public mutating func recolour(_ tagID: String, to color: TagColor) throws {
        guard let index = tags.firstIndex(where: { $0.id == tagID }) else {
            throw TagError.unknownTag(tagID)
        }
        tags[index].color = color
    }

    /// Deletes a tag **and every assignment of it**.
    ///
    /// Both halves, always. Leaving the assignments behind would make a deleted tag come back
    /// the moment someone created a new tag that happened to be minted with the same id — which
    /// cannot happen with UUIDs, but "cannot happen" is how orphaned rows accumulate until it
    /// can. The caller is expected to have said how many things this affects first; see
    /// `usageCount(of:)`.
    public mutating func deleteTag(_ tagID: String) {
        tags.removeAll { $0.id == tagID }
        for key in assignments.keys {
            assignments[key]?.removeAll { $0 == tagID }
            if assignments[key]?.isEmpty == true { assignments[key] = nil }
        }
    }

    // MARK: Assigning

    /// Puts a tag on a subject, or takes it off. Idempotent in both directions: applying a tag
    /// twice is not an error and does not produce two pills.
    ///
    /// An unknown tag id is refused rather than stored. An assignment to a tag that does not
    /// exist is invisible — `tags(on:)` drops it — so accepting one would be a silent no-op,
    /// which is the failure shape this codebase keeps finding.
    public mutating func setTag(_ tagID: String, on subject: TagSubject, to applied: Bool) throws {
        guard tags.contains(where: { $0.id == tagID }) else { throw TagError.unknownTag(tagID) }
        let key = subject.storageKey
        var ids = assignments[key] ?? []
        if applied {
            guard !ids.contains(tagID) else { return }
            ids.append(tagID)
        } else {
            ids.removeAll { $0 == tagID }
        }
        assignments[key] = ids.isEmpty ? nil : ids
    }

    public mutating func toggleTag(_ tagID: String, on subject: TagSubject) throws {
        try setTag(tagID, on: subject, to: !isTagged(subject, with: tagID))
    }

    /// Removes every tag from a subject — the menu's "Clear Tags", and what a section calls when
    /// the user deletes the thing itself and says to forget it.
    public mutating func clearTags(on subject: TagSubject) {
        assignments[subject.storageKey] = nil
    }

    /// Drops assignments for subjects of `kind` whose id is not in `live`.
    ///
    /// Explicit, never automatic. The inventory this is checked against comes from a poll that
    /// can fail or return early, and a sweep on every refresh would quietly delete the user's
    /// tags the first time the runtime hiccuped. Returns how many were dropped so the caller can
    /// say so.
    @discardableResult
    public mutating func removeAssignments(ofKind kind: ActivityKind,
                                           notIn live: Set<String>) -> Int {
        var removed = 0
        for key in assignments.keys {
            guard let subject = TagSubject(storageKey: key), subject.kind == kind else { continue }
            guard !live.contains(subject.id) else { continue }
            assignments[key] = nil
            removed += 1
        }
        return removed
    }
}
