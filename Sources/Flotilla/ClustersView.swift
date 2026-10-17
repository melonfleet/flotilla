import SwiftUI
import Foundation
import FlotillaCore

/// Local Kubernetes clusters — `container k8s`.
///
/// **A flat list, and that is the CLI's shape rather than a simplification.** `k8s list` prints a
/// CLUSTER column that comes back empty even with two clusters present, and puts the cluster's
/// name under NODE. There is no cluster-to-node hierarchy to draw; each row is a cluster, which
/// on 1.4.1 is also its single `control-plane,worker` node.
///
/// **The band at the top is not decoration.** `container k8s --help` calls the family
/// EXPERIMENTAL and Apple's `docs/kubernetes.md` does not use the word at all. A section built on
/// a command that may change under it should say so where the user is, not only in a commit.
struct ClustersView: View {
    let model: AppModel
    let ui: ResourceUIState<HostedCluster>
    /// Held by `MainWindowView`, like `ui` — see `RowSortState`.
    let sort: RowSortState

    @State private var selection = Set<HostedCluster.ID>()
    @State private var showingCreate = false
    @State private var showingSuggestions = false
    @State private var createPrefill: ClusterSuggestion?
    @State private var pendingDelete: HostedCluster?
    /// A recreate awaiting confirmation. Recreate deletes the cluster and everything in it, so it
    /// always asks, whatever `confirmDestructiveActions` says — the same rule bulk deletes follow.
    @State private var pendingRecreate: HostedCluster?
    /// The cluster being loaded into, or nil for the list. An embedded screen like the create
    /// form, not a dialog — see `LoadImageView`.
    @State private var loadImageTarget: K8sNode?

    /// The old table's sortable columns. Ties break on name.
    static let sortKeys: [(id: String, title: String)] = [
        ("name", "Name"), ("state", "State"), ("host", "Host"), ("role", "Role"),
        ("cpus", "CPUs"), ("memory", "Memory"), ("address", "Address"), ("ports", "Ports"),
    ]

    private var sortOrder: [KeyPathComparator<HostedCluster>] {
        let order = sort.order
        let byName = KeyPathComparator(\HostedCluster.name)
        switch sort.key {
        case "state": return [KeyPathComparator(\HostedCluster.stateSortKey, order: order), byName]
        case "host": return [KeyPathComparator(\HostedCluster.hostName, order: order), byName]
        case "role": return [KeyPathComparator(\HostedCluster.roleSortKey, order: order), byName]
        case "cpus": return [KeyPathComparator(\HostedCluster.cpuSortKey, order: order), byName]
        case "memory": return [KeyPathComparator(\HostedCluster.memory, order: order), byName]
        case "address": return [KeyPathComparator(\HostedCluster.address, order: order), byName]
        case "ports": return [KeyPathComparator(\HostedCluster.portSortKey, order: order), byName]
        default: return [KeyPathComparator(\HostedCluster.name, order: order)]
        }
    }

    var body: some View {
        Group {
            if showingCreate {
                NewClusterView(model: model, dismiss: { showingCreate = false; createPrefill = nil },
                               prefill: createPrefill, initialHost: ui.hostFilter ?? .local)
            } else if showingSuggestions {
                ResourceSuggestionsGallery(
                    intro: "Single-node clusters sized for common work, on Kubernetes 1.35 with "
                        + "the node image pinned. Use one to open New Cluster with it filled in.",
                    items: ClusterSuggestion.catalogue,
                    use: useSuggestion,
                    dismiss: { showingSuggestions = false })
            } else if let target = loadImageTarget {
                LoadImageView(model: model, cluster: target) { loadImageTarget = nil }
            } else {
                VStack(spacing: 0) {
                    experimentalBand
                    toolbar
                    Divider()
                    content
                }
                // Fill the pane, with the toolbar at the top, whatever `content` is. An empty or
                // unreachable section is a `ContentUnavailableView`, which takes only its own
                // height, and the toolbar then rode down to the middle of the window (the
                // owner, on an empty Volumes, 5 October). Machines already did this.
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshClusters() }
        // File ▸ New Cluster… and File ▸ Suggestions ▸ Clusters…. One-shot.
        .onChange(of: model.pendingClusterForm) { _, requested in
            if requested { model.pendingClusterForm = false; showingSuggestions = false; createPrefill = nil; showingCreate = true }
        }
        .onChange(of: model.pendingSuggestions) { _, section in
            if section == .clusters { model.pendingSuggestions = nil; showingCreate = false; showingSuggestions = true }
        }
        .onAppear {
            if model.pendingClusterForm {
                model.pendingClusterForm = false; showingSuggestions = false; createPrefill = nil; showingCreate = true
            }
            if model.pendingSuggestions == .clusters {
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
            "Delete the cluster “\(pendingDelete?.name ?? "")”\(pendingDelete.map(onHost) ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Cluster", role: .destructive) {
                if let row = pendingDelete { Task { await model.deleteCluster(row.cluster, on: row.host) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Everything running in it goes with it. This cannot be undone.")
        }
        .confirmationDialog(
            "Recreate the cluster “\(pendingRecreate?.name ?? "")”\(pendingRecreate.map(onHost) ?? "")?",
            isPresented: Binding(get: { pendingRecreate != nil },
                                 set: { if !$0 { pendingRecreate = nil } }),
            titleVisibility: .visible,
            presenting: pendingRecreate
        ) { row in
            Button("Delete and Recreate", role: .destructive) {
                Task { await model.recreateCluster(row.cluster, on: row.host) }
                pendingRecreate = nil
            }
            Button("Cancel", role: .cancel) { pendingRecreate = nil }
        } message: { row in
            Text(Self.recreateMessage(for: row.cluster))
        }
    }

    /// What a recreate keeps and what it loses, said before anything happens.
    ///
    /// The reason comes first: a user who has only ever pressed Start needs to know why that is
    /// gone, or Recreate reads as Flotilla being heavy-handed rather than `container` 1.5 having
    /// no restart.
    static func recreateMessage(for cluster: K8sNode) -> String {
        var kept = ["the name"]
        if let cpus = cluster.cpus { kept.append("\(cpus) CPU\(cpus == 1 ? "" : "s")") }
        if cluster.memoryFlag != nil { kept.append(cluster.memory) }
        return "container 1.5 can't restart a stopped cluster. Apple's way back is to delete it and "
            + "create it again, which is what this does, keeping \(kept.joined(separator: ", ")).\n\n"
            + "Everything inside the cluster is lost: deployments, pods, loaded images and stored data. "
            + "Its kubectl context is written again. A custom node image or CNI is not kept; the "
            + "defaults are used. Creating can take several minutes. This cannot be undone."
    }

    /// Said once, at the top, in the section's own words.
    ///
    /// **No `fixedSize` on the text, and that is load-bearing.** This app reaches for
    /// `.fixedSize(horizontal: false, vertical: true)` almost everywhere it wraps a sentence,
    /// and it is right almost everywhere — in a `VStack`, where the width is already decided.
    /// Here the text sits in an `HStack` beside an icon, so its width is *negotiated*, and
    /// fixing the vertical axis makes it report the ideal height for a very narrow proposal.
    /// That height propagates: the band alone drove the window's split view from 865pt to
    /// 2005pt, pushing every section's content above the top edge and rendering a blank window.
    /// Bisected by measurement — the band with `fixedSize` gives 2005, without it 865, and the
    /// text still wraps because the greedy frame gives it the room.
    ///
    /// Worse, the grown split view is **saved**. Once it happened, every section came back at
    /// 2182pt on the next launch, which reads as the whole app being broken rather than one
    /// band — and made the first bisect attempt lie, because the corrupted state survived the
    /// change that was meant to clear it. Deleting
    /// `NSSplitView Subview Frames main, SidebarNavigationSplitView` from the preference domain
    /// is the cure if it ever happens again.
    private var experimentalBand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "flask")
                .foregroundStyle(Theme.warning)
            Text("Experimental. `container k8s` describes itself that way, and its output has no machine-readable form — Flotilla reads the printed table, so a change to it will show up here first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.10))
    }

    private func useSuggestion(_ suggestion: ClusterSuggestion) {
        createPrefill = suggestion
        showingSuggestions = false
        showingCreate = true
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search clusters…",
                       matches: displayedClusters.count,
                       updated: model.clustersLastRefresh,
                       leading: {
            ResourceListControls<HostedCluster>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                filters: [],
                hostFilter: Binding(get: { ui.hostFilter }, set: { ui.hostFilter = $0 }),
                hosts: hostChoices)
            RowSortMenu(state: sort, keys: Self.sortKeys)
        }, trailing: {
            ToolbarIconMenu(systemImage: "plus", label: "Create a cluster") {
                Button("New Cluster…") { createPrefill = nil; showingCreate = true }
                Divider()
                Button("Suggestions…") { showingSuggestions = true }
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh clusters") {
                Task { await model.refreshClusters() }
            }
        })
    }

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.hostFilter != nil
    }

    /// This Mac and every paired host, for the filter and New Cluster's picker (Q51).
    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// " on Tahoe" for a host's cluster, nothing for This Mac's.
    private func onHost(_ row: HostedCluster) -> String {
        row.host.isLocal ? "" : " on \(row.hostName)"
    }

    /// This Mac's clusters and each paired host's last answer, through the host filter.
    private var allRows: [HostedCluster] {
        var rows: [HostedCluster] = []
        if ui.hostFilter == nil || ui.hostFilter == .local {
            rows += model.clusters.map { HostedCluster(cluster: $0, host: .local, hostName: model.hostLabel) }
        }
        let now = Date()
        for (peer, snapshot) in model.hostMode.fleetClusters {
            let host = HostRef.peer(peer.fingerprint)
            if let only = ui.hostFilter, only != host { continue }
            let stale = snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil
            rows += snapshot.items.map { HostedCluster(cluster: $0, host: host, hostName: peer.displayName, staleSince: stale) }
        }
        return rows
    }

    private var displayedClusters: [HostedCluster] {
        var rows = allRows
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter {
                $0.name.lowercased().contains(query) || $0.cluster.address.lowercased().contains(query)
                    || $0.hostName.lowercased().contains(query)
            }
        }
        return rows.sorted(using: sortOrder)
    }

    @ViewBuilder
    private var content: some View {
        switch model.clustersState {
        case .idle, .loading:
            ProgressView("Loading clusters…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // A failed load must never render as an empty list — that would look like a Mac with
            // no clusters on it, which is the same mistake the other sections guard against.
            ContentUnavailableView(
                "Can't list Kubernetes clusters",
                systemImage: "exclamationmark.triangle",
                description: Text(reason))

        case .loaded where displayedClusters.isEmpty:
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No Kubernetes clusters",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "circle.hexagongrid")
            } description: {
                Text(isFiltered
                     ? "No cluster matches the current search or host."
                     : "A cluster is a single-node Kubernetes running in its own VM. You reach it with kubectl; Flotilla creates it, loads images into it, and recreates it if it stops.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.hostFilter = nil }
                } else {
                    VStack(spacing: 14) {
                        Button("Create Cluster") { createPrefill = nil; showingCreate = true }
                            .buttonStyle(.borderedProminent)
                        SuggestionQuickPicks(
                            picks: ClusterSuggestion.catalogue.map { suggestion in
                                (suggestion.title, { useSuggestion(suggestion) })
                            },
                            more: { showingSuggestions = true })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            switch ui.presentation {
            case .list: rowsList
            case .cards: cards
            }
        }
    }

    /// The rows, filling the pane — `ResourceRow`'s two lines, the list's own selection. Rows are
    /// as tall as their content; nothing here writes a height down, and the list takes whatever
    /// the pane gives it (the old table needed `maxHeight: .infinity` for the same reason).
    ///
    /// A cluster has no page, so a double-click opens nothing and the name is plain text.
    private var rowsList: some View {
        List(displayedClusters, selection: $selection) { row in
            listRow(row)
                .listRowInsets(EdgeInsets())
                .accessibilityActions { rowAccessibilityActions(row) }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: HostedCluster.ID.self) { ids in
            // There are no bulk actions on clusters, so a right-click on several offers none
            // rather than the first one's menu.
            let picked = displayedClusters.filter { ids.contains($0.id) }
            if picked.count == 1, let row = picked.first { menu(for: row) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ row: HostedCluster) -> some View {
        ResourceRow(
            title: row.name,
            openHelp: "kubectl --context \(row.name)" + (row.host.isLocal ? "" : " — on \(row.hostName)"),
            detail: detailParts(row).joined(separator: " · "),
            detailHelp: "The API server is reachable on this Mac at the host port",
            selected: selection.contains(row.id),
            summary: rowSummary(row),
            reservesMetrics: false,
            dimsPlainTitle: false,
            leading: { stateMark(row.cluster) },
            chips: { rowChips(row) },
            metrics: { EmptyView() },
            actions: { rowActions(for: row) })
    }

    private func stateMark(_ cluster: K8sNode) -> some View {
        Circle()
            .fill(cluster.isRunning ? Theme.online : Color.secondary)
            .frame(width: 8, height: 8)
            .help(cluster.state.capitalized)
    }

    /// The role (`control-plane, worker`) and — only for another Mac's cluster — the host.
    @ViewBuilder
    private func rowChips(_ row: HostedCluster) -> some View {
        HStack(spacing: 4) {
            if !row.cluster.roles.isEmpty {
                ResourceChip(text: row.cluster.roles.joined(separator: ", "))
                    .help("control-plane runs Kubernetes itself")
            }
            if !row.host.isLocal {
                HostCell(name: row.hostName, staleSince: row.staleSince)
                    .chipStyle()
                    .fixedSize()
            }
        }
    }

    /// State · CPUs · memory · address · API port, each only when there is one. `k8s list` prints
    /// no Kubernetes version and no node count (a cluster is its one node on 1.5), so those are not
    /// here; the memory stays as the CLI prints it.
    private func detailParts(_ row: HostedCluster) -> [String] {
        let cluster = row.cluster
        var parts = [cluster.state.capitalized]
        if let cpus = cluster.cpus { parts.append("\(cpus) CPU\(cpus == 1 ? "" : "s")") }
        if !cluster.memory.isEmpty { parts.append(cluster.memory) }
        if !cluster.address.isEmpty { parts.append(cluster.address) }
        if !cluster.ports.isEmpty { parts.append("API " + cluster.ports.joined(separator: ", ")) }
        return parts
    }

    private func rowSummary(_ row: HostedCluster) -> String {
        var parts = ["Cluster " + row.name] + detailParts(row).map { $0.replacingOccurrences(of: "->", with: " to ") }
        if !row.cluster.roles.isEmpty { parts.append(row.cluster.roles.joined(separator: ", ")) }
        if !row.host.isLocal {
            parts.append("on " + row.hostName)
            if row.staleSince != nil { parts.append("not answering") }
        }
        return parts.joined(separator: ", ")
    }

    /// The row's buttons as VoiceOver actions: the row is one element, so the buttons inside it
    /// are not reachable any other way. An action the button would refuse is not offered.
    @ViewBuilder
    private func rowAccessibilityActions(_ row: HostedCluster) -> some View {
        let cluster = row.cluster
        if !model.isBusy(row.host.rowID(cluster.node), kind: .cluster) {
            if !cluster.isRunning {
                Button("Recreate \(cluster.node)") { pendingRecreate = row }
            }
            if cluster.isRunning, row.host.isLocal {
                Button("Load an image into \(cluster.node)") { loadImageTarget = cluster }
            }
            if row.host.isLocal {
                Button("Write kubeconfig for \(cluster.node)") { Task { await model.writeKubeconfig(for: cluster) } }
            }
            Button("Delete \(cluster.node)") { pendingDelete = row }
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedClusters) { row in
                let cluster = row.cluster
                ResourceCard(
                    title: row.name,
                    badge: cluster.isRunning ? "Running" : cluster.state.capitalized,
                    fields: [
                        ("Role", cluster.roles.joined(separator: ", ")),
                        ("CPUs", cluster.cpus.map(String.init)),
                        ("Memory", cluster.memory.isEmpty ? nil : cluster.memory),
                        ("Address", cluster.address.isEmpty ? nil : cluster.address),
                        ("Ports", cluster.ports.isEmpty ? nil : cluster.ports.joined(separator: ", ")),
                    ] + (hostChoices.count > 1 ? [("Host", row.hostName)] : []),
                    // Clusters are not tagged, so no empty pill row.
                    showsTags: false,
                    onOpen: nil
                ) {
                    rowActions(for: row)
                }
                .contextMenu { menu(for: row) }
            }
        }
    }

    /// Recreate, then overflow, then bin — the arrangement every other section uses.
    ///
    /// **No Start, and no Stop.** `container` 1.5.0 removed `k8s start` (apple/container#2290), and
    /// there was never a command that stops a cluster without destroying it. So the first button
    /// is Recreate, offered for a cluster that is not running: delete and create again, which is
    /// Apple's documented recovery. It asks first, because it destroys what is inside.
    @ViewBuilder
    private func rowActions(for row: HostedCluster) -> some View {
        let cluster = row.cluster
        let busy = model.isBusy(row.host.rowID(cluster.node), kind: .cluster)
        HStack(spacing: 2) {
            IconActionButton(systemImage: "arrow.triangle.2.circlepath",
                             label: "Recreate \(cluster.node)",
                             help: cluster.isRunning
                                 ? "\(cluster.node) is running. Recreate is for a stopped cluster."
                                 : "Delete \(cluster.node) and create it again — container 1.5 cannot restart it",
                             busy: busy, disabled: cluster.isRunning) {
                pendingRecreate = row
            }

            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(cluster.node)")
            .accessibilityLabel("More actions for \(cluster.node)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(cluster.node)",
                             help: "Delete \(cluster.node)" + onHost(row),
                             busy: busy, destructive: true) {
                pendingDelete = row
            }
            Spacer(minLength: 0)
        }
    }

    /// Load Image and Write Kubeconfig are This Mac's own (Q51): one reads its image store, the
    /// other writes a file its kubectl reads.
    @ViewBuilder
    private func menu(for row: HostedCluster) -> some View {
        let cluster = row.cluster
        Button("Load Image…") { loadImageTarget = cluster }
            .disabled(!cluster.isRunning || !row.host.isLocal)
            .help(row.host.isLocal ? "" : "Images are loaded into a cluster on its own Mac")
        Button("Recreate…") { pendingRecreate = row }
            .disabled(cluster.isRunning)
        // No result dialog. What it wrote and how to use it are reported in the progress panel
        // that already appears — one surface for the operation instead of a panel that closes
        // and a second card that opens saying the same thing.
        Button("Write Kubeconfig…") {
            Task { await model.writeKubeconfig(for: cluster) }
        }
        .disabled(!row.host.isLocal)
        Divider()
        CopyMenu([
            ("Name", cluster.node),
            ("Address", cluster.address.isEmpty ? nil : cluster.address),
            ("kubectl context", "kubectl --context \(cluster.node)"),
        ])
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = row }
    }
}

/// A cluster and the Mac it runs on (Q51). Two Macs' `dev` clusters are two rows.
struct HostedCluster: Identifiable {
    let cluster: K8sNode
    let host: HostRef
    let hostName: String
    /// A host's row older than a fresh answer: shown, with its age.
    var staleSince: Date? = nil

    var id: String { host.rowID(cluster.node) }
    var name: String { cluster.node }
    var stateSortKey: String { cluster.stateSortKey }
    var roleSortKey: String { cluster.roleSortKey }
    var cpuSortKey: Int { cluster.cpuSortKey }
    var memory: String { cluster.memory }
    var address: String { cluster.address }
    var portSortKey: String { cluster.portSortKey }
}

extension K8sNode {
    /// Sort keys. `Table` needs a `Comparable` key path on the row, and several of these columns
    /// hold arrays or optionals that have no natural one.
    var stateSortKey: String { state }
    var roleSortKey: String { roles.joined(separator: ",") }
    /// Absent sorts last rather than as zero — a cluster with no reported CPU count is not a
    /// cluster with none.
    var cpuSortKey: Int { cpus ?? Int.max }
    var portSortKey: String { ports.joined(separator: ",") }
}
