import Foundation
import Testing
@testable import FlotillaCore

/// Pins the tagging rules.
///
/// The rules are all here rather than in the app layer for exactly this reason: the app target
/// has no test target, and "what happens to assignments when a tag is deleted" is not something
/// to find out by deleting a tag.
@Suite("Tagging")
struct TagBookTests {

    private func book() -> TagBook { .starter }
    private let web = TagSubject(kind: .container, id: "web")

    // MARK: Subjects

    /// The bug this type exists to prevent: the activity feed was keyed on the subject alone, so
    /// a container called `web` showed a volume called `web`'s history. A tag on one must not
    /// appear on the other.
    @Test("a container and a volume of the same name are different subjects")
    func kindIsPartOfIdentity() throws {
        var book = book()
        let container = TagSubject(kind: .container, id: "web")
        let volume = TagSubject(kind: .volume, id: "web")
        #expect(container != volume)

        try book.setTag("starter.production", on: container, to: true)
        #expect(book.isTagged(container, with: "starter.production"))
        #expect(!book.isTagged(volume, with: "starter.production"))
    }

    /// An image reference contains slashes, and the storage key uses one as its separator. The
    /// split has to be on the **first** slash or every `docker.io/library/nginx` round-trips
    /// wrong.
    @Test("a storage key round-trips through ids that contain slashes")
    func storageKeyRoundTrip() throws {
        for subject in [TagSubject(kind: .container, id: "web"),
                        TagSubject(kind: .image, id: "docker.io/library/nginx:latest"),
                        TagSubject(kind: .volume, id: "a/b/c")] {
            let key = subject.storageKey
            #expect(TagSubject(storageKey: key) == subject, Comment(rawValue: key))
        }
    }

    @Test("a malformed storage key is rejected rather than guessed at")
    func storageKeyRejectsRubbish() {
        for key in ["", "web", "nosuchkind/web", "container/", "/web"] {
            #expect(TagSubject(storageKey: key) == nil, Comment(rawValue: "accepted '\(key)'"))
        }
    }

    // MARK: Names

    @Test("a name must be present, short enough, and not already taken")
    func nameRules() {
        var book = book()
        #expect(throws: TagBook.TagError.emptyName) {
            try book.createTag(name: "   ", color: .red)
        }
        #expect(throws: TagBook.TagError.nameTooLong(TagBook.maximumNameLength)) {
            try book.createTag(name: String(repeating: "x", count: 33), color: .red)
        }
        #expect(throws: TagBook.TagError.duplicateName("Production")) {
            try book.createTag(name: "Production", color: .blue)
        }
    }

    /// "Prod" and "prod" as two separate tags is not a distinction anybody means to draw.
    @Test("duplicate detection ignores case and diacritics")
    func duplicatesAreLoose() {
        var book = book()
        #expect(book.problem(withName: "production") != nil)
        #expect(book.problem(withName: "PRODUCTION") != nil)
        #expect(book.problem(withName: "Prodúction") != nil)
        #expect(book.problem(withName: "Production 2") == nil)
        #expect(throws: Never.self) { try book.createTag(name: "  Spaced  ", color: .red) }
        #expect(book.tags.last?.name == "Spaced")
    }

    /// A tag being renamed must not collide with *itself*.
    @Test("renaming a tag to its own name is allowed")
    func renameToSelf() throws {
        var book = book()
        try book.rename("starter.production", to: "Production")
        #expect(book.tag(id: "starter.production")?.name == "Production")
    }

    /// Identity is minted once. Keying assignments by name would detach every tagged thing on a
    /// rename — which is the whole reason `Tag.id` is not the name.
    @Test("a rename keeps every assignment")
    func renameKeepsAssignments() throws {
        var book = book()
        try book.setTag("starter.production", on: web, to: true)
        try book.rename("starter.production", to: "Live")
        #expect(book.tags(on: web).map(\.name) == ["Live"])
    }

    // MARK: Assigning

    @Test("applying a tag twice does not produce two of it")
    func idempotentApply() throws {
        var book = book()
        try book.setTag("starter.production", on: web, to: true)
        try book.setTag("starter.production", on: web, to: true)
        #expect(book.tags(on: web).count == 1)
    }

    @Test("removing a tag that is not applied is not an error")
    func idempotentRemove() throws {
        var book = book()
        try book.setTag("starter.production", on: web, to: false)
        #expect(book.tags(on: web).isEmpty)
        // The subject's entry goes with its last tag, so the map does not grow a
        // row of empty arrays for everything that was ever tagged.
        #expect(book.assignments.isEmpty)
    }

    /// An assignment to a tag that does not exist is invisible — `tags(on:)` drops it — so
    /// accepting one would be a silent no-op.
    @Test("an unknown tag id is refused rather than stored")
    func unknownTagRefused() {
        var book = book()
        #expect(throws: TagBook.TagError.unknownTag("nope")) {
            try book.setTag("nope", on: web, to: true)
        }
        #expect(book.assignments.isEmpty)
    }

    /// Two rows carrying the same pair of tags must draw them the same way round, or a column of
    /// pills is not scannable.
    @Test("tags come back in definition order, not application order")
    func stableOrder() throws {
        var book = book()
        let other = TagSubject(kind: .container, id: "db")
        try book.setTag("starter.archive", on: web, to: true)
        try book.setTag("starter.production", on: web, to: true)
        try book.setTag("starter.production", on: other, to: true)
        try book.setTag("starter.archive", on: other, to: true)
        #expect(book.tags(on: web).map(\.id) == book.tags(on: other).map(\.id))
        #expect(book.tags(on: web).map(\.id) == ["starter.production", "starter.archive"])
    }

    @Test("toggling flips whichever way the tag currently is")
    func toggle() throws {
        var book = book()
        try book.toggleTag("starter.healthy", on: web)
        #expect(book.isTagged(web, with: "starter.healthy"))
        try book.toggleTag("starter.healthy", on: web)
        #expect(!book.isTagged(web, with: "starter.healthy"))
    }

    // MARK: Deleting

    @Test("deleting a tag takes every assignment of it with it")
    func deleteCascades() throws {
        var book = book()
        let other = TagSubject(kind: .machine, id: "default")
        try book.setTag("starter.production", on: web, to: true)
        try book.setTag("starter.staging", on: web, to: true)
        try book.setTag("starter.production", on: other, to: true)

        book.deleteTag("starter.production")
        #expect(book.tag(id: "starter.production") == nil)
        #expect(book.tags(on: web).map(\.id) == ["starter.staging"])
        // The last tag off a subject takes the subject's entry with it, so the map does not grow
        // a row of empty arrays for everything that was ever tagged.
        #expect(book.assignments[other.storageKey] == nil)
        #expect(book.usageCount(of: "starter.production") == 0)
    }

    @Test("usage counts subjects, not assignments")
    func usageCount() throws {
        var book = book()
        try book.setTag("starter.production", on: web, to: true)
        try book.setTag("starter.staging", on: web, to: true)
        #expect(book.usageCount(of: "starter.production") == 1)
        try book.setTag("starter.production",
                        on: TagSubject(kind: .container, id: "db"), to: true)
        #expect(book.usageCount(of: "starter.production") == 2)
    }

    // MARK: Clean-up

    /// The one destructive sweep, and it must only ever touch the kind it was asked about — a
    /// container list that came back does not license deleting a machine's tags.
    @Test("clean-up drops only the named kind, and only what is missing")
    func cleanUpIsNarrow() throws {
        var book = book()
        let gone = TagSubject(kind: .container, id: "deleted")
        let machine = TagSubject(kind: .machine, id: "never-polled")
        try book.setTag("starter.production", on: web, to: true)
        try book.setTag("starter.production", on: gone, to: true)
        try book.setTag("starter.production", on: machine, to: true)

        let removed = book.removeAssignments(ofKind: .container, notIn: ["web"])
        #expect(removed == 1)
        #expect(book.isTagged(web, with: "starter.production"))
        #expect(!book.isTagged(gone, with: "starter.production"))
        // Untouched: it is a machine, and machines were not what was asked about.
        #expect(book.isTagged(machine, with: "starter.production"))
    }

    // MARK: The starting set

    /// Seven, one per colour, so the palette is fully demonstrated — and every id distinct, or
    /// two starter tags would be one tag.
    @Test("the starter set covers every colour exactly once with unique ids")
    func starterSet() {
        let tags = TagBook.starterTags
        #expect(Set(tags.map(\.color)) == Set(TagColor.allCases))
        #expect(tags.count == TagColor.allCases.count)
        #expect(Set(tags.map(\.id)).count == tags.count)
        #expect(Set(tags.map(\.name)).count == tags.count)
        // No starter tag is named after its own colour: a tag called "Red" says nothing you
        // cannot already see.
        for tag in tags {
            #expect(tag.name.lowercased() != tag.color.rawValue)
        }
    }
}

/// A group is a sixth tag subject (Q21), and it keys on the group's **id** rather than its name
/// so a rename keeps every pill. The id is a UUID, which is the case worth pinning: `storageKey`
/// splits on the *first* slash, and a subject id is free to contain more of them.
@Test func aGroupIsATagSubjectAndRoundTripsThroughItsStorageKey() throws {
    let id = "75A7241F-71F4-42B0-9E1D-BCFC223F82A3"
    let subject = TagSubject(kind: .group, id: id)
    #expect(subject.storageKey == "group/\(id)")

    let restored = try #require(TagSubject(storageKey: subject.storageKey))
    #expect(restored == subject)

    // A group and a container may share a name without sharing tags — the same collision the
    // kind exists to prevent between a volume and a container.
    var book = TagBook.starter
    let tag = try #require(book.tags.first)
    try book.setTag(tag.id, on: TagSubject(kind: .group, id: "shop"), to: true)
    #expect(book.tags(on: TagSubject(kind: .container, id: "shop")).isEmpty)
    #expect(book.tags(on: TagSubject(kind: .group, id: "shop")).count == 1)
}
