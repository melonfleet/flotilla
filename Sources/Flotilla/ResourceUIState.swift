import SwiftUI
import FlotillaCore

/// List state for the sections on two-line rows that have no lifecycle of their own to filter by:
/// Images, Volumes, Networks, Hosts, Registries, DNS and Clusters.
///
/// Owned by `MainWindowView`, like `ContainersUIState` and `MachinesUIState`, and for the same
/// reason: a section view is destroyed and rebuilt on every sidebar change, so a sort or a filter
/// held as its own `@State` silently resets the moment you visit another section.
///
/// One generic class rather than seven near-identical ones; `Row` names the section it is for.
/// `ContainersUIState` and `MachinesUIState` stay separate because they carry things these do
/// not (a state filter, groups), and folding those in would mean a class where most of the
/// properties are unused by any given caller.
@Observable
final class ResourceUIState<Row: Identifiable> {
    var search = ""

    /// The split's expand button and narrow-window state, for the session (Q58) — here so a widened
    /// page is still widened after a visit to another section.
    let pane = PaneState()

    /// The Sort menu's key, as the section's `RowSortKey` raw value, for the reason `filterID` is
    /// a string: the key enum is the owning view's own. `nil` is that view's default, which is
    /// name everywhere. Read it with `sortKey(default:)`; the menu is `sortMenu(default:)`.
    var sortKeyID: String?
    var sortAscending = true

    /// Rows the user has expanded, by id.
    ///
    /// Only Groups has anything to expand today — a group's services are rows *inside* its row.
    /// It lives here rather than as the section's own `@State` for the reason at the top of this
    /// file: a section view is destroyed and rebuilt on every sidebar change, so an expanded
    /// group would silently collapse the moment you looked at Containers and came back.
    var expandedIDs: Set<String> = []

    /// Group rows the user has closed — Hosts' groups start open, so it keeps the closed ones.
    var collapsedIDs: Set<String> = []

    /// The selected filter, stored as its **id string** rather than a typed enum.
    ///
    /// Each section's filter means something different — built-in versus user-defined for
    /// networks, tagged versus untagged for images, per-driver for volumes — and several are
    /// derived from the data rather than fixed. Making this generic over a second `Filter` type
    /// would parameterise every use of the class to express something only the owning view reads
    /// and writes. A string id is the honest amount of structure: `"all"` is the reset, and the
    /// view that defines the options is the view that interprets them.
    var filterID = "all"

    /// Which Mac's rows to list: `nil` for every host (PLAN.md Phase C).
    var hostFilter: HostRef?

    init() {}
}
