import SwiftUI
import Foundation
import FlotillaCore

/// The containers section: **the product**.
///
/// Q2 in `DECISIONS.md`: the container list is a **table** by default — running-first,
/// sortable, multi-select — with the card grid demoted to a toggle, because cards stop
/// scaling around twenty rows. The table is *cross-host* from the outset (`Host` column),
/// even though Phase 1 only talks to this Mac: the aggregate view is the differentiator no
/// comparable tool has, and retrofitting a host dimension later is far more painful than
/// carrying it from the start.
///
/// Moved out of `MainWindowView` unchanged when the window became a `NavigationSplitView`
/// (Phase 1 UI contract), then extended here with state filtering, a bulk-action bar, the
/// Created/IP columns, and the detail sheet hook.
struct ContainersView: View {
    let model: AppModel
    /// Held by `MainWindowView` so it outlives this view — see `ContainersUIState`.
    /// Without it, navigating to another section and back reset the user's columns, sort,
    /// filter and search.
    @Bindable var ui: ContainersUIState

    enum Presentation: String, CaseIterable, Identifiable {
        case list = "List"
        case cards = "Cards"
        var id: Self { self }

        /// Icons rather than words in the segmented control — the two views are a visual
        /// choice, and the glyphs read faster than reading "List"/"Cards" every time.
        /// `list.bullet` is the lines-with-dots list mark; `square.grid.2x2` the four
        /// squares. The words survive as accessibility labels and tooltips, so nothing is
        /// lost to anyone who cannot see the glyph.
        var systemImage: String {
            switch self {
            case .list: "list.bullet"
            case .cards: "square.grid.2x2"
            }
        }
    }

    /// What the list is showing. Single-select, and rendered as a **radio group** in the
    /// filter popover.
    ///
    /// This was briefly a multi-select set of checkboxes, matching the Columns menu. Radio is
    /// the better fit and the owner called it: there are exactly three meaningful outcomes and
    /// radio names all three, including `All`. Checkboxes left "All" implicit in *both ticked*
    /// and admitted a fourth, useless state — neither ticked, showing nothing — that then
    /// needed designing around. A control with no degenerate state beats one with a
    /// well-handled degenerate state.
    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .all: "circle.grid.2x2"
            case .running: "play.circle"
            case .stopped: "stop.circle"
            }
        }
    }

    @State private var selection = Set<Container.ID>()

    /// The container whose detail sheet is open, by **id** rather than by value: the sheet can
    /// outlive the snapshot that opened it, so it re-reads from the model on every refresh and
    /// shows current state instead of a frozen copy.
    @State private var detailTarget: DetailTarget?

    /// `sheet(item:)` needs `Identifiable`, and a bare `String` is not. Small enough to live
    /// here rather than becoming a shared type.
    /// A container to show, and optionally which tab to land on. Same reasoning as the machines
    /// screen: the tab travels in the navigation value rather than through a dictionary the detail
    /// view reads once in `init`, because a request that can be silently dropped is a menu item
    /// that sometimes does nothing.
    private struct DetailTarget: Identifiable, Hashable {
        let id: String
        var tab: DetailTab?
    }
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. A `TagSheetTarget` rather than a
    /// bare `TagSubject` — see that type for why a subject is not `Identifiable`.
    ///
    /// Presented from the view, never from inside the menu: a `.sheet` attached within a `Menu`
    /// never appears, because the menu is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?
    /// Non-nil while a single row's trash button is awaiting confirmation. Destructive
    /// actions confirm with the object *named* (`FEATURES.md`'s destructive-action policy),
    /// which is why this holds the container rather than a bool.
    @State private var confirmingRowDelete: Container?
    @State private var showingRun = false
    /// Set when Run was opened from an existing container ("Run Again with Changes…"), and cleared
    /// on dismiss so the next plain Run starts empty.
    @State private var runPrefill: RunPrefill?


    @State private var showingColumns = false
    @State private var showingFilter = false

    /// The group form, embedded like every other create form, when "+ ▸ New Group…" or a group's
    /// Edit opened it. Groups have lived in this list since 5 October (to-do item 4).
    @State private var editingGroup: GroupFormTarget?
    /// Suggestions (Q28), embedded like every form. The stack is set when a quick pick in the
    /// empty state opens one straight away.
    @State private var showingSuggestions = false
    @State private var suggestionPick: StackSuggestion?

    /// A group delete awaiting confirmation, and which kind. The owner's rule: a group row's
    /// Delete offers *both* "the group only" and "the group and its containers", and the second
    /// names every container it will remove.
    @State private var pendingGroupDelete: GroupDeleteRequest?

    struct GroupDeleteRequest: Identifiable {
        enum Mode { case ask, groupOnly, withContainers }
        let group: ContainerGroup
        let mode: Mode
        var id: String { group.id }
    }

    /// The columns the Columns popover offers, in table order.
    ///
    /// Name and Actions are deliberately absent: Name is the row's identity and Actions is
    /// how you operate on it, so neither is something to hide. Docker Desktop's own column
    /// menu makes the same choice about its Name column.
    private static let columnSpecs: [(id: String, title: String)] = [
        ("state", "State"),
        // Group or Container. The owner asked for an indicator column so the two kinds read
        // apart at a glance, with the caret as the other cue.
        ("type", "Type"),
        ("tags", "Tags"),
        ("image", "Image"),
        ("created", "Created"),
        ("ports", "Ports"),
        ("cpu", "CPU"),
        ("memory", "Memory"),
        ("ip", "IP / Network"),
        ("host", "Host"),
    ]

    /// Docker Desktop's columns control, which is a good pattern: an explicit button beside
    /// the view switcher rather than relying on people discovering a right-click on the
    /// header. The header menu still works — this just makes it findable.
    private var columnsButton: some View {
        IconActionButton(systemImage: "rectangle.split.3x1", label: "Columns",
                         help: "Show or hide columns") { showingColumns.toggle() }
        .popover(isPresented: $showingColumns, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // Checkboxes, not switches. `.checkbox` puts the control leading with the
                // label after it, so every row shares one left edge — switches trail their
                // labels, which left the boxes ragged against text of different lengths.
                ForEach(Self.columnSpecs, id: \.id) { spec in
                    Toggle(spec.title, isOn: binding(for: spec.id))
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                }
                Divider().padding(.vertical, 6)
                HStack {
                    Button("Hide All") { setAllColumns(.hidden) }
                    Spacer()
                    Button("Show All") { setAllColumns(.visible) }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)
            .frame(width: 210)
        }
    }

    /// Embedded, not a sheet, since 9 August — the dimming and the close button went with it.
    private var runScreen: some View {
        RunSheetView(model: model, prefill: runPrefill) {
            showingRun = false
            runPrefill = nil
        }
    }

    /// Detail **embedded in the window**, not a modal — the arrangement
    /// `research/review/mockups/container-detail.html` specified all along. That mockup has the
    /// app sidebar in it; the sheet was my divergence, and it cost three things worth having:
    /// the pane could not be resized, it was capped at a fixed frame that the Terminal tab in
    /// particular wants more of, and the sidebar behind it was dimmed and inert.
    ///
    /// The modal treatment is not discarded, it is now applied where it belongs. `ModalCard` —
    /// red ×, dim behind — still wraps Run, New Volume and New Network. The line is **a form is
    /// modal, a place is navigable**: a form is a question you answer and dismiss, and detail is
    /// somewhere you go and come back from.
    ///
    /// Going somewhere is why this earns Back and the prev/next stepper. Stepping between
    /// containers without closing anything is the workflow persistent terminal sessions made
    /// possible — shells stay alive in `TerminalSessionStore`, so you can leave a build running
    /// in one container, step to the next, and step back to it still running.
    @ViewBuilder
    private func detailScreen(_ target: DetailTarget) -> some View {
        VStack(spacing: 0) {
            if let container = model.containers.first(where: { $0.id == target.id }) {
                detailHeader(for: container)
                Divider()
                ContainerDetailView(model: model, container: container, requestedTab: target.tab)
            } else {
                detailHeader(for: nil)
                Divider()
                ContentUnavailableView(
                    "Container unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("“\(target.id)” is no longer on this Mac. It may have been deleted.")
                )
            }
        }
    }

    /// Back, identity, the stepper, and the lifecycle actions — the mockup's `toolbar tall`.
    @ViewBuilder
    private func detailHeader(for container: Container?) -> some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back to Containers",
                             help: "Back to Containers") { detailTarget = nil }

            if let container {
                Image(systemName: "shippingbox")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(container.id).font(.headline)
                        HStack(spacing: 4) {
                            Circle().fill(container.stateColor).frame(width: 6, height: 6)
                            Text(container.status.state.capitalized).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Text(subtitle(for: container))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Container unavailable").font(.headline)
            }

            Spacer()

            stepper

            if let container {
                ActionCluster { rowActions(for: container) }
            }
        }
        // Horizontal 12, vertical 8 — the pair every band under the title bar uses.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Steps through the containers **as currently shown** — same filter, same search, same
    /// sort. Stepping into a row the table is hiding would be its own small betrayal.
    ///
    /// Deliberately not wrapping at the ends: the buttons disable instead. Wrapping from the
    /// last container back to the first, silently, is how you lose track of where you are in a
    /// list you are stepping through one at a time.
    @ViewBuilder
    private var stepper: some View {
        let order = sorted
        let index = order.firstIndex { $0.id == detailTarget?.id }

        HStack(spacing: 2) {
            Button {
                if let index, index > 0 { detailTarget = DetailTarget(id: order[index - 1].id) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == nil || index == 0)
            .help("Previous container")
            .accessibilityLabel("Previous container")

            Button {
                if let index, index < order.count - 1 {
                    detailTarget = DetailTarget(id: order[index + 1].id)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == nil || index == order.count - 1)
            .help("Next container")
            .accessibilityLabel("Next container")

            if let index {
                Text("\(index + 1) of \(order.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private func subtitle(for container: Container) -> String {
        var parts = [ContainerImage.shortReference(container.imageReference), model.hostLabel]
        if AppModel.isRunning(container), let started = container.status.startedDate {
            parts.append(RelativeDate.relative(started, prefix: "up"))
        } else {
            parts.append(RelativeDate.relative(container.configuration.creationDate, prefix: "created"))
        }
        if let ip = container.ipv4 { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    private func openDetail(_ id: String, tab: DetailTab? = nil) {
        detailTarget = DetailTarget(id: id, tab: tab)
    }

    /// Same icon-and-popover shape as `columnsButton` — both answer "what am I looking at",
    /// so both are a glyph with a menu rather than words spread across the toolbar. The
    /// contents differ because the questions differ: columns are independent (checkboxes),
    /// the state filter is one choice (radio).
    ///
    /// The icon fills when a filter is active, so a hidden state is visible from the toolbar
    /// rather than something you discover by wondering where your containers went.
    /// `IconActionButton`, like every other icon control in the app — **not** a bare `Button`
    /// with an `Image`, which is what this was. That is the difference the owner spotted: the shared
    /// button carries the hover tint and the pressed scale, so a filter button that skipped it had
    /// no shading while the columns button beside it did, on the same band. Same glyph, same
    /// accent-when-active rule, same feedback, everywhere.
    private var filterButton: some View {
        let filtering = ui.filter != .all || ui.kindFilter != .all
        return IconActionButton(systemImage: "line.3.horizontal.decrease",
                                label: "Filter",
                                help: filtering ? filterSummary : "Filter by state or kind",
                                active: filtering) {
            showingFilter.toggle()
        }
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            // Two radio groups, because they are two independent questions: *what state* and
            // *what kind*. The kind filter is what lets the merged list collapse back to just
            // groups, or just containers — which covers what the separate Groups screen gave.
            VStack(alignment: .leading, spacing: 10) {
                Text("State").font(.caption).foregroundStyle(.secondary)
                Picker("State", selection: $ui.filter) {
                    ForEach(Filter.allCases) { option in
                        Label(option.rawValue, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Divider()
                Text("Show").font(.caption).foregroundStyle(.secondary)
                Picker("Show", selection: $ui.kindFilter) {
                    Label("Groups and containers", systemImage: "square.grid.2x2").tag(ContainerListing.KindFilter.all)
                    Label("Groups only", systemImage: Section.groupSymbol).tag(ContainerListing.KindFilter.groups)
                    Label("Containers only", systemImage: "shippingbox").tag(ContainerListing.KindFilter.containers)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .padding(14)
        }
    }

    /// The filter button's tooltip while a filter is on, so a hidden row is explained from the
    /// toolbar rather than discovered by wondering where it went.
    private var filterSummary: String {
        var parts: [String] = []
        if ui.filter != .all { parts.append(ui.filter.rawValue.lowercased()) }
        switch ui.kindFilter {
        case .all: break
        case .groups: parts.append("groups only")
        case .containers: parts.append("containers only")
        }
        return "Showing " + parts.joined(separator: ", ")
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { ui.columnCustomization[visibility: id] != .hidden },
            set: { ui.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    /// `Visibility` is SwiftUI's own top-level enum, not a type nested in
    /// `TableColumnCustomization` — the `[visibility:]` subscript trades in the same
    /// `.automatic / .visible / .hidden` used everywhere else in SwiftUI.
    private func setAllColumns(_ visibility: Visibility) {
        for spec in Self.columnSpecs {
            ui.columnCustomization[visibility: spec.id] = visibility
        }
    }

    /// The state filter in the shared listing's terms.
    private var stateFilter: ContainerListing.StateFilter {
        switch ui.filter {
        case .all: .all
        case .running: .running
        case .stopped: .stopped
        }
    }

    /// Which rows exist at all: standalone containers and groups, with each group's members,
    /// through the kind, state and search filters. The rules — a grouped container appears only
    /// inside its group, a partly running group is under both Running and Stopped — live in
    /// `ContainerListing`, where tests pin them.
    private var listing: [ContainerListing.Item] {
        let needle = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return ContainerListing.items(containers: model.containers, groups: model.groups.groups,
                                          kind: ui.kindFilter, state: stateFilter)
        }
        // **Tag names are searchable too, on every section.** This is how tags filter: one line
        // per section, the same everywhere, and it composes with whatever filter is already on.
        return ContainerListing.items(
            containers: model.containers, groups: model.groups.groups,
            kind: ui.kindFilter, state: stateFilter,
            containerMatches: { container in
                container.id.lowercased().contains(needle)
                    || container.status.state.lowercased().contains(needle)
                    || model.tags.tags(on: .container, container.id)
                        .contains { $0.name.lowercased().contains(needle) }
            },
            groupMatches: { group in
                group.name.lowercased().contains(needle)
                    || model.tags.tags(on: .group, group.id)
                        .contains { $0.name.lowercased().contains(needle) }
            },
            memberMatches: { member in
                member.name.lowercased().contains(needle) || member.image.lowercased().contains(needle)
            })
    }

    /// The rows the table shows, in order: each top-level row, followed by its members when the
    /// group is open. See `sortedRows`.
    private var rows: [ContainerRow] { sortedRows }

    /// The containers on screen, in on-screen order — standalone ones and the members of open
    /// groups. The detail stepper walks this, so "next" is always the next container you can see.
    private var sorted: [Container] { rows.compactMap(\.container) }

    /// Whether anything the user chose is hiding rows, so an empty state can say so.
    private var isFiltered: Bool {
        !ui.search.isEmpty || ui.filter != .all || ui.kindFilter != .all
    }

    private var visibleIDs: Set<ContainerRow.ID> { Set(rows.map(\.id)) }

    /// What a bulk action may actually touch: the selection **intersected with what is on
    /// screen**. `selection` outlives the rows that produced it — filter, search and deletion all
    /// hide rows without clearing their ids — so every bulk path acts on this, never `selection`.
    private var actionable: Set<ContainerRow.ID> { selection.intersection(visibleIDs) }

    /// The groups in the actionable selection.
    private var actionableGroups: [ContainerGroup] {
        model.groups.groups.filter { actionable.contains(ContainerRow.groupRowID($0.id)) }
    }

    /// The containers in the actionable selection: standalone rows and existing members. A
    /// member of a selected group is left out, so selecting a group and one of its members does
    /// not start that member twice.
    private var actionableContainerIDs: Set<Container.ID> {
        let ownedBySelectedGroups = Set(actionableGroups.flatMap(\.memberNames))
        let existing = Set(model.containers.map(\.id))
        return Set(actionable.filter { !ContainerRow.isGroupRowID($0) })
            .intersection(existing)
            .subtracting(ownedBySelectedGroups)
    }

    private func selectionToggle(for id: ContainerRow.ID, name: String) -> some View {
        let isOn = Binding<Bool>(
            get: { selection.contains(id) },
            set: { on in
                if on { selection.insert(id) } else { selection.remove(id) }
            })
        return Toggle("", isOn: isOn)
            .labelsHidden()
            .accessibilityLabel("Select \(name)")
            .help("Select \(name)")
    }

    /// True when every visible row is selected — against what is *visible*, so select-all under
    /// a filter means "all of these" rather than silently reaching rows the filter hides.
    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    /// True while any actionable container has an action in flight, so a second click cannot
    /// fire a duplicate operation on top of the first.
    private var selectionBusy: Bool { model.isAnyBusy(actionableContainerIDs, kind: .container) }

    /// How the bulk bar and the bulk menu describe the selection: "3 containers", "1 group",
    /// "2 containers and 1 group".
    private var selectionNoun: String {
        let c = actionableContainerIDs.count, g = actionableGroups.count
        let containers = "\(c) container\(c == 1 ? "" : "s")"
        let groups = "\(g) group\(g == 1 ? "" : "s")"
        switch (c, g) {
        case (_, 0): return containers
        case (0, _): return groups
        default: return "\(containers) and \(groups)"
        }
    }

    /// Per-row action buttons, in an **Actions** column — the pattern Docker Desktop uses and
    /// the one the owner asked for: small, always-visible, icon-only controls on the row they
    /// affect, rather than a bar above the table that acts on a selection you have to make
    /// first.
    ///
    /// Three rules this follows deliberately:
    /// - **Always visible, never hover-revealed.** `research/FEATURES.md`'s accessibility
    ///   baseline rules out hover-only affordances, and a control that appears on approach is
    ///   also unreachable by keyboard.
    /// - **Labelled.** Icon-only buttons carry `accessibilityLabel` plus `help` — a glyph with
    ///   no name is invisible to VoiceOver and ambiguous to everyone else.
    /// - **Start and Stop swap, they do not both show.** Offering Stop on a stopped container
    ///   would be a control that does nothing, which is the failure mode this whole pass is
    ///   about.

    /// The right-hand half of the containers table.
    ///
    /// Split out for two reasons, both mechanical. `TableColumnBuilder` accepts **ten** columns
    /// and the Tags column made eleven; and wrapping the overflow in a `Group` — the documented
    /// remedy — pushed this body past what the type checker will solve in reasonable time, which
    /// it said out loud. A `@TableColumnBuilder` property is the same columns, checked in two
    /// smaller pieces, and it renders and customises identically.
    @TableColumnBuilder<ContainerRow, KeyPathComparator<ContainerRow>>
    private var trailingColumns: some TableColumnContent<ContainerRow, KeyPathComparator<ContainerRow>> {
                // A group's CPU and memory are its members' sum, so a group row answers "how
                // much is this whole stack using" — the question you have about a stack.
                TableColumn("CPU", value: \.cpu) { row in
                    Text(AppModel.cpuLabel(row.cpu < 0 ? nil : row.cpu))
                        .monospacedDigit()
                        .foregroundStyle(row.cpu < 0 ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 56, ideal: 68)
                .customizationID("cpu")

                TableColumn("Memory", value: \.memory) { row in
                    Text(AppModel.memoryLabel(row.memory < 0 ? nil : row.memory))
                        .monospacedDigit()
                        .foregroundStyle(row.memory < 0 ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 68, ideal: 84)
                .customizationID("memory")

                TableColumn("IP / Network", value: \.ipSortKey) { row in
                    Text(ipNetworkLabel(row))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 130)
                .customizationID("ip")

                // Hidden by default (see `ui.columnCustomization`): with one host it reads
                // "This Mac" on every row, and a column identical in every row is pure width.
                // **Not sortable, and not an omission** — a column with one distinct value cannot
                // be ordered. It gains a `value:` the moment a row carries a real host.
                TableColumn("Host") { _ in Text(model.hostLabel).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 100)
                    .customizationID("host")

                // Last. Sized to its content rather than fixed, so it compresses with
                // everything else instead of forcing the table wider than the window.
                TableColumn("Actions") { row in
                    switch row.kind {
                    case .group:
                        if let group = row.group { groupRowActions(for: group) }
                    case .container, .member:
                        if let container = row.container {
                            rowActions(for: container)
                        } else {
                            // A member the group has not created yet has nothing to act on; its
                            // group's own Start is what creates it.
                            Text("Not created")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("Starting the group creates this container")
                        }
                    }
                }
                .width(min: 118, ideal: 128)
                .customizationID("actions")
    }

    @ViewBuilder
    private func rowActions(for container: Container) -> some View {
        let busy = model.isBusy(container.id, kind: .container)
        let running = AppModel.isRunning(container)

        HStack(spacing: 2) {
            if running {
                iconButton("stop.fill", "Stop \(container.id)", busy: busy) {
                    Task { await model.perform(.stop, on: container) }
                }
                iconButton("arrow.clockwise", "Restart \(container.id)", busy: busy) {
                    Task { await model.perform(.restart, on: container) }
                }
            } else {
                iconButton("play.fill", "Start \(container.id)", busy: busy) {
                    Task { await model.perform(.start, on: container) }
                }
                // Keeps the column a stable width whichever state the row is in, so the
                // buttons don't jump sideways as containers start and stop.
                iconButton("arrow.clockwise", "Restart \(container.id)", busy: true) {}
                    .hidden()
            }

            // The **same** builder the right-click menu uses. It used to be its own two-item
            // menu — Details and Copy — so the three dots and a right-click on the same row
            // offered different things, and everything in between (Logs, Terminal, Inspect, Run
            // Again, Force Kill, Delete) was reachable only by right-click. Two menus for one row
            // is two menus to keep in step, and they had already drifted.
            Menu {
                actions(for: container)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(container.id)")

            Divider().frame(height: 14)

            iconButton("trash", "Delete \(container.id)", busy: busy, destructive: true) {
                requestDelete(container)
            }
        }
    }

    /// Every single-container delete enters here, and `model.deletePolicy` is the only thing that
    /// decides whether it stops to ask. Containers previously ignored
    /// `confirmDestructiveActions` entirely: the trash button confirmed unconditionally, the
    /// context menu never confirmed at all, and the preference governed neither.
    private func requestDelete(_ container: Container) {
        if model.deletePolicy.requiresConfirmation(.single) {
            confirmingRowDelete = container
        } else {
            Task { await model.perform(.delete, on: container) }
        }
    }

    /// `label` names the row — "Stop web", not "Stop" — and is both what VoiceOver reads and the
    /// tooltip, the shape `MachinesView` already had. A bare verb was announced identically on
    /// every row, so nobody listening could tell which container a button acted on.
    private func iconButton(
        _ symbol: String, _ label: String,
        busy: Bool, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        // Delegates to the shared button so the containers rows, the machines rows and the
        // section toolbars all give the same feedback. See `IconActionButton`.
        IconActionButton(systemImage: symbol, label: label, help: label,
                         busy: busy, destructive: destructive, action: action)
    }

    /// The context menu for a right-click that landed on one or more rows.
    ///
    /// `ids` comes from the table itself, so everything in it is on screen by construction —
    /// this is the one bulk path that does not need intersecting with what is visible.
    @ViewBuilder
    private func tableContextMenu(for ids: Set<ContainerRow.ID>) -> some View {
        if ids.isEmpty {
            // Right-click on empty space still deserves the primary actions rather than an
            // empty menu that looks like a bug — the same two the toolbar's "+" offers.
            addMenuItems
        } else if ids.count == 1, let id = ids.first, let row = rowsByID[id] {
            switch row.kind {
            case .group:
                if let group = row.group { groupMenu(for: group) }
            case .container, .member:
                if let container = row.container {
                    actions(for: container)
                } else if let group = row.group {
                    // A member not created yet: its group is the thing you can act on.
                    groupMenu(for: group)
                }
            }
        } else {
            let containers = Set(ids.filter { !ContainerRow.isGroupRowID($0) })
                .intersection(Set(model.containers.map(\.id)))
            let groups = model.groups.groups.filter { ids.contains(ContainerRow.groupRowID($0.id)) }
            let busy = model.isAnyBusy(containers, kind: .container)
            Button("Start \(ids.count)") { Task { await startSelected(containers, groups) } }
                .disabled(busy)
            Button("Stop \(ids.count)") { Task { await stopSelected(containers, groups) } }
                .disabled(busy)
            Button("Restart \(ids.count)") { Task { await restartSelected(containers, groups) } }
                .disabled(busy)
            Divider()
            Button("Delete \(ids.count)…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(busy)
        }
    }

    /// "Run Container…" and "New Group…": the two ways to add to this list, in the toolbar's "+"
    /// menu, the empty-space right-click and the empty state alike.
    @ViewBuilder
    private var addMenuItems: some View {
        Button("Run Container…") { showingRun = true }
        Button("New Group…") { editingGroup = .new }
        Divider()
        Button("Suggestions…") { suggestionPick = nil; showingSuggestions = true }
    }

    private var rowsByID: [ContainerRow.ID: ContainerRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Bulk lifecycle across containers and groups

    /// Containers first, then groups, each the way its own row would do it. A group is started
    /// with its own ordered start (`startGroup`), never as a bag of containers, because order is
    /// the one thing a group is for.
    private func startSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.start, on: containers) }
        if !groups.isEmpty { await model.startGroups(groups.filter(canStart)) }
    }

    private func stopSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.stop, on: containers) }
        if !groups.isEmpty { await model.stopGroups(groups.filter(canStop)) }
    }

    private func restartSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.restart, on: containers) }
        for group in groups where canStop(group) { await model.restartGroup(group) }
    }

    // MARK: Group rows

    private func canStart(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return state != .empty && state != .running
    }

    private func canStop(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return state != .empty && state != .stopped && state != .notCreated
    }

    /// Start and Stop together, then the overflow, then the bin — the same arrangement and the
    /// same width as a container row's controls, so the column does not jump between kinds.
    /// Both lifecycle buttons rather than one that swaps, because a partly running group needs
    /// both.
    @ViewBuilder
    private func groupRowActions(for group: ContainerGroup) -> some View {
        HStack(spacing: 2) {
            // Labels name the group, as the retired Groups screen's did: VoiceOver reads the label,
            // and a row of buttons all called "Delete" does not say which row they act on.
            IconActionButton(systemImage: "play.fill", label: "Start \(group.name)",
                             help: model.state(of: group) == .empty
                                 ? "Add a service before starting this group"
                                 : "Start every service in \(group.name)",
                             disabled: !canStart(group)) {
                Task { await model.startGroup(group) }
            }
            IconActionButton(systemImage: "stop.fill", label: "Stop \(group.name)",
                             help: "Stop every running service in \(group.name)",
                             disabled: !canStop(group)) {
                Task { await model.stopGroup(group) }
            }

            // The **same** builder the right-click menu uses, which `check-menu-parity.sh` holds
            // every row to.
            Menu {
                groupMenu(for: group)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(group.name)")

            Divider().frame(height: 14)

            // The bin asks which delete you mean; the menu names each one directly.
            IconActionButton(systemImage: "trash", label: "Delete \(group.name)",
                             help: "Delete \(group.name)", destructive: true) {
                pendingGroupDelete = GroupDeleteRequest(group: group, mode: .ask)
            }
        }
    }

    /// A group row's menu, shared by its `⋯` and a right-click.
    @ViewBuilder
    private func groupMenu(for group: ContainerGroup) -> some View {
        // First, above everything: the thing this row opens. A group's detail is its form.
        Button("Edit…") { editingGroup = .existing(group.id) }
        Divider()
        Button("Start") { Task { await model.startGroup(group) } }
            .disabled(!canStart(group))
        Button("Stop") { Task { await model.stopGroup(group) } }
            .disabled(!canStop(group))
        Button("Restart") { Task { await model.restartGroup(group) } }
            .disabled(!canStop(group))
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .group, id: group.id)) {
            tagSheet = TagSheetTarget([TagSubject(kind: .group, id: group.id)])
        }
        Divider()
        CopyMenu([
            ("Name", group.name),
            ("Services", group.members.isEmpty ? nil : group.memberNames.joined(separator: " ")),
            ("Images", group.members.isEmpty ? nil : group.members.map(\.image).joined(separator: " ")),
            ("Network", group.network ?? "default"),
        ])
        Divider()
        // Two deletes, named for exactly what each removes (the owner, 5 October).
        Button("Delete Group…", role: .destructive) {
            pendingGroupDelete = GroupDeleteRequest(group: group, mode: .groupOnly)
        }
        Button("Delete Group and Containers…", role: .destructive) {
            pendingGroupDelete = GroupDeleteRequest(group: group, mode: .withContainers)
        }
        .disabled(existingMembers(of: group).isEmpty)
    }

    /// The members of a group that exist as containers right now — what "Delete Group and
    /// Containers" would remove.
    private func existingMembers(of group: ContainerGroup) -> [String] {
        let existing = Set(model.containers.map(\.id))
        return group.memberNames.filter(existing.contains)
    }

    /// Start/stop/restart/delete for one container. Attached to both the table rows and
    /// the cards so the two views offer the same capabilities — a toggle that changes what
    /// you can *do*, not just how it looks, is a trap.
    @ViewBuilder
    private func actions(for container: Container) -> some View {
        let busy = model.isBusy(container.id, kind: .container)
        let running = AppModel.isRunning(container)
        Button("Details…") { openDetail(container.id) }

        // Jump straight to the tab you actually wanted. The machines menu has done this since
        // "Edit Settings…" existed; containers offered Details and left you to find the tab, on
        // the screen with the most tabs. Logs and Terminal are the two people go looking for.
        Button("Logs") { openDetail(container.id, tab: .logs) }
        Button("Terminal") { openDetail(container.id, tab: .terminal) }
            // A shell needs a running process to attach to.
            .disabled(!running)
        Button("Inspect") { openDetail(container.id, tab: .inspect) }

        Divider()
        // Every lifecycle item, always, with the ones that do not apply greyed out rather than
        // absent — the rule the runtime band's menu follows, in the same order, and carried here
        // so containers and machines answer a right-click the same way. The old shape showed
        // Stop/Restart/Force Kill *or* Start, so which item sat under the pointer depended on the
        // row you happened to open it on.
        Button("Start") { Task { await model.perform(.start, on: container) } }
            .disabled(running || busy)
        Button("Stop") { Task { await model.perform(.stop, on: container) } }
            .disabled(!running || busy)
        Button("Restart") { Task { await model.perform(.restart, on: container) } }
            .disabled(!running || busy)
        // Below Stop and Restart, and named plainly. For the container that ignores its stop
        // signal, the only alternative used to be deleting it.
        Button("Force Kill") { Task { await model.perform(.kill, on: container) } }
            .disabled(!running || busy)

        // The nearest thing to "Edit Settings…" that the CLI can actually back. There is no
        // `container update`: a container's configuration is fixed at creation, so the only way to
        // change one is to create another. This opens Run prefilled from this container — see
        // `RunPrefill` for what it carries and what it deliberately does not.
        //
        // Named for what it does rather than "Edit Settings…", which would promise an edit. It
        // does not delete the original; that stays a separate, confirmed decision.
        Button("Run Again with Changes…") {
            // Host ports every *other* container already publishes. The source's own ports count
            // too while it is still running, which is the whole point: copying them verbatim
            // produced a container that could not bind and died immediately.
            let taken = Set(model.containers
                                 .filter { $0.isRunning }
                                 .flatMap { $0.publishedPorts.map(\.hostPort) })
            runPrefill = RunPrefill(from: container,
                                    existingNames: Set(model.containers.map(\.id)),
                                    usedHostPorts: taken)
            showingRun = true
        }

        Divider()
        // Tags, in the same place on every row menu in the app: after the things you open and
        // operate on, and before Copy. Not a destructive action, not a read of the runtime — it
        // changes how the row looks to you and nothing about what it is.
        TagMenu(store: model.tags, subject: TagSubject(kind: .container, id: container.id)) {
            tagSheet = TagSheetTarget(kind: .container, id: container.id)
        }

        Divider()
        // Containers were the **only** section without this. Machines, volumes, networks and
        // images all offer it, and the ids and ports here are the most copied values in the app.
        CopyMenu([
            ("Name", container.id),
            ("Image", container.configuration.image.reference),
            // The same two labels the table renders, not a second derivation of them —
            // `portSummary` lives on the model and `ipNetworkLabel` is this view's own.
            ("Ports", container.portSummary),
            ("IP / Network", Self.ipNetworkLabel(container)),
            // Carried over from `CopyMenu.forContainer`, which the cards used until this menu
            // became the single definition. It is the one entry that list had and this one did
            // not, and the useful form is something you can paste into a browser rather than the
            // mapping. Dropped by `CopyMenu` when the container publishes no ports.
            ("Port URL", container.publishedPorts.first.map { "http://localhost:\($0.hostPort)" }),
        ])
        Divider()
        // Destructive, and deliberately only in the main window — never the popover.
        //
        // This used to call `model.perform(.delete, …)` directly, so right-click → Delete destroyed
        // a container **with no dialog at all** while the row's trash button two lines away always
        // asked. Not in the audit; found while centralising the decision, which is the argument for
        // centralising it — the inconsistency was invisible until the five call sites were read
        // side by side.
        Button("Delete", role: .destructive) { requestDelete(container) }
            .disabled(busy)
    }

    /// The tab a `requestDetail` asked for, resolved against **this** screen's own tab type.
    ///
    /// A title this screen does not have resolves to nil and the detail opens on its default tab,
    /// which is the point of carrying a title rather than an index: a request naming a tab only
    /// the other detail screen has can never land on an arbitrary third one.
    private var requestedTab: DetailTab? {
        model.pendingDetailTab.flatMap(DetailTab.init(rawValue:))
    }

    var body: some View {
        Group {
            if showingRun {
                runScreen
            } else if let target = editingGroup {
                // Embedded, like every other create form (`CLAUDE.md`, 9 August).
                GroupFormView(model: model, target: target) { editingGroup = nil }
            } else if showingSuggestions {
                SuggestionsView(model: model,
                                dismiss: { showingSuggestions = false; suggestionPick = nil },
                                chosen: suggestionPick)
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  open: { openActivitySubject($0) },
                                  canOpen: { canOpenActivitySubject($0) })
                }
            }
        }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        // "Open in Flotilla" from the menu-bar popover names a subject, not just a section.
        // One-shot: cleared on consumption so a rebuild does not reopen it.
        .onChange(of: model.pendingDetailSubject) { _, subject in
            // Only this section's own requests — containers, and since 5 October groups, which
            // the menu bar names by name. See `AppModel.requestDetail`.
            guard let subject else { return }
            consumeDetailRequest(subject)
        }
        .onAppear {
            if let subject = model.pendingDetailSubject { consumeDetailRequest(subject) }
        }
        // "Run…" in the menu-bar popover. One-shot: consumed and cleared, so the sheet does
        // not reopen every time this view is rebuilt.
        .onChange(of: model.pendingRunSheet) { _, requested in
            if requested { showingRun = true; model.pendingRunSheet = false }
        }
        .onAppear {
            if model.pendingRunSheet { showingRun = true; model.pendingRunSheet = false }
        }
        // `actionable` already stops a hidden row from being *acted on*; this stops one
        // from being *counted*. One observation covers all three ways the visible set
        // moves out from under the selection — filter change, search change, and the data
        // itself changing (a bulk delete leaves the dead ids behind otherwise, so the bar
        // would linger claiming rows that no longer exist).
        .onChange(of: visibleIDs) { _, ids in
            selection.formIntersection(ids)
        }
        // Single-row delete, from the trash button. Names the container — a dialog that just
        // says "are you sure" makes you go back and check which row you clicked.
        .confirmationDialog(
            "Delete “\(confirmingRowDelete?.id ?? "")”?",
            isPresented: Binding(get: { confirmingRowDelete != nil },
                                 set: { if !$0 { confirmingRowDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = confirmingRowDelete {
                    Task { await model.perform(.delete, on: target) }
                }
                confirmingRowDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingRowDelete = nil }
        } message: {
            Text(confirmingRowDelete?.isRunning == true
                 ? "It is running and will be stopped first. This cannot be undone."
                 : "This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(selectionNoun)?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectionNoun)", role: .destructive) {
                let containers = actionableContainerIDs, groups = actionableGroups
                Task {
                    if !containers.isEmpty { await model.performBulk(.delete, on: containers) }
                    for group in groups { model.deleteGroup(group) }
                }
            }
            // Only when groups are in the selection: their containers go too, which the button
            // above deliberately does not do.
            if !actionableGroups.isEmpty, !actionableGroups.flatMap(existingMembers).isEmpty {
                Button("Delete Including the Groups' Containers", role: .destructive) {
                    let groups = actionableGroups
                    let containers = actionableContainerIDs.union(groups.flatMap(existingMembers))
                    Task {
                        await model.performBulk(.delete, on: containers)
                        for group in groups { model.deleteGroup(group) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(bulkDeleteMessage)
        }
        .confirmationDialog(
            pendingGroupDelete.map(groupDeleteTitle) ?? "",
            isPresented: Binding(get: { pendingGroupDelete != nil },
                                 set: { if !$0 { pendingGroupDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingGroupDelete
        ) { request in
            let members = existingMembers(of: request.group)
            if request.mode != .withContainers {
                Button("Delete Group Only", role: .destructive) {
                    model.deleteGroup(request.group)
                    pendingGroupDelete = nil
                }
            }
            if request.mode != .groupOnly, !members.isEmpty {
                Button("Delete Group and \(members.count) Container\(members.count == 1 ? "" : "s")",
                       role: .destructive) {
                    let group = request.group
                    Task {
                        await model.performBulk(.delete, on: Set(members))
                        model.deleteGroup(group)
                    }
                    pendingGroupDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingGroupDelete = nil }
        } message: { request in
            Text(groupDeleteMessage(request))
        }
    }

    // MARK: Delete wording

    private func groupDeleteTitle(_ request: GroupDeleteRequest) -> String {
        switch request.mode {
        case .withContainers: "Delete the group “\(request.group.name)” and its containers?"
        case .ask, .groupOnly: "Delete the group “\(request.group.name)”?"
        }
    }

    /// Names every container a delete would remove — the owner's condition for offering it.
    private func groupDeleteMessage(_ request: GroupDeleteRequest) -> String {
        let members = existingMembers(of: request.group)
        let keep = "Deleting the group only removes the grouping: its containers stay, as standalone rows, and running ones keep running."
        guard !members.isEmpty else { return keep + " None of its containers exists yet." }
        let named = "This would delete: " + members.joined(separator: ", ") + "."
        let running = members.filter { name in model.containers.first { $0.id == name }?.isRunning == true }
        let stopNote = running.isEmpty ? "" : " Running ones are stopped first."
        switch request.mode {
        case .groupOnly: return keep
        case .withContainers: return named + stopNote + " This cannot be undone."
        case .ask: return keep + "\n\nOr delete the containers too. " + named + stopNote + " That cannot be undone."
        }
    }

    private var bulkDeleteMessage: String {
        var parts: [String] = []
        if runningInSelection > 0 {
            parts.append("\(runningInSelection) of the containers \(runningInSelection == 1 ? "is" : "are") running and will be stopped first.")
        }
        if !actionableGroups.isEmpty {
            parts.append("Deleting a group removes only the grouping; its containers stay unless you delete them too.")
        }
        parts.append("This cannot be undone.")
        return parts.joined(separator: " ")
    }

    // MARK: Requests and activity

    /// Opens what a menu-bar "Open in Flotilla" named, and clears the request either way — a
    /// request for something since deleted must not wait to be applied to the next one.
    private func consumeDetailRequest(_ subject: String) {
        switch model.pendingDetailKind {
        case .container:
            detailTarget = DetailTarget(id: subject, tab: requestedTab)
            model.clearPendingDetail()
        case .group:
            // The menu bar names a group by name; the form is addressed by id.
            if let group = model.groups.groups.first(where: { $0.name == subject }) {
                editingGroup = .existing(group.id)
            }
            model.clearPendingDetail()
        default:
            break
        }
    }

    /// A feed row names a container or a group. A container opens its detail; a group opens its
    /// form, which is the only detail a group has.
    private func openActivitySubject(_ subject: String) {
        if model.containers.contains(where: { $0.id == subject }) {
            openDetail(subject)
        } else if let group = model.groups.groups.first(where: { $0.name == subject }) {
            editingGroup = .existing(group.id)
        }
    }

    private func canOpenActivitySubject(_ subject: String) -> Bool {
        model.containers.contains { $0.id == subject } || model.groups.groups.contains { $0.name == subject }
    }

    /// How many of the containers about to be deleted are running.
    private var runningInSelection: Int {
        actionableContainerIDs.compactMap { id in model.containers.first { $0.id == id } }.count { $0.isRunning }
    }

    /// **The shared band, not a copy of it.** This screen used to hand-roll the same
    /// arrangement, and three sections doing that independently is exactly why the owner felt the UI
    /// move as he switched between them. Measured: Activity's search field was 260pt where this
    /// one was 280, and the trailing clusters on Machines and Activity were missing the
    /// `h8/v4 + glassEffect` this one applied — so the same controls sat at different sizes and
    /// different heights on three screens. Worse, Run and Refresh here were raw `Button`s, which
    /// made them the only action controls in the app with no hover or pressed feedback at all.
    ///
    /// One definition owns the padding, the search width, the status slot and the glass cluster
    /// now; each section supplies only what is genuinely its own.
    private var toolbar: some View {
        SectionToolbar(search: $ui.search,
                       searchPrompt: "Search containers and groups…",
                       updated: model.lastRefresh,
                       leading: {
            // Head of the leading cluster, so it sits above the table's checkbox column. Only
            // meaningful in list view — cards have no checkbox column to select from.
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all" : "Select all")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            Picker("View", selection: $ui.presentation) {
                ForEach(Presentation.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("\(option.rawValue) view")
                        .help("\(option.rawValue) view")
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // Immediately beside the view switcher, as in Docker Desktop — the two are both
            // "how do I want to look at this", so they belong together.
            columnsButton
                .disabled(ui.presentation != .list)     // cards have no columns to configure

            filterButton
        }, trailing: {
            // A menu since groups joined this list (the owner, 5 October): two ways to add to it,
            // under the one glyph that means "add".
            ToolbarIconMenu(systemImage: "plus", label: "Run a container or create a group") {
                addMenuItems
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh now") {
                Task { await model.reload() }
            }
        })
    }

    /// Shown only while rows are multi-selected — the hook the `selection` state existed
    /// for but went unused before this.

    /// The selected rows as tag subjects, in the table's own order.
    ///
    /// Built from `actionable`, not from `selection`: filtering does not clear a table's
    /// selection, so a row you selected and then filtered away is still in the set — and tagging
    /// something the user cannot see is the same mistake the bulk delete bars guard against.
    private var selectedTagSubjects: [TagSubject] {
        actionableContainerIDs.sorted().map { TagSubject(kind: .container, id: $0) }
            + actionableGroups.map { TagSubject(kind: .group, id: $0.id) }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        // 2+, not 1+. Every row now carries its own start/stop/restart/delete, so a bar
        // above the table for a single selection would just be a second way to do the same
        // thing — and it was the bar the owner didn't want. Bulk is the one thing per-row
        // controls genuinely cannot do, so that is all it appears for.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(selectionNoun) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                // Tags first in the cluster, before the lifecycle controls: it is the one action
                // here that changes nothing about what the selection *is*.
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
                Divider().frame(height: 14)
                // The rows' glyphs, not words — the same four actions must not look like
                // different controls depending on how many things you selected. A group in the
                // selection is started and stopped the way its own row would do it.
                let containers = actionableContainerIDs, groups = actionableGroups
                iconButton("play.fill", "Start \(selectionNoun)", busy: selectionBusy) {
                    Task { await startSelected(containers, groups) }
                }
                iconButton("stop.fill", "Stop \(selectionNoun)", busy: selectionBusy) {
                    Task { await stopSelected(containers, groups) }
                }
                iconButton("arrow.clockwise", "Restart \(selectionNoun)", busy: selectionBusy) {
                    Task { await restartSelected(containers, groups) }
                }
                iconButton("trash", "Delete \(selectionNoun)",
                           busy: selectionBusy, destructive: true) {
                    confirmingBulkDelete = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// Every container's events, newest first, flattened into one list.
    ///
    /// Across all containers rather than the visible ones: a filter is about what you are
    /// looking at, and a container that just died is exactly the thing you want to be told
    /// about even if the current filter hides it.
    /// Groups' events too, since groups live here now: starting a stack is activity on this
    /// screen.
    private var activityEntries: [ActivityStrip.Entry] {
        let containerEntries = model.containers.flatMap { container in
            model.events(for: container.id, kind: .container).map {
                ActivityStrip.Entry(id: $0.id, subject: container.id, event: $0)
            }
        }
        let groupEntries = model.events(ofKind: .group).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
        return (containerEntries + groupEntries).sorted { $0.event.date > $1.event.date }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Distinguish "cannot see the fleet" from "the fleet is empty". Showing an
            // empty table on a failed poll is the exact class of bug that made an
            // unreachable printer look healthy in a sibling tool.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
            // Fills the pane like the empty state below, so the activity strip stays at the
            // bottom when the runtime is unreachable too.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where rows.isEmpty:
            // An empty state that carries the primary action, per `FEATURES.md`. Until the
            // run sheet existed there was nothing to offer here; now "no containers" has an
            // obvious next step, and a filtered-empty list can undo the thing hiding rows
            // rather than leaving the user to work out which control did it.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No containers", systemImage: "tray")
            } description: {
                Text(isFiltered
                     ? "Nothing matches the current filter."
                     : "Nothing is running on this Mac yet. Run a container, or create a group to start several together.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") {
                        ui.search = ""
                        ui.filter = .all
                        ui.kindFilter = .all
                    }
                } else {
                    VStack(spacing: 14) {
                        HStack {
                            Button("Run a Container…") { showingRun = true }
                                .buttonStyle(.borderedProminent)
                            Button("New Group…") { editingGroup = .new }
                        }
                        // A few Suggestions, as decided: an empty list is where a ready-made
                        // stack is most useful.
                        SuggestionQuickPicks(
                            picks: StackSuggestion.catalogue.prefix(3).map { stack in
                                (stack.title, { suggestionPick = stack; showingSuggestions = true })
                            },
                            more: { suggestionPick = nil; showingSuggestions = true })
                    }
                }
            }
            // Fills the pane, the same way the loading branch above and the table below do.
            // Without it `content` sizes to this view's intrinsic height, the enclosing VStack
            // shrinks to less than the pane, and SwiftUI centres it — which put a large blank
            // band *above the toolbar* and another below the activity strip. A tester reported
            // it as "a huge gap on the top of the screen between the controls and the toolbar",
            // and noticed it only here because the other sections were not empty at the time.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    /// The table fills the pane.
    ///
    /// It used to be capped to `count * 28 + 32` for lists under twelve, to avoid the
    /// alternating placeholder rows macOS draws past the last real row. Two things were wrong
    /// with that. The constant guessed a 28pt row and the real rows are taller, so the space
    /// computed for five containers held four and the fifth had to be scrolled to — inside a
    /// pane with a large empty margin beneath it, which is worse than any placeholder row.
    /// And the Machines table never had the cap, so the two sections behaved differently.
    ///
    /// Any fix that keeps the cap needs the true row height, which depends on the font, the
    /// control size and whether a cell wraps — a number this file cannot know and would have
    /// to re-guess every time the row changes. Filling the pane needs no such number.
    /// One table row: the container **plus the sampled figures shown beside it**.
    ///
    /// The table used to be built straight from `[Container]`, and that is why clicking CPU or
    /// Memory did nothing: a `TableColumn` sorts only when given a `value:` key path, and those
    /// two figures do not live on `Container` — they come from `StatsSampler` via the model, keyed
    /// by id. SwiftUI has no custom-comparator column either (checked the macOS 26 SDK: there is
    /// no `sortUsing:` initialiser), so the only way to sort on them is to put them on the row.
    struct ContainerRow: Identifiable {
        /// Since 5 October a row is a standalone container, a group, or a member under an open
        /// group (to-do item 4). One type, because `Table` has one value type; a branch on
        /// `kind` in each cell, because the three genuinely differ.
        enum Kind { case container, group, member }

        let kind: Kind
        /// The container behind the row: the container itself, or a member's if it exists yet.
        /// `nil` for a group, and for a member the group has not created.
        let container: Container?
        /// The group, for a group row and for each of its members.
        let group: ContainerGroup?
        let member: GroupMember?
        let groupState: GroupState?
        /// **`-1` means unsampled, not idle.** The cell renders a dash for it; this value exists
        /// only to sort with. For a group it is the sum over sampled members.
        let cpu: Double
        let memory: Int64
        let id: String

        // MARK: Sort keys, one per sortable column, valid for every kind

        let name: String
        let stateRank: Int
        let kindLabel: String
        let imageSortKey: String
        let creationSortKey: String
        /// The lowest published host port, or `Int.max` when nothing is published, so those
        /// gather at one end. Numeric, because as text "8080" sorts before "9".
        let portSortKey: Int
        /// Octets zero-padded, so `.9` sorts before `.10`.
        let ipSortKey: String

        /// A group's row id is namespaced, because a group and a container could otherwise share a
        /// name; a container's and a member's id is the container name, which is unique, since a
        /// grouped container never also appears as a standalone row.
        static func groupRowID(_ groupID: String) -> String { "group:" + groupID }
        static func isGroupRowID(_ id: String) -> Bool { id.hasPrefix("group:") }

        init(container: Container, kind: Kind = .container, group: ContainerGroup? = nil,
             member: GroupMember? = nil, cpu: Double, memory: Int64) {
            self.kind = kind
            self.container = container
            self.group = group
            self.member = member
            self.groupState = nil
            self.cpu = cpu
            self.memory = memory
            self.id = container.id
            self.name = container.id
            self.stateRank = container.sortRank * 2
            self.kindLabel = "Container"
            self.imageSortKey = container.imageReference
            self.creationSortKey = container.creationSortKey
            self.portSortKey = container.publishedPorts.map(\.hostPort).min() ?? .max
            self.ipSortKey = Self.paddedIP(container.ipv4)
        }

        /// A member the group has not created yet.
        init(uncreated member: GroupMember, in group: ContainerGroup) {
            self.kind = .member
            self.container = nil
            self.group = group
            self.member = member
            self.groupState = nil
            self.cpu = -1
            self.memory = -1
            self.id = member.name
            self.name = member.name
            self.stateRank = GroupState.notCreated.sortRank
            self.kindLabel = "Container"
            self.imageSortKey = member.image
            self.creationSortKey = "9999"
            self.portSortKey = .max
            self.ipSortKey = ""
        }

        init(group: ContainerGroup, state: GroupState, cpu: Double, memory: Int64) {
            self.kind = .group
            self.container = nil
            self.group = group
            self.member = nil
            self.groupState = state
            self.cpu = cpu
            self.memory = memory
            self.id = Self.groupRowID(group.id)
            self.name = group.name
            self.stateRank = state.sortRank
            self.kindLabel = "Group"
            self.imageSortKey = ""
            self.creationSortKey = "9999"
            self.portSortKey = .max
            self.ipSortKey = ""
        }

        private static func paddedIP(_ ip: String?) -> String {
            guard let ip else { return "" }
            return ip.split(separator: ".").map { String(format: "%03d", Int($0) ?? 0) }.joined(separator: ".")
        }
    }

    private func containerRow(_ container: Container, kind: ContainerRow.Kind = .container,
                              group: ContainerGroup? = nil, member: GroupMember? = nil) -> ContainerRow {
        ContainerRow(container: container, kind: kind, group: group, member: member,
                     cpu: model.cpuPercent(for: container.id) ?? -1,
                     memory: model.memoryBytes(for: container.id) ?? -1)
    }

    /// The listing, as rows: top-level rows sorted by whatever header was clicked, and each open
    /// group's members under it, **sorted by the same header** (the owner, 5 October). A group
    /// never splits apart: its members always sit directly under it.
    private var sortedRows: [ContainerRow] {
        var top: [ContainerRow] = []
        var children: [ContainerRow.ID: [ContainerRow]] = [:]
        for item in listing {
            switch item {
            case .container(let container):
                top.append(containerRow(container))
            case .group(let group, let members, let expandForSearch):
                let memberRows = members.map { m in
                    m.container.map { containerRow($0, kind: .member, group: group, member: m.member) }
                        ?? ContainerRow(uncreated: m.member, in: group)
                }
                let sampledCPU = memberRows.map(\.cpu).filter { $0 >= 0 }
                let sampledMemory = memberRows.map(\.memory).filter { $0 >= 0 }
                let row = ContainerRow(group: group, state: model.state(of: group),
                                       cpu: sampledCPU.isEmpty ? -1 : sampledCPU.reduce(0, +),
                                       memory: sampledMemory.isEmpty ? -1 : sampledMemory.reduce(0, +))
                top.append(row)
                if ui.expandedGroupIDs.contains(group.id) || expandForSearch {
                    children[row.id] = memberRows.sorted(using: ui.sortOrder)
                }
            }
        }
        return top.sorted(using: ui.sortOrder).flatMap { [$0] + (children[$0.id] ?? []) }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $ui.sortOrder,
                  columnCustomization: $ui.columnCustomization) {
                // **Column one carries the selection checkbox and the state dot together** —
                // `TableColumnBuilder` accepts at most ten columns. Dot only for state, with the
                // CLI's own string on hover and for VoiceOver (UI-01, closed as won't-do
                // 2026-08-23). A group's dot is green, grey or half-filled for partly running.
                TableColumn("", value: \.stateRank) { (row: ContainerRow) in
                    HStack(spacing: 6) {
                        selectionToggle(for: row.id, name: row.name)
                        switch row.kind {
                        case .group:
                            if let state = row.groupState { GroupStateDot(state: state) }
                        case .member:
                            ServiceStateDot(container: row.container)
                        case .container:
                            if let c = row.container {
                                Circle()
                                    .fill(c.stateColor)
                                    .frame(width: 8, height: 8)
                                    .help(c.status.state.capitalized)
                                    .accessibilityLabel(c.status.state.capitalized)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 52, ideal: 64, max: 80)
                .customizationID("state")

                TableColumn("Name", value: \.name) { row in
                    nameCell(row)
                }

                // The indicator column the owner asked for: a group and a container read apart
                // at a glance, with the caret as the second cue.
                TableColumn("Type", value: \.kindLabel) { row in
                    Label(row.kindLabel, systemImage: row.kind == .group ? Section.groupSymbol : "shippingbox")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 100)
                .customizationID("type")

                // Next to the name, the way Finder puts a tag beside a filename. Unsorted: a row's
                // tags live in `TagStore`, not on the model.
                TableColumn("Tags") { row in
                    if row.kind == .group, let group = row.group {
                        TagPillRow(tags: model.tags.tags(on: .group, group.id), compact: true)
                    } else {
                        TagPillRow(tags: model.tags.tags(on: .container, row.id), compact: true)
                    }
                }
                .width(min: 60, ideal: 130)
                .customizationID("tags")

                TableColumn("Image", value: \.imageSortKey) { row in
                    imageCell(row)
                }
                .width(min: 90, ideal: 150)
                .customizationID("image")
                TableColumn("Created", value: \.creationSortKey) { row in
                    if let c = row.container {
                        Text(Self.createdLabel(c.configuration.creationDate))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(Self.createdTooltip(c.configuration.creationDate))
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 80, ideal: 100)
                .customizationID("created")
                TableColumn("Ports", value: \.portSortKey) { row in
                    // An em dash, not a blank cell: "publishes nothing" and "we couldn't read
                    // this" must not look the same.
                    let summary = row.container?.portSummary
                    Text(summary ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(summary == nil ? .tertiary : .secondary)
                        .help(summary ?? "No published ports")
                }
                .width(min: 80, ideal: 110)
                .customizationID("ports")
                trailingColumns
            }
            // On the Table, not on a cell: `.contextMenu` inside a `TableColumn` covers one cell.
            .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
                tableContextMenu(for: ids)
            } primaryAction: { ids in
                // Double-click opens — a container's detail, a group's form — but only when the
                // activation names exactly ONE row: with several selected, `ids.first` is an
                // arbitrary member. (Found by Grok 4.6 in review, 2026-08-18.)
                guard ids.count == 1, let id = ids.first, let row = rowsByID[id] else { return }
                if row.kind == .group, let group = row.group {
                    editingGroup = .existing(group.id)
                } else if let container = row.container {
                    openDetail(container.id)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The name, by kind.
    ///
    /// - A **container** is a link to its detail, the way Docker Desktop does it.
    /// - A **group** has the caret that opens it, then its name, which opens its form. The caret is
    ///   a button of its own, so a click on the name never means two things.
    /// - A **member** is indented under its group and links to its container — or, if the group
    ///   has not created it yet, is plain text, not a link to a page about nothing.
    @ViewBuilder
    private func nameCell(_ row: ContainerRow) -> some View {
        switch row.kind {
        case .container:
            Button { openDetail(row.id) } label: { Text(row.name).lineLimit(1) }
                .buttonStyle(.link)
                // A selected row is filled with the system accent, and a link-blue name on a blue
                // fill vanishes, so the colour has to know. See `Theme.rowName`.
                .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                .help("Open \(row.name)")
        case .group:
            if let group = row.group {
                HStack(spacing: 4) {
                    caret(for: group)
                    Button(group.name) { editingGroup = .existing(group.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                        .lineLimit(1)
                        .help("Edit \(group.name)")
                }
            }
        case .member:
            HStack(spacing: 4) {
                Color.clear.frame(width: 20, height: 16)
                if row.container != nil {
                    Button(row.name) { openDetail(row.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                        .lineLimit(1)
                        .help("Open \(row.name)")
                } else {
                    Text(row.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Not created yet — starting “\(row.group?.name ?? "")” creates it")
                }
            }
        }
    }

    /// The disclosure caret. A group with no services has none — an empty disclosure is the
    /// control-that-does-nothing failure in miniature — but keeps the space, so names line up.
    @ViewBuilder
    private func caret(for group: ContainerGroup) -> some View {
        if group.members.isEmpty {
            Color.clear.frame(width: 16, height: 16)
        } else {
            let open = ui.expandedGroupIDs.contains(group.id)
            Button {
                if open { ui.expandedGroupIDs.remove(group.id) } else { ui.expandedGroupIDs.insert(group.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide the containers in \(group.name)" : "Show the containers in \(group.name)")
            .help(open ? "Hide containers" : "Show \(group.members.count) containers")
        }
    }

    @ViewBuilder
    private func imageCell(_ row: ContainerRow) -> some View {
        if row.kind == .group, let group = row.group {
            // What the group is made of, not one image: a count, with every image on hover.
            Text(group.members.isEmpty ? "No services" : "\(group.members.count) services")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(group.members.map { "\($0.name) — \($0.image)" }.joined(separator: "\n"))
        } else {
            let reference = row.container?.configuration.image.reference ?? row.member?.image ?? ""
            Text(Self.imageLabel(reference))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.container == nil ? .secondary : .primary)
                .help(reference)
        }
    }

    /// A container's IP and network; a group's network, which all its members join.
    private func ipNetworkLabel(_ row: ContainerRow) -> String {
        if row.kind == .group, let group = row.group { return group.network ?? "default" }
        guard let container = row.container else { return "—" }
        return Self.ipNetworkLabel(container)
    }

    /// The Cards toggle: a card per standalone container and a card per group, in the table's
    /// top-level order. A group's card shows a chip per member, and clicking a chip opens that
    /// container (the owner, 5 October).
    private var cards: some View {
        let topLevel = rows.filter { $0.kind != .member }
        let members = Dictionary(listing.compactMap { item -> (String, [ContainerListing.Member])? in
            if case .group(let group, let members, _) = item { return (group.id, members) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        // The shared grid: top-aligned, the same columns as every section, and every card the
        // height of the tallest, so a group card no longer sits shorter than its neighbours.
        return ResourceCardGrid {
                ForEach(topLevel) { row in
                    if row.kind == .group, let group = row.group, let state = row.groupState {
                        GroupCard(group: group, state: state, members: members[group.id] ?? [],
                                  tags: model.tags.tags(on: .group, group.id),
                                  onEdit: { editingGroup = .existing(group.id) },
                                  onOpenMember: { openDetail($0) }) {
                            groupRowActions(for: group)
                        }
                        .contextMenu { groupMenu(for: group) }
                    } else if let container = row.container {
                        ContainerCard(
                            container: container,
                            cpuPercent: model.cpuPercent(for: container.id),
                            memoryBytes: model.memoryBytes(for: container.id),
                            history: model.cpuHistory(for: container.id),
                            isBusy: model.isBusy(container.id, kind: .container),
                            tags: model.tags.tags(on: .container, container.id),
                            onStart: { Task { await model.perform(.start, on: container) } },
                            onStop: { Task { await model.perform(.stop, on: container) } },
                            onRestart: { Task { await model.perform(.restart, on: container) } },
                            onDetails: { openDetail(container.id) },
                            onDelete: { requestDelete(container) },
                            menuContent: { actions(for: container) }
                        )
                        // Same menu as the table row and the card's own `⋯`: one builder.
                        .contextMenu { actions(for: container) }
                    }
                }
        }
    }

    /// `creationDate` is an ISO-8601 string from `container`, not a `Date` — parse it here
    /// for display only; `FlotillaCore` keeps the raw string.
    private static func createdLabel(_ iso: String?) -> String { RelativeDate.relative(iso) }

    /// The absolute timestamp, for the row's tooltip.
    private static func createdTooltip(_ iso: String?) -> String { RelativeDate.absolute(iso) }

    /// Shortening lives in `FlotillaCore` (`ContainerImage.shortReference`) so its awkward
    /// cases — digests, registry ports — are covered by tests this target cannot have.
    private static func imageLabel(_ reference: String) -> String {
        ContainerImage.shortReference(reference)
    }

    private static func ipNetworkLabel(_ c: Container) -> String {
        switch (c.ipv4, c.status.networks?.first?.network) {
        case let (ip?, network?): "\(ip) (\(network))"
        case let (ip?, nil): ip
        case let (nil, network?): network
        case (nil, nil): "—"
        }
    }
}
