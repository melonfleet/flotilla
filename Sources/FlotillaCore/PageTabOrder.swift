import Foundation

/// What a page tab *is*, in the one order every page's pill draws it (Kamal, 18 October: "the icons
/// and pills across all the sections should be in the same order, so the user isn't confused about
/// where one thing is versus another").
///
/// The order is the declaration order, and it is the rule:
///
///     Overview · own views · Settings · Logs · Inspect  |  Terminal · Files · Screen Sharing
///
/// - **Overview** is first everywhere: it is where a page opens, and ⌘1 is always it.
/// - **Own views** are what only that kind of thing has — a container's Processes, a Mac's System,
///   Flotilla and Updates. They sit next to Overview because they are more of the same: reading
///   the thing, in more depth.
/// - **Settings** follows them: what you can change comes after what you can read, and before the
///   record of what happened.
/// - **Logs** — and a Mac's Activity, which is its log — then **Inspect**, which closes the data
///   group as the raw record behind everything to its left. Inspect is last so the JSON is always
///   at the same end, whatever a page has in its middle.
/// - After the divider, **the ways in**: a session first (a container's Terminal, a machine's
///   shell, a host's SSH — the same kind of thing under three names), then Files, then Screen
///   Sharing. These do something rather than show something, which is why they are fenced off,
///   and they are in order of how far in they reach: a prompt, a filesystem, the whole screen.
///
/// So a container is Overview · Processes · Logs · Inspect | Terminal · Files, a machine is
/// Overview · Settings · Logs · Inspect | Terminal, and a host is Overview · System · Flotilla ·
/// Updates · Settings · Activity | SSH · Files · Screen Sharing. Where two pages share a kind,
/// it is in the same place relative to everything else both have.
///
/// Foundation-only, so the rule is tested on Linux with everything else; `PageTabs` arranges by it
/// and `Scripts/check-tab-order.sh` holds every page's tab enum to it.
public enum PageTabKind: Int, CaseIterable, Comparable, Sendable {
    case overview
    case view
    case settings
    case history
    case inspect
    case session
    case files
    case screen

    public enum Group: Sendable, Equatable {
        /// Reading the thing: Overview to Inspect.
        case data
        /// Getting into it: a session, its files, its screen.
        case access
    }

    public var group: Group { self < .session ? .data : .access }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PageTabOrder {
    /// `items` in canonical order. Stable: two tabs of one kind (a host's System, Flotilla and
    /// Updates are all `.view`) keep the order they were given in.
    public static func arranged<Item>(_ items: [Item], kind: (Item) -> PageTabKind) -> [Item] {
        items.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (kind(lhs.element), kind(rhs.element))
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
    }

    /// True when `kinds` is already in canonical order — what a page's tab list must be.
    public static func isCanonical(_ kinds: [PageTabKind]) -> Bool {
        zip(kinds, kinds.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// For each tab of an arranged list, whether a divider goes before it: at the first access tab,
    /// and only when a data tab precedes it. A page with only one group draws none.
    public static func dividers(_ kinds: [PageTabKind]) -> [Bool] {
        kinds.indices.map { index in
            index > 0 && kinds[index].group == .access && kinds[index - 1].group == .data
        }
    }
}
