import Foundation

/// The forms on screen that have edits nobody has saved, and what leaving them should do.
///
/// Every form's **Back** has asked before discarding since `FormEditTracker` landed. Every *other*
/// way out did not: choosing a sidebar section, a menu command or ⌘K that changes section, and
/// quitting all dropped a half-filled form without a word, because each of those routes lives
/// somewhere that cannot see the form's `@State`. So the form reports outwards instead — it marks
/// itself here while it is dirty — and every route asks this one value before it navigates.
///
/// It lives in `FlotillaCore`, Foundation-only, for the reason `BusySet` gives: the app target has
/// no test target, and "does a clean form leave without a prompt" belongs in the tested half.
///
/// A form is keyed by an opaque token rather than by its title, because two screens can share a
/// title (two "Edit Group" registrations while a service is open inside one) and a title can change
/// under a form that stays on screen (a DNS form's title is the domain being typed).
public struct UnsavedForms: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let token: UUID
        var title: String
    }

    /// Dirty forms only, in the order they became dirty. A clean form is removed rather than kept
    /// with a flag: "registered" and "would lose something" are then the same question, so nothing
    /// can answer one while meaning the other.
    private var entries: [Entry] = []

    public init() {}

    /// Called whenever a form's dirtiness or title may have changed. Idempotent; a clean form is
    /// forgotten, so a form whose edits are undone by hand stops prompting.
    public mutating func mark(_ token: UUID, title: String, isDirty: Bool) {
        guard isDirty else { return remove(token) }
        if let index = entries.firstIndex(where: { $0.token == token }) {
            entries[index].title = title
        } else {
            entries.append(Entry(token: token, title: title))
        }
    }

    /// The form saved, or left by any route. Removing a token that was never marked is not an
    /// error: a clean form's disappearance takes this path too.
    public mutating func remove(_ token: UUID) {
        entries.removeAll { $0.token == token }
    }

    /// Whether leaving now would lose something.
    public var isDirty: Bool { !entries.isEmpty }

    /// The dirty forms' titles, once each, in the order they became dirty.
    public var titles: [String] {
        var seen = Set<String>()
        return entries.map(\.title).filter { seen.insert($0).inserted }
    }

    /// The question to ask before leaving, or nil when there is nothing to lose — in which case
    /// the caller navigates without asking. One sentence for every route, so the sidebar, the menus
    /// and Quit cannot drift into three wordings of the same choice.
    public var discardQuestion: String? {
        let names = titles
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last
            : names.dropLast().joined(separator: ", ") + " and " + last
        return "Discard your changes to \(list)?"
    }
}
