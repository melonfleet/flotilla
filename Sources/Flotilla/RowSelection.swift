import SwiftUI

/// A row's leading checkbox: whether the row is in its section's selection, or why it cannot be.
///
/// Kamal, 17 October: "The select boxes have gone … those should come back … it should be the same
/// all through all the designs." The two-line rows (Q56) had dropped them for the `List`'s own
/// selection; they are back as a **view of that selection**, not a second one. `isOn` toggles the
/// row's id in the same `Set` the `List` binds, so ⌘-click, ⇧-click and ⌘A tick boxes, a tick adds
/// a row without clearing the others, and the bulk bar counts one thing.
struct RowCheck {
    var isOn: Binding<Bool>
    /// Why this row cannot be acted on in bulk, or `nil` when it can. Such a row keeps a disabled,
    /// empty box — the column still lines up — and the reason is its help tag.
    var unavailable: String?

    /// The box for `id` in `selection`.
    init<ID: Hashable>(_ id: ID, in selection: Binding<Set<ID>>, unavailable: String? = nil) {
        self.isOn = selection[member: id]
        self.unavailable = unavailable
    }
}

extension Set {
    /// Whether `element` is in the set, as something a `Binding` can project: setting it inserts or
    /// removes that one element and leaves the rest alone. What a row's checkbox toggles.
    subscript(member element: Element) -> Bool {
        get { contains(element) }
        set { if newValue { insert(element) } else { remove(element) } }
    }
}

/// The box `ResourceRow` draws from a `RowCheck`.
struct RowCheckbox: View {
    let check: RowCheck
    /// The row's name, for "Select web".
    let name: String

    var body: some View {
        if let reason = check.unavailable {
            // Empty rather than mirroring the list's selection: the box says what a bulk action
            // would touch, and this row is never in it.
            Toggle("Select \(name)", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
                .help(reason)
                .accessibilityLabel("Select \(name)")
                .accessibilityHint(reason)
        } else {
            Toggle("Select \(name)", isOn: check.isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(check.isOn.wrappedValue ? "Deselect \(name)" : "Select \(name)")
                .accessibilityLabel("Select \(name)")
        }
    }
}

/// The toolbar's select-all box, at the left of the band where it sat above the old tables'
/// checkbox column. It covers the rows **on screen** — after the search, the filter and a closed
/// group — and only those a bulk action can take; it is mixed while some of them are selected.
struct SelectAllCheckbox<ID: Hashable>: View {
    @Binding var selection: Set<ID>
    /// The selectable rows on screen, in list order.
    let ids: [ID]
    /// The section's plural noun: "Select all containers".
    let noun: String

    var body: some View {
        let chosen = ids.count { selection.contains($0) }
        Toggle(sources: ids.map { $selection[member: $0] }, isOn: \.self) {
            Text("Select all \(noun)")
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(ids.isEmpty)
        .help(ids.isEmpty ? "Nothing to select"
              : chosen == ids.count ? "Deselect all \(noun)" : "Select all \(ids.count) \(noun)")
        .accessibilityLabel("Select all \(noun)")
    }
}

/// The band under a section's toolbar while one or more rows are selected: how many, then the
/// actions a selection can take. One shape for every section, so the bar is in the same place and
/// reads the same wherever you selected.
struct BulkActionBar<Actions: View>: View {
    /// "3 selected", or the section's own wording ("2 containers, 1 group selected").
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}
