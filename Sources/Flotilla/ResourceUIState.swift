import SwiftUI
import FlotillaCore

/// List state for the Volumes, Networks and Images sections.
///
/// Owned by `MainWindowView`, like `ContainersUIState` and `MachinesUIState`, and for the same
/// reason: a section view is destroyed and rebuilt on every sidebar change, so a sort order or a
/// hidden column held as its own `@State` silently resets the moment you visit another section.
///
/// One generic class rather than three near-identical ones. `TableColumnCustomization` and
/// `KeyPathComparator` are both generic over the row type, so the only thing that differs
/// between these three sections is that type — which is exactly what a generic parameter is for.
/// `ContainersUIState` and `MachinesUIState` stay separate because they carry things these do
/// not (presentation toggle, state filter, activity band), and folding those in would mean a
/// class where two thirds of the properties are unused by any given caller.
@Observable
final class ResourceUIState<Row: Identifiable> {
    var search = ""
    var sortOrder: [KeyPathComparator<Row>]
    var columnCustomization = TableColumnCustomization<Row>()

    /// Name-ascending, per the 9 August decision that a table's default sort should be stable
    /// rather than clever — see `ContainersUIState`.
    init(sortOrder: [KeyPathComparator<Row>]) {
        self.sortOrder = sortOrder
    }
}
