import SwiftUI
import FlotillaCore

/// View state for the Machines screen, owned by `MainWindowView` for exactly the reason
/// `ContainersUIState` is: the detail views are destroyed and recreated on every sidebar
/// change, so `@State` held inside `MachinesView` is lost the moment you visit Images and
/// come back. Presentation, filter, search, sort and column visibility all have to outlive
/// the view that shows them.
///
/// Deliberately a **separate** object from `ContainersUIState` rather than a generic one
/// shared between them. The two screens sort on different key paths and have different
/// columns, and the machine screen's default sort is not the container screen's — a shared
/// type would have to be parameterised on all of that to save one small class.
@Observable
final class MachinesUIState {

    var presentation: MachinesView.Presentation = .list
    var filter: MachinesView.Filter = .all
    var search = ""

    /// Running-first, matching the containers screen's Q2 rule — the machines you can act on
    /// stay at the top. A stopped machine is usually one you have finished with.
    var sortOrder = [KeyPathComparator(\ContainerMachine.sortRank)]

    /// Which columns are shown, in what order and at what width.
    ///
    /// **Disk** starts hidden. It reports the VM's disk image size, which for a freshly created
    /// Alpine machine is ~75 MB on every row and does not move — a column identical in every
    /// row is pure width, the same argument that hides Host on the containers screen. It is
    /// still there for anyone who wants it.
    var columnCustomization: TableColumnCustomization<ContainerMachine> = {
        var customization = TableColumnCustomization<ContainerMachine>()
        customization[visibility: "disk"] = .hidden
        return customization
    }()
}

extension ContainerMachine {
    /// Running before stopped, then alphabetical inside each group. A plain `status` sort would
    /// put "running" after "stopped" alphabetically, which is backwards from what you want.
    var sortRank: String {
        let group = status.lowercased() == "running" ? "0" : "1"
        return group + id.lowercased()
    }
}
