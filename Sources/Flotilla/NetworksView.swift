import SwiftUI
import Foundation
import FlotillaCore

/// The networks section: list, create, delete — same shape as `VolumesView`.
struct NetworksView: View {
    let model: AppModel
    let ui: ResourceUIState<ContainerNetwork>

    @State private var selection = Set<ContainerNetwork.ID>()

    @State private var search = ""
    @State private var showingCreate = false
    /// Which network the detail screen is showing, and optionally which tab to open it on.
    private struct DetailTarget: Identifiable, Hashable {
        let id: String
        var tab: NetworkDetailTab?
    }

    /// The network whose detail screen is showing, or nil for the list.
    @State private var detailTarget: DetailTarget?
    @State private var pendingDelete: ContainerNetwork?
    @State private var confirmingBulkDelete = false

    var body: some View {
        Group {
            if showingCreate {
                NewNetworkView(model: model) { showingCreate = false }
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                }
                // Same band as Containers and Machines. See `ResourceUIState.activityExpanded`
                // for why it is collapsible: on this section it is usually empty.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  // As in Volumes: the detail screen, which is what clicking
                                  // the name gives too.
                                  open: { detailTarget = DetailTarget(id: $0) },
                                  canOpen: { id in model.networks.contains { $0.id == id } })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshNetworks() }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingNetworkForm) { _, requested in
            if requested { showingCreate = true; model.pendingNetworkForm = false }
        }
        .onAppear {
            if model.pendingNetworkForm { showingCreate = true; model.pendingNetworkForm = false }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Delete network “\(pendingDelete?.id ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let network = pendingDelete {
                    Task { await model.removeNetwork(network) }
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
                Task { await model.deleteNetworks(actionable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
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

            ResourceListControls<ContainerNetwork>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: Self.roleFilters)
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "Create a network…") {
                showingCreate = true
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh networks") {
                Task { await model.refreshNetworks() }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("mode", "Mode"), ("subnet", "Subnet"), ("gateway", "Gateway"), ("created", "Created"),
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
    private var isFiltered: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" }

    private var displayedNetworks: [ContainerNetwork] {
        var networks = model.networks

        switch ui.filterID {
        case "user": networks = networks.filter { !$0.isBuiltin }
        case "builtin": networks = networks.filter(\.isBuiltin)
        default: break
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            networks = networks.filter { $0.id.lowercased().contains(query) }
        }

        return networks.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<ContainerNetwork.ID> { Set(displayedNetworks.map(\.id)) }

    /// Search and role filters can hide selected rows without clearing their ids; bulk delete is
    /// therefore constrained to what remains on screen.
    ///
    /// Built-in networks are excluded here rather than refused later. The row's own delete button
    /// is already `disabled: network.isBuiltin`, so leaving `default` in the batch would have the
    /// bar count it, ask to delete it, and then report a failure the row had already ruled out —
    /// the bulk path claiming not to know something the per-row path does.
    private var actionable: Set<ContainerNetwork.ID> {
        Set(displayedNetworks.lazy.filter { selection.contains($0.id) && !$0.isBuiltin }.map(\.id))
    }

    private func selectionToggle(for id: ContainerNetwork.ID) -> some View {
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

    @ViewBuilder
    private var bulkActionBar: some View {
        // A single network already has the same delete control in its row.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
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
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
                } else {
                    Button("New Network…") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedNetworks) { network in
                ResourceCard(
                    title: network.name,
                    badge: network.isBuiltin ? "built-in" : nil,
                    fields: [("Mode", network.mode),
                             ("Subnet", network.subnet),
                             ("Gateway", network.gateway),
                             ("Created", RelativeDate.relative(network.configuration.creationDate))],
                    // The card title opens the detail, so the list/cards toggle does not change
                    // what you can reach. Every caller of `ResourceCard` passed `nil` here.
                    onOpen: { detailTarget = DetailTarget(id: network.id) }
                ) {
                    rowActions(for: network)
                }
                .contextMenu { menu(for: network) }
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
            TableColumn("") { network in
                selectionToggle(for: network.id)
            }
            .width(min: 28, ideal: 30, max: 34)

            TableColumn("Name", value: \.id) { network in
                HStack(spacing: 6) {
                    // The way in, as in every other table.
                    Button(network.name) { detailTarget = DetailTarget(id: network.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.rowName(selected: selection.contains(network.id)))
                        .lineLimit(1)
                        .help("Open \(network.name)")
                    if network.isBuiltin {
                        Text("built-in")
                            .font(.caption2).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 150, ideal: 210)

            TableColumn("Mode", value: \.modeSortKey) { network in
                Text(network.mode ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 88)
            .customizationID("mode")

            TableColumn("Subnet", value: \.subnetSortKey) { network in
                Text(network.subnet ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
            .customizationID("subnet")

            TableColumn("Gateway", value: \.gatewaySortKey) { network in
                Text(network.gateway ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            .customizationID("gateway")

            TableColumn("Created", value: \.creationSortKey) { network in
                Text(RelativeDate.relative(network.configuration.creationDate))
                    .foregroundStyle(.secondary)
                    .help(RelativeDate.absolute(network.configuration.creationDate))
            }
            .width(min: 80, ideal: 104)
            .customizationID("created")

            TableColumn("Actions") { network in
                rowActions(for: network)
            }
            .width(min: 78, ideal: 88)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: ContainerNetwork.ID.self) { ids in
            if let network = model.networks.first(where: { ids.contains($0.id) }) {
                menu(for: network)
            }
        } primaryAction: { ids in
            // Double-click opens the detail, and only for an unambiguous activation — `ids` is a
            // `Set`, so with several rows selected `first` is an arbitrary member.
            guard ids.count == 1,
                  let network = model.networks.first(where: { ids.contains($0.id) }) else { return }
            detailTarget = DetailTarget(id: network.id)
        }
    }

    @ViewBuilder
    private func rowActions(for network: ContainerNetwork) -> some View {
        let busy = model.isBusy(network.id, kind: .network)
        HStack(spacing: 2) {
            Menu {
                menu(for: network)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(network.id)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(network.id)",
                             help: network.isBuiltin
                                 ? "\(network.id) is built in and cannot be deleted"
                                 : "Delete \(network.id)",
                             busy: busy,
                             disabled: network.isBuiltin,
                             destructive: true) {
                requestDelete(network)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detailScreen(_ target: DetailTarget) -> some View {
        VStack(spacing: 0) {
            if let network = model.networks.first(where: { $0.id == target.id }) {
                detailHeader(for: network)
                Divider()
                NetworkDetailView(model: model, network: network, requestedTab: target.tab)
                    .id(network.id)
            } else {
                detailHeader(for: nil)
                Divider()
                ContentUnavailableView(
                    "Network unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("\u{201C}\(target.id)\u{201D} is no longer on this Mac. It may have been deleted.")
                )
            }
        }
    }

    @ViewBuilder
    private func detailHeader(for network: ContainerNetwork?) -> some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back to Networks",
                             help: "Back to Networks") { detailTarget = nil }

            if let network {
                Image(systemName: "globe")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(network.name).font(.headline)
                        if network.isBuiltin {
                            Text("built-in").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle(for: network))
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text("Network unavailable").font(.headline)
            }

            Spacer()
            stepper
            if let network {
                ActionCluster { rowActions(for: network) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stepper: some View {
        let order = displayedNetworks
        let index = order.firstIndex { $0.id == detailTarget?.id }
        HStack(spacing: 2) {
            Button {
                if let index, index > 0 { detailTarget = DetailTarget(id: order[index - 1].id) }
            } label: { Image(systemName: "chevron.up") }
                .disabled(index == nil || index == 0)
                .help("Previous network")
                .accessibilityLabel("Previous network")

            Button {
                if let index, index < order.count - 1 {
                    detailTarget = DetailTarget(id: order[index + 1].id)
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

    private func subtitle(for network: ContainerNetwork) -> String {
        [network.mode, network.subnet, network.gateway]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func menu(for network: ContainerNetwork) -> some View {
        let busy = model.isBusy(network.id, kind: .network)

        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)`, which greyed out the reads — Inspect, Copy — on the one surface and
        // left them live on the other.
        // GAP-06, same as Volumes. Worth more here than there: `network inspect` carries the
        // `status` block — the gateway and both subnets the runtime actually assigned — which
        // `network ls` does not always return.
        Button("Details…") { detailTarget = DetailTarget(id: network.id) }
        Button("Inspect") { detailTarget = DetailTarget(id: network.id, tab: .inspect) }
        Divider()
        CopyMenu([
            ("Name", network.id),
            ("Subnet", network.subnet),
            ("Gateway", network.gateway),
        ])
        Divider()
        // `isBuiltin`, not just `busy`. The trash **button** beside this menu has carried
        // `disabled: network.isBuiltin` since the busy/disabled split, and its tooltip explains
        // why — but the menu never learned: right-click → Delete on `default` offered a deletion
        // the CLI refuses outright. Same family as the containers context menu that deleted with
        // no dialog while the button two lines away always asked.
        Button("Delete…", role: .destructive) { requestDelete(network) }
            .disabled(network.isBuiltin || busy)
    }



    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ network: ContainerNetwork) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = network
        } else {
            Task { await model.removeNetwork(network) }
        }
    }
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
        .onAppear { edits.open(editSignature) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                          optional: true) {
                    keyValueList($newLabels, title: nil, placeholder: "team=infra")
                }

                FormField("Plugin options",
                          help: FieldHelp(
                              "Options passed straight through to the network plugin.",
                              detail: "Up to eight, as key=value. What they mean is the plugin's business.",
                              example: "mtu=1500"),
                          optional: true) {
                    keyValueList($newOptions, title: nil, placeholder: "mtu=1500")
                }

                FormField("Plugin",
                          help: FieldHelp(
                              "Which network plugin backs this network.",
                              detail: "Left empty, `container` uses its default.",
                              example: "container-network-vmnet"),
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
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Create") {
                let name = trimmedName
                let opts = options
                dismiss()
                Task { await model.createNetwork(name, options: opts) }
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

    /// Repeatable `key=value` flags, capped at the `Allowlist`'s own maximum of 8 — the cap is
    /// shown rather than silently enforced.
    @ViewBuilder
    private func keyValueList(_ list: Binding<[String]>, title: String? = nil,
                              placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let title {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(list.wrappedValue.count)/8").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { list.wrappedValue.indices.contains(index) ? list.wrappedValue[index] : "" },
                        set: { if list.wrappedValue.indices.contains(index) { list.wrappedValue[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        list.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove")
                }
            }
            Button {
                list.wrappedValue.append("")
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(list.wrappedValue.count >= 8)
        }
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



    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }
}
