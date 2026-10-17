import SwiftUI
import FlotillaCore

/// View state for the Machines screen, owned by `MainWindowView` for exactly the reason
/// `ContainersUIState` is: the detail views are destroyed and recreated on every sidebar
/// change, so `@State` held inside `MachinesView` is lost the moment you visit Images and
/// come back. Filter, search and sort all have to outlive the view that shows them.
///
/// Deliberately a **separate** object from `ContainersUIState` rather than a generic one
/// shared between them. The two screens sort on different keys and filter differently — a
/// shared type would have to be parameterised on all of that to save one small class.
@Observable
final class MachinesUIState {

    var filter: MachinesView.Filter = .all
    var search = ""

    /// **By name**, not by state.
    ///
    /// This was running-first, and running-first has a flaw that only shows up in use: stopping
    /// a machine makes its row jump to the bottom of the list, so the thing you were working on
    /// moves the instant you act on it. With a handful of machines that is annoying; with a
    /// screenful it means chasing rows up and down. The owner called it, and he is right.
    ///
    /// Nothing is lost — State is still a sort key, so running-first is two clicks away. A
    /// stable default and an available sort beat a clever default.
    ///
    /// Since Q56 the list is two-line rows with no headers, so the sort is a **key and a
    /// direction** from the Sort menu, exactly as on Containers, and `sortOrder` is derived from
    /// them. The hideable columns went with the table.
    var sortKey: MachinesView.SortKey = .name
    var sortAscending = true

    var sortOrder: [KeyPathComparator<ContainerMachine>] {
        sortKey.comparators(ascending: sortAscending)
    }
}

extension ContainerMachine {
    /// Running first, then the two on their way somewhere, then stopped, then what the runtime
    /// cannot name. A plain `status` sort would put "running" after "stopped" alphabetically,
    /// which is backwards from what you want. Just the rank: the Sort menu breaks ties on name,
    /// so a descending State sort reverses the groups and not the names inside them.
    var stateRank: Int {
        switch state {
        case .running: 0
        case .starting, .stopping: 1
        case .stopped: 2
        case .unknown, .other: 3
        }
    }
}
