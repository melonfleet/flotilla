import SwiftUI
import Foundation
import FlotillaCore

/// The networks section: list, create, delete — same shape as `VolumesView`.
struct NetworksView: View {
    let model: AppModel
    let ui: ResourceUIState<HostedNetwork>

    @State private var selection = Set<HostedNetwork.ID>()

    @State private var search = ""
    @State private var showingCreate = false
    @State private var showingSuggestions = false
    @State private var createPrefill: NetworkSuggestion?
    /// Which network the detail screen is showing, and optionally which tab to open it on.
    private struct DetailTarget: Identifiable, Hashable {
        let name: String
        var host: HostRef = .local
        var tab: NetworkDetailTab?
        var id: String { host.rowID(name) }
    }

    /// The network whose detail screen is showing, or nil for the list.
    @State private var detailTarget: DetailTarget?
    @State private var pendingDelete: HostedNetwork?
    /// This Mac's network being pushed to hosts (PLAN.md Phase D).
    @State private var pushing: ContainerNetwork?
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. A `TagSheetTarget` rather than a
    /// bare `TagSubject` — see that type for why a subject is not `Identifiable`.
    ///
    /// Presented from the view, never from inside the menu: a `.sheet` attached within a `Menu`
    /// never appears, because the menu is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?

    var body: some View {
        Group {
            if let network = pushing {
                PushDefinitionView(model: model, subject: .network(network)) { pushing = nil }
            } else if showingCreate {
                NewNetworkView(model: model, dismiss: { showingCreate = false; createPrefill = nil },
                               prefill: createPrefill, initialHost: ui.hostFilter ?? .local)
            } else if showingSuggestions {
                ResourceSuggestionsGallery(
                    intro: "Networks for common layouts. Use one to open New Network with it "
                        + "filled in — change anything before you create it.",
                    items: NetworkSuggestion.catalogue,
                    use: useSuggestion,
                    dismiss: { showingSuggestions = false })
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    // apple/container#2051: a network that has lost its bridge (Q30).
                    DisconnectedNetworksBanner(model: model)
                    content
                }
                // Fill the pane, with the toolbar at the top, whatever `content` is. An empty or
                // unreachable section is a `ContentUnavailableView`, which takes only its own
                // height, and the strip below then rode up under it, halfway up the window (the
                // owner, on an empty Volumes, 5 October). Machines already did this.
                .frame(maxHeight: .infinity, alignment: .top)
                // Same band as Containers and Machines. See `ResourceUIState.activityExpanded`
                // for why it is collapsible: on this section it is usually empty.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  // As in Volumes: the detail screen, which is what clicking
                                  // the name gives too.
                                  open: { detailTarget = DetailTarget(name: $0) },
                                  canOpen: { id in model.networks.contains { $0.id == id } })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshNetworks() }
        // Paired hosts' networks kept current while this section is open, as Containers does.
        .task {
            while !Task.isCancelled {
                await model.hostMode.refreshLiveStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingNetworkForm) { _, requested in
            if requested { showingCreate = true; model.pendingNetworkForm = false }
        }
        .onAppear {
            if model.pendingNetworkForm { showingCreate = true; model.pendingNetworkForm = false }
        }
        // File ▸ Suggestions ▸ Networks…. One-shot.
        .onChange(of: model.pendingSuggestions) { _, section in
            if section == .networks { model.pendingSuggestions = nil; showingCreate = false; showingSuggestions = true }
        }
        .onAppear {
            if model.pendingSuggestions == .networks {
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
            "Delete network “\(pendingDelete?.name ?? "")”\(pendingDelete.map(onHost) ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    leaveDetailIfShowing(row)
                    Task { await model.removeNetwork(row.network, host: row.host) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(actionable.count) network\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Network\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                let rows = actionableRows
                Task {
                    let local = Set(rows.filter(\.host.isLocal).map(\.network.id))
                    if !local.isEmpty { await model.deleteNetworks(local) }
                    // Other Macs' networks one at a time, as Containers acts on its remote rows.
                    for row in rows where !row.host.isLocal {
                        await model.removeNetwork(row.network, host: row.host)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text([FleetWording.onMacs(actionableRows.map { ($0.host, $0.hostName) }), "This cannot be undone."]
                    .compactMap { $0 }.joined(separator: " "))
        }
    }

    private func useSuggestion(_ suggestion: NetworkSuggestion) {
        createPrefill = suggestion
        showingSuggestions = false
        showingCreate = true
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search networks…",
                       updated: model.networksLastRefresh,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all networks" : "Select all networks")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<HostedNetwork>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: Self.roleFilters,
                hostFilter: Binding(get: { ui.hostFilter }, set: { ui.hostFilter = $0 }),
                hosts: hostChoices)
        }, trailing: {
            ToolbarIconMenu(systemImage: "plus", label: "Create a network") {
                Button("New Network…") { createPrefill = nil; showingCreate = true }
                Divider()
                Button("Suggestions…") { showingSuggestions = true }
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh networks") {
                Task { await model.refreshNetworks() }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"),
        ("mode", "Mode"), ("subnet", "Subnet"), ("gateway", "Gateway"), ("created", "Created"),
        ("host", "Host"), ("spread", "On hosts"),
    ]

    /// Built-in versus your own. Fixed rather than derived, because the distinction is always
    /// meaningful here — `default` ships with the runtime and cannot be deleted, and separating
    /// "networks I made" from "the one that was already there" is the question you actually have.
    private static let roleFilters: [ResourceFilterOption] = [
        .init(id: "all", title: "All", systemImage: "circle.grid.2x2"),
        .init(id: "user", title: "User-defined", systemImage: "person"),
        .init(id: "builtin", title: "Built-in", systemImage: "lock"),
    ]

    /// Free-text filter over the network name.
    /// Whether anything is currently narrowing the list. Drives the empty state's wording and
    /// its action: "no matches, clear the filter" and "none exist, make one" are different
    /// situations and only one of them is the user's mistake.
    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" || ui.hostFilter != nil
    }

    /// This Mac and every trusted host, for the filter's Host section.
    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// " on mini" for a paired host's network, nothing for This Mac's.
    private func onHost(_ row: HostedNetwork) -> String {
        row.host.isLocal ? "" : " on \(row.hostName)"
    }

    /// This Mac's networks and every paired host's last answer, through the host filter (PLAN.md
    /// Phase C). Every Mac has its own `default`, and two Macs' `backend` networks are separate
    /// private networks, so each is its own row.
    private var allRows: [HostedNetwork] {
        var rows: [HostedNetwork] = []
        if ui.hostFilter == nil || ui.hostFilter == .local {
            rows += model.networks.map { HostedNetwork(network: $0, host: .local, hostName: model.hostLabel) }
        }
        let now = Date()
        for (peer, snapshot) in model.hostMode.fleetNetworks {
            let host = HostRef.peer(peer.fingerprint)
            if let only = ui.hostFilter, only != host { continue }
            let stale = snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil
            rows += snapshot.items.map {
                HostedNetwork(network: $0, host: host, hostName: peer.displayName, staleSince: stale)
            }
        }
        return rows
    }

    private var displayedNetworks: [HostedNetwork] {
        var networks = allRows

        switch ui.filterID {
        case "user": networks = networks.filter { !$0.network.isBuiltin }
        case "builtin": networks = networks.filter(\.network.isBuiltin)
        default: break
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
        // **Tag names are searchable too, on every section.**
        //
        // This is how tags filter. The alternative was a tag entry in each section's filter
        // control, which Volumes and Networks could take as a string id but Containers and
        // Machines could not without widening their typed `Filter` enums — and a tag filter that
        // exists on two sections out of five is the asymmetry this app keeps being asked to
        // remove. Searching the name reaches every section through one line each, works exactly
        // the same way everywhere, and composes with whatever filter is already on.
            networks = networks.filter {
                $0.name.lowercased().contains(query)
                    || (!$0.host.isLocal && $0.hostName.lowercased().contains(query))
                    || model.tags.tags(on: .network, $0.detailKey)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }

        return networks.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<HostedNetwork.ID> { Set(displayedNetworks.map(\.id)) }

    /// Search and role filters can hide selected rows without clearing their ids; bulk delete is
    /// therefore constrained to what remains on screen.
    ///
    /// Built-in networks are excluded here rather than refused later. The row's own delete button
    /// is already `disabled: network.isBuiltin`, so leaving `default` in the batch would have the
    /// bar count it, ask to delete it, and then report a failure the row had already ruled out —
    /// the bulk path claiming not to know something the per-row path does.
    private var actionable: Set<HostedNetwork.ID> {
        Set(displayedNetworks.lazy.filter { selection.contains($0.id) && !$0.network.isBuiltin }.map(\.id))
    }

    private var actionableRows: [HostedNetwork] { displayedNetworks.filter { actionable.contains($0.id) } }

    private func open(_ row: HostedNetwork, tab: NetworkDetailTab? = nil) {
        detailTarget = DetailTarget(name: row.name, host: row.host, tab: tab)
    }

    /// Deleting the network whose detail is open goes back to the list, as in Containers.
    private func leaveDetailIfShowing(_ row: HostedNetwork) {
        if detailTarget?.id == row.detailKey { detailTarget = nil }
    }

    private func selectionToggle(for id: HostedNetwork.ID) -> some View {
        let isOn = Binding<Bool>(
            get: { selection.contains(id) },
            set: { on in
                if on { selection.insert(id) } else { selection.remove(id) }
            })
        return Toggle("", isOn: isOn)
            .labelsHidden()
            .accessibilityLabel("Select \(id)")
            .help("Select \(id)")
    }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    private var selectionBusy: Bool { model.isAnyBusy(actionable, kind: .network) }


    /// The selected rows as tag subjects, in the table's own order.
    ///
    /// Built from `actionable`, not from `selection`: filtering does not clear a table's
    /// selection, so a row you selected and then filtered away is still in the set — and tagging
    /// something the user cannot see is the same mistake the bulk delete bars guard against.
    private var selectedTagSubjects: [TagSubject] {
        actionableRows.map { TagSubject(kind: .network, id: $0.detailKey) }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        // A single network already has the same delete control in its row.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                // Tags first in the cluster, before the lifecycle controls, and separated by a
                // divider: it is the one action here that changes nothing about what the
                // selection *is*. Same menu the row offers, asking the three-state question a
                // multi-row selection actually poses — see `BulkTagMenu`.
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "trash",
                                 label: "Delete \(actionable.count) networks",
                                 help: "Delete \(actionable.count) networks",
                                 busy: selectionBusy, destructive: true) {
                    confirmingBulkDelete = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// This section's slice of the one activity feed. Rows do not navigate — you are already
    /// on the section they belong to.
    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .network).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.networksState {
        case .idle, .loading:
            ProgressView("Loading networks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as containers and volumes: a failed load must never render as an
            // empty list — that would look like a healthy, network-less fleet.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .loaded where displayedNetworks.isEmpty:
            // Filtered-empty and genuinely-empty are different states, and this used to test
            // only the second (`model.networks.isEmpty`) — so narrowing the filter to nothing
            // rendered an empty table with no message at all, and no way to see which control had
            // hidden the rows. UI-03/UI-04 in the 2026-08-20 audit, and the Containers screen had
            // already solved both; this is that pattern, not a new one.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No networks",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "network")
            } description: {
                Text(isFiltered
                     ? "No network matches the current filter."
                     : "Create one to give containers an isolated network.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all"; ui.hostFilter = nil }
                } else {
                    VStack(spacing: 14) {
                        Button("New Network…") { createPrefill = nil; showingCreate = true }
                            .buttonStyle(.borderedProminent)
                        SuggestionQuickPicks(
                            picks: NetworkSuggestion.catalogue.map { suggestion in
                                (suggestion.title, { useSuggestion(suggestion) })
                            },
                            more: { showingSuggestions = true })
                    }
                }
            }

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedNetworks) { row in
                let network = row.network
                ResourceCard(
                    title: network.name,
                    badge: network.isBuiltin ? "built-in" : nil,
                    fields: [("Mode", network.mode),
                             ("Subnet", network.subnet),
                             ("Gateway", network.gateway),
                             ("Created", RelativeDate.relative(network.configuration.creationDate))]
                        // Named only when there is more than one Mac to tell apart.
                        + (hostChoices.count > 1 ? [("Host", row.hostName)] : []),
                    tags: model.tags.tags(on: .network, row.detailKey),
                    // The card title opens the detail, so the list/cards toggle does not change
                    // what you can reach. Every caller of `ResourceCard` passed `nil` here.
                    onOpen: { open(row) }
                ) {
                    rowActions(for: row)
                }
                .contextMenu { menu(for: row) }
            }
        }
    }

    /// A `Table`, matching every other section. Was a `List` of two-line rows whose second line
    /// crammed mode, subnet and gateway into a caption — unsortable, and unreadable past a
    /// handful of networks.
    ///
    /// No state column: a network exists or it does not. The built-in badge stays on the name,
    /// because "you cannot delete this one" is a property of the row, not a state it is in.
    private var table: some View {
        SwiftUI.Table(displayedNetworks,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("") { row in
                selectionToggle(for: row.id)
            }
            .width(min: 28, ideal: 30, max: 34)

            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    // The way in, as in every other table.
                    Button(row.network.name) { open(row) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                        .lineLimit(1)
                        .help("Open \(row.network.name)\(onHost(row))")
                    if row.network.isBuiltin {
                        Text("built-in")
                            .font(.caption2).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 150, ideal: 210)

            // Next to the name, the way Finder puts a tag beside a filename: the whole point is
            // that you recognise the row without reading it, which only works if the pill is
            // where your eye already is.
            //
            // Unsorted, deliberately. `TableColumn`'s sort takes a key path on the **row**, and a
            // row's tags live in `TagStore`, not on the model — so a sortable column here would
            // mean denormalising the user's tags onto the runtime's own types. Hideable instead,
            // through the same column menu every other column uses.
            TableColumn("Tags") { row in
                TagPillRow(tags: model.tags.tags(on: .network, row.detailKey), compact: true)
            }
            .width(min: 60, ideal: 130)
            .customizationID("tags")

            TableColumn("Mode", value: \.modeSortKey) { row in
                Text(row.network.mode ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 88)
            .customizationID("mode")

            TableColumn("Subnet", value: \.subnetSortKey) { row in
                Text(row.network.subnet ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
            .customizationID("subnet")

            TableColumn("Gateway", value: \.gatewaySortKey) { row in
                Text(row.network.gateway ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            .customizationID("gateway")

            TableColumn("Created", value: \.creationSortKey) { row in
                Text(RelativeDate.relative(row.network.configuration.creationDate))
                    .foregroundStyle(.secondary)
                    .help(RelativeDate.absolute(row.network.configuration.creationDate))
            }
            .width(min: 80, ideal: 104)
            .customizationID("created")

            // Which Mac the network is on, as in Containers, Images and Volumes.
            TableColumn("Host", value: \.hostName) { row in
                HostCell(name: row.hostName, staleSince: row.staleSince)
            }
            .width(min: 80, ideal: 110)
            .customizationID("host")

            // How far This Mac's network has been pushed (PLAN.md Phase D) — and whether a host's
            // copy has drifted from it.
            TableColumn("On hosts") { row in
                if row.host.isLocal, !row.network.isBuiltin {
                    SpreadCell(spread: model.spread(of: row.network))
                }
            }
            .width(min: 70, ideal: 96)
            .customizationID("spread")

            TableColumn("Actions") { row in
                rowActions(for: row)
            }
            .width(min: 78, ideal: 88)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: HostedNetwork.ID.self) { ids in
            if let row = displayedNetworks.first(where: { ids.contains($0.id) }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            // Double-click opens the detail, and only for an unambiguous activation — `ids` is a
            // `Set`, so with several rows selected `first` is an arbitrary member.
            guard ids.count == 1,
                  let row = displayedNetworks.first(where: { ids.contains($0.id) }) else { return }
            open(row)
        }
    }

    @ViewBuilder
    private func rowActions(for row: HostedNetwork) -> some View {
        let network = row.network
        let busy = model.isBusy(row.id, kind: .network)
        let name = network.id + onHost(row)
        HStack(spacing: 2) {
            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(name)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(name)",
                             help: network.isBuiltin
                                 ? "\(name) is built in and cannot be deleted"
                                 : "Delete \(name)",
                             busy: busy,
                             disabled: network.isBuiltin,
                             destructive: true) {
                requestDelete(row)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detailScreen(_ target: DetailTarget) -> some View {
        VStack(spacing: 0) {
            if let row = hostedNetwork(target) {
                detailHeader(for: row)
                Divider()
                NetworkDetailView(model: model, network: row.network, host: row.host, requestedTab: target.tab)
                    .id(row.detailKey)
            } else {
                detailHeader(for: nil)
                Divider()
                // Top-aligned with neutral wording, as Containers' detail does.
                ContentUnavailableView(
                    "Network unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("\u{201C}\(target.name)\u{201D} is no longer on "
                                      + "\(model.hostMode.hostName(target.host, local: "this Mac")). It may have been deleted.")
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// The row a detail target names: This Mac's by name, a paired host's from its last answer.
    private func hostedNetwork(_ target: DetailTarget) -> HostedNetwork? {
        switch target.host {
        case .local:
            return model.networks.first { $0.id == target.name }
                .map { HostedNetwork(network: $0, host: .local, hostName: model.hostLabel) }
        case .peer(let fingerprint):
            guard let network = model.hostMode.networkSnapshots[fingerprint]?.items
                .first(where: { $0.id == target.name }) else { return nil }
            return HostedNetwork(network: network, host: target.host,
                                 hostName: model.hostMode.hostName(target.host, local: model.hostLabel))
        }
    }

    @ViewBuilder
    private func detailHeader(for row: HostedNetwork?) -> some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back to Networks",
                             help: "Back to Networks") { detailTarget = nil }

            if let row {
                let network = row.network
                Image(systemName: "globe")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(network.name).font(.headline)
                        if network.isBuiltin {
                            Text("built-in").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle(for: row))
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text("Network unavailable").font(.headline)
            }

            Spacer()
            stepper
            if let row {
                ActionCluster { rowActions(for: row) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stepper: some View {
        let order = displayedNetworks
        let index = order.firstIndex { $0.detailKey == detailTarget?.id }
        HStack(spacing: 2) {
            Button {
                if let index, index > 0 { open(order[index - 1]) }
            } label: { Image(systemName: "chevron.up") }
                .disabled(index == nil || index == 0)
                .help("Previous network")
                .accessibilityLabel("Previous network")

            Button {
                if let index, index < order.count - 1 {
                    open(order[index + 1])
                }
            } label: { Image(systemName: "chevron.down") }
                .disabled(index == nil || index == order.count - 1)
                .help("Next network")
                .accessibilityLabel("Next network")

            if let index {
                Text("\(index + 1) of \(order.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private func subtitle(for row: HostedNetwork) -> String {
        let network = row.network
        return [row.host.isLocal ? nil : row.hostName, network.mode, network.subnet, network.gateway]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func menu(for row: HostedNetwork) -> some View {
        let network = row.network
        let busy = model.isBusy(row.id, kind: .network)

        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)`, which greyed out the reads — Inspect, Copy — on the one surface and
        // left them live on the other.
        // GAP-06, same as Volumes. Worth more here than there: `network inspect` carries the
        // `status` block — the gateway and both subnets the runtime actually assigned — which
        // `network ls` does not always return.
        Button("Details…") { open(row) }
        Button("Inspect") { open(row, tab: .inspect) }
        if row.host.isLocal, !network.isBuiltin {
            Button("Push to Hosts\u{2026}") { pushing = network }
                .disabled(model.hostMode.trustedHosts.isEmpty)
        }
        Divider()
        // Tags, in the same place on every row menu in the app: after the things you open and
        // before Copy. Not a destructive action, not a read of the runtime — it changes how the
        // row looks to you and nothing about what it is.
        TagMenu(store: model.tags, subject: TagSubject(kind: .network, id: row.detailKey)) {
            tagSheet = TagSheetTarget(kind: .network, id: row.detailKey)
        }
        Divider()
        CopyMenu([
            ("Name", network.id),
            ("Subnet", network.subnet),
            ("Gateway", network.gateway),
        ] + (row.host.isLocal ? [] : [("Host", row.hostName)]))
        Divider()
        // `isBuiltin`, not just `busy`. The trash **button** beside this menu has carried
        // `disabled: network.isBuiltin` since the busy/disabled split, and its tooltip explains
        // why — but the menu never learned: right-click → Delete on `default` offered a deletion
        // the CLI refuses outright. Same family as the containers context menu that deleted with
        // no dialog while the button two lines away always asked.
        Button("Delete…", role: .destructive) { requestDelete(row) }
            .disabled(network.isBuiltin || busy)
    }



    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ row: HostedNetwork) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = row
        } else {
            leaveDetailIfShowing(row)
            Task { await model.removeNetwork(row.network, host: row.host) }
        }
    }
}

/// One network on one Mac (PLAN.md Phase C). This Mac's rows keep `ContainerNetwork.id` as their
/// id and tag key, so selection, busy state and tags are unchanged for them.
struct HostedNetwork: Identifiable {
    let network: ContainerNetwork
    let host: HostRef
    let hostName: String
    /// A host's row that is older than a fresh answer: shown, with its age, rather than hidden.
    var staleSince: Date? = nil

    var id: String { host.rowID(network.id) }
    /// How the detail screen and tags name the network, on its Mac.
    var detailKey: String { host.rowID(network.id) }

    var name: String { network.id }
    var modeSortKey: String { network.modeSortKey }
    var subnetSortKey: String { network.subnetSortKey }
    var gatewaySortKey: String { network.gatewaySortKey }
    var creationSortKey: String { network.creationSortKey }
}

extension ContainerNetwork {
    var modeSortKey: String { mode ?? "" }
    var subnetSortKey: String { subnet ?? "" }
    var gatewaySortKey: String { gateway ?? "" }

    /// Sortable form of `creationDate`, which the CLI gives as an ISO-8601 *string* that
    /// happens to sort correctly lexicographically. Same rule `Container.creationSortKey`
    /// uses: an absent date sorts last rather than first.
    var creationSortKey: String { configuration.creationDate ?? "9999" }
}

/// The New Network form, hosted in its own **window** rather than a sheet.
///
/// The owner's rule, stated generally: any window that comes up should carry macOS's own traffic
/// lights. A sheet has no title bar, so it cannot — which is why this is a `WindowGroup`
/// (see `FlotillaApp`). Confirmations and error alerts stay as alerts: those are modal
/// decisions, and traffic lights on a "delete this?" prompt would be wrong.
struct NewNetworkView: View {
    let model: AppModel
    /// Supplied by the presenter rather than using `@Environment(\.dismiss)`: the sheet's
    /// own `isPresented` binding is the single source of truth for whether it is open, and
    /// two mechanisms for closing one thing is how a sheet gets stuck.
    let dismiss: () -> Void
    /// Set when a suggestion opened the form (Q28): its values fill the fields.
    var prefill: NetworkSuggestion?
    /// The Mac the form opens on — the one the list is filtered to, if any (PLAN.md Phase C).
    var initialHost: HostRef = .local

    @State private var host: HostRef = .local

    @State private var newNetworkName = ""
    @State private var newSubnet = ""
    @State private var newSubnetV6 = ""
    @State private var newInternal = false
    @State private var newLabels: [String] = []
    @State private var newOptions: [String] = []
    @State private var newPlugin = ""
    @State private var edits = FormEditTracker()

    private var editSignature: String {
        [newNetworkName, addressFamily.rawValue, newSubnet, newSubnetV6, newPlugin,
         "\(newInternal)",
         newLabels.joined(separator: ","),
         newOptions.joined(separator: ",")].joined(separator: "\u{1}")
    }
    @State private var addressFamily: AddressFamily = .ipv4

    /// The **only** moment a network's settings can be chosen.
    ///
    /// `container network` has create, delete, list, inspect and prune — no update, edit or
    /// set. A network is immutable once it exists, so anything not chosen here can never be
    /// changed. That is why every flag the CLI accepts is offered, and why the addressing is
    /// split in two: v4 and v6 are independent, a network may be either or both, and mixing
    /// their examples in one column made neither clear.
    /// The `ScrollView` is load-bearing — see `VolumesView.createScreen` for the measurement.
    /// Without it, `maxHeight: .infinity` inside an unbounded parent let this form grow the
    /// window's split view to 2020pt and pushed every control off-screen, leaving a blank window
    /// with no way back.
    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Network", systemImage: "network.badge.shield.half.filled",
                       hasUnsavedChanges: edits.isDirty(editSignature), onBack: dismiss)
            Divider()
            FormScaffold {
                form
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .onAppear {
            host = initialHost
            if let prefill {
                newNetworkName = ResourceSuggestions.uniqueName(prefill.baseName, taken: networkNames(on: host))
                newInternal = prefill.hostOnly
            }
            edits.open(editSignature)
        }
    }

    /// This Mac and every trusted host.
    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// Names already taken on a Mac, so a suggestion never proposes one that exists there.
    private func networkNames(on host: HostRef) -> Set<String> {
        switch host {
        case .local: Set(model.networks.map(\.id))
        case .peer(let fingerprint): Set(model.hostMode.networkSnapshots[fingerprint]?.items.map(\.id) ?? [])
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            if hostChoices.count > 1 {
                FormField("Create on",
                          help: FieldHelp("Which Mac the network is created on.",
                                          detail: "A network belongs to one Mac. The same name on two Macs is two separate private networks, and an empty subnet is chosen by that Mac.")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $host) {
                            ForEach(hostChoices, id: \.ref) { Text($0.name).tag($0.ref) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        ContainerSkewNote(model: model, hosts: [host])
                    }
                }
            }
            FormField("Name",
                      help: FieldHelp(
                          "What the network is called, and how you attach a container to it.",
                          detail: "It appears in the Run form's Network picker under this name.",
                          example: "Letters, numbers, dots, dashes or\nunderscores. Must start with a letter\nor number. No spaces."),
                      problem: nameProblem) {
                TextField("my-network", text: $newNetworkName)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            FormField("Addressing",
                      help: FieldHelp(
                          "Which address family this network uses.",
                          detail: "IPv4 and IPv6 are independent, and each takes its own subnet — which is why they are not offered in one column.")) {
                Picker("Addressing", selection: $addressFamily) {
                    ForEach(AddressFamily.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch addressFamily {
            case .ipv4:
                FormField("Subnet",
                          help: FieldHelp(
                              "The address range containers on this network are given.",
                              detail: "CIDR notation. Left empty, a private range is assigned for you.",
                              example: "10.10.0.0/24\n192.168.80.0/24"),
                          problem: subnetProblem,
                          optional: true) {
                    TextField("10.10.0.0/24", text: $newSubnet)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                }
            case .ipv6:
                FormField("Subnet",
                          help: FieldHelp(
                              "The address range containers on this network are given.",
                              detail: "CIDR notation. Left empty, a private range is assigned for you.",
                              example: "fd00:1234::/64",
                              warning: "Use a unique-local prefix (fd00::/8) for a private network — a globally routable prefix you do not own will not behave."),
                          problem: subnetV6Problem,
                          optional: true) {
                    TextField("fd00:1234::/64", text: $newSubnetV6)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                }
            }

            FormField("Isolation",
                      help: FieldHelp(
                          "Whether containers on this network can reach anything outside it.",
                          detail: "Host-only keeps them talking to each other and to nothing else — the right default for a database that only its own app should reach.")) {
                Toggle("Host-only — no external access", isOn: $newInternal)
                    .toggleStyle(.checkbox)
            }

            // Expanded, not behind a disclosure triangle: three short controls, and hiding them
            // behind a chevron mostly hides that they exist.
            VStack(alignment: .leading, spacing: 14) {
                FormSectionHeader(title: "Advanced")

                FormField("Labels",
                          help: FieldHelp(
                              "Your own key=value metadata, carried on the network.",
                              detail: "Up to eight. Nothing reads them but you.",
                              example: "team=infra"),
                          problem: labelsProblem,
                          optional: true) {
                    keyValueList($newLabels, title: nil, placeholder: "team=infra")
                }

                FormField("Plugin options",
                          help: FieldHelp(
                              "Options passed straight through to the network plugin.",
                              detail: "Up to eight, as key=value. What they mean is the plugin's business.",
                              example: "mtu=1500"),
                          problem: optionsProblem,
                          optional: true) {
                    keyValueList($newOptions, title: nil, placeholder: "mtu=1500")
                }

                FormField("Plugin",
                          help: FieldHelp(
                              "Which network plugin backs this network.",
                              detail: "Left empty, `container` uses its default.",
                              example: "container-network-vmnet",
                              warning: "A plugin **name**, not an option. `mtu=1500` and the like "
                                  + "belong in Plugin options above."),
                          problem: pluginProblem,
                          optional: true) {
                    TextField("container-network-vmnet", text: $newPlugin)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                }
            }
        }
    }

    /// The validated command, in the rail.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text((["container"] + ContainerCLI.createNetworkArguments(trimmedName, options: options))
                    .joined(separator: " "))
                .font(.system(size: 11, design: .monospaced))
                // Red when the command is refused, like the machine form's preview. It was
                // `.secondary` unconditionally, so a rejected command looked exactly like an
                // accepted one — which is how a disabled button ended up with no signal anywhere
                // on the screen.
                .foregroundStyle(anyProblem != nil && !trimmedName.isEmpty
                                 ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !host.isLocal {
                Label("Runs on \(model.hostMode.hostName(host, local: model.hostLabel))",
                      systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            // Says why, when nothing else does. A disabled button with no explanation anywhere
            // on the screen is what this form shipped with.
            if let unclaimedProblem {
                Label(unclaimedProblem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Create") {
                let name = trimmedName
                let opts = options
                let target = host
                dismiss()
                Task { await model.createNetwork(name, options: opts, host: target) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedName.isEmpty || anyProblem != nil)
        }
        .padding(12)
    }

    enum AddressFamily: String, CaseIterable, Identifiable {
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        var id: Self { self }
    }

    @ViewBuilder
    private func addressField(
        text: Binding<String>, placeholder: String, problem: String?, note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subnet").font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .monospaced()
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Theme.danger)
            } else {
                Text(note + " Cannot be changed later.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Repeatable `key=value` flags. The cap is `--label`'s and `--option`'s own `maxRepeats`
    /// in `Allowlist`; the editor itself is shared — see `KeyValueList`.
    @ViewBuilder
    private func keyValueList(_ list: Binding<[String]>, title: String? = nil,
                              placeholder: String) -> some View {
        KeyValueList(values: list, limit: 8, placeholder: placeholder,
                     title: title, itemLabel: "entry")
    }

    private var options: ContainerCLI.NetworkOptions {
        ContainerCLI.NetworkOptions(
            subnet: addressFamily == .ipv4 ? trimmedSubnet : nil,
            subnetV6: addressFamily == .ipv6 ? trimmedSubnetV6 : nil,
            isInternal: newInternal,
            labels: newLabels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            options: newOptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            plugin: newPlugin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : newPlugin.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// One validation pass over the whole command, so Create is disabled for *any* bad field —
    /// labels and plugin options included, not just the two with their own messages.
    private var anyProblem: String? {
        problem(in: ContainerCLI.createNetworkArguments(
            trimmedName.isEmpty ? "placeholder" : trimmedName, options: options))
    }

    private var trimmedName: String {
        newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedSubnet: String? {
        let value = newSubnet.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private var trimmedSubnetV6: String? {
        let value = newSubnetV6.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Validated **here**, against the same `Allowlist` the execution path uses, so an invalid
    /// name is refused with the reason while it is still being typed. Previously the only
    /// feedback was an "Action failed" alert after the fact, whose message named the verdict
    /// and not the rule — "'Test 1' is not a valid identifier" led to the wrong conclusion
    /// that capitals were the problem. They are not; the space was.
    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }   // don't scold an empty field
        return problem(in: ContainerCLI.createNetworkArguments(trimmedName))
    }

    private var subnetProblem: String? {
        guard let subnet = trimmedSubnet else { return nil }
        // Validated alone, with a name known to be fine, so the message can only be about
        // this field.
        return problem(in: ContainerCLI.createNetworkArguments(
            "placeholder", options: .init(subnet: subnet)))
    }

    private var subnetV6Problem: String? {
        guard let v6 = trimmedSubnetV6 else { return nil }
        return problem(in: ContainerCLI.createNetworkArguments(
            "placeholder", options: .init(subnetV6: v6)))
    }

    /// The three fields that could refuse a create with nothing to say.
    ///
    /// `--plugin` takes a plugin **name**, and the example beside it says so — but the field next
    /// to it is "Plugin options", which takes `key=value`, and typing `mtu=1500` into the wrong
    /// one of the two disabled Create with no message anywhere on the screen. Reported exactly
    /// that way: form filled in, button grey.
    private var pluginProblem: String? {
        let value = newPlugin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return problem(in: ContainerCLI.createNetworkArguments(
            "placeholder", options: .init(plugin: value)))
    }

    private var labelsProblem: String? {
        let values = newLabels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !values.isEmpty else { return nil }
        return problem(in: ContainerCLI.createNetworkArguments(
            "placeholder", options: .init(labels: values)))
    }

    private var optionsProblem: String? {
        let values = newOptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !values.isEmpty else { return nil }
        return problem(in: ContainerCLI.createNetworkArguments(
            "placeholder", options: .init(options: values)))
    }

    /// Why Create is refusing, when **no field has claimed it**.
    ///
    /// The backstop. Every field above validates itself, but `anyProblem` checks the whole
    /// command, so a combination — or a field added later without its own message — can still
    /// block the button. Rather than let that be silent, the reason goes beside the button.
    ///
    /// Nil when a field is already showing it, so the same sentence is not printed twice.
    private var unclaimedProblem: String? {
        guard let anyProblem, !trimmedName.isEmpty else { return nil }
        let claimed = [nameProblem, subnetProblem, subnetV6Problem,
                       pluginProblem, labelsProblem, optionsProblem].compactMap { $0 }
        return claimed.contains(anyProblem) ? nil : anyProblem
    }



    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }
}
