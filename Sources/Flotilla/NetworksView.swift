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
    @State private var pendingDelete: ContainerNetwork?

    var body: some View {
        Group {
            if showingCreate {
                NewNetworkView(model: model) { showingCreate = false }
            } else {
                VStack(spacing: 0) {
                    toolbar
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
                                  open: { _ in })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshNetworks() }
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
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search networks…",
                       updated: model.networksLastRefresh,
                       leading: {
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

        case .loaded where model.networks.isEmpty:
            ContentUnavailableView(
                "No networks",
                systemImage: "network",
                description: Text("Create one to give containers an isolated network.")
            )

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
                    onOpen: nil
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
            TableColumn("Name", value: \.id) { network in
                HStack(spacing: 6) {
                    Text(network.name).foregroundStyle(Theme.accentText).lineLimit(1)
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
        }
    }

    @ViewBuilder
    private func rowActions(for network: ContainerNetwork) -> some View {
        let busy = model.busy.contains(network.id)
        HStack(spacing: 2) {
            Menu {
                menu(for: network)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
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

    @ViewBuilder
    private func menu(for network: ContainerNetwork) -> some View {
        CopyMenu([
            ("Name", network.id),
            ("Subnet", network.subnet),
            ("Gateway", network.gateway),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(network) }
            .disabled(model.busy.contains(network.id))
    }



    /// Honours `confirmDestructiveActions` — the whole point of that registry key.
    private func requestDelete(_ network: ContainerNetwork) {
        if model.settingsStore[SettingsKeys.confirmDestructiveActions] {
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
/// the owner's rule, stated generally: any window that comes up should carry macOS's own traffic
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
    @State private var addressFamily: AddressFamily = .ipv4

    /// The **only** moment a network's settings can be chosen.
    ///
    /// `container network` has create, delete, list, inspect and prune — no update, edit or
    /// set. A network is immutable once it exists, so anything not chosen here can never be
    /// changed. That is why every flag the CLI accepts is offered, and why the addressing is
    /// split in two: v4 and v6 are independent, a network may be either or both, and mixing
    /// their examples in one column made neither clear.
    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Network", systemImage: "network.badge.shield.half.filled",
                       onBack: dismiss)
            Divider()
            form
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-network", text: $newNetworkName)
                    .textFieldStyle(.roundedBorder)
                if let problem = nameProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                }
            }

            Picker("Addressing", selection: $addressFamily) {
                ForEach(AddressFamily.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Each family gets its own field, example and note — that is the point of
            // separating them.
            switch addressFamily {
            case .ipv4:
                addressField(
                    text: $newSubnet,
                    placeholder: "10.10.0.0/24",
                    problem: subnetProblem,
                    note: "Optional. Leave empty and a private range is assigned for you."
                )
            case .ipv6:
                addressField(
                    text: $newSubnetV6,
                    placeholder: "fd00:1234::/64",
                    problem: subnetV6Problem,
                    note: "Optional. Use a unique-local prefix (fd00::/8) for a private network."
                )
            }

            Toggle("Host-only — no external access", isOn: $newInternal)
                .toggleStyle(.checkbox)

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueList($newLabels, title: "Labels", placeholder: "team=infra")
                    keyValueList($newOptions, title: "Plugin options", placeholder: "mtu=1500")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plugin").font(.caption).foregroundStyle(.secondary)
                        TextField("container-network-vmnet", text: $newPlugin)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty for the default.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }

            Divider()

            Text((["container"] + ContainerCLI.createNetworkArguments(trimmedName, options: options))
                    .joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Create") {
                    let name = trimmedName
                    let opts = options
                    dismiss()
                    Task { await model.createNetwork(name, options: opts) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || anyProblem != nil)
            }
        }
        .padding(20)
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
    private func keyValueList(_ list: Binding<[String]>, title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
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
