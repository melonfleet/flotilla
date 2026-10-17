import SwiftUI

/// A key a two-line-row section can sort on (Q56). Each section's `SortKey` enum is one: the old
/// table's sortable columns, in the order the headers had them, with the menu's words as raw
/// values.
///
/// An enum rather than a string id so the section's `switch` over it is exhaustive — a key the
/// menu offers and the comparators forget is a compile error, not a quiet fall-back to Name.
protocol RowSortKey: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {}

extension RowSortKey {
    /// What the Sort menu calls it.
    var title: String { rawValue }
}

/// The toolbar's Sort menu, in every section on rows: "Sort by" with a checkmark on the current
/// key, then the direction. Two groups of checkmarked items, so the current choice is read straight
/// off the menu.
///
/// **One menu for all nine sections.** Two had grown in parallel on 17 October — one bound to a
/// separate `RowSortState` object per section, one to fields on the section's UI state — and
/// Containers had a third, private copy. This keeps the second's shape (bindings, so it works over
/// `ContainersUIState`, `MachinesUIState` and `ResourceUIState` alike) and the first's insistence
/// that a key is an id rather than whatever the label happens to say; the keys are typed instead,
/// so the switch that turns one into comparators is checked.
struct RowSortMenu<Key: RowSortKey>: View {
    @Binding var key: Key
    @Binding var ascending: Bool

    var body: some View {
        ToolbarIconMenu(systemImage: "arrow.up.arrow.down",
                        label: "Sort: \(key.title), \(ascending ? "ascending" : "descending")") {
            Picker("Sort by", selection: $key) {
                ForEach(Array(Key.allCases), id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        }
    }
}

extension ResourceUIState {
    /// The section's key, read back from `sortKeyID`; `fallback` when nothing is chosen yet.
    func sortKey<Key: RowSortKey>(default fallback: Key) -> Key {
        sortKeyID.flatMap(Key.init(rawValue:)) ?? fallback
    }

    /// The Sort menu's bindings over this state, for a section whose keys are `Key`.
    @MainActor
    func sortMenu<Key: RowSortKey>(default fallback: Key) -> RowSortMenu<Key> {
        RowSortMenu(key: Binding(get: { [weak self] in self?.sortKey(default: fallback) ?? fallback },
                                 set: { [weak self] in self?.sortKeyID = $0.rawValue }),
                    ascending: Binding(get: { [weak self] in self?.sortAscending ?? true },
                                       set: { [weak self] in self?.sortAscending = $0 }))
    }
}
