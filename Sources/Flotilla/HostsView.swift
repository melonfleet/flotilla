import SwiftUI
import AppKit
import Network
import FlotillaCore
import FlotillaTrust

/// One Mac in the Hosts section: This Mac, or a host in the `PeerBook` — paired, waiting for the
/// owner's approval, turned away or removed. Every column is one a remote host can answer; the
/// counts a remote host cannot give until Phase C reads them read "—", not zero.
struct HostRow: Identifiable, Hashable {
    /// This Mac's is fixed; a host's is its fingerprint, never its name, which the owner can change.
    let id: String
    let name: String
    let isThisMac: Bool
    /// The host's entry in the book; `nil` for This Mac.
    let peer: Peer?
    let status: String
    /// Whether it is usable now — This Mac's runtime is up, or a host is paired.
    let connected: Bool
    let containersRunning: Int?
    let containersTotal: Int?
    let machines: Int?
    let macOS: String?
    let containerVersion: String?
    let modelIdentifier: String?
    /// The Mac's Flotilla, with its build number.
    var appVersion: String? = nil
    /// Set when the version differs from This Mac's enough to say so (PLAN.md Phase C).
    var containerSkew: VersionSkew? = nil
    var appSkew: VersionSkew? = nil
    /// Set for a host named in an imported file and not paired yet (Q34) — not a peer.
    var imported: HostModeController.ImportedHost? = nil
    /// Set when the row is a group's header rather than a Mac (Group By).
    var header: HostGroupHeader? = nil

    static let thisMacID = "this-mac"

    static func header(_ header: HostGroupHeader, running: Int?, total: Int?, machines: Int?) -> HostRow {
        HostRow(id: "group:" + (header.value ?? "\u{0}none"), name: header.title, isThisMac: false, peer: nil,
                status: "\(header.connected) of \(header.hostIDs.count) connected", connected: header.connected > 0,
                containersRunning: running, containersTotal: total, machines: machines,
                macOS: nil, containerVersion: nil, modelIdentifier: nil, header: header)
    }

    var isPending: Bool { peer?.status == .pending }
    var nameSortKey: String { name.lowercased() }
    var statusSortKey: String { (isPending ? "0" : connected ? "1" : "2") + status }
    var containersSortKey: Int { containersRunning ?? -1 }
    var machinesSortKey: Int { machines ?? -1 }
    var macOSSortKey: String { macOS ?? "" }
    var containerSortKey: String { containerVersion ?? "" }
    var appSortKey: String { appVersion ?? "" }
    var modelSortKey: String { modelIdentifier ?? "" }

    var containersText: String {
        guard let containersRunning, let containersTotal else { return "—" }
        return "\(containersRunning) running of \(containersTotal)"
    }
    var machinesText: String { machines.map(String.init) ?? "—" }

    /// The words for a host's state in the book.
    static func statusText(_ status: Peer.Status) -> String {
        switch status {
        case .pending: "Waiting for approval"
        case .approved: "Paired"
        case .rejected: "Turned away"
        case .revoked: "Access removed"
        }
    }
}

extension AppModel {
    /// This Mac's `container` version, as preflight found it.
    var localContainerVersion: String? {
        switch preflight {
        case .ok(let version, _), .serviceStopped(let version, _, _), .needsKernel(let version, _, _):
            version
        case .needsRestart(let cli, _, _): cli
        case .tooOld(let found, _): found
        case .missing, .unusable, nil: nil
        }
    }

    /// How a paired host's `container` differs from This Mac's (PLAN.md Phase C). `nil` for This
    /// Mac, or when either version is unknown.
    func containerSkew(_ host: HostRef) -> VersionSkew? {
        guard case .peer(let fingerprint) = host else { return nil }
        return VersionSkew(this: localContainerVersion, other: hostMode.live[fingerprint]?.containerVersion)
    }

    /// How a paired host's Flotilla differs from this one.
    func appSkew(_ host: HostRef) -> VersionSkew? {
        guard case .peer(let fingerprint) = host else { return nil }
        return VersionSkew(this: HostModeController.appVersion, other: hostMode.live[fingerprint]?.appVersion)
    }

    /// One sentence for a host whose `container` may refuse what This Mac's checks allow, or `nil`.
    func containerSkewWarning(_ host: HostRef) -> String? {
        guard let skew = containerSkew(host), skew.mayRefuseCommands,
              case .peer(let fingerprint) = host,
              let theirs = hostMode.live[fingerprint]?.containerVersion, let ours = localContainerVersion
        else { return nil }
        return "\(hostMode.hostName(host, local: hostLabel)) runs container \(theirs) and This Mac \(ours). "
            + "Flotilla checks commands against \(ours), so it may refuse an option allowed here."
    }

    /// This Mac, then every host in the book.
    var hostRows: [HostRow] {
        let version = localContainerVersion
        let system = systemInfo
        let thisMac = HostRow(id: HostRow.thisMacID, name: HostModeController.computerName, isThisMac: true, peer: nil,
                              status: RuntimeStatus.describe(preflight).title,
                              connected: runtimeUsable,
                              containersRunning: containers.filter(AppModel.isRunning).count,
                              containersTotal: containers.count,
                              machines: machines.count,
                              macOS: system.osVersion,
                              containerVersion: version,
                              modelIdentifier: system.modelIdentifier,
                              appVersion: HostModeController.appVersion)
        let hosts = hostMode.hosts.map { peer in
            let live = peer.isTrusted ? hostMode.live[peer.fingerprint] : nil
            // While Flotilla updates there, the connection drops on purpose for the relaunch: said
            // so, rather than shown as a fault (measured 8 October, Tahoe read "The connection closed").
            let status: String = if hostMode.updating.contains(peer.fingerprint) && live?.state != .connected {
                "Updating Flotilla…"
            } else {
                switch live?.state {
                case .connected: "Connected"
                case .checking: "Checking…"
                case .failed(let why): hostMissingContainer(peer.fingerprint) ? "container isn't installed" : why
                case nil: HostRow.statusText(peer.status)
                }
            }
            return HostRow(id: peer.fingerprint.hex, name: peer.displayName, isThisMac: false, peer: peer,
                           status: status, connected: live?.state == .connected,
                           containersRunning: live?.containersRunning, containersTotal: live?.containersTotal,
                           machines: live?.machines,
                           macOS: peer.details.macOSVersion, containerVersion: live?.containerVersion,
                           modelIdentifier: peer.details.model,
                           appVersion: live?.appVersion,
                           containerSkew: containerSkew(.peer(peer.fingerprint)),
                           appSkew: appSkew(.peer(peer.fingerprint)))
        }
        // Imported claims, until each is paired (Q34).
        let imported = hostMode.importedHosts.map { host in
            HostRow(id: host.fingerprint.hex, name: host.name, isThisMac: false, peer: nil,
                    status: "Imported — not paired", connected: false,
                    containersRunning: nil, containersTotal: nil, machines: nil,
                    macOS: nil, containerVersion: nil, modelIdentifier: nil, imported: host)
        }
        return [thisMac] + hosts + imported
    }
}

/// Hosts — every Mac Flotilla manages, with the same table setup as every other section (the
/// owner, 6 October): list and cards, search, filter, sortable and hideable columns, row menus that
/// match the context menu, multi-select, tags, Add and Refresh, and the activity band.
///
/// **Add** pairs a new host (B3b): by the code it shows, or with the fleet enrolment key. Macs that
/// asked to join with the key wait here for the owner's approval — a banner says how many — and
/// nothing is trusted until approved. This Mac's page is the per-Mac dashboard; a paired host's is
/// what it said about itself when it paired, until Phase C brings its containers here.
struct HostsView: View {
    let model: AppModel
    let ui: ResourceUIState<HostRow>
    let go: (Section) -> Void

    @State private var selection = Set<HostRow.ID>()
    @State private var openHost: HostRow.ID?
    @State private var showingAdd = false
    @State private var tagSheet: TagSheetTarget?
    @State private var pendingForget: HostRow?
    /// A host whose `container` the owner asked to install or upgrade (Q39) — confirmed first.
    @State private var pendingRuntime: HostRow?
    @State private var runtimeError: String?
    /// An imported host being paired: Add Host, holding the key it must present.
    @State private var pairing: HostModeController.ImportedHost?
    /// The host being given the owner's own name, and the text so far.
    @State private var renaming: Peer?
    @State private var newName = ""
    /// A real `Bool` beside the action, for the reason `RuntimeStatusBand` records: a computed
    /// binding over an optional did not present the dialog at all.
    @State private var confirming: RuntimeLifecycleAction = .stop
    @State private var showingConfirmation = false
    /// Group By — kept across launches; "none", "subnet" or "category:<id>".
    @AppStorage("hostsGroupBy") private var groupByKey = "none"
    @State private var showingCategories = false
    @State private var valueTarget: ValueTarget?

    /// A category and the hosts a new value is for, for `.sheet(item:)`.
    struct ValueTarget: Identifiable {
        let category: HostCategory
        let hosts: [String]
        var id: String { category.id + hosts.joined() }
    }

    private static let removeHelp = "This Mac is the admin machine — it can’t be removed"
    private var hostMode: HostModeController { model.hostMode }

    var body: some View {
        Group {
            if showingAdd || pairing != nil {
                AddHostView(model: model, importing: pairing) { showingAdd = false; pairing = nil }
            } else if let id = openHost {
                hostPage(id)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    approvalBanner
                    content
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  open: { subject in
                                      openHost = model.hostRows.first { $0.name == subject }?.id ?? HostRow.thisMacID
                                  },
                                  canOpen: { _ in true })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A host's name elsewhere — Overview's Hosts table — opens its page here. One-shot.
        .onChange(of: model.pendingDetailSubject) { _, subject in
            guard let subject, model.pendingDetailKind == .host else { return }
            openHost = subject
            model.clearPendingDetail()
        }
        .onAppear {
            if let subject = model.pendingDetailSubject, model.pendingDetailKind == .host {
                openHost = subject
                model.clearPendingDetail()
            }
            if model.pendingAddHost, hostMode.isAdmin { showingAdd = true }
            model.pendingAddHost = false
        }
        .onChange(of: model.pendingAddHost) { _, wanted in
            guard wanted else { return }
            if hostMode.isAdmin { showingAdd = true }
            model.pendingAddHost = false
        }
        .task {
            await model.refreshMachines()
            // Kept current while Hosts is open: a host's state, counts and name (after a rename)
            // without anyone pressing Refresh. Stops when the section goes.
            while !Task.isCancelled {
                await hostMode.refreshLiveStatus()
                // Every paired Mac has an address block once its networks are known (Q35).
                await model.refreshNetworks()
                model.updateAddressPlan()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        .sheet(isPresented: $showingCategories) {
            HostCategoriesSheet(store: model.hostCategories) { showingCategories = false }
        }
        .sheet(item: $valueTarget) { target in
            HostValueSheet(store: model.hostCategories, category: target.category, hosts: target.hosts) { valueTarget = nil }
        }
        .confirmationDialog(confirming.question,
                            isPresented: $showingConfirmation,
                            titleVisibility: .visible) {
            Button(confirming.verb, role: .destructive) { perform(confirming) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming.consequence)
        }
        .alert("Rename “\(renaming?.details.computerName ?? "")”", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let peer = renaming { hostMode.rename(peer.fingerprint, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("A name for this host on this Mac only. Leave it empty to use the name the host gives itself.")
        }
        .confirmationDialog(runtimeQuestion,
                            isPresented: Binding(get: { pendingRuntime != nil }, set: { if !$0 { pendingRuntime = nil } }),
                            titleVisibility: .visible, presenting: pendingRuntime) { row in
            Button(runtimeButton(row)) {
                guard let peer = row.peer else { return }
                Task { if let failure = await model.setUpRuntime(on: peer.fingerprint) { runtimeError = failure } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(runtimeMessage(row))
        }
        .alert("container wasn't set up", isPresented: Binding(get: { runtimeError != nil }, set: { if !$0 { runtimeError = nil } })) {
            Button("OK") { runtimeError = nil }
        } message: {
            Text(runtimeError ?? "")
        }
        .confirmationDialog("Remove “\(pendingForget?.name ?? "")”?",
                            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
                            titleVisibility: .visible, presenting: pendingForget) { row in
            Button("Remove", role: .destructive) {
                if let peer = row.peer { hostMode.remove(peer.fingerprint) }
                if let imported = row.imported { hostMode.removeImported(imported.fingerprint) }
                model.hostCategories.forgetHost(row.id)
                selection.remove(row.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(row.imported != nil
                 ? "It is forgotten. Import the file again to bring it back."
                 : row.peer?.isTrusted == true
                 ? "This Mac stops managing it. To manage it again, pair it again."
                 : "It is forgotten, and can ask to join again.")
        }
    }

    @ViewBuilder
    private func hostPage(_ id: HostRow.ID) -> some View {
        let row = model.hostRows.first { $0.id == id }
        VStack(spacing: 0) {
            FormHeader(title: row?.name ?? HostModeController.computerName,
                       systemImage: Section.hosts.systemImage,
                       hasUnsavedChanges: false, onBack: { openHost = nil },
                       titleBadge: row?.isThisMac == true ? "This Mac" : nil) {
                // Ask this Mac again now rather than waiting for the next look (the owner, 9 October).
                ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh \(row?.name ?? model.hostLabel)") {
                    Task {
                        if let peer = row?.peer, peer.isTrusted {
                            await hostMode.refreshHost(peer.fingerprint)
                        } else if row?.peer == nil {
                            await model.reload()
                            await model.refreshSystemFacts()
                        }
                    }
                }
            }
            Divider()
            // One tabbed page for This Mac and every trusted host (the owner, 9 October). A host
            // still waiting for approval keeps the approve/turn-away screen until it is trusted.
            if let peer = row?.peer, !peer.isTrusted {
                PeerDetailView(peer: peer, model: model) { openHost = nil }
            } else if let peer = row?.peer {
                HostDetailView(model: model, host: .peer(peer.fingerprint), go: go)
            } else {
                HostDetailView(model: model, host: .local, go: go)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Approvals

    @ViewBuilder
    private var approvalBanner: some View {
        let waiting = hostMode.hosts.filter { $0.status == .pending }
        if !waiting.isEmpty {
            HStack(spacing: 8) {
                Label(waiting.count == 1
                      ? "\(waiting[0].displayName) is waiting for your approval."
                      : "\(waiting.count) Macs are waiting for your approval.",
                      systemImage: "person.badge.key")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if ui.filterID != "pending" {
                    Button("Show Them") { ui.filterID = "pending" }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
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
            HostGroupByMenu(store: model.hostCategories, grouping: groupingBinding) { showingCategories = true }
        }, trailing: {
            if model.startingRuntime { ProgressView().controlSize(.small) }
            ToolbarIconButton(systemImage: "plus", label: "Add a host",
                              help: hostMode.isAdmin ? "Pair another Mac"
                                                     : "This Mac is a host. Make it an admin in Settings ▸ Host Mode to add Macs.",
                              disabled: !hostMode.isAdmin) { showingAdd = true }
            if hostMode.isAdmin, !hostMode.trustedHosts.isEmpty {
                updatesMenu
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh hosts") {
                Task {
                    await model.reload()
                    await model.refreshMachines()
                    await hostMode.refreshLiveStatus(force: true)
                }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"), ("containers", "Containers"),
        ("machines", "Machines"), ("macos", "macOS"), ("container", "container"), ("flotilla", "Flotilla"),
        ("model", "Model"),
    ]

    private static let filters: [ResourceFilterOption] = [
        .init(id: "all", title: "All", systemImage: "circle.grid.2x2"),
        .init(id: "connected", title: "Connected", systemImage: "checkmark.circle"),
        .init(id: "pending", title: "Waiting for approval", systemImage: "person.badge.key"),
        .init(id: "attention", title: "Needs attention", systemImage: "exclamationmark.triangle"),
    ]

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all"
    }

    private var displayedRows: [HostRow] {
        var rows = model.hostRows
        switch ui.filterID {
        case "connected": rows = rows.filter(\.connected)
        case "pending": rows = rows.filter(\.isPending)
        case "attention": rows = rows.filter { !$0.connected && !$0.isPending }
        default: break
        }
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.lowercased().contains(query)
                    || builtIns(row).contains { $0.name.lowercased().contains(query) }
                    || row.status.lowercased().contains(query)
                    || (row.modelIdentifier?.lowercased().contains(query) ?? false)
                    || (row.peer?.details.serialNumber?.lowercased().contains(query) ?? false)
                    || model.tags.tags(on: .host, row.id)
                        .contains { $0.name.lowercased().contains(query) }
                    || (model.hostCategories.book.values[row.id]?.values
                        .contains { $0.lowercased().contains(query) } ?? false)
            }
        }
        return rows.sorted(using: ui.sortOrder)
    }

    // MARK: Group By

    private var grouping: HostGrouping {
        let stored = HostGrouping(storageKey: groupByKey)
        // A category that has since been removed groups by nothing.
        if case .category(let id) = stored, model.hostCategories.book.category(id: id) == nil { return .none }
        return stored
    }

    private var groupingBinding: Binding<HostGrouping> {
        Binding(get: { grouping }, set: { groupByKey = $0.storageKey })
    }

    /// The value a host is grouped under, for the current grouping.
    private func groupValue(_ row: HostRow) -> String? {
        switch grouping {
        case .none: nil
        case .subnet: subnet(row)
        case .category(let id): model.hostCategories.book.value(of: id, for: row.id)
        }
    }

    private func subnet(_ row: HostRow) -> String? {
        if row.isThisMac { return model.subnet(of: .local) }
        return row.peer.flatMap { model.subnet(of: .peer($0.fingerprint)) }
    }

    private var groupNoun: String {
        switch grouping {
        case .none: ""
        case .subnet: "subnet"
        case .category(let id): model.hostCategories.book.category(id: id)?.name ?? ""
        }
    }

    /// Each group's header and its hosts, in table order.
    private var groups: [(header: HostGroupHeader, rows: [HostRow])] {
        let rows = displayedRows
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return HostGrouping.buckets(rows.map(\.id)) { id in byID[id].flatMap(groupValue) }.map { bucket in
            let members = bucket.hosts.compactMap { byID[$0] }
            let title = bucket.value.map { grouping == .subnet ? $0 : "\(groupNoun) \($0)" } ?? "No \(groupNoun.lowercased())"
            return (HostGroupHeader(value: bucket.value, title: title, hostIDs: bucket.hosts,
                                    connected: members.filter(\.connected).count), members)
        }
    }

    /// The table's rows: hosts, or each group's header followed by its hosts unless it is closed.
    private var tableRows: [HostRow] {
        guard grouping != .none else { return displayedRows }
        return groups.flatMap { group -> [HostRow] in
            let sum = { (key: KeyPath<HostRow, Int?>) -> Int? in
                let known = group.rows.compactMap { $0[keyPath: key] }
                return known.isEmpty ? nil : known.reduce(0, +)
            }
            let header = HostRow.header(group.header, running: sum(\.containersRunning),
                                        total: sum(\.containersTotal), machines: sum(\.machines))
            return [header] + (ui.collapsedIDs.contains(header.id) ? [] : group.rows)
        }
    }

    /// The disclosure caret on a group's header.
    private func caret(_ row: HostRow) -> some View {
        let open = !ui.collapsedIDs.contains(row.id)
        return Button {
            if open { ui.collapsedIDs.insert(row.id) } else { ui.collapsedIDs.remove(row.id) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Hide the hosts in \(row.name)" : "Show the hosts in \(row.name)")
        .help(open ? "Hide hosts" : "Show \(row.header?.hostIDs.count ?? 0) hosts")
    }

    /// A header's checkbox selects or clears every host in its group.
    private func groupToggle(_ header: HostGroupHeader, name: String) -> some View {
        let ids = Set(header.hostIDs)
        return Toggle("", isOn: Binding(get: { !ids.isEmpty && ids.isSubset(of: selection) },
                                        set: { on in if on { selection.formUnion(ids) } else { selection.subtract(ids) } }))
            .labelsHidden()
            .accessibilityLabel("Select the hosts in \(name)")
            .help("Select the \(ids.count) hosts in \(name)")
    }

    private func builtIns(_ row: HostRow) -> [BuiltInHostTag] {
        BuiltInHostTag.tags(isThisMac: row.isThisMac,
                            role: row.isThisMac ? hostMode.mode.rawValue
                                                : row.peer.flatMap { hostMode.facts[$0.fingerprint]?.role })
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
            let pending = selectedRows.compactMap(\.peer).filter { $0.status == .pending }
            HStack(spacing: 12) {
                Text("\(selectedRows.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !pending.isEmpty {
                    Button("Approve \(pending.count)") { pending.forEach { hostMode.approve($0.fingerprint) } }
                        .controlSize(.small)
                }
                HostCategoryMenu(store: model.hostCategories, hosts: selectedRows.map(\.id),
                                 newValue: { valueTarget = ValueTarget(category: $0, hosts: selectedRows.map(\.id)) },
                                 editCategories: { showingCategories = true })
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Group the \(selectedRows.count) selected hosts")
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// The runtime's starts and stops, and hosts paired, approved and removed.
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

    /// The right-hand half of the table, split out because `TableColumnBuilder` takes ten columns
    /// and the Flotilla column made eleven — the same remedy as `ContainersView.trailingColumns`.
    @TableColumnBuilder<HostRow, KeyPathComparator<HostRow>>
    private var trailingColumns: some TableColumnContent<HostRow, KeyPathComparator<HostRow>> {
            TableColumn("macOS", value: \.macOSSortKey) { row in
                if row.header == nil {
                    Text(row.macOS ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 76)
            .customizationID("macos")

            TableColumn("container", value: \.containerSortKey) { row in
                if row.header == nil { containerCell(row) }
            }
            .width(min: 64, ideal: 100)
            .customizationID("container")

            // Shown since Phase C, so a host still on an older Flotilla is visible before it
            // matters. A different build is worth a mark; the wire version, which actually decides
            // whether the two can talk, is checked when they connect.
            TableColumn("Flotilla", value: \.appSortKey) { row in
                if row.header == nil { flotillaCell(row) }
            }
            .width(min: 100, ideal: 200)
            .customizationID("flotilla")

            TableColumn("Model", value: \.modelSortKey) { row in
                if row.header == nil {
                    Text(row.modelIdentifier ?? "—").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 70, ideal: 84)
            .customizationID("model")

            TableColumn("Actions") { row in
                if row.header == nil { rowActions(for: row) }
            }
            .width(min: 78, ideal: 88)
    }

    private var table: some View {
        SwiftUI.Table(tableRows,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            // Column one carries the selection checkbox and the status dot together, as in
            // Containers: the dot's colour says how the Mac is, its tooltip says it in full, and the
            // host's page carries it as a line (the owner, 9 October).
            TableColumn(Text("").accessibilityLabel("Selection and status"), value: \.statusSortKey) { row in
                HStack(spacing: 6) {
                    if let header = row.header {
                        groupToggle(header, name: row.name)
                        HostGroupDot(header: header)
                    } else {
                        selectionToggle(for: row)
                        HostStatusDot(model: model, row: row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 52, ideal: 56, max: 64)

            TableColumn("Name", value: \.nameSortKey) { row in
                HStack(spacing: 6) {
                    if let header = row.header {
                        caret(row)
                        Text(row.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Text("\(header.hostIDs.count)").font(.caption).foregroundStyle(.secondary)
                            .help("\(header.hostIDs.count) host\(header.hostIDs.count == 1 ? "" : "s"), \(header.connected) connected")
                    } else {
                        if grouping != .none { Color.clear.frame(width: 16, height: 16) }
                        Button { open(row) } label: { Text(row.name).lineLimit(1).truncationMode(.middle) }
                            .buttonStyle(.link)
                            .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                            .help("Open \(row.name)")
                    }
                }
            }
            .width(min: 130, ideal: 170)

            TableColumn("Tags") { row in
                if row.header == nil {
                    TagPillRow(tags: model.tags.tags(on: .host, row.id), compact: true, builtIns: builtIns(row))
                }
            }
            .width(min: 90, ideal: 170)
            .customizationID("tags")

            TableColumn("Containers", value: \.containersSortKey) { row in
                Text(row.containersText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 116)
            .customizationID("containers")

            TableColumn("Machines", value: \.machinesSortKey) { row in
                Text(row.machinesText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 76)
            .customizationID("machines")

            trailingColumns
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: HostRow.ID.self) { ids in
            if let row = model.hostRows.first(where: { ids.contains($0.id) }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            if id.hasPrefix("group:") {
                if ui.collapsedIDs.contains(id) { ui.collapsedIDs.remove(id) } else { ui.collapsedIDs.insert(id) }
                return
            }
            guard let row = model.hostRows.first(where: { $0.id == id }) else { return }
            open(row)
        }
    }

    /// A host's Flotilla: its version, and where it stands against This Mac's (DECISIONS Q38) — an
    /// Update button when it is behind and can be updated from here.
    @ViewBuilder
    private func flotillaCell(_ row: HostRow) -> some View {
        if let peer = row.peer, peer.isTrusted {
            HStack(spacing: 6) {
                Text(row.appVersion ?? "—").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                switch model.updateState(peer.fingerprint) {
                case .available:
                    Button("Update") { Task { await model.updateHost(peer.fingerprint) } }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(hostMode.rollingOut)
                        .help("Update \(row.name) to This Mac’s Flotilla, build \(model.ownBuild.map(String.init) ?? "?"). "
                              + "Running containers are not touched.")
                case .updating:
                    ProgressView().controlSize(.mini)
                        .help("Updating — \(row.name) relaunches Flotilla when it is idle; containers keep running.")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Theme.warning)
                        .help("The last update failed: \(message)")
                        .accessibilityLabel("The last update failed: \(message)")
                case .manualOnly:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Theme.warning)
                        .help("\(row.name)’s Flotilla is too old to be updated from here — update it by hand once.")
                        .accessibilityLabel("Too old to update from here")
                case .current, .ahead, .unknown:
                    EmptyView()
                }
            }
        } else {
            versionCell(row.appVersion, skew: row.appSkew, warnAt: .build, what: "Flotilla", host: row.name)
        }
    }

    /// A host's `container`: its version, and Install or Upgrade when it is missing or behind the
    /// version this Flotilla expects (Q39). This Mac's row keeps the plain version and skew mark.
    @ViewBuilder
    private func containerCell(_ row: HostRow) -> some View {
        if let peer = row.peer, peer.isTrusted {
            HStack(spacing: 6) {
                Text(row.containerVersion ?? "—").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                switch model.hostRuntimeState(peer.fingerprint) {
                case .behind, .missing:
                    Button(model.hostRuntimeState(peer.fingerprint) == .missing ? "Install" : "Upgrade") { pendingRuntime = row }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Set up container \(ContainerRuntime.expectedVersion) on \(row.name) — the version this Flotilla expects.")
                case .working:
                    ProgressView().controlSize(.mini).help("Setting up container on \(row.name)…")
                case .tooOldToAsk:
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Theme.warning)
                        .help("\(row.name) needs container \(ContainerRuntime.expectedVersion); update its Flotilla first.")
                        .accessibilityLabel("Needs container \(ContainerRuntime.expectedVersion); update its Flotilla first")
                case .current, .newer, .unknown:
                    EmptyView()
                }
            }
        } else {
            versionCell(row.containerVersion, skew: row.containerSkew, warnAt: .minor, what: "container", host: row.name)
        }
    }

    private var runtimeQuestion: String {
        guard let row = pendingRuntime else { return "" }
        return row.containerVersion == nil
            ? "Install container \(ContainerRuntime.expectedVersion) on \(row.name)?"
            : "Upgrade container on \(row.name) to \(ContainerRuntime.expectedVersion)?"
    }

    private func runtimeButton(_ row: HostRow) -> String {
        row.containerVersion == nil ? "Install" : ((row.containersRunning ?? 0) > 0 ? "Stop Containers and Upgrade" : "Upgrade")
    }

    private func runtimeMessage(_ row: HostRow) -> String {
        var text = "\(row.name) downloads Apple's container installer, and its Flotilla Helper installs it after checking it is Apple's. "
        if row.containerVersion != nil {
            let running = row.containersRunning ?? 0
            text += running > 0
                ? "container restarts there, which stops the \(running) running container\(running == 1 ? "" : "s"); start them again afterwards. "
                : "container restarts there; nothing is running. "
        }
        return text + "Then the recommended kernel, if it has none."
    }

    /// Updates for the fleet (Q38): update every host now, one at a time, or let This Mac do it by
    /// itself whenever it is newer.
    private var updatesMenu: some View {
        let waiting = model.hostsWithUpdates.count
        return ToolbarIconMenu(systemImage: waiting > 0 ? "arrow.down.circle.fill" : "arrow.down.circle",
                               label: waiting > 0 ? "\(waiting) host\(waiting == 1 ? "" : "s") can be updated" : "Host updates") {
            if hostMode.rollingOut || !hostMode.updating.isEmpty {
                Text("Updating \(hostMode.updating.count == 1 ? "a host" : "hosts")… one at a time")
                Divider()
            }
            Button(waiting == 0 ? "Every Host Is Up to Date" : "Update \(waiting) Host\(waiting == 1 ? "" : "s") Now") {
                Task { await model.rollOutUpdates(automatic: false) }
            }
            .disabled(waiting == 0 || hostMode.rollingOut)
            Divider()
            Toggle("Update Hosts Automatically", isOn: Binding(
                get: { model.autoUpdateHosts },
                set: { on in
                    try? model.settingsStore.set(on, for: SettingsKeys.autoUpdateHosts)
                    if on { Task { await model.rollOutUpdates() } }
                }))
        }
    }

    /// A version, with a mark when it is behind or ahead of This Mac's by `warnAt` or more.
    @ViewBuilder
    private func versionCell(_ version: String?, skew: VersionSkew?, warnAt: VersionSkew.Level,
                             what: String, host: String) -> some View {
        HStack(spacing: 4) {
            Text(version ?? "—").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            if let skew, skew.level >= warnAt {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .help("\(host)’s \(what) is \(skew.otherIsOlder ? "older" : "newer") than This Mac’s"
                          + (what == "container"
                             ? " — Flotilla checks commands against This Mac’s, so it may refuse an option allowed here."
                             : " — update Flotilla on both Macs to the same build."))
                    .accessibilityLabel("\(what) version differs from This Mac’s")
            }
        }
    }

    /// Cards, under a heading per group when Hosts is grouped.
    private var cards: some View {
        ResourceCardGrid {
            if grouping == .none {
                ForEach(displayedRows) { card($0) }
            } else {
                ForEach(groups, id: \.header) { group in
                    SwiftUI.Section {
                        ForEach(group.rows) { card($0) }
                    } header: {
                        HStack(spacing: 6) {
                            HostGroupDot(header: group.header)
                            Text(group.header.title).font(.headline)
                            Text("\(group.rows.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func card(_ row: HostRow) -> some View {
        ResourceCard(
            title: row.name,
            badge: row.isThisMac ? "this Mac" : (row.isPending ? "waiting" : nil),
            fields: [("Status", row.status),
                     ("Containers", row.containersText),
                     ("Machines", row.machinesText),
                     ("macOS", row.macOS),
                     ("container", row.containerVersion),
                     ("Flotilla", row.appVersion)],
            tags: model.tags.tags(on: .host, row.id),
            onOpen: { open(row) }
        ) {
            rowActions(for: row)
        }
        .contextMenu { menu(for: row) }
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
                             disabled: row.isThisMac, destructive: true) {
                pendingForget = row
            }
            Spacer(minLength: 0)
        }
    }

    /// This Mac's runtime items match the sidebar band's menu word for word; a host's items are its
    /// trust — approve, turn away, remove access.
    @ViewBuilder
    private func menu(for row: HostRow) -> some View {
        if let imported = row.imported {
            Button("Pair\u{2026}") { pairing = imported }
                .disabled(!hostMode.isAdmin)
        } else {
            Button("Open") { open(row) }
        }
        Divider()
        if row.imported != nil {
            // Nothing to manage until it is paired: no trust, no runtime.
            EmptyView()
        } else if let peer = row.peer {
            Button("Rename…") {
                newName = peer.nickname ?? ""
                renaming = peer
            }
            Divider()
            switch peer.status {
            case .pending:
                Button("Approve") { hostMode.approve(peer.fingerprint) }
                Button("Turn Away") { hostMode.reject(peer.fingerprint) }
            case .approved:
                switch model.updateState(peer.fingerprint) {
                case .available, .failed:
                    Button("Update Flotilla") { Task { await model.updateHost(peer.fingerprint) } }
                        .disabled(hostMode.rollingOut)
                    Divider()
                default:
                    EmptyView()
                }
                // macOS's own ways in, straight from the table (the owner, 9 October): no need to open
                // the host first. The same helper as its page's buttons.
                ForEach(HostConnect.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { HostConnect.open(kind, model, peer.fingerprint) }
                        .disabled(HostConnect.address(model, peer.fingerprint) == nil)
                }
                Divider()
                Button("Remove Access") { hostMode.revoke(peer.fingerprint) }
            case .rejected, .revoked:
                Button("Approve") { hostMode.approve(peer.fingerprint) }
            }
        } else {
            let enablement = RuntimeStatus.enablement(model.preflight)
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
        }
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .host, id: row.id)) {
            tagSheet = TagSheetTarget(kind: .host, id: row.id)
        }
        HostCategoryMenu(store: model.hostCategories, hosts: [row.id],
                         newValue: { valueTarget = ValueTarget(category: $0, hosts: [row.id]) },
                         editCategories: { showingCategories = true })
        Divider()
        CopyMenu([("Name", row.name),
                  ("macOS version", row.macOS),
                  ("container version", row.containerVersion),
                  ("Flotilla version", row.appVersion),
                  ("Model", row.modelIdentifier),
                  ("Serial number", row.peer?.details.serialNumber),
                  ("Fingerprint", row.peer?.fingerprint.hex ?? row.imported?.fingerprint.hex),
                  ("Address block", row.peer?.isTrusted == true || row.isThisMac
                      ? model.addressBlock(for: row.isThisMac ? .local : .peer(row.peer!.fingerprint))?.description
                      : nil)])
        Divider()
        Button("Remove…", role: .destructive) { pendingForget = row }
            .disabled(row.isThisMac)
            .help(row.isThisMac ? Self.removeHelp : "")
    }

    /// A paired host or This Mac opens its page; an imported one goes straight to pairing, which
    /// is the only thing there is to do with it.
    private func open(_ row: HostRow) {
        if let imported = row.imported { pairing = imported } else { openHost = row.id }
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

/// A host's status: This Mac's runtime, or a host's place in the book.
struct HostStatusDot: View {
    let model: AppModel
    let row: HostRow

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 8, height: 8)
            } else {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
        .frame(width: 10, height: 10)
        .contentShape(Rectangle())
        .help(row.isThisMac ? (RuntimeStatus.describe(model.preflight).detail.map { "\(row.status) — \($0)" } ?? row.status)
                            : row.status)
        .accessibilityLabel(row.status)
    }

    /// Starting this Mac's runtime, or updating Flotilla on a host: work under way, not a state.
    private var busy: Bool {
        if row.isThisMac { return model.startingRuntime }
        guard let peer = row.peer else { return false }
        return model.hostMode.updating.contains(peer.fingerprint) && model.hostMode.live[peer.fingerprint]?.state != .connected
    }

    /// Green connected, amber waiting on someone, red not answering, grey not known yet.
    private var tint: Color {
        if row.isThisMac { return RuntimeStatus.describe(model.preflight).tint }
        if let peer = row.peer, peer.isTrusted, let live = model.hostMode.live[peer.fingerprint] {
            switch live.state {
            case .connected: return Theme.online
            case .checking: return .secondary
            case .failed: return model.hostMissingContainer(peer.fingerprint) ? Theme.warning : Theme.danger
            }
        }
        switch row.peer?.status {
        case .approved: return Theme.online
        case .pending: return Theme.warning
        default: return .secondary
        }
    }
}

/// A paired or waiting host's page, until Phase C brings its containers here: what it said about
/// itself, how it was trusted, and the actions on that trust.
struct PeerDetailView: View {
    let peer: Peer
    let model: AppModel
    let close: () -> Void

    var body: some View {
        Form {
            SwiftUI.Section("This host") {
                LabeledContent("Status", value: HostRow.statusText(peer.status))
                LabeledContent("Computer name", value: peer.details.computerName)
                if let model = peer.details.model { LabeledContent("Model", value: model) }
                if let serial = peer.details.serialNumber { LabeledContent("Serial number", value: serial) }
                if let macOS = peer.details.macOSVersion { LabeledContent("macOS", value: macOS) }
                LabeledContent("Fingerprint") {
                    Text(HostModePane.shortFingerprint(peer.fingerprint))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                if peer.isTrusted, let block = model.addressBlock(for: .peer(peer.fingerprint)) {
                    // Pushed networks take their subnets from here (PLAN.md Phase D; Q35).
                    LabeledContent("Address block") {
                        Text(block.description).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                LabeledContent("Joined by", value: peer.method == .enrolmentKey ? "Fleet enrolment key" : "Pairing code")
                LabeledContent("Asked", value: peer.requestedAt.formatted(date: .abbreviated, time: .shortened))
                if let decided = peer.decidedAt {
                    LabeledContent("Decided", value: decided.formatted(date: .abbreviated, time: .shortened))
                }
            }
            SwiftUI.Section {
                HStack {
                    Spacer()
                    switch peer.status {
                    case .pending:
                        Button("Turn Away") { model.hostMode.reject(peer.fingerprint) }
                        Button("Approve") { model.hostMode.approve(peer.fingerprint) }
                            .buttonStyle(.borderedProminent)
                    case .approved:
                        Button("Remove Access") { model.hostMode.revoke(peer.fingerprint) }
                    case .rejected, .revoked:
                        Button("Approve") { model.hostMode.approve(peer.fingerprint) }
                    }
                }
            } footer: {
                if peer.status == .pending {
                    Text("Approve only a Mac you recognise — check the serial number against your inventory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
