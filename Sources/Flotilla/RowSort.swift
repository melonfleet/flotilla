import SwiftUI

/// The sort a two-line-row section is showing: a key and a direction, held above the section.
///
/// The rows have no clickable headers (Q56), so sorting is a menu. This is Containers' pair —
/// `sortKey` and `sortAscending` — for the sections that share `ResourceUIState`, kept beside it
/// rather than in it so that class stays as the other sections left it. Held by `MainWindowView`
/// for the reason everything in `ResourceUIState` is: a section view is rebuilt on every sidebar
/// change.
///
/// The key is a string id and the *section* turns it into comparators, because only the section
/// knows its row type.
@Observable
final class RowSortState {
    var key: String
    var ascending = true

    init(key: String) { self.key = key }

    var order: SortOrder { ascending ? .forward : .reverse }
}

/// The toolbar's Sort menu: "Sort by" with a checkmark on the current key, then the direction.
/// The same arrangement as Containers', so the current choice is read straight off the menu.
struct RowSortMenu: View {
    @Bindable var state: RowSortState
    let keys: [(id: String, title: String)]

    var body: some View {
        ToolbarIconMenu(systemImage: "arrow.up.arrow.down", label: label) {
            Picker("Sort by", selection: $state.key) {
                ForEach(keys, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $state.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        }
    }

    private var label: String {
        let title = keys.first { $0.id == state.key }?.title ?? state.key
        return "Sort: \(title), \(state.ascending ? "ascending" : "descending")"
    }
}
