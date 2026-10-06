import SwiftUI
import FlotillaCore

/// One Mac in the Hosts section. Today the only row is This Mac; host mode adds the rest, and
/// every column here is one a remote host can answer too.
struct HostRow: Identifiable, Hashable {
    /// The key tags and the activity band use. This Mac's is fixed; a paired host's will be its
    /// enrolment identity, never its name, which the owner can change.
    let id: String
    let name: String
    let isThisMac: Bool
    let status: String
    /// Whether the runtime is usable — the "Connected" filter, and the dot.
    let connected: Bool
    let containersRunning: Int
    let containersTotal: Int
    let machines: Int
    let macOS: String
    let containerVersion: String?
    let modelIdentifier: String?

    static let thisMacID = "this-mac"

    var nameSortKey: String { name.lowercased() }
    var statusSortKey: String { (connected ? "0" : "1") + status }
    var containersSortKey: Int { containersRunning }
    var macOSSortKey: String { macOS }
    var containerSortKey: String { containerVersion ?? "" }
    var modelSortKey: String { modelIdentifier ?? "" }

    var containersText: String { "\(containersRunning) running of \(containersTotal)" }
}

extension AppModel {
    /// Every host Flotilla manages. One until host mode (PLAN.md Phase B).
    var hostRows: [HostRow] {
        let version: String? = switch preflight {
        case .ok(let version, _), .serviceStopped(let version, _, _), .needsKernel(let version, _, _):
            version
        case .needsRestart(let cli, _, _): cli
        case .tooOld(let found, _): found
        case .missing, .unusable, nil: nil
        }
        let system = systemInfo
        return [HostRow(id: HostRow.thisMacID,
                        name: hostLabel,
                        isThisMac: true,
                        status: RuntimeStatus.describe(preflight).title,
                        connected: runtimeUsable,
                        containersRunning: containers.filter(AppModel.isRunning).count,
                        containersTotal: containers.count,
                        machines: machines.count,
                        macOS: system.osVersion,
                        containerVersion: version,
                        modelIdentifier: system.modelIdentifier)]
    }
}

/// Hosts — every Mac Flotilla manages, with the same table setup as every other section (the
/// owner, 6 October): list and cards, search, filter, sortable and hideable columns, row menus that
/// match the context menu, multi-select, tags, Add and Refresh, and the activity band. A host's page
/// is the per-Mac dashboard that used to be the app's front page.
///
/// **Add is shown and disabled** until host mode exists — the control the section will have, saying
/// why it cannot be used yet, rather than a button that does nothing. Remove is the same for This
/// Mac, which is the admin machine and is never removed.
struct HostsView: View {
    let model: AppModel
    let ui: ResourceUIState<HostRow>
    let go: (Section) -> Void

    @State private var selection = Set<HostRow.ID>()
    @State private var openHost: HostRow.ID?
    @State private var tagSheet: TagSheetTarget?
    /// A real `Bool` beside the action, for the reason `RuntimeStatusBand` records: a computed
    /// binding over an optional did not present the dialog at all.
    @State private var confirming: RuntimeLifecycleAction = .stop
    @State private var showingConfirmation = false

    private static let addHelp = "Adding another Mac arrives with host mode"
    private static let removeHelp = "This Mac is the admin machine — it can’t be removed"

    var body: some View {
        Group {
            if let id = openHost {
                hostPage(id)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  open: { _ in openHost = HostRow.thisMacID },
                                  canOpen: { _ in true })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshMachines() }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        .confirmationDialog(confirming.question,
                            isPresented: $showingConfirmation,
                            titleVisibility: .visible) {
            Button(confirming.verb, role: .destructive) { perform(confirming) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming.consequence)
        }
    }

    private func hostPage(_ id: HostRow.ID) -> some View {
        VStack(spacing: 0) {
            FormHeader(title: model.hostRows.first { $0.id == id }?.name ?? model.hostLabel,
                       systemImage: Section.hosts.systemImage,
                       hasUnsavedChanges: false, onBack: { openHost = nil })
            Divider()
            DashboardView(model: model, go: go)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search hosts…",
                       updated: model.lastRefresh,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all hosts" : "Select all hosts")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<HostRow>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: Self.filters)
        }, trailing: {
            if model.startingRuntime { ProgressView().controlSize(.small) }
            ToolbarIconButton(systemImage: "plus", label: "Add a host", help: Self.addHelp,
                              disabled: true) {}
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh hosts") {
                Task {
                    await model.reload()
                    await model.refreshMachines()
                }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"), ("status", "Status"), ("containers", "Containers"),
        ("machines", "Machines"), ("macos", "macOS"), ("container", "container"), ("model", "Model"),
    ]

    private static let filters: [ResourceFilterOption] = [
        .init(id: "all", title: "All", systemImage: "circle.grid.2x2"),
        .init(id: "connected", title: "Connected", systemImage: "checkmark.circle"),
        .init(id: "attention", title: "Needs attention", systemImage: "exclamationmark.triangle"),
    ]

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all"
    }

    private var displayedRows: [HostRow] {
        var rows = model.hostRows
        switch ui.filterID {
        case "connected": rows = rows.filter(\.connected)
        case "attention": rows = rows.filter { !$0.connected }
        default: break
        }
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.lowercased().contains(query)
                    || row.status.lowercased().contains(query)
                    || (row.modelIdentifier?.lowercased().contains(query) ?? false)
                    || model.tags.tags(on: .host, row.id)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }
        return rows.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<HostRow.ID> { Set(displayedRows.map(\.id)) }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    private var selectedRows: [HostRow] {
        displayedRows.filter { selection.contains($0.id) }
    }

    private var selectedTagSubjects: [TagSubject] {
        selectedRows.map { TagSubject(kind: .host, id: $0.id) }
    }

    private func selectionToggle(for row: HostRow) -> some View {
        Toggle("", isOn: Binding(get: { selection.contains(row.id) },
                                 set: { on in
                                     if on { selection.insert(row.id) } else { selection.remove(row.id) }
                                 }))
            .labelsHidden()
            .accessibilityLabel("Select \(row.name)")
            .help("Select \(row.name)")
    }

    // MARK: Bulk

    @ViewBuilder
    private var bulkActionBar: some View {
        if selectedRows.count > 1 {
            HStack(spacing: 12) {
                Text("\(selectedRows.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// The runtime's starts and stops, and — with host mode — hosts added and removed.
    private var activityEntries: [ActivityStrip.Entry] {
        (model.events(ofKind: .runtime) + model.events(ofKind: .host))
            .sorted { $0.date > $1.date }
            .map { ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if displayedRows.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("No host matches the current filter.")
            } actions: {
                Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ui.presentation == .list {
            table
        } else {
            cards
        }
    }

    private var table: some View {
        SwiftUI.Table(displayedRows,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("") { row in
                selectionToggle(for: row)
            }
            .width(min: 28, ideal: 30, max: 34)

            TableColumn("Name", value: \.nameSortKey) { row in
                Button(row.name) { openHost = row.id }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                    .lineLimit(1)
                    .help("Open \(row.name)")
            }
            .width(min: 140, ideal: 200)

            TableColumn("Tags") { row in
                TagPillRow(tags: model.tags.tags(on: .host, row.id), compact: true)
            }
            .width(min: 60, ideal: 110)
            .customizationID("tags")

            TableColumn("Status", value: \.statusSortKey) { row in
                HostStatusLabel(model: model, row: row)
            }
            .width(min: 140, ideal: 200)
            .customizationID("status")

            TableColumn("Containers", value: \.containersSortKey) { row in
                Text(row.containersText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            .customizationID("containers")

            TableColumn("Machines", value: \.machines) { row in
                Text("\(row.machines)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            .customizationID("machines")

            TableColumn("macOS", value: \.macOSSortKey) { row in
                Text(row.macOS).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            .customizationID("macos")

            TableColumn("container", value: \.containerSortKey) { row in
                Text(row.containerVersion ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80)
            .customizationID("container")

            TableColumn("Model", value: \.modelSortKey) { row in
                Text(row.modelIdentifier ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 90)
            .customizationID("model")

            TableColumn("Actions") { row in
                rowActions(for: row)
            }
            .width(min: 78, ideal: 88)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: HostRow.ID.self) { ids in
            if let row = model.hostRows.first(where: { ids.contains($0.id) }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            openHost = id
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedRows) { row in
                ResourceCard(
                    title: row.name,
                    badge: row.isThisMac ? "this Mac" : nil,
                    fields: [("Status", row.status),
                             ("Containers", row.containersText),
                             ("Machines", "\(row.machines)"),
                             ("macOS", row.macOS),
                             ("container", row.containerVersion)],
                    tags: model.tags.tags(on: .host, row.id),
                    onOpen: { openHost = row.id }
                ) {
                    rowActions(for: row)
                }
                .contextMenu { menu(for: row) }
            }
        }
    }

    // MARK: Row actions and menu

    @ViewBuilder
    private func rowActions(for row: HostRow) -> some View {
        HStack(spacing: 2) {
            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(row.name)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Remove \(row.name)",
                             help: row.isThisMac ? Self.removeHelp : "Remove \(row.name)",
                             disabled: row.isThisMac, destructive: true) {}
            Spacer(minLength: 0)
        }
    }

    /// The runtime items match the sidebar band's menu word for word, and are greyed out by the
    /// same rule rather than coming and going.
    @ViewBuilder
    private func menu(for row: HostRow) -> some View {
        let enablement = RuntimeStatus.enablement(model.preflight)
        Button("Open") { openHost = row.id }
        Divider()
        Button("Start Container System") { Task { await model.startRuntime() } }
            .disabled(!enablement.start || model.startingRuntime)
        Button("Stop Container System…") { ask(.stop) }
            .disabled(!enablement.stopRestart || model.startingRuntime)
        if case .needsRestart = model.preflight {
            Button("Restart Container System") { Task { await model.restartRuntime() } }
        } else {
            Button("Restart Container System…") { ask(.restart) }
                .disabled(!enablement.stopRestart || model.startingRuntime)
        }
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .host, id: row.id)) {
            tagSheet = TagSheetTarget(kind: .host, id: row.id)
        }
        Divider()
        CopyMenu([("Name", row.name),
                  ("macOS version", row.macOS),
                  ("container version", row.containerVersion),
                  ("Model", row.modelIdentifier)])
        Divider()
        Button("Remove…", role: .destructive) {}
            .disabled(row.isThisMac)
            .help(row.isThisMac ? Self.removeHelp : "")
    }

    private func ask(_ action: RuntimeLifecycleAction) {
        confirming = action
        showingConfirmation = true
    }

    private func perform(_ action: RuntimeLifecycleAction) {
        switch action {
        case .stop: Task { await model.stopRuntime() }
        case .restart: Task { await model.restartRuntime() }
        }
    }
}

/// A host's status, the same in the table and the sidebar band.
struct HostStatusLabel: View {
    let model: AppModel
    let row: HostRow

    var body: some View {
        let status = RuntimeStatus.describe(model.preflight)
        HStack(spacing: 6) {
            if model.startingRuntime {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 8, height: 8)
            } else {
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
            Text(row.status).lineLimit(1)
        }
        .font(.caption)
        .help(status.detail ?? row.status)
    }
}
