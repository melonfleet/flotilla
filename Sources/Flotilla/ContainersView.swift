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
/// (Phase 1 UI contract), then extended here with filter tabs, a bulk-action bar, the
/// Created/IP columns, and the detail sheet hook.
struct ContainersView: View {
    let model: AppModel

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

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: Self { self }
    }

    @State private var presentation: Presentation = .list
    @State private var filter: Filter = .all
    @State private var selection = Set<Container.ID>()
    @State private var search = ""
    @State private var detailContainer: Container?
    @State private var confirmingBulkDelete = false
    /// Non-nil while a single row's trash button is awaiting confirmation. Destructive
    /// actions confirm with the object *named* (`FEATURES.md`'s destructive-action policy),
    /// which is why this holds the container rather than a bool.
    @State private var confirmingRowDelete: Container?
    /// Running-first by default, per DECISIONS.md Q2. Sorting is on state, so the containers
    /// you can act on stay at the top rather than being buried alphabetically.
    @State private var sortOrder = [KeyPathComparator(\Container.sortRank)]
    @State private var showingRun = false

    /// Which columns are shown, in what order and at what width — driven by the header's
    /// own right-click menu, which is what `FEATURES.md` means by "hideable columns".
    ///
    /// Host starts hidden: with a single host it prints "This Mac" on every row. Ten columns
    /// cannot fit a window, and the table was scrolling sideways with the Actions column off
    /// the right-hand edge entirely, which is the bug this fixes.
    ///
    /// Deliberately **not** persisted into `SettingsStore`: `FEATURES.md` keeps window and UI
    /// state separate from preferences precisely so "reset preferences" does not rearrange
    /// your table. Persisting it belongs with the window-state work, not here.
    @State private var columnCustomization: TableColumnCustomization<Container> = {
        var customization = TableColumnCustomization<Container>()
        // Host: one host today, so it prints "This Mac" on every row.
        customization[visibility: "host"] = .hidden
        // Created: the identifier and the live figures earn their space first. The owner asked
        // for this hidden by default in favour of showing the container's id — and on
        // Apple's `container` the id *is* the name, so the Name column already covers it
        // (see `columnSpecs`).
        customization[visibility: "created"] = .hidden
        return customization
    }()

    @State private var showingColumns = false

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
        Button {
            showingColumns.toggle()
        } label: {
            Image(systemName: "rectangle.split.3x1")
        }
        .help("Show or hide columns")
        .accessibilityLabel("Columns")
        .popover(isPresented: $showingColumns, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.columnSpecs, id: \.id) { spec in
                    Toggle(spec.title, isOn: binding(for: spec.id))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
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

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { columnCustomization[visibility: id] != .hidden },
            set: { columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    /// `Visibility` is SwiftUI's own top-level enum, not a type nested in
    /// `TableColumnCustomization` — the `[visibility:]` subscript trades in the same
    /// `.automatic / .visible / .hidden` used everywhere else in SwiftUI.
    private func setAllColumns(_ visibility: Visibility) {
        for spec in Self.columnSpecs {
            columnCustomization[visibility: spec.id] = visibility
        }
    }

    private var filtered: [Container] {
        switch filter {
        case .all: model.containers
        case .running: model.running
        case .stopped: model.stopped
        }
    }

    private var visible: [Container] {
        guard !search.isEmpty else { return filtered }
        let needle = search.lowercased()
        return filtered.filter {
            $0.id.lowercased().contains(needle) || $0.status.state.lowercased().contains(needle)
        }
    }

    /// `visible` filtered, then ordered by whatever the user clicked in the header.
    ///
    /// The table binds to this rather than to `visible` — a `Table` with a `sortOrder`
    /// binding does **not** reorder its rows for you, it only reports what was clicked.
    /// Binding the header without applying the comparator gives arrows that move and rows
    /// that never do.
    private var sorted: [Container] { visible.sorted(using: sortOrder) }

    /// Whether anything the user chose is hiding rows. Both the search field and the filter
    /// tabs can empty the table, and an empty state that only mentions search would be wrong
    /// half the time.
    private var isFiltered: Bool { !search.isEmpty || filter != .all }

    private var visibleIDs: Set<Container.ID> { Set(visible.map(\.id)) }

    /// What a bulk action may actually touch: the selection **intersected with what is on
    /// screen**.
    ///
    /// `selection` outlives the rows that produced it. Select three containers under
    /// `All`, switch the filter to `Running` so two of them are hidden, and the raw
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
                Button("Details…") { detailContainer = container }
                Divider()
                copyMenu(for: container)
            } label: {
                Image(systemName: "ellipsis")
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
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)          // even taps regardless of glyph width
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .disabled(busy)
        .help(help)
        .accessibilityLabel(label)
    }

    /// `FEATURES.md` asks for a Copy submenu (id, image, IP, port URL) on the row. Shape and
    /// nil-dropping come from `CopyMenu` so every surface's Copy menu behaves alike.
    private func copyMenu(for container: Container) -> CopyMenu {
        CopyMenu([
            ("Name", container.id),
            ("Image", container.configuration.image.reference),
            ("IP Address", container.ipv4),
            // The useful form is something you can paste into a browser, not the mapping.
            ("Port URL", container.publishedPorts.first.map { "http://localhost:\($0.hostPort)" }),
        ])
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
        Button("Details…") { detailContainer = container }
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
        VStack(spacing: 0) {
            toolbar
            bulkActionBar
            Divider()
            content
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(item: $detailContainer) { container in
            ContainerDetailView(model: model, container: container)
        }
        .sheet(isPresented: $showingRun) {
            RunSheetView(model: model)
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
            Picker("View", selection: $presentation) {
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
                .disabled(presentation != .list)     // cards have no columns to configure

            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            TextField("Search containers…", text: $search)
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
                    }
                    .help("Create and start a new container")

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
        // Glass on the toolbar band itself, matching the sidebar. The table below stays
        // opaque — it is the content layer.
        .background(.ultraThinMaterial)
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
                        search = ""
                        filter = .all
                    }
                } else {
                    Button("Run a Container…") { showingRun = true }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .loaded:
            if presentation == .list { table } else { cards }
        }
    }

    /// A macOS `Table` fills all available vertical space with alternating-background
    /// placeholder rows past the last real one, which looks broken with just a handful of
    /// containers. Cap the table to its content height for short lists and let a plain
    /// `Spacer` take the rest; once the list is long enough to need scrolling, let the
    /// table fill normally.
    private var table: some View {
        VStack(spacing: 0) {
            Table(sorted, selection: $selection, sortOrder: $sortOrder,
                  columnCustomization: $columnCustomization) {
                TableColumn("State", value: \.sortRank) { c in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppModel.isRunning(c) ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(c.status.state.capitalized)
                    }
                }
                .width(min: 76, ideal: 92)
                .customizationID("state")

                TableColumn("Name", value: \.id) { c in
                    Text(c.id)
                        .lineLimit(1)
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

                // Hidden by default (see `columnCustomization`): with one host it reads
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
                    detailContainer = container
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
                        onDetails: { detailContainer = container },
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
    private static func createdLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else { return "—" }
        // Relative, not absolute. "Jul 27, 2026 at 5:56 PM" does not fit the column and
        // truncated to "Jul 27, 2026 at 5:56 P…" it wastes every character on parts that
        // never vary. Age is the question you actually ask of a container; the exact
        // timestamp stays available on hover.
        return date.formatted(.relative(presentation: .named))
    }

    /// The absolute timestamp, for the row's tooltip.
    private static func createdTooltip(_ iso: String?) -> String {
        guard let iso else { return "Creation date unknown" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else {
            return "Creation date unreadable (\(iso))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

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
