import Foundation

/// What the Containers list shows, now that groups live in it (5 October, to-do item 4).
///
/// Docker Desktop lists a Compose stack as a row you expand to see its containers, and the owner
/// asked for the same: one list, groups and containers together, with the separate Groups section
/// gone. The rules for *which rows appear, and where* live here, Foundation-only, so they are
/// pinned by tests the app target cannot have. The view adds sorting, cells and actions.
///
/// The decisions this encodes, all the owner's:
///
/// - **A grouped container appears only inside its group.** Nothing is listed twice, so the row
///   count stays honest and a selection never holds the same container under two rows.
/// - **The kind filter can collapse the list back to one kind.** `.containers` lists *every*
///   container flat, members included, which is exactly what the Containers screen showed before
///   groups joined it. `.groups` lists only groups.
/// - **A group belongs to whichever state its members are in.** A partly running group is both
///   "running" and "stopped", because it is both, and hiding it from either filter would hide
///   the thing you were looking for.
public enum ContainerListing {

    public enum KindFilter: String, CaseIterable, Sendable {
        case all, groups, containers
    }

    public enum StateFilter: String, CaseIterable, Sendable {
        case all, running, stopped
    }

    /// One member of a group, with the container behind it if one exists. A member that has never
    /// been started has no container yet, and that is a real state rather than an error.
    public struct Member: Sendable, Equatable {
        public let member: GroupMember
        public let container: Container?

        public init(member: GroupMember, container: Container?) {
            self.member = member
            self.container = container
        }
    }

    /// One top-level row and, for a group, the members that go under it.
    public enum Item: Sendable, Equatable {
        case container(Container)
        /// `members` is already filtered to what should show when the group is expanded.
        /// `expandForSearch` is true when the search matched a member rather than the group, so
        /// the view can open the group to show why it is in the results.
        case group(ContainerGroup, members: [Member], expandForSearch: Bool)
    }

    /// The rows to show.
    ///
    /// - Parameters:
    ///   - containerMatches: whether a container matches the search; `nil` when there is no
    ///     search. A closure because matching includes the user's tags, which live in `TagBook`
    ///     and are the caller's to look up.
    ///   - groupMatches: the same, for the group's own name and tags.
    ///   - memberMatches: the same, for a member with no container yet, by the name and image the
    ///     group will create it from.
    public static func items(containers: [Container],
                             groups: [ContainerGroup],
                             kind: KindFilter,
                             state: StateFilter,
                             containerMatches: ((Container) -> Bool)? = nil,
                             groupMatches: ((ContainerGroup) -> Bool)? = nil,
                             memberMatches: ((GroupMember) -> Bool)? = nil) -> [Item] {
        let byName = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groupedNames = Set(groups.flatMap(\.memberNames))

        var items: [Item] = []

        if kind != .groups {
            // Flat under `.containers`, standalone-only under `.all`: in the merged view a member
            // is shown under its group instead.
            let pool = kind == .containers ? containers : containers.filter { !groupedNames.contains($0.id) }
            for container in pool where matches(container, state) && (containerMatches?(container) ?? true) {
                items.append(.container(container))
            }
        }

        guard kind != .containers else { return items }

        let running = Set(containers.filter(\.isRunning).map(\.id))
        let existing = Set(byName.keys)

        for group in groups {
            let members = group.members.map { Member(member: $0, container: byName[$0.name]) }
            let groupState = group.state(runningNames: running, existingNames: existing)
            guard matches(groupState, state) else { continue }

            // Members that pass the state filter. A partly running group under "Running" opens
            // onto its running members, not its stopped ones.
            var shown = members.filter { matches($0, state) }

            var expandForSearch = false
            if let containerMatches {
                let groupHit = groupMatches?(group) ?? false
                // A member matches by its container (name, state, tags) or, if it has none yet, by
                // the name and image the group will create it from.
                let memberHits = shown.filter { m in
                    if let container = m.container { return containerMatches(container) }
                    return memberMatches?(m.member) ?? false
                }
                if !groupHit {
                    guard !memberHits.isEmpty else { continue }
                    shown = memberHits
                    expandForSearch = true
                }
            }

            items.append(.group(group, members: shown, expandForSearch: expandForSearch))
        }
        return items
    }

    // MARK: State matching

    private static func matches(_ container: Container, _ filter: StateFilter) -> Bool {
        switch filter {
        case .all: true
        case .running: container.isRunning
        case .stopped: !container.isRunning
        }
    }

    /// A never-created member counts as stopped: it is not running, and "Stopped" is the filter
    /// someone uses to find what needs starting.
    private static func matches(_ member: Member, _ filter: StateFilter) -> Bool {
        guard let container = member.container else { return filter != .running }
        return matches(container, filter)
    }

    private static func matches(_ state: GroupState, _ filter: StateFilter) -> Bool {
        switch filter {
        case .all: return true
        case .running:
            if case .running = state { return true }
            if case .partial(let up, _) = state { return up > 0 }
            return false
        case .stopped:
            switch state {
            case .stopped, .notCreated, .partial: return true
            case .running, .empty: return false
            }
        }
    }
}
