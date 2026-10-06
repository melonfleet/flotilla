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
    @State private var showingSuggestions = false
    @State private var createPrefill: ClusterSuggestion?
    @State private var pendingDelete: K8sNode?
    /// A recreate awaiting confirmation. Recreate deletes the cluster and everything in it, so it
    /// always asks, whatever `confirmDestructiveActions` says — the same rule bulk deletes follow.
    @State private var pendingRecreate: K8sNode?
    /// The cluster being loaded into, or nil for the list. An embedded screen like the create
    /// form, not a dialog — see `LoadImageView`.
    @State private var loadImageTarget: K8sNode?

    static let columnSpecs: [(id: String, title: String)] = [
        ("role", "Role"), ("cpus", "CPUs"), ("memory", "Memory"),
        ("address", "Address"), ("ports", "Ports"),
    ]

    var body: some View {
        Group {
            if showingCreate {
                NewClusterView(model: model, dismiss: { showingCreate = false; createPrefill = nil },
                               prefill: createPrefill)
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
                // height, and the strip below then rode up under it, halfway up the window (the
                // owner, on an empty Volumes, 5 October). Machines already did this.
                .frame(maxHeight: .infinity, alignment: .top)
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
        .confirmationDialog(
            "Recreate the cluster “\(pendingRecreate?.node ?? "")”?",
            isPresented: Binding(get: { pendingRecreate != nil },
                                 set: { if !$0 { pendingRecreate = nil } }),
            titleVisibility: .visible,
            presenting: pendingRecreate
        ) { cluster in
            Button("Delete and Recreate", role: .destructive) {
                Task { await model.recreateCluster(cluster) }
                pendingRecreate = nil
            }
            Button("Cancel", role: .cancel) { pendingRecreate = nil }
        } message: { cluster in
            Text(Self.recreateMessage(for: cluster))
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
                     : "A cluster is a single-node Kubernetes running in its own VM. You reach it with kubectl; Flotilla creates it, loads images into it, and recreates it if it stops.")
            } actions: {
                if isFiltered {
                    Button("Clear Search") { ui.search = "" }
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
                    // Clusters are not tagged, so no empty pill row.
                    showsTags: false,
                    onOpen: nil
                ) {
                    rowActions(for: cluster)
                }
                .contextMenu { menu(for: cluster) }
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
    private func rowActions(for cluster: K8sNode) -> some View {
        let busy = model.isBusy(cluster.node, kind: .cluster)
        HStack(spacing: 2) {
            IconActionButton(systemImage: "arrow.triangle.2.circlepath",
                             label: "Recreate \(cluster.node)",
                             help: cluster.isRunning
                                 ? "\(cluster.node) is running. Recreate is for a stopped cluster."
                                 : "Delete \(cluster.node) and create it again — container 1.5 cannot restart it",
                             busy: busy, disabled: cluster.isRunning) {
                pendingRecreate = cluster
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
        Button("Recreate…") { pendingRecreate = cluster }
            .disabled(cluster.isRunning)
        // No result dialog. What it wrote and how to use it are reported in the progress panel
        // that already appears — one surface for the operation instead of a panel that closes
        // and a second card that opens saying the same thing.
        Button("Write Kubeconfig…") {
            Task { await model.writeKubeconfig(for: cluster) }
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
