import SwiftUI
import FlotillaCore

/// The Machines section: the Linux micro-VMs `container` runs containers inside.
///
/// Built to `research/MACHINES-SPEC.md`, and deliberately the **same shapes** as the containers
/// side — the owner asked for that explicitly. `SectionToolbar` for the control band, an embedded
/// detail screen with Back and a prev/next stepper, an embedded create form, and the same
/// two-line rows (Q56, `ResourceRow`) with the same row actions. A machine is a different noun,
/// not a different app.
///
/// Where it differs, it differs because machines *are* different:
///
/// - **Delete is louder.** A machine is the VM every container on this host runs inside, so
///   deleting one destroys the substrate rather than one workload. The confirmation says so.
/// - **The default machine is called out.** `machine set-default` decides where a bare
///   `machine stop` or `machine inspect` lands, and I put the host into a no-default state
///   earlier today simply by deleting a machine — a UI that hides that fact repeats it.
/// - **Config changes need a restart**, which the form states rather than discovering.
struct MachinesView: View {
    let model: AppModel

    /// Owned by `MainWindowView`, not here — see `MachinesUIState`. Filter, search and sort have
    /// to survive a trip to another section.
    let ui: MachinesUIState

    /// The tester compared these menus directly, so Machines uses the Containers vocabulary
    /// rather than keeping an identical second list that can drift unnoticed.
    typealias Filter = ContainersView.Filter

    /// What the Sort menu orders the rows by — one per column the old table sorted on. Ties break
    /// on name, as on Containers, so equal rows keep a stable, readable order.
    enum SortKey: String, RowSortKey, Identifiable {
        case name = "Name"
        case state = "State"
        case cpus = "CPUs"
        case memory = "Memory"
        case disk = "Disk"
        case ip = "IP"
        case created = "Created"
        var id: Self { self }

        func comparators(ascending: Bool) -> [KeyPathComparator<ContainerMachine>] {
            let order: SortOrder = ascending ? .forward : .reverse
            let byName = KeyPathComparator(\ContainerMachine.id)
            switch self {
            case .name: return [KeyPathComparator(\ContainerMachine.id, order: order)]
            case .state: return [KeyPathComparator(\ContainerMachine.stateRank, order: order), byName]
            case .cpus: return [KeyPathComparator(\ContainerMachine.cpus, order: order), byName]
            case .memory: return [KeyPathComparator(\ContainerMachine.memory, order: order), byName]
            case .disk: return [KeyPathComparator(\ContainerMachine.diskSize, order: order), byName]
            case .ip: return [KeyPathComparator(\ContainerMachine.ipSortKey, order: order), byName]
            case .created: return [KeyPathComparator(\ContainerMachine.creationSortKey, order: order), byName]
            }
        }
    }

    @State private var showingFilter = false
    @State private var selection = Set<ContainerMachine.ID>()
    /// The rows the page beside the list is showing: `selection`, once the form guard has let it
    /// through (Q58). By **id**, so the page re-reads live state each pass rather than showing a
    /// frozen copy.
    @State private var shown = Set<ContainerMachine.ID>()
    @State private var request: DetailTarget?
    @State private var showingCreate = false
    @State private var showingSuggestions = false
    @State private var createPrefill: MachineSuggestion?
    @State private var confirmingDelete: ContainerMachine?
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. A `TagSheetTarget` rather than a
    /// bare `TagSubject` — see that type for why a subject is not `Identifiable`.
    ///
    /// Presented from the view, never from inside the menu: a `.sheet` attached within a `Menu`
    /// never appears, because the menu is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?

    /// A menu's request for a machine's page on a particular tab — "Edit Settings…".
    ///
    /// The tab used to travel through `model.lastMachineTab`, written by the menu and read by
    /// `MachineDetailView.init`. That is a write-once side channel, and `@State` seeded in `init`
    /// only takes effect when SwiftUI *installs* the view — so from a detail that was already on
    /// screen (stepping between machines, or reopening one) the requested tab was silently
    /// dropped and you stayed where you were. "Edit Settings…" appearing to do nothing is exactly
    /// what that looks like. Carrying the intent in the request instead means it cannot be lost
    /// between being made and being honoured; and each request is new (`nonce`), so asking for
    /// Settings again after leaving the tab still lands on it.
    private struct DetailTarget: Hashable {
        let id: String
        var tab: MachineDetailTab?
        let nonce = UUID()
    }

    /// The tab a `requestDetail` asked for, resolved against **this** screen's own tab type.
    ///
    /// A title this screen does not have resolves to nil and the detail opens on its default tab,
    /// which is the point of carrying a title rather than an index: a request naming a tab only
    /// the other detail screen has can never land on an arbitrary third one.
    private var requestedTab: MachineDetailTab? {
        model.pendingDetailTab.flatMap(MachineDetailTab.init(rawValue:))
    }

    var body: some View {
        Group {
            // Create is a screen now, not a sheet — see `MachineFormView`. Checked before the
            // detail so "New Machine" from inside a detail still lands somewhere sensible.
            if showingCreate {
                MachineFormView(model: model, prefill: createPrefill) {
                    showingCreate = false
                    createPrefill = nil
                }
            } else if showingSuggestions {
                ResourceSuggestionsGallery(
                    intro: "Machine images that boot on container 1.5 — each was booted and "
                        + "logged in to before it was offered. Use one to open New Machine with "
                        + "it filled in.",
                    items: MachineSuggestion.catalogue,
                    use: useSuggestion,
                    dismiss: { showingSuggestions = false })
            } else {
                // Q58: the list, and the selected machine's page beside it.
                SplitPanes(list: "machines", pane: ui.pane, showing: shownMachine?.id) {
                    VStack(spacing: 0) {
                        toolbar
                        bulkActionBar
                        Divider()
                        content
                    }
                    // Without this the whole stack centres vertically whenever `content` is a
                    // `ContentUnavailableView` rather than a table, which floats the control band
                    // into the middle of the window. The toolbar is chrome; it stays at the top.
                    .frame(maxHeight: .infinity, alignment: .top)
                } detail: {
                    page
                }
            }
        }
        .task { await model.refreshMachines() }
        // `actionable` already stops a hidden row from being acted on; this stops one from being
        // counted. Filter, search and the data itself changing all move the visible set.
        .selection($selection, confinedTo: visibleIDs, showing: existingIDs)
        .paneFollows($selection, into: $shown, guard: model.formGuard, existing: existingIDs)
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        // "Open in Flotilla" from the menu-bar popover names a subject, not just a section.
        // One-shot: cleared on consumption so a rebuild does not reopen it.
        .onChange(of: model.pendingDetailSubject) { _, subject in
            // Only this section's own requests. See `AppModel.requestDetail`.
            guard let subject, model.pendingDetailKind == .machine else { return }
            open(subject, tab: requestedTab)
            model.clearPendingDetail()
        }
        .onAppear {
            if let subject = model.pendingDetailSubject, model.pendingDetailKind == .machine {
                open(subject, tab: requestedTab)
                model.clearPendingDetail()
            }
        }
        // "New Machine…" from the menu-bar popover. One-shot: consumed and cleared, so the form
        // does not reopen every time this view is rebuilt — the same shape as `pendingRunSheet`.
        .onChange(of: model.pendingMachineForm) { _, requested in
            if requested { showingCreate = true; model.pendingMachineForm = false }
        }
        .onAppear {
            if model.pendingMachineForm { showingCreate = true; model.pendingMachineForm = false }
        }
        // File ▸ Suggestions ▸ Machines…. One-shot.
        .onChange(of: model.pendingSuggestions) { _, section in
            if section == .machines { model.pendingSuggestions = nil; showingCreate = false; showingSuggestions = true }
        }
        .onAppear {
            if model.pendingSuggestions == .machines {
                model.pendingSuggestions = nil; showingCreate = false; showingSuggestions = true
            }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Delete the machine “\(confirmingDelete?.id ?? "")”?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Machine", role: .destructive) {
                if let machine = confirmingDelete {
                    Task { await model.perform(.delete, on: machine) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(deleteWarning)
        }
        .confirmationDialog(
            "Delete \(actionable.count) machine\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Machine\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                Task { await model.performMachineBulk(.delete, on: actionable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting these virtual machines destroys anything stored in them. This cannot be undone.")
        }
    }

    /// Every machine delete enters here. Machines ignored `confirmDestructiveActions` and always
    /// confirmed, so switching the preference off did nothing on this screen.
    ///
    /// Worth stating what honouring it now means: with confirmations off, deleting a machine
    /// destroys a VM and everything in it without a dialog. That is what the preference says it
    /// does, on by default, and respecting a switch the user deliberately turned off is the point
    /// of having one — but it is a real consequence, and the Settings summary now spells out that
    /// machines are included rather than listing four kinds and covering three.
    private func requestDelete(_ machine: ContainerMachine) {
        if model.deletePolicy.requiresConfirmation(.single) {
            confirmingDelete = machine
        } else {
            Task { await model.perform(.delete, on: machine) }
        }
    }

    /// Names what is actually at stake — "are you sure?" makes you go back and check which row
    /// you clicked. Extracted from the dialog because inlined it defeated the type-checker.
    private var deleteWarning: String {
        var text = "A machine is the virtual machine containers run inside. Deleting it destroys "
            + "that VM and anything stored in it, and cannot be undone."
        if confirmingDelete?.isDefault == true {
            // I put this Mac into a no-default state earlier today simply by deleting a
            // machine. A dialog that stays silent about it repeats the surprise.
            text += "\n\nThis is also the default machine, so the host will be left without one "
                + "until you set another."
        }
        return text
    }

    // MARK: List

    /// The containers screen's control band, member for member and in the same order: select-all,
    /// sort, filter, updated stamp, then the create/refresh cluster.
    ///
    /// It used to be a bare `SectionToolbar` with only search and refresh, which made Machines
    /// the one section where you could not filter by state.
    /// A section that quietly offers less than its neighbours reads as unfinished rather than
    /// as a deliberate simplification.
    private func useSuggestion(_ suggestion: MachineSuggestion) {
        createPrefill = suggestion
        showingSuggestions = false
        showingCreate = true
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search machines…",
                       matches: displayed.count,
                       updated: model.machinesLastRefresh,
                       leading: {
            SelectAllCheckbox(selection: $selection, ids: displayed.map(\.id), noun: "machines")

            // Replaces the table's clickable headers, as on Containers.
            RowSortMenu(key: Binding(get: { [weak ui] in ui?.sortKey ?? .name },
                                     set: { [weak ui] in ui?.sortKey = $0 }),
                        ascending: Binding(get: { [weak ui] in ui?.sortAscending ?? true },
                                           set: { [weak ui] in ui?.sortAscending = $0 }))

            filterButton
        }, trailing: {
            ToolbarIconMenu(systemImage: "plus", label: "Create a machine") {
                addMenuItems
            }
            ToolbarRefreshButton(label: "Refresh machines") {
                Task { await model.refreshMachines() }
            }
        })
    }

    /// "New Machine…" and "Suggestions…": the ways to add to this list, in the toolbar's "+" menu
    /// and a right-click on empty space alike.
    @ViewBuilder
    private var addMenuItems: some View {
        Button("New Machine…") { createPrefill = nil; showingCreate = true }
        Divider()
        Button("Suggestions…") { showingSuggestions = true }
    }

    /// `IconActionButton`, like every other icon control in the app — **not** a bare `Button`
    /// with an `Image`, which is what this was. That is the difference the owner spotted: the shared
    /// button carries the hover tint and the pressed scale, so a filter button that skipped it had
    /// no shading while the columns button beside it did, on the same band. Same glyph, same
    /// accent-when-active rule, same feedback, everywhere.
    private var filterButton: some View {
        IconActionButton(systemImage: "line.3.horizontal.decrease",
                         label: "Filter by state",
                         help: ui.filter == .all
                             ? "Filter by state"
                             : "Showing \(ui.filter.rawValue.lowercased()) only",
                         active: ui.filter != .all) {
            showingFilter.toggle()
        }
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            Picker("Show", selection: Binding(get: { ui.filter }, set: { ui.filter = $0 })) {
                ForEach(Filter.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(14)
        }
    }

    private var displayed: [ContainerMachine] {
        var machines = model.machines

        switch ui.filter {
        case .all: break
        case .running: machines = machines.filter { Self.isRunning($0) }
        case .stopped: machines = machines.filter { !Self.isRunning($0) }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // Name **and** image, because a machine's name is often generated and the image is
            // the thing you actually remember about it.
        // **Tag names are searchable too, on every section.**
        //
        // This is how tags filter. The alternative was a tag entry in each section's filter
        // control, which Volumes and Networks could take as a string id but Containers and
        // Machines could not without widening their typed `Filter` enums — and a tag filter that
        // exists on two sections out of five is the asymmetry this app keeps being asked to
        // remove. Searching the name reaches every section through one line each, works exactly
        // the same way everywhere, and composes with whatever filter is already on.
            machines = machines.filter {
                $0.id.lowercased().contains(query)
                || ($0.image?.reference.lowercased().contains(query) ?? false)
                || model.tags.tags(on: .machine, $0.id)
                    .contains { $0.name.lowercased().contains(query) }
            }
        }

        return machines.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<ContainerMachine.ID> { Set(displayed.map(\.id)) }

    /// A retained list selection can include rows hidden by a later filter change, so bulk
    /// actions only touch ids the user can still see when they press the button.
    private var actionable: Set<ContainerMachine.ID> { selection.intersection(visibleIDs) }

    private var selectionBusy: Bool { model.isAnyBusy(actionable, kind: .machine) }


    /// The selected rows as tag subjects, in the table's own order.
    ///
    /// Built from `actionable`, not from `selection`: filtering does not clear a table's
    /// selection, so a row you selected and then filtered away is still in the set — and tagging
    /// something the user cannot see is the same mistake the bulk delete bars guard against.
    private var selectedTagSubjects: [TagSubject] {
        actionable.sorted().map { TagSubject(kind: .machine, id: $0) }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        // From two rows, as the page's summary is (Kamal, 17 October, round 2): one row is its page.
        // And only while that summary is not on screen — `BulkActionBar`.
        if selection.count > 1, !actionable.isEmpty {
            BulkActionBar(title: "\(actionable.count) selected") { bulkActions }
        }
    }

    /// The bulk bar's controls, and the page's when several are ticked — one builder for both.
    @ViewBuilder
    private var bulkActions: some View {
        // Tags first in the cluster, before the lifecycle controls, and separated by a divider:
        // it is the one action here that changes nothing about what the selection *is*. Same menu
        // the row offers, asking the three-state question a multi-row selection actually poses —
        // see `BulkTagMenu`.
        BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
            tagSheet = TagSheetTarget(selectedTagSubjects)
        }
        Divider().frame(height: 14)
        iconButton("play.fill", "Start \(actionable.count) machines", busy: selectionBusy) {
            Task { await model.performMachineBulk(.start, on: actionable) }
        }
        iconButton("stop.fill", "Stop \(actionable.count) machines", busy: selectionBusy) {
            Task { await model.performMachineBulk(.stop, on: actionable) }
        }
        iconButton("trash", "Delete \(actionable.count) machines",
                   busy: selectionBusy, destructive: true) {
            confirmingBulkDelete = true
        }
    }

    /// Shows a machine's page by selecting it, and only it (Q58) — clearing the filter first if it
    /// is hiding the row, so the page always has a place in the list to step from.
    private func open(_ id: ContainerMachine.ID, tab: MachineDetailTab? = nil) {
        if !visibleIDs.contains(id) { ui.search = ""; ui.filter = .all }
        request = tab.map { DetailTarget(id: id, tab: $0) }
        selection = [id]
        ui.pane.reveal()
    }

    @ViewBuilder
    private var content: some View {
        switch model.machinesState {
        // Two arms on purpose: `case .idle, .loading where …` binds the `where` to `.loading` only
        // (CLAUDE.md). Not yet loaded always shows the spinner; loading only while nothing is shown.
        case .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.machines.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Never render a failed load as an empty list — that would look like a machine-less
            // Mac, which is the offline-detection mistake this project already made once.
            ContentUnavailableView("Can't list machines",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(reason))
                // Every branch fills the pane, so none can size the stack to its content.
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where model.machines.isEmpty:
            ContentUnavailableView {
                Label("No machines", systemImage: "server.rack")
            } description: {
                // `ubuntu:24.04` used to be the second example here. It does not boot as a
                // machine — see `MachineCreateSheet.suggestions`. Naming an image that fails is
                // worse than naming none.
                Text(LocalizedStringKey("Containers run inside a Linux virtual machine. "
                     + "`container` creates one on demand, and you can also create and size them "
                     + "yourself — a machine is built from a container image, such as "
                     + "`alpine:3.22`, rather than an installer disc."))
            } actions: {
                VStack(spacing: 14) {
                    Button("Create a machine…") { createPrefill = nil; showingCreate = true }
                        .buttonStyle(.borderedProminent)
                    SuggestionQuickPicks(
                        picks: MachineSuggestion.catalogue.map { suggestion in
                            (suggestion.title, { useSuggestion(suggestion) })
                        },
                        more: { showingSuggestions = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        // A filter that matches nothing is not the same as having no machines, and must not
        // render as the "No machines" onboarding — that would invite you to create a second
        // machine you already have.
        //
        // The `where` is repeated on **both** patterns deliberately. Written as
        // `case .loaded, .loading where displayed.isEmpty` the condition binds only to the last
        // pattern, so `.loaded` matched unconditionally and the screen said "No matching
        // machines" while two machines sat in the model. Swift accepts that silently.
        case .loaded where displayed.isEmpty, .loading where displayed.isEmpty:
            ContentUnavailableView {
                Label("No matching machines", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text(ui.filter == .all
                     ? "No machine matches “\(ui.search)”."
                     : "No \(ui.filter.rawValue.lowercased()) machine matches the current filter.")
            } actions: {
                Button("Clear filters") { ui.search = ""; ui.filter = .all }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            rowsList
        }
    }

    /// The rows, filling the pane — Containers' list, with a machine's say in each slot.
    ///
    /// A `List` for native multi-selection (⌘-click, ⇧-click, ⌘A), ↑/↓, Return to open and a
    /// right-click that lands on the whole selection, with `ResourceRow`'s checkboxes as a view of
    /// that same selection. No row height is written down: two lines and `ResourceRow`'s padding make it.
    /// `displayed` is the order the page's stepper walks, so ↓ goes to the next row you can see.
    private var rowsList: some View {
        SelectionRevealingList(selection: selection) {
            List(displayed, selection: $selection) { machine in
                listRow(machine)
                    // The row paints its own padding, so its hover wash and the list's selection fill
                    // reach the same edges.
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            // Fills what is left, like every other branch of `content`. A `List` is bounded, but the
            // activity strip that used to sit below broke this screen once by leaving its height to chance.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // On the List, not on a row: this one hands back every selected id.
            .contextMenu(forSelectionType: ContainerMachine.ID.self) { ids in
                rowContextMenu(for: ids)
            } primaryAction: { ids in
                // Selecting already shows the machine (Q58); double-click and Return bring its page
                // forward in a window too narrow for both panes, only when the activation names
                // exactly one row: with several selected, `ids.first` is an arbitrary member.
                guard ids.count == 1, let id = ids.first else { return }
                open(id)
            }
        }
    }

    /// One two-line row: the state dot; the name, "default" and the tags; the image, the CPUs
    /// and memory it was given, and its address. The buttons, shown on hover, are the row's
    /// share of `rowActions` — the header has the rest.
    private func listRow(_ machine: ContainerMachine) -> some View {
        ResourceRow(
            title: machine.id,
            detail: subtitle(for: machine),
            detailHelp: detailHelp(for: machine),
            selected: selection.contains(machine.id),
            check: RowCheck(machine.id, in: $selection),
            summary: rowSummary(machine),
            leading: {
                RowLeadingMark {
                    Circle()
                        .fill(Self.stateColor(machine))
                        .frame(width: 8, height: 8)
                        .help(machine.status.capitalized)
                }
            },
            chips: {
                // Which machine a bare `machine stop` or `inspect` would hit. Not cosmetic, so it
                // comes first, and a chip, which shows whole or not at all — never "defa…".
                if machine.isDefault == true {
                    ResourceChip(text: "default")
                        .help("Used when a command names no machine")
                }
                TagPillRow(tags: model.tags.tags(on: .machine, machine.id), compact: true)
            },
            actions: { rowActions(for: machine) })
    }

    /// The second line on hover, with the full image reference rather than its shortening.
    private func detailHelp(for machine: ContainerMachine) -> String {
        subtitleParts(for: machine, fullImage: true).joined(separator: " · ")
    }

    /// What VoiceOver reads for the row: "build, running, default machine, alpine:3.22, 2 CPUs, …".
    private func rowSummary(_ machine: ContainerMachine) -> String {
        var parts = [machine.id, machine.status.lowercased()]
        if machine.isDefault == true { parts.append("default machine") }
        parts.append(contentsOf: subtitleParts(for: machine))
        let tags = model.tags.tags(on: .machine, machine.id).map(\.name)
        if !tags.isEmpty { parts.append("tags " + tags.joined(separator: ", ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The right-click: the row's own menu for one row, the bulk bar's actions for several, and
    /// the "+" menu on empty space rather than an empty menu that looks like a bug.
    ///
    /// `ids` comes from the list, so everything in it is on screen by construction. The table this
    /// replaced offered the menu of `ids.first` for any selection — an arbitrary member.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<ContainerMachine.ID>) -> some View {
        if ids.isEmpty {
            addMenuItems
        } else if ids.count == 1, let machine = model.machines.first(where: { ids.contains($0.id) }) {
            machineMenu(for: machine)
        } else {
            let busy = model.isAnyBusy(ids, kind: .machine)
            Button("Start \(ids.count) Machines") { Task { await model.performMachineBulk(.start, on: ids) } }
                .disabled(busy)
            Button("Stop \(ids.count) Machines") { Task { await model.performMachineBulk(.stop, on: ids) } }
                .disabled(busy)
            Divider()
            Button("Delete \(ids.count) Machines…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(busy)
        }
    }

    /// Same shape as the containers row: start/stop swap and the overflow menu on the row; Restart
    /// and the bin as well in the page's header — icon-only with the word kept as tooltip and
    /// accessibility label.
    @ViewBuilder
    private func rowActions(for machine: ContainerMachine, place: RowActionPlace = .row) -> some View {
        let busy = model.isBusy(machine.id, kind: .machine)
        HStack(spacing: 2) {
            if Self.isRunning(machine) {
                iconButton("stop.fill", "Stop \(machine.id)", busy: busy) {
                    Task { await model.perform(.stop, on: machine) }
                }
                if place == .header {
                    iconButton("arrow.clockwise", "Restart \(machine.id)", busy: busy) {
                        Task { await model.perform(.restart, on: machine) }
                    }
                }
            } else {
                iconButton("play.fill", "Start \(machine.id)", busy: busy) {
                    Task { await model.perform(.start, on: machine) }
                }
            }

            Menu {
                machineMenu(for: machine)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(machine.id)")
            .accessibilityLabel("More actions for \(machine.id)")

            if place == .header {
                Divider().frame(height: 14)

                iconButton("trash", "Delete \(machine.id)", busy: busy, destructive: true) {
                    requestDelete(machine)
                }
            }
        }
    }

    @ViewBuilder
    private func machineMenu(for machine: ContainerMachine) -> some View {
        let running = Self.isRunning(machine)
        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)` while the context menu had no guard at all, so right-click → Stop on
        // a machine that was already stopping issued a second command — and the reads were
        // greyed on one surface and live on the other.
        let busy = model.isBusy(machine.id, kind: .machine)

        Button("Details…") { open(machine.id) }
        // Edit opens the machine's own Settings tab rather than a second copy of the form.
        // `machine set` only accepts cpus, memory and home-mount — an "edit" that showed the
        // image and name as though they were changeable would be lying about what the CLI can
        // do, and the Settings tab already states the restart requirement.
        Button("Edit Settings…") { open(machine.id, tab: .settings) }
        Divider()
        // Greyed out when it is already the default, rather than absent — same rule as the
        // lifecycle items below.
        Button("Set as Default") { Task { await model.perform(.setDefault, on: machine) } }
            .disabled(machine.isDefault == true || busy)

        // All three lifecycle items, always, with the ones that do not apply greyed out rather
        // than absent — the rule the status bar's runtime menu follows, in the same order, and for the
        // same reason: a menu whose items rearrange as state changes teaches nothing about what
        // the section can do, while a greyed-out Stop says plainly that this machine is already
        // stopped. The old shape showed Stop and Restart *or* Start, so the item under the
        // pointer depended on the row.
        Button("Start") { Task { await model.perform(.start, on: machine) } }
            .disabled(running || busy)
        Button("Stop") { Task { await model.perform(.stop, on: machine) } }
            .disabled(!running || busy)
        Button("Restart") { Task { await model.perform(.restart, on: machine) } }
            .disabled(!running || busy)
        Divider()
        // Tags, in the same place on every row menu in the app: after the things you open and
        // before Copy. Not a destructive action, not a read of the runtime — it changes how the
        // row looks to you and nothing about what it is.
        TagMenu(store: model.tags, subject: TagSubject(kind: .machine, id: machine.id)) {
            tagSheet = TagSheetTarget(kind: .machine, id: machine.id)
        }
        Divider()
        CopyMenu([
            ("Name", machine.id),
            ("IP Address", machine.ipAddress),
            ("Image", machine.image?.reference),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(machine) }
            .disabled(busy)
    }

    private func iconButton(_ symbol: String, _ label: String, busy: Bool,
                            destructive: Bool = false, action: @escaping () -> Void) -> some View {
        IconActionButton(systemImage: symbol, label: label, help: label,
                         busy: busy, destructive: destructive, action: action)
    }

    // MARK: Detail

    /// The page beside the list (Q58): the selected machine's detail, a summary of several, or an
    /// empty state. `MachineDetailView` keeps its identity as the selection moves, as it did while
    /// stepping, so the tab you are on stays the tab you are on and a shell keeps running.
    @ViewBuilder
    private var page: some View {
        if let machine = shownMachine {
            VStack(spacing: 0) {
                detailHeader(for: machine)
                Divider()
                MachineDetailView(model: model, machine: machine,
                                  requestedTab: request?.id == machine.id ? request?.tab : nil)
            }
            // Header at the top whatever is below it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .paneStep("machine", "machines", order: displayed.map(\.id), current: machine.id) { open($0) }
            .id(request?.nonce)
        } else if shown.count > 1, !actionable.isEmpty {
            SelectionSummaryPane(title: "\(actionable.count) machines selected", systemImage: "server.rack",
                                 names: displayed.filter { actionable.contains($0.id) }.map(\.id)) { bulkActions }
        } else {
            PaneEmptyState(title: "Choose a machine", systemImage: "server.rack",
                           description: "Its state, shell, logs and settings show here.")
        }
    }

    /// The one machine the page shows, when one is selected — from every machine, not the filtered
    /// list (Kyle, 17 October): a filter hides rows in the list, never the page that's open.
    private var shownMachine: ContainerMachine? {
        guard shown.count == 1, let id = shown.first else { return nil }
        return model.machines.first { $0.id == id }
    }

    /// Every machine, whatever the filters show: what one selected row may be.
    private var existingIDs: Set<ContainerMachine.ID> { Set(model.machines.map(\.id)) }

    /// Identity, the row's actions, the stepper and the expand button — no Back: the list is beside it.
    private func detailHeader(for machine: ContainerMachine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 19)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(machine.id).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Circle().fill(Self.stateColor(machine)).frame(width: 6, height: 6)
                        Text(machine.status.capitalized).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    if machine.isDefault == true {
                        Text("default").font(.caption2).foregroundStyle(Theme.accent)
                            .help("Used when a command names no machine")
                            .fixedSize()
                    }
                }
                Text(subtitle(for: machine))
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(subtitle(for: machine))
            }

            Spacer(minLength: 0)
            ActionCluster { rowActions(for: machine, place: .header) }
            DetailStepper()
        }
        // Horizontal 12, vertical 8 — the pair every band under the title bar uses.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Image · CPUs · memory · IP — the detail header's subtitle and a row's second line, one
    /// derivation for both.
    private func subtitle(for machine: ContainerMachine) -> String {
        subtitleParts(for: machine).joined(separator: " · ")
    }

    /// `fullImage` for a tooltip, where the whole reference fits.
    private func subtitleParts(for machine: ContainerMachine, fullImage: Bool = false) -> [String] {
        var parts: [String] = []
        if let image = machine.image?.reference {
            parts.append(fullImage ? image : ContainerImage.shortReference(image))
        }
        parts.append("\(machine.cpus) CPU\(machine.cpus == 1 ? "" : "s")")
        parts.append(Self.bytes(machine.memory))
        if let ip = machine.ipAddress { parts.append(ip) }
        return parts
    }

    // MARK: Helpers

    /// `status`, not `state` — the machine payload spells it differently from `Container`, which
    /// is the sort of detail the captured fixture settled and a guess would have got wrong.
    static func isRunning(_ machine: ContainerMachine) -> Bool { machine.state.isRunning }

    /// The dot's colour — and since the State column dropped its text on 9 August, the dot is
    /// now the *whole* statement, so a wrong colour is a wrong claim rather than a redundant one.
    ///
    /// That change immediately exposed a bug the text had been covering: the old rule matched
    /// `status.contains("stopp")`, which is true of **stopped** as well as *stopping*, so a
    /// machine sitting quietly at rest was painted amber — "needs attention". Nobody noticed
    /// while the word "Stopped" sat next to it explaining otherwise.
    ///
    /// Amber is for the transitional states only: something is moving and will settle. Stopped
    /// is a resting state and takes the same neutral grey a stopped container does.
    ///
    /// The rule is now a `switch` over `MachineState` rather than substring tests, which is what
    /// let the `stopp` bug exist at all — and which was also hiding a dead branch: the danger
    /// arm tested for `error` and `fail`, and the runtime's machine vocabulary is
    /// `starting`/`running`/`stopping`/`stopped`/`unknown` with no failure in it. `unknown`
    /// takes the danger tint instead, being the one status that actually means something is
    /// wrong. See `MachineState` and DECISIONS.md Q18.
    static func stateColor(_ machine: ContainerMachine) -> Color {
        switch machine.state {
        case .running: Theme.online
        case .starting, .stopping: Theme.warning
        case .unknown: Theme.danger
        case .stopped, .other: .secondary
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

extension ContainerMachine {
    /// `ipAddress` is nil for a stopped machine — no lease, no address. Sorted to the end
    /// (`"zzzz"` is lexicographically after any dotted-quad), matching `creationSortKey`'s
    /// rule that "we don't know" is not the same as "first" or "zero".
    /// Octets zero-padded to three digits, so `192.168.64.9` sorts before `192.168.64.10`.
    /// A plain string sort puts `.10` first, which reads as a bug to anyone scanning an address
    /// column — the same key `ContainersView.ContainerRow.ipSortKey` uses, for the same reason.
    /// An absent address becomes `zzz…` so it sorts last rather than masquerading as `0.0.0.0`.
    var ipSortKey: String {
        guard let ipAddress else { return "zzz" }
        return ipAddress.split(separator: ".")
            .map { String(format: "%03d", Int($0) ?? 0) }
            .joined(separator: ".")
    }

    /// Sortable form of `createdDate`, which the CLI gives as an ISO-8601 *string* that
    /// happens to sort correctly lexicographically. Same shape as `Container.creationSortKey`
    /// — an absent date sorts last rather than first, so a machine we couldn't date doesn't
    /// masquerade as the oldest one on the host.
    var creationSortKey: String { createdDate ?? "9999" }
}
