import SwiftUI
import FlotillaCore

/// View state for the containers screen that must **survive navigating away and back**.
///
/// `NavigationSplitView`'s detail switches on the sidebar selection, so moving to Images and
/// returning destroys `ContainersView` and builds a new one. Anything held in its `@State`
/// resets — which silently threw away the user's sort order, filter and search text every time
/// they looked at another section.
///
/// The Docker Desktop study is what surfaced this: Docker shipped the same class of bug
/// (hidden columns re-enabling themselves, `docker/for-mac#6391`) and he flagged our surface
/// as overlapping directly. Checking found we had it too. Owning this state above the
/// navigation switch is the fix — `MainWindowView` is the window's root and is created once.
///
/// Deliberately **not** in `SettingsStore`: `research/FEATURES.md` keeps window and UI state
/// separate from preferences so that "reset preferences" cannot rearrange your table. This is
/// per-session state; persisting it across launches belongs with the window-state work, and
/// this class is the natural place to do it when that happens.
@MainActor
@Observable
final class ContainersUIState {

    var filter: ContainersView.Filter = .all
    /// Groups, containers or both — the merged list's second filter (5 October). `.containers`
    /// lists every container flat, which is what this screen showed before groups joined it.
    var kindFilter: ContainerListing.KindFilter = .all
    /// Which Macs' containers to list: `nil` for all, else one host (PLAN.md Phase C).
    var hostFilter: HostRef?
    var search = ""

    /// The split's expand button and narrow-window state, for the session (Q58) — here so a widened
    /// page is still widened after a visit to another section.
    let pane = PaneState()

    /// Groups the user has opened, by group id. Here for the reason everything else is: the section
    /// view is rebuilt on every sidebar change, and an open group would silently close.
    var expandedGroupIDs: Set<String> = []

    /// **By name**, not running-first.
    ///
    /// This reverses the running-first default from `DECISIONS.md` Q2, at the owner's direction on
    /// 9 August. Q2's argument was that the containers you can act on should be at the top; the
    /// argument against it is that acting on one *moves it*, so the row you just clicked leaves
    /// the place you were looking. With a long list that turns every stop into a hunt.
    ///
    /// State is still a sort key, so running-first is two clicks away.
    ///
    /// Since Q56 the list is two-line rows with no column headers, so the sort is a **key and a
    /// direction** chosen from the Sort menu, and `sortOrder` is derived from them. Held here, with
    /// the rest of the screen's session state, for the same reason as everything else in this class.
    var sortKey: ContainersView.SortKey = .name
    var sortAscending = true

    /// Comparators over `ContainersView.ContainerRow`, not `Container` — the row carries the
    /// sampled CPU and memory figures, and since 5 October it is a group or a member as often as a
    /// container, so it carries its own sort keys for all three.
    var sortOrder: [KeyPathComparator<ContainersView.ContainerRow>] {
        sortKey.comparators(ascending: sortAscending)
    }
}
