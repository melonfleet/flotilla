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
    private struct DetailTarget: Identifiable, Hashable {
        let id: String
    }
    @State private var confirmingBulkDelete = false
    /// Non-nil while a single row's trash button is awaiting confirmation. Destructive
    /// actions confirm with the object *named* (`FEATURES.md`'s destructive-action policy),
    /// which is why this holds the container rather than a bool.
    @State private var confirmingRowDelete: Container?
    @State private var showingRun = false


    @State private var showingColumns = false
    @State private var showingFilter = false

    /// The columns the Columns popover offers, in table order.
    ///
    /// Name and Actions are deliberately absent: Name is the row's identity and Actions is
    /// how you operate on it, so neither is something to hide. Docker Desktop's own column
    /// menu makes the same choice about its Name column.
    private static let columnSpecs: [(id: String, title: String)] = [
        ("state", "State"),
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
        RunSheetView(model: model) { showingRun = false }
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
                ContainerDetailView(model: model, container: container)
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
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) { rowActions(for: container) }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(in: .rect(cornerRadius: 8))
                }
                .fixedSize()
            }
        }
        .padding(12)
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

    private func openDetail(_ id: String) {
        detailTarget = DetailTarget(id: id)
    }

    /// Same icon-and-popover shape as `columnsButton` — both answer "what am I looking at",
    /// so both are a glyph with a menu rather than words spread across the toolbar. The
    /// contents differ because the questions differ: columns are independent (checkboxes),
    /// the state filter is one choice (radio).
    ///
    /// The icon fills when a filter is active, so a hidden state is visible from the toolbar
    /// rather than something you discover by wondering where your containers went.
    private var filterButton: some View {
        Button {
            showingFilter.toggle()
        } label: {
            Image(systemName: ui.filter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .help(ui.filter == .all ? "Filter by state" : "Showing \(ui.filter.rawValue.lowercased()) only")
        .accessibilityLabel("Filter by state")
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            Picker("Show", selection: $ui.filter) {
                ForEach(Filter.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(14)
        }
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

    private var filtered: [Container] {
        switch ui.filter {
        case .all: model.containers
        case .running: model.running
        case .stopped: model.stopped
        }
    }

    private var visible: [Container] {
        guard !ui.search.isEmpty else { return filtered }
        let needle = ui.search.lowercased()
        return filtered.filter {
            $0.id.lowercased().contains(needle) || $0.status.state.lowercased().contains(needle)
        }
    }

    /// `visible` filtered, then ordered by whatever the user clicked in the header.
    ///
    /// The table binds to this rather than to `visible` — a `Table` with a `ui.sortOrder`
    /// binding does **not** reorder its rows for you, it only reports what was clicked.
    /// Binding the header without applying the comparator gives arrows that move and rows
    /// that never do.
    private var sorted: [Container] { visible.sorted(using: ui.sortOrder) }

    /// Whether anything the user chose is hiding rows. Both the search field and the state
    /// tabs can empty the table, and an empty state that only mentions ui.search would be wrong
    /// half the time.
    private var isFiltered: Bool { !ui.search.isEmpty || ui.filter != .all }

    private var visibleIDs: Set<Container.ID> { Set(visible.map(\.id)) }

    /// What a bulk action may actually touch: the selection **intersected with what is on
    /// screen**.
    ///
    /// `selection` outlives the rows that produced it. Select three containers under
    /// `All`, hide the running ones so two of them disappear, and the raw
    /// selection still holds all three — so a bulk Delete would destroy two containers the
    /// user cannot see and was never shown in the confirmation count. Searching hides rows
    /// the same way, and a deleted container leaves its id behind entirely. Every bulk
    /// path therefore acts on this, never on `selection`.
    private var actionable: Set<Container.ID> { selection.intersection(visibleIDs) }

    /// True while any actionable id has an action in flight — disables the bulk bar so a
    /// second click can't fire a duplicate operation on top of the first.
    private var selectionBusy: Bool { !actionable.isDisjoint(with: model.busy) }

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
    @ViewBuilder
    private func rowActions(for container: Container) -> some View {
        let busy = model.busy.contains(container.id)
        let running = AppModel.isRunning(container)

        HStack(spacing: 2) {
            if running {
                iconButton("stop.fill", "Stop", help: "Stop \(container.id)", busy: busy) {
                    Task { await model.perform(.stop, on: container) }
                }
                iconButton("arrow.clockwise", "Restart", help: "Restart \(container.id)", busy: busy) {
                    Task { await model.perform(.restart, on: container) }
                }
            } else {
                iconButton("play.fill", "Start", help: "Start \(container.id)", busy: busy) {
                    Task { await model.perform(.start, on: container) }
                }
                // Keeps the column a stable width whichever state the row is in, so the
                // buttons don't jump sideways as containers start and stop.
                iconButton("arrow.clockwise", "Restart", help: "Restart \(container.id)", busy: true) {}
                    .hidden()
            }

            // The overflow: everything that isn't a one-tap lifecycle action.
            Menu {
                Button("Details…") { openDetail(container.id) }
                Divider()
                copyMenu(for: container)
            } label: {
                Image(systemName: "ellipsis.vertical")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(container.id)")
            .disabled(busy)

            Divider().frame(height: 14)

            iconButton("trash", "Delete", help: "Delete \(container.id)", busy: busy, destructive: true) {
                confirmingRowDelete = container
            }
        }
    }

    private func iconButton(
        _ symbol: String, _ label: String, help: String,
        busy: Bool, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        // Delegates to the shared button so the containers rows, the machines rows and the
        // section toolbars all give the same feedback. See `IconActionButton`.
        IconActionButton(systemImage: symbol, label: label, help: help,
                         busy: busy, destructive: destructive, action: action)
    }

    /// `FEATURES.md` asks for a Copy submenu (id, image, IP, port URL) on the row. The contents
    /// now live on `CopyMenu` itself so the card gets the identical menu — see
    /// `CopyMenu.forContainer`.
    private func copyMenu(for container: Container) -> CopyMenu {
        CopyMenu.forContainer(container)
    }

    /// The context menu for a right-click that landed on one or more rows.
    ///
    /// `ids` comes from the table itself, so everything in it is on screen by construction —
    /// this is the one bulk path that does not need intersecting with `visible`.
    @ViewBuilder
    private func tableContextMenu(for ids: Set<Container.ID>) -> some View {
        if ids.isEmpty {
            // Right-click on empty space still deserves the primary action rather than an
            // empty menu that looks like a bug.
            Button("Run a Container…") { showingRun = true }
        } else if ids.count == 1,
                  let container = visible.first(where: { $0.id == ids.first }) {
            actions(for: container)
        } else {
            let busy = !ids.isDisjoint(with: model.busy)
            Button("Start \(ids.count)") { Task { await model.performBulk(.start, on: ids) } }
                .disabled(busy)
            Button("Stop \(ids.count)") { Task { await model.performBulk(.stop, on: ids) } }
                .disabled(busy)
            Button("Restart \(ids.count)") { Task { await model.performBulk(.restart, on: ids) } }
                .disabled(busy)
            Divider()
            Button("Delete \(ids.count)…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(busy)
        }
    }

    /// Start/stop/restart/delete for one container. Attached to both the table rows and
    /// the cards so the two views offer the same capabilities — a toggle that changes what
    /// you can *do*, not just how it looks, is a trap.
    @ViewBuilder
    private func actions(for container: Container) -> some View {
        let busy = model.busy.contains(container.id)
        Button("Details…") { openDetail(container.id) }
        Divider()
        if AppModel.isRunning(container) {
            Button("Stop") { Task { await model.perform(.stop, on: container) } }.disabled(busy)
            Button("Restart") { Task { await model.perform(.restart, on: container) } }.disabled(busy)
        } else {
            Button("Start") { Task { await model.perform(.start, on: container) } }.disabled(busy)
        }
        Divider()
        // Destructive, and deliberately only in the main window — never the popover.
        Button("Delete", role: .destructive) {
            Task { await model.perform(.delete, on: container) }
        }.disabled(busy)
    }

    var body: some View {
        Group {
            if showingRun {
                runScreen
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                }
            }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
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
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(actionable.count) container\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Container\(actionable.count == 1 ? "" : "s")", role: .destructive) {
                Task { await model.performBulk(.delete, on: actionable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
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

            TextField("Search containers…", text: $ui.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The mockup's **one** `GlassEffectContainer` — the Run/Pull control cluster.
            // Kept to a single container deliberately: the placement note says glass belongs
            // on chrome only, and stacking glass on glass is explicitly ruled out.
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        showingRun = true
                    } label: {
                        Label("Run…", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    // Icon only, with the word on hover — the label is still there for
                    // VoiceOver and the tooltip, so nothing is lost by not printing it.
                    .help("Run a container…")
                    .accessibilityLabel("Run a container")

                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("Refresh now")
                    .accessibilityLabel("Refresh")
                    .disabled(model.state == .loading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(in: .rect(cornerRadius: 8))
            }
            .fixedSize()
        }
        .padding(12)
        // No material here, deliberately. This band sits directly beneath the window's real
        // toolbar, which on macOS 26 is Liquid Glass already; a second translucent strip under
        // it produced two disagreeing translucencies and made the `glassEffect` cluster below
        // glass-on-glass — the one thing Apple's guidance rules out. The band is the content
        // layer's own chrome, so it takes the window background and lets the real glass above
        // it be the glass.
    }

    /// Shown only while rows are multi-selected — the hook the `selection` state existed
    /// for but went unused before this.
    @ViewBuilder
    private var bulkActionBar: some View {
        // 2+, not 1+. Every row now carries its own start/stop/restart/delete, so a bar
        // above the table for a single selection would just be a second way to do the same
        // thing — and it was the bar the owner didn't want. Bulk is the one thing per-row
        // controls genuinely cannot do, so that is all it appears for.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start") { Task { await model.performBulk(.start, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Stop") { Task { await model.performBulk(.stop, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Restart") { Task { await model.performBulk(.restart, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Delete", role: .destructive) { confirmingBulkDelete = true }
                    .disabled(selectionBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
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

        case .loaded where visible.isEmpty:
            // An empty state that carries the primary action, per `FEATURES.md`. Until the
            // run sheet existed there was nothing to offer here; now "no containers" has an
            // obvious next step, and a filtered-empty list can undo the thing hiding rows
            // rather than leaving the user to work out which control did it.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No containers", systemImage: "tray")
            } description: {
                Text(isFiltered
                     ? "No container matches the current filter."
                     : "Nothing is running on this Mac yet.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") {
                        ui.search = ""
                        ui.filter = .all
                    }
                } else {
                    Button("Run a Container…") { showingRun = true }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    /// A macOS `Table` fills all available vertical space with alternating-background
    /// placeholder rows past the last real one, which looks broken with just a handful of
    /// containers. Cap the table to its content height for short lists and let a plain
    /// `Spacer` take the rest; once the list is long enough to need scrolling, let the
    /// table fill normally.
    private var table: some View {
        VStack(spacing: 0) {
            Table(sorted, selection: $selection, sortOrder: $ui.sortOrder,
                  columnCustomization: $ui.columnCustomization) {
                // Dot only — see the matching column in `MachinesView`. The exact state word
                // matters more here than for machines, because `stateColor` folds several
                // states into one colour: "exited (137)" and "dead" are both danger red. So the
                // tooltip carries the CLI's own string rather than a tidied-up version of it.
                TableColumn("", value: \.sortRank) { c in
                    Circle()
                        .fill(c.stateColor)
                        .frame(width: 8, height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(c.status.state.capitalized)
                        .accessibilityLabel(c.status.state.capitalized)
                }
                .width(min: 26, ideal: 28, max: 34)
                .customizationID("state")

                TableColumn("Name", value: \.id) { c in
                    // Clicking the name opens the container, the way Docker Desktop does.
                    // A plain `Button` inside a `Table` row swallows row selection, so this
                    // is a link-styled button with the selection behaviour left intact:
                    // `.buttonStyle(.link)` keeps the click local to the text.
                    Button {
                        openDetail(c.id)
                    } label: {
                        Text(c.id).lineLimit(1)
                    }
                    .buttonStyle(.link)
                    // `.link` hardcodes the system blue and ignores the scene tint.
                    .foregroundStyle(Theme.accentText)
                    .help("Open \(c.id)")
                }
                TableColumn("Image", value: \.imageReference) { c in
                    Text(Self.imageLabel(c.configuration.image.reference))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(c.configuration.image.reference)
                }
                .width(min: 90, ideal: 150)
                .customizationID("image")
                TableColumn("Created", value: \.creationSortKey) { c in
                    Text(Self.createdLabel(c.configuration.creationDate))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Self.createdTooltip(c.configuration.creationDate))
                }
                .width(min: 80, ideal: 100)
                .customizationID("created")
                TableColumn("Ports") { c in
                    // An em dash, not a blank cell: "publishes nothing" and "we couldn't
                    // read this" must not look the same.
                    Text(c.portSummary ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(c.portSummary == nil ? .tertiary : .secondary)
                        .help(c.portSummary ?? "No published ports")
                }
                .width(min: 80, ideal: 110)
                .customizationID("ports")
                // CPU and Memory, which the approved mockup's table has had all along and
                // this table never did. nil renders as a dash, never 0% — an unsampled
                // container is not an idle one, and a table that says 0% and then jumps is
                // lying twice.
                TableColumn("CPU") { c in
                    Text(model.cpuLabel(for: c.id))
                        .monospacedDigit()
                        .foregroundStyle(model.cpuPercent(for: c.id) == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 56, ideal: 68)
                .customizationID("cpu")

                TableColumn("Memory") { c in
                    Text(model.memoryLabel(for: c.id))
                        .monospacedDigit()
                        .foregroundStyle(model.memoryBytes(for: c.id) == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .width(min: 68, ideal: 84)
                .customizationID("memory")

                TableColumn("IP / Network") { c in
                    Text(Self.ipNetworkLabel(c))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 130)
                .customizationID("ip")

                // Hidden by default (see `ui.columnCustomization`): with one host it reads
                // "This Mac" on every row, and a column identical in every row is pure
                // width. The cross-host *dimension* stays — the data is on the row and the
                // column is one header-menu click away — it just stops costing space until
                // Phase 3 gives it something to say.
                TableColumn("Host") { _ in Text(model.hostLabel).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 100)
                    .customizationID("host")

                // Last. Sized to its content rather than fixed, so it compresses with
                // everything else instead of forcing the table wider than the window.
                TableColumn("Actions") { c in
                    rowActions(for: c)
                }
                .width(min: 118, ideal: 128)
                .customizationID("actions")
            }
            // On the Table, not on a cell: `.contextMenu` inside a `TableColumn` only covers
            // that one cell, so right-clicking a row anywhere but the name did nothing at all.
            // `forSelectionType:` also hands us the whole right-clicked selection, which is
            // what makes bulk actions reachable from the menu.
            .contextMenu(forSelectionType: Container.ID.self) { ids in
                tableContextMenu(for: ids)
            } primaryAction: { ids in
                // Double-click opens the detail sheet, matching the cards.
                if let id = ids.first, let container = visible.first(where: { $0.id == id }) {
                    openDetail(container.id)
                }
            }
            .frame(maxHeight: isShortList ? shortListHeight : .infinity)

            if isShortList { Spacer(minLength: 0) }
        }
    }

    private var isShortList: Bool { visible.count < 12 }
    private var shortListHeight: CGFloat { CGFloat(visible.count) * 28 + 32 }

    /// The Cards toggle. Previously a status dot, a name, an image and a host label — no
    /// controls at all, and none of the usage figures the mockup shows, which is exactly what
    /// the owner flagged. `ContainerCard` now carries the row's content plus its own action
    /// cluster and a CPU sparkline.
    ///
    /// Actions arrive as closures rather than the card reaching into `AppModel`: it keeps
    /// every mutation on the one path through `ContainerCLI`, and keeps the card previewable.
    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(visible) { container in
                    ContainerCard(
                        container: container,
                        cpuPercent: model.cpuPercent(for: container.id),
                        memoryBytes: model.memoryBytes(for: container.id),
                        history: model.cpuHistory(for: container.id),
                        isBusy: model.busy.contains(container.id),
                        onStart: { Task { await model.perform(.start, on: container) } },
                        onStop: { Task { await model.perform(.stop, on: container) } },
                        onRestart: { Task { await model.perform(.restart, on: container) } },
                        onDetails: { openDetail(container.id) },
                        onDelete: { confirmingRowDelete = container }
                    )
                    // Same menu as the table row, so the two presentations offer identical
                    // capabilities — a toggle that changes what you can *do* is a trap.
                    .contextMenu { actions(for: container) }
                }
            }
            .padding(12)
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
