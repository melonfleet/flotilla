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
    let ui: ResourceUIState<K8sNode>

    @State private var selection = Set<K8sNode.ID>()
    @State private var showingCreate = false
    @State private var pendingDelete: K8sNode?
    /// The cluster whose kubeconfig was just written, so the result is actionable rather than a
    /// toast that disappears.
    @State private var wroteConfigFor: KubeconfigResult?
    @State private var loadImageTarget: K8sNode?

    static let columnSpecs: [(id: String, title: String)] = [
        ("role", "Role"), ("cpus", "CPUs"), ("memory", "Memory"),
        ("address", "Address"), ("ports", "Ports"),
    ]

    var body: some View {
        Group {
            if showingCreate {
                NewClusterView(model: model) { showingCreate = false }
            } else {
                VStack(spacing: 0) {
                    experimentalBand
                    toolbar
                    Divider()
                    content
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  // Nothing to open: a cluster's detail is kubectl's, not this
                                  // app's, so a feed row here is a record and not a link.
                                  open: { _ in },
                                  canOpen: { _ in false })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshClusters() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(item: $loadImageTarget) { cluster in
            LoadImageSheet(model: model, cluster: cluster) { loadImageTarget = nil }
        }
        .sheet(item: $wroteConfigFor) { result in
            KubeconfigSheet(result: result) { wroteConfigFor = nil }
        }
        .confirmationDialog(
            "Delete the cluster “\(pendingDelete?.node ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Cluster", role: .destructive) {
                if let cluster = pendingDelete { Task { await model.deleteCluster(cluster) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Everything running in it goes with it. This cannot be undone.")
        }
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

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search clusters…",
                       updated: model.clustersLastRefresh,
                       leading: {
            ResourceListControls<K8sNode>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: [])
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "Create a cluster…") {
                showingCreate = true
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh clusters") {
                Task { await model.refreshClusters() }
            }
        })
    }

    private var isFiltered: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var displayedClusters: [K8sNode] {
        var clusters = model.clusters
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            clusters = clusters.filter {
                $0.node.lowercased().contains(query) || $0.address.lowercased().contains(query)
            }
        }
        return clusters.sorted(using: ui.sortOrder)
    }

    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .cluster).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
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
                Label(isFiltered ? "No matches" : "No clusters",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "circle.hexagongrid")
            } description: {
                Text(isFiltered
                     ? "No cluster matches the current search."
                     : "A cluster is a single-node Kubernetes running in its own VM. You reach it with kubectl; Flotilla creates it, starts it and loads images into it.")
            } actions: {
                if isFiltered {
                    Button("Clear Search") { ui.search = "" }
                } else {
                    Button("Create Cluster") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            switch ui.presentation {
            case .list: table
            case .cards: cards
            }
        }
    }

    private var table: some View {
        SwiftUI.Table(displayedClusters,
              selection: $selection,
              sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
              columnCustomization: Binding(get: { ui.columnCustomization },
                                           set: { ui.columnCustomization = $0 })) {
            TableColumn("", value: \.stateSortKey) { cluster in
                Circle()
                    .fill(cluster.isRunning ? Theme.online : Color.secondary)
                    .frame(width: 8, height: 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(cluster.state.capitalized)
                    .accessibilityLabel(cluster.state.capitalized)
            }
            .width(min: 26, ideal: 28, max: 34)
            .customizationID("state")

            TableColumn("Name", value: \.node) { cluster in
                Text(cluster.node)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help("kubectl --context \(cluster.node)")
            }
            .width(min: 120, ideal: 170)

            TableColumn("Role", value: \.roleSortKey) { cluster in
                Text(cluster.roles.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)
            .customizationID("role")

            TableColumn("CPUs", value: \.cpuSortKey) { cluster in
                Text(cluster.cpus.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            .customizationID("cpus")

            // Printed as the CLI prints it, `16384 MB`. Not reformatted: the unit is its choice,
            // and a number without one would lose what it meant.
            TableColumn("Memory", value: \.memory) { cluster in
                Text(cluster.memory.isEmpty ? "—" : cluster.memory)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID("memory")

            TableColumn("Address", value: \.address) { cluster in
                Text(cluster.address.isEmpty ? "—" : cluster.address)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            .customizationID("address")

            TableColumn("Ports", value: \.portSortKey) { cluster in
                Text(cluster.ports.isEmpty ? "—" : cluster.ports.joined(separator: ", "))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("The API server, reachable on this Mac at that host port")
            }
            .width(min: 90, ideal: 120)
            .customizationID("ports")

            TableColumn("Actions") { cluster in
                rowActions(for: cluster)
            }
            .width(min: 120, ideal: 140)
        }
        .tableStyle(.inset)
        // Load-bearing, and its absence renders the whole section at a negative Y. A `Table` in
        // a `VStack` inside an unbounded parent asks for as much height as it likes, so the
        // column of band + toolbar + table grew past the window and pushed everything above the
        // top edge — a blank screen with the content off-screen, which is the same failure
        // `VolumesView.createScreen` records for its `ScrollView`.
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: K8sNode.ID.self) { ids in
            if let cluster = model.clusters.first(where: { ids.contains($0.id) }) {
                menu(for: cluster)
            }
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedClusters) { cluster in
                ResourceCard(
                    title: cluster.node,
                    badge: cluster.isRunning ? "Running" : cluster.state.capitalized,
                    fields: [
                        ("Role", cluster.roles.joined(separator: ", ")),
                        ("CPUs", cluster.cpus.map(String.init)),
                        ("Memory", cluster.memory.isEmpty ? nil : cluster.memory),
                        ("Address", cluster.address.isEmpty ? nil : cluster.address),
                        ("Ports", cluster.ports.isEmpty ? nil : cluster.ports.joined(separator: ", ")),
                    ],
                    onOpen: nil
                ) {
                    rowActions(for: cluster)
                }
                .contextMenu { menu(for: cluster) }
            }
        }
    }

    /// Start, then overflow, then bin — the arrangement every other section uses.
    ///
    /// **No Stop.** `container k8s` has `create`, `start` and `delete` and nothing between: there
    /// is no command that stops a cluster without destroying it, so a Stop button here would have
    /// nothing to call. Delete is the only way down.
    @ViewBuilder
    private func rowActions(for cluster: K8sNode) -> some View {
        let busy = model.isBusy(cluster.node, kind: .cluster)
        HStack(spacing: 2) {
            IconActionButton(systemImage: "play.fill",
                             label: "Start \(cluster.node)",
                             help: cluster.isRunning
                                 ? "\(cluster.node) is already running"
                                 : "Start \(cluster.node)",
                             busy: busy, disabled: cluster.isRunning) {
                Task { await model.startCluster(cluster) }
            }

            Menu {
                menu(for: cluster)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(cluster.node)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(cluster.node)",
                             help: "Delete \(cluster.node)",
                             busy: busy, destructive: true) {
                pendingDelete = cluster
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(for cluster: K8sNode) -> some View {
        Button("Load Image…") { loadImageTarget = cluster }
            .disabled(!cluster.isRunning)
        Button("Write Kubeconfig…") {
            Task {
                if let url = await model.writeKubeconfig(for: cluster) {
                    wroteConfigFor = KubeconfigResult(cluster: cluster.node, url: url)
                }
            }
        }
        Divider()
        CopyMenu([
            ("Name", cluster.node),
            ("Address", cluster.address.isEmpty ? nil : cluster.address),
            ("kubectl context", "kubectl --context \(cluster.node)"),
        ])
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = cluster }
    }
}

/// Where a kubeconfig was written, and for which cluster.
struct KubeconfigResult: Identifiable, Hashable {
    let cluster: String
    let url: URL
    var id: String { url.path }
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
