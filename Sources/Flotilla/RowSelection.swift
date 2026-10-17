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

extension View {
    /// Keeps `selection` inside `selectable` — the rows on screen that a bulk action can take — on
    /// every change to either.
    ///
    /// The `List` selects whatever is clicked, ⇧-clicked or ⌘A'd, including rows whose box is
    /// disabled (This Mac, a built-in network, a group member not created yet, a host group
    /// heading), and a closed group or a filter hides rows without clearing their ids. Either way
    /// the highlight, the boxes and the bulk bar stopped agreeing — "0 containers selected" for a
    /// member nobody could tick, a bulk tag landing on hosts in a collapsed group (Kyle, 17
    /// October). Such a row now never stays in a selection of several, so there is one answer to
    /// "what is selected".
    ///
    /// **One row on its own may be any row with a page** (`showing`), since the split (Q58): selecting
    /// a row is how its page is shown, and This Mac and the built-in networks have pages too. Alone,
    /// it agrees with everything — the highlight is the page beside it, its box stays empty and
    /// disabled, and the bulk bar, which counts only what a bulk action can take, does not appear.
    /// The moment a second row joins it, it drops out as before. `showing` defaults to `selectable`,
    /// which is the old rule exactly.
    ///
    /// **Pass every row in the model with a page as `showing`, not the rows on screen.** A filter
    /// hides rows in the list, never the page that is open (Kyle, 17 October): confined to the
    /// visible rows, typing a search that hid the shown row emptied the selection and took the page
    /// with it — a registry, domain or group form and its unsaved draft included. Only a row that
    /// has really gone — deleted, or its host forgotten — leaves the selection now, and that goes
    /// through `paneFollows` and the form guard like any other change of page.
    func selection<ID: Hashable>(_ selection: Binding<Set<ID>>, confinedTo selectable: Set<ID>,
                                 showing showable: Set<ID>? = nil) -> some View {
        modifier(SelectionConfinement(selection: selection, selectable: selectable,
                                      showable: showable ?? selectable))
    }

    /// The page beside the list follows `selection` into `shown` — **through the form guard**.
    ///
    /// A page can be a form (a registry, a domain, a group), and choosing another row would replace
    /// it, so a choice that would lose unsaved edits asks first, the same question the sidebar asks.
    /// Keep Editing puts the list's selection back. A page that is not a dirty form changes at once,
    /// in the same frame: the guard is synchronous when nothing would be lost.
    ///
    /// `existing` is every id that still has a page — the same set given to `selection(_:confinedTo:showing:)`.
    /// Keep Editing restores only those: when the shown row has been deleted, putting its id back
    /// would be confined straight out again and ask the same question for ever. The page keeps its
    /// form on screen instead (a form page draws from its id, not from the row), so the draft is
    /// still there to copy or save, and the next choice of row asks again.
    func paneFollows<ID: Hashable>(_ selection: Binding<Set<ID>>, into shown: Binding<Set<ID>>,
                                   guard formGuard: FormGuard, existing: Set<ID>? = nil) -> some View {
        modifier(PaneFollowing(selection: selection, shown: shown, formGuard: formGuard, existing: existing))
    }
}

private struct SelectionConfinement<ID: Hashable>: ViewModifier {
    @Binding var selection: Set<ID>
    let selectable: Set<ID>
    let showable: Set<ID>

    func body(content: Content) -> some View {
        content
            .onChange(of: selection, initial: true) { _, _ in confine() }
            .onChange(of: selectable) { _, _ in confine() }
            .onChange(of: showable) { _, _ in confine() }
    }

    private func confine() {
        if selection.count == 1, let only = selection.first, showable.contains(only) { return }
        let kept = selection.intersection(selectable)
        if kept != selection { selection = kept }
    }
}

private struct PaneFollowing<ID: Hashable>: ViewModifier {
    @Binding var selection: Set<ID>
    @Binding var shown: Set<ID>
    let formGuard: FormGuard
    let existing: Set<ID>?

    func body(content: Content) -> some View {
        content
            .onChange(of: selection, initial: true) { _, chosen in
                guard chosen != shown else { return }
                formGuard.confirmLeaving(onKeepEditing: {
                    selection = existing.map { shown.intersection($0) } ?? shown
                }) { shown = chosen }
            }
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

/// The band under a section's toolbar while two or more rows are selected: how many, then the
/// actions a selection can take. One shape for every section, so the bar is in the same place and
/// reads the same wherever you selected.
///
/// **Only where the page's summary cannot be seen** (Kamal, 17 October). In the split every row
/// section's page shows "N selected" with the same actions, from the same builder, the moment a
/// second row is ticked — so above the list the bar was the same buttons twice, and at one row it
/// sat over a list whose page already had that row's actions. Sections show it from two rows, and
/// it stands down here whenever the page is beside the list (`pageBesideList`). What is left is a
/// window too narrow for both panes, where the list is alone and the bar is the only place a
/// selection of several can be acted on without a right-click.
struct BulkActionBar<Actions: View>: View {
    /// "3 selected", or the section's own wording ("2 containers, 1 group selected").
    let title: String
    @ViewBuilder var actions: Actions
    @Environment(\.pageBesideList) private var pageBesideList

    var body: some View {
        if !pageBesideList { bar }
    }

    private var bar: some View {
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

/// A row list that keeps its one selected row in view when something other than a click moved
/// the selection there — the page's ↑ ↓ stepping while the list is beside it, a menu or the search
/// box opening a row further down, or the list coming back after the page was widened over it.
/// A click selects a row that is already on screen, so revealing it moves nothing. Mail's message
/// list does the same as you step through it.
struct SelectionRevealingList<ID: Hashable, Content: View>: View {
    let selection: Set<ID>
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            content
                // After the rows are laid out: on appear the list has none yet to scroll to.
                .onAppear { Task { @MainActor in reveal(proxy) } }
                .onChange(of: selection) { _, _ in reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard selection.count == 1, let id = selection.first else { return }
        proxy.scrollTo(id)
    }
}
