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
        Self.question(about: titles)
    }

    /// The question for leaving **one** form, or nil when that form has nothing to lose.
    ///
    /// Back and Cancel on a nested form lose only that form's edits: Add Service inside New Group
    /// takes the service's changes and leaves the group's draft where it is. Asking
    /// `discardQuestion` there would name a form the user is not leaving. The sidebar and Quit
    /// leave everything and keep using `discardQuestion`; the wording is shared so the two cannot
    /// drift apart.
    public func discardQuestion(for token: UUID) -> String? {
        guard let entry = entries.first(where: { $0.token == token }) else { return nil }
        return Self.question(about: [entry.title])
    }

    private static func question(about names: [String]) -> String? {
        guard let last = names.last else { return nil }
        let list = names.count == 1 ? last
            : names.dropLast().joined(separator: ", ") + " and " + last
        return "Discard your changes to \(list)?"
    }
}

extension UnsavedForms {
    /// One string for a form's fields, for comparing against the one taken when it opened.
    ///
    /// Length-prefixed rather than joined on a separator, so no two field lists can collide: a
    /// separator character typed into a field — a newline in a multi-line one — would otherwise
    /// let "ab" + "c" read the same as "a" + "bc", and an edit go unnoticed.
    public static func signature(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

extension GroupMember {
    /// The Add Service / Edit Service screen's edit signature: every field it edits or carries, as
    /// the user typed it.
    ///
    /// The text, not the parsed member: a half-typed `sh -c 'echo` does not split, parses to no
    /// command at all, and would read as untouched on a service that had none.
    public static func editSignature(name: String, image: String, ports: String, env: String,
                                     volumes: String, command: String, cpus: String,
                                     memory: String, readyPort: String,
                                     secretEnv: [SecretEnv]) -> String {
        UnsavedForms.signature([name, image, ports, env, volumes, command, cpus, memory, readyPort]
                               + secretEnv.flatMap { [$0.name, $0.secret] })
    }

    /// The signature of this member as the service screen first shows it — which is also what the
    /// group's own signature compares per member, so a service saved with only its environment
    /// changed still leaves the group with something to lose.
    public var editSignature: String {
        Self.editSignature(name: name, image: image,
                           ports: ports.joined(separator: "\n"), env: env.joined(separator: "\n"),
                           volumes: volumes.joined(separator: "\n"), command: ShellWords.join(command),
                           cpus: cpus.map(String.init) ?? "", memory: memory ?? "",
                           readyPort: readyPort.map(String.init) ?? "", secretEnv: secretEnv)
    }
}
