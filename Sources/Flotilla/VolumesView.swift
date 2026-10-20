import SwiftUI
import Foundation
import FlotillaCore

/// The volumes section: list, create, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct VolumesView: View {
    let model: AppModel
    /// Owned by `MainWindowView` — see `ResourceUIState`. Search, sort and filter have to
    /// outlive a trip to another section.
    let ui: ResourceUIState<HostedVolume>

    @State private var selection = Set<HostedVolume.ID>()
    @State private var showingCreate = false
    /// A menu's request for one volume's page on a particular tab. Private per section, as it is
    /// in Containers and Machines — the tab type differs. Each request is new (`nonce`), so asking
    /// for a tab again after leaving it still lands on it.
    private struct DetailTarget: Hashable {
        let id: HostedVolume.ID
        var tab: VolumeDetailTab?
        let nonce = UUID()
    }
    @State private var request: DetailTarget?

    /// The rows the page beside the list is showing: `selection`, once the form guard has let it
    /// through (Q58). The page looks the volume up each render, so it is never stale data.
    @State private var shown = Set<HostedVolume.ID>()
    @State private var pendingDelete: HostedVolume?
    /// This Mac's volume being pushed to hosts (PLAN.md Phase D).
    @State private var pushing: ContainerVolume?
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. A `TagSheetTarget` rather than a
    /// bare `TagSubject` — see that type for why a subject is not `Identifiable`.
    ///
    /// Presented from the view, never from inside the menu: a `.sheet` attached within a `Menu`
    /// never appears, because the menu is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?
    private func consumeDetailRequest() {
        guard let subject = model.pendingDetailSubject, model.pendingDetailKind == .volume else { return }
        showingCreate = false
        pushing = nil
        if let row = everyRow.first(where: { $0.detailKey == subject }) { open(row.id) }
        model.clearPendingDetail()
    }

    var body: some View {
        Group {
            if let volume = pushing {
                PushDefinitionView(model: model, subject: .volume(volume)) { pushing = nil }
            } else if showingCreate {
                NewVolumeView(model: model, dismiss: { showingCreate = false }, initialHost: ui.hostFilter ?? .local)
            } else {
                // Q58: the list, and the selected volume's page beside it.
                SplitPanes(list: "volumes", pane: ui.pane, showing: shownRow?.id) {
                    VStack(spacing: 0) {
                        toolbar
                        bulkActionBar
                        Divider()
                        content
                    }
                    // Fill the pane, with the toolbar at the top, whatever `content` is. An empty or
                    // unreachable section is a `ContentUnavailableView`, which takes only its own
                    // height, and the toolbar then rode down to the middle of the window (the
                    // owner, on an empty Volumes, 5 October). Machines already did this.
                    .frame(maxHeight: .infinity, alignment: .top)
                } detail: {
                    page
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshVolumes() }
        // `actionable` already stops a hidden row from being acted on; this stops one from being
        // counted. Filter, search and the data itself changing all move the visible set.
        .selection($selection, confinedTo: visibleIDs, showing: existingIDs)
        .paneFollows($selection, into: $shown, guard: model.formGuard, existing: existingIDs)
        // A volume asked for by name elsewhere — the window bar's search box. One-shot, as Containers does it.
        .onChange(of: model.pendingDetailSubject) { _, _ in consumeDetailRequest() }
        .onAppear { consumeDetailRequest() }
        // Paired hosts' volumes kept current while this section is open, as Containers does.
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
        .onChange(of: model.pendingVolumeForm) { _, requested in
            if requested { showingCreate = true; model.pendingVolumeForm = false }
        }
        .onAppear {
            if model.pendingVolumeForm { showingCreate = true; model.pendingVolumeForm = false }
        }

        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Delete volume “\(pendingDelete?.name ?? "")”\(pendingDelete.map(onHost) ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    Task { await model.removeVolume(row.volume, host: row.host) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(actionable.count) volume\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Volume\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                let rows = actionableRows
                Task {
                    let local = Set(rows.filter(\.host.isLocal).map(\.volume.id))
                    if !local.isEmpty { await model.deleteVolumes(local) }
                    // Other Macs' volumes one at a time, as Containers acts on its remote rows.
                    for row in rows where !row.host.isLocal {
                        await model.removeVolume(row.volume, host: row.host)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text([FleetWording.onMacs(actionableRows.map { ($0.host, $0.hostName) }), "This cannot be undone."]
                    .compactMap { $0 }.joined(separator: " "))
        }
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search volumes…",
                       matches: displayedVolumes.count,
                       updated: model.volumesLastRefresh,
                       leading: {
            ResourceListControls(
                selection: $selection,
                selectable: displayedVolumes.map(\.id),
                noun: "volumes",
                sort: ui.sortMenu(default: SortKey.name),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                filters: volumeFilters,
                hostFilter: Binding(get: { ui.hostFilter }, set: { ui.hostFilter = $0 }),
                hosts: hostChoices)
        }, trailing: {
            ToolbarIconMenu(systemImage: "plus", label: "Create a volume") {
                addMenuItems
            }
            ToolbarRefreshButton(label: "Refresh volumes") {
                Task { await model.refreshVolumes() }
            }
        })
    }

    /// Free-text filter over the volume name.
    /// Whether anything is currently narrowing the list. Drives the empty state's wording and
    /// its action: "no matches, clear the filter" and "none exist, make one" are different
    /// situations and only one of them is the user's mistake.
    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" || ui.hostFilter != nil
    }

    /// This Mac and every trusted host, for the filter's Host section and New Volume's picker.
    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// " on mini" for a paired host's volume, nothing for This Mac's.
    private func onHost(_ row: HostedVolume) -> String {
        row.host.isLocal ? "" : " on \(row.hostName)"
    }

    /// This Mac's volumes and every paired host's last answer, through the host filter (PLAN.md
    /// Phase C). Two Macs' `data` volumes are two rows: neither is the other's.
    private var allRows: [HostedVolume] { rows(through: ui.hostFilter) }

    /// Every Mac's, through no filter: what the page resolves against, so a filter hides rows in
    /// the list and never the page that's open (Kyle, 17 October).
    private var everyRow: [HostedVolume] { rows(through: nil) }

    /// Every row with a page, whatever the filters show: what one selected row may be.
    private var existingIDs: Set<HostedVolume.ID> { Set(everyRow.map(\.id)) }

    private func rows(through hostFilter: HostRef?) -> [HostedVolume] {
        var rows: [HostedVolume] = []
        if hostFilter == nil || hostFilter == .local {
            rows += model.volumes.map { HostedVolume(volume: $0, host: .local, hostName: model.hostLabel) }
        }
        let now = Date()
        for (peer, snapshot) in model.hostMode.fleetVolumes {
            let host = HostRef.peer(peer.fingerprint)
            if let only = hostFilter, only != host { continue }
            let stale = snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil
            rows += snapshot.items.map {
                HostedVolume(volume: $0, host: host, hostName: peer.displayName, staleSince: stale)
            }
        }
        return rows
    }

    private var displayedVolumes: [HostedVolume] {
        var volumes = allRows

        // The one filter control covers two independent facets — age and label — because
        // `ResourceUIState.filterID` is a single selected string, not a set of facets. The id
        // itself says which facet fired: an age bucket's id round-trips through `VolumeAgeBucket`,
        // anything else is checked against the `label:` prefix.
        if let bucket = VolumeSizeBucket.allCases.first(where: { $0.filterID == ui.filterID }) {
            volumes = volumes.filter { Self.sizeBucket(for: $0.volume) == bucket }
        } else if let bucket = VolumeAgeBucket.allCases.first(where: { $0.filterID == ui.filterID }) {
            volumes = volumes.filter { Self.ageBucket(for: $0.volume) == bucket }
        } else if ui.filterID.hasPrefix(Self.labelFilterPrefix) {
            let pair = ui.filterID.dropFirst(Self.labelFilterPrefix.count)
            if let separator = pair.firstIndex(of: "=") {
                let key = String(pair[..<separator])
                let value = String(pair[pair.index(after: separator)...])
                volumes = volumes.filter { $0.volume.configuration.labels?[key] == value }
            }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // `name` is non-optional: the real payload nests it under `configuration` where it
            // is always present. It was optional before commit c258911 fixed the fabricated
            // fixture, and a `?? ""` here was leftover defensive code from that shape.
        // **Tag names are searchable too, on every section.**
        //
        // This is how tags filter. The alternative was a tag entry in each section's filter
        // control, which Volumes and Networks could take as a string id but Containers and
        // Machines could not without widening their typed `Filter` enums — and a tag filter that
        // exists on two sections out of five is the asymmetry this app keeps being asked to
        // remove. Searching the name reaches every section through one line each, works exactly
        // the same way everywhere, and composes with whatever filter is already on.
            volumes = volumes.filter {
                $0.name.lowercased().contains(query)
                    || (!$0.host.isLocal && $0.hostName.lowercased().contains(query))
                    || model.tags.tags(on: .volume, $0.detailKey)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }

        return volumes.sorted(using: sortKey.comparators(ascending: ui.sortAscending))
    }

    private var visibleIDs: Set<HostedVolume.ID> { Set(displayedVolumes.map(\.id)) }

    /// Filtering does not clear table selection, so destructive batches must never include a
    /// row that disappeared before the user confirmed the action.
    private var actionable: Set<HostedVolume.ID> { selection.intersection(visibleIDs) }

    private var actionableRows: [HostedVolume] { displayedVolumes.filter { actionable.contains($0.id) } }

    private func open(_ row: HostedVolume, tab: VolumeDetailTab? = nil) {
        open(row.id, tab: tab)
    }

    /// Shows a volume's page by selecting it, and only it (Q58) — clearing the filter first if it
    /// is hiding the row, so the page always has a place in the list to step from.
    private func open(_ id: HostedVolume.ID, tab: VolumeDetailTab? = nil) {
        if !visibleIDs.contains(id) { ui.search = ""; ui.filterID = "all"; ui.hostFilter = nil }
        request = tab.map { DetailTarget(id: id, tab: $0) }
        selection = [id]
        ui.pane.reveal()
    }

    private var selectionBusy: Bool { model.isAnyBusy(actionable, kind: .volume) }

    /// The selected rows as tag subjects, in the table's own order.
    ///
    /// Built from `actionable`, not from `selection`: filtering does not clear a table's
    /// selection, so a row you selected and then filtered away is still in the set — and tagging
    /// something the user cannot see is the same mistake the bulk delete bars guard against.
    private var selectedTagSubjects: [TagSubject] {
        // Resolved through the rows rather than mapping the id set straight across. Tags on
        // volumes key on `name` (prefixed for a paired host) — the key the activity feed uses
        // too — and `actionable` holds row ids built from `ContainerVolume.ID`. They are equal on
        // every volume this CLI returns, which is exactly the kind of coincidence that stops
        // being true quietly.
        actionableRows.map { TagSubject(kind: .volume, id: $0.detailKey) }
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
        IconActionButton(systemImage: "trash",
                         label: "Delete \(actionable.count) volumes",
                         help: "Delete \(actionable.count) volumes",
                         busy: selectionBusy, destructive: true) {
            confirmingBulkDelete = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.volumesState {
        case .idle, .loading:
            ProgressView("Loading volumes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as containers: a failed load must never render as an empty list.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
            // Every branch fills the pane, so none can size the stack to its content.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where displayedVolumes.isEmpty:
            // Filtered-empty and genuinely-empty are different states, and this used to test
            // only the second (`model.volumes.isEmpty`) — so narrowing the filter to nothing
            // rendered an empty table with no message at all, and no way to see which control had
            // hidden the rows. UI-03/UI-04 in the 2026-08-20 audit, and the Containers screen had
            // already solved both; this is that pattern, not a new one.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No volumes",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "cylinder.split.1x2")
            } description: {
                Text(isFiltered
                     ? "No volume matches the current filter."
                     : "Create one to persist data across container runs.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all"; ui.hostFilter = nil }
                } else {
                    VStack(spacing: 14) {
                        Button("New Volume…") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                        SuggestionQuickPicks(
                            picks: VolumeSuggestion.catalogue.map { suggestion in
                                (suggestion.title, { model.requestSuggestion(SuggestionItem.volume(suggestion).id, host: ui.hostFilter) })
                            },
                            more: { model.requestSuggestionsTab(.volumes, host: ui.hostFilter) })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            rowsList
        }
    }

    /// What the Sort menu orders the rows by — one per column the old table sorted on ("On hosts"
    /// never sorted). Ties break on name, then host, so two Macs' `data` keep a stable order.
    enum SortKey: String, RowSortKey, Identifiable {
        case name = "Name"
        case format = "Format"
        case driver = "Driver"
        case capacity = "Capacity"
        case created = "Created"
        case host = "Host"
        var id: Self { self }

        func comparators(ascending: Bool) -> [KeyPathComparator<HostedVolume>] {
            let order: SortOrder = ascending ? .forward : .reverse
            let ties = [KeyPathComparator(\HostedVolume.name), KeyPathComparator(\HostedVolume.hostName)]
            switch self {
            case .name: return [KeyPathComparator(\HostedVolume.name, order: order), ties[1]]
            case .format: return [KeyPathComparator(\HostedVolume.formatSortKey, order: order)] + ties
            case .driver: return [KeyPathComparator(\HostedVolume.driverSortKey, order: order)] + ties
            case .capacity: return [KeyPathComparator(\HostedVolume.sizeSortKey, order: order)] + ties
            case .created: return [KeyPathComparator(\HostedVolume.creationSortKey, order: order)] + ties
            case .host: return [KeyPathComparator(\HostedVolume.hostName, order: order)] + ties
            }
        }
    }

    /// The Sort menu's choice; Name until one is made.
    private var sortKey: SortKey { ui.sortKey(default: .name) }

    /// Prefix for a label filter's id, e.g. `label:team=infra`. Namespaced against
    /// `VolumeAgeBucket.filterID` so the two facets sharing one `filterID` string can never
    /// collide, however a label key happens to be spelled.
    private static let labelFilterPrefix = "label:"

    /// Age and label — the two facets that genuinely vary for volumes created through this
    /// CLI. There used to be a driver filter here; it is gone, not merely empty. The captured
    /// help for `volume create` (`reference/cli-help/container-volume-create-1.0.0-help.txt`)
    /// has no `--driver` and no `--format` flag, so every volume this app can create is
    /// `local`/`ext4` — a driver filter could never have more than one real option, ever, on
    /// any Mac. That is a dead control, not a currently-empty one, so it does not belong even
    /// behind the same "only show it when there is a real choice" guard the other filters use.
    ///
    /// Both facets follow that guard anyway: an option is only offered when it would exclude
    /// at least one volume `All` would show. Verified in `container volume list --format json`:
    /// `creationDate`, `labels` (and `sizeInBytes`, unused here) do vary across real volumes.
    private var volumeFilters: [ResourceFilterOption] {
        let volumes = allRows.map(\.volume)
        let total = volumes.count

        // Age. A volume with no readable `creationDate` is its own (unlabelled) category —
        // "unknown", never "old" — so it still makes a bucket meaningful even when every dated
        // volume falls in the same one: selecting that bucket would exclude the undated volumes.
        // Only when literally everything (dated or not) lands in one category does a bucket
        // filter nothing, and that is when it is withheld.
        let presentBuckets = Set(volumes.compactMap(Self.ageBucket(for:)))
        let hasUnknownAge = volumes.contains { Self.ageBucket(for: $0) == nil }
        let ageOptions: [ResourceFilterOption] =
            presentBuckets.count + (hasUnknownAge ? 1 : 0) > 1
            ? VolumeAgeBucket.allCases.filter(presentBuckets.contains).map {
                ResourceFilterOption(id: $0.filterID, title: $0.title, systemImage: $0.systemImage)
            }
            : []

        // Labels. One option per distinct `key=value` pair actually present, offered only when
        // it does not match every volume. `--label` is a real `volume create` flag and the
        // create form's own `newLabels` writes it, so this is populated by ordinary use, not
        // aspirational.
        let pairCounts = volumes
            .flatMap { ($0.configuration.labels ?? [:]).map { "\($0.key)=\($0.value)" } }
            .reduce(into: [String: Int]()) { counts, pair in counts[pair, default: 0] += 1 }
        let labelOptions = pairCounts.keys.sorted().compactMap { pair -> ResourceFilterOption? in
            guard pairCounts[pair] ?? 0 < total else { return nil }
            return ResourceFilterOption(id: Self.labelFilterPrefix + pair, title: pair, systemImage: "tag")
        }

        // Size. Same rule as age: offered only when the volumes actually straddle the boundary,
        // so selecting a bucket can never produce an empty list.
        let presentSizes = Set(volumes.compactMap(Self.sizeBucket(for:)))
        let hasUnknownSize = volumes.contains { Self.sizeBucket(for: $0) == nil }
        let sizeOptions: [ResourceFilterOption] =
            presentSizes.count + (hasUnknownSize ? 1 : 0) > 1
            ? VolumeSizeBucket.allCases.filter(presentSizes.contains).map {
                ResourceFilterOption(id: $0.filterID, title: $0.title, systemImage: $0.systemImage)
            }
            : []

        let options = sizeOptions + ageOptions + labelOptions
        guard !options.isEmpty else { return [] }
        return [ResourceFilterOption(id: "all", title: "All", systemImage: "circle.grid.2x2")] + options
    }

    /// Which size bucket, if any — `nil` when the runtime reported no size, which is "unknown"
    /// rather than "small", the same distinction the age classifier draws.
    private static func sizeBucket(for volume: ContainerVolume) -> VolumeSizeBucket? {
        guard let bytes = volume.configuration.sizeInBytes else { return nil }
        return bytes < VolumeSizeBucket.boundary ? .underGigabyte : .gigabyteAndOver
    }

    /// Which bucket, if any, a volume's age falls into — `nil` when `creationDate` is absent.
    /// Absent is "unknown", not "old": the same distinction `ContainerVolume.creationSortKey`
    /// draws by sorting an absent date last rather than treating it as the oldest.
    private static func ageBucket(for volume: ContainerVolume) -> VolumeAgeBucket? {
        guard let created = RelativeDate.parse(volume.configuration.creationDate) else { return nil }
        let age = Date().timeIntervalSince(created)
        if age < 86_400 { return .last24Hours }
        if age < 86_400 * 7 { return .last7Days }
        return .older
    }

    /// Two-line rows (Q56), in Containers' shape: the name, its tags and another Mac's chip, then
    /// the format, the capacity, how far it has been pushed, and its age.
    ///
    /// No state dot. A volume has no lifecycle — it exists or it does not — so the leading slot
    /// carries the section's glyph, the same on every row, rather than a dot that always said the
    /// same thing.
    ///
    /// This section was two-line rows once before, and became a table because those rows could not
    /// be sorted and crammed everything into one caption. The Sort menu is what that version lacked,
    /// and the second line now says only what tells one row from the next.
    private var rowsList: some View {
        SelectionRevealingList(selection: selection) {
            List(displayedVolumes, selection: $selection) { row in
                listRow(row)
                    // The row paints its own padding, so its hover wash and the list's selection fill
                    // reach the same edges.
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // On the List, not on a row: this one hands back every selected id.
            .contextMenu(forSelectionType: HostedVolume.ID.self) { ids in
                rowContextMenu(for: ids)
            } primaryAction: { ids in
                // Selecting already shows the volume (Q58); double-click and Return bring its page
                // forward in a window too narrow for both panes — but only when the activation names
                // exactly one row. `ids` is a `Set`, so with several selected `first` is an arbitrary
                // member, and opening the wrong volume is worse than opening none.
                guard ids.count == 1, let row = displayedVolumes.first(where: { ids.contains($0.id) })
                else { return }
                open(row)
            }
        }
    }

    /// One row. The buttons, shown on hover, are the row's share of `rowActions` — the header has the rest.
    private func listRow(_ row: HostedVolume) -> some View {
        ResourceRow(
            title: row.name,
            detail: detailParts(row).joined(separator: " · "),
            selected: selection.contains(row.id),
            check: RowCheck(row.id, in: $selection),
            summary: rowSummary(row),
            leading: { RowLeadingMark { RowKindGlyph(systemImage: Section.volumes.systemImage) } },
            chips: {
                TagPillRow(tags: model.tags.tags(on: .volume, row.detailKey), compact: true)
                if !row.host.isLocal {
                    HostCell(name: row.hostName, staleSince: row.staleSince)
                        .chipStyle()
                        .fixedSize()
                }
            },
            actions: { rowActions(for: row) })
    }

    /// Format · capacity · on N hosts · created, each only when there is one.
    ///
    /// **Capacity, and it says so.** `volume list` reports the size the volume was *created* with:
    /// one made with `--size 64M` reports exactly 67,108,864 bytes, and one made with no size at all
    /// 549,755,813,888 — the 512 GiB default. Measured 2026-09-12: those two occupy 2.2 MB and
    /// 66 MB on disk, and `system df` agrees with `du`, not with this field. A bare "549.76 GB"
    /// beside a dashboard total of 141.1 MB is answering a different question, and the CLI has no
    /// per-volume usage to show instead, so the honest fix is the word.
    ///
    /// The **driver** is left off unless it is not `local`: `volume create` has no
    /// `--driver`, so it is the same word on every row this app can make, and "a column identical
    /// in every row is pure width" holds for a line just as well. It stays a sort key.
    /// "On N hosts" is This Mac's volume only, and only once a host has answered — the rule the
    /// On hosts column followed.
    private func detailParts(_ row: HostedVolume) -> [String] {
        let configuration = row.volume.configuration
        var parts: [String] = []
        if let driver = configuration.driver, driver != "local" { parts.append(driver) }
        if let format = configuration.format { parts.append(format) }
        if let size = row.volume.sizeInBytes { parts.append(Self.byteCount(size) + " capacity") }
        if row.host.isLocal, let spread = model.spread(of: row.volume).rowText { parts.append(spread) }
        let created = RelativeDate.relative(configuration.creationDate, prefix: "created")
        if created != "—" { parts.append(created) }
        return parts
    }

    /// What VoiceOver reads for the row: "pg-data, volume, ext4, 2 GB capacity, …".
    private func rowSummary(_ row: HostedVolume) -> String {
        var parts = [row.name, "volume"] + detailParts(row)
        let tags = model.tags.tags(on: .volume, row.detailKey).map(\.name)
        if !tags.isEmpty { parts.append("tags " + tags.joined(separator: ", ")) }
        if !row.host.isLocal { parts.append("on " + row.hostName) }
        return parts.joined(separator: ", ")
    }

    /// The right-click: the row's own menu for one row, the bulk bar's Delete for several, and the
    /// "+" menu on empty space. The table this replaced offered the menu of `ids.first` for any
    /// selection — an arbitrary member.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<HostedVolume.ID>) -> some View {
        if ids.isEmpty {
            addMenuItems
        } else if ids.count == 1, let row = displayedVolumes.first(where: { ids.contains($0.id) }) {
            menu(for: row)
        } else {
            Button("Delete \(ids.count) Volumes…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(model.isAnyBusy(ids, kind: .volume))
        }
    }

    /// The overflow on the row — a volume has no primary action to put beside it; in the page's
    /// header the bin as well, after the same divider every section uses, so the destructive
    /// control is always in the same place.
    @ViewBuilder
    private func rowActions(for row: HostedVolume, place: RowActionPlace = .row) -> some View {
        let busy = model.isBusy(row.id, kind: .volume)
        let name = row.name + onHost(row)
        HStack(spacing: 2) {
            RowOverflowMenu(label: "More actions for \(name)") {
                menu(for: row)
            }

            if place == .header {
                Divider().frame(height: 14)

                IconActionButton(systemImage: "trash",
                                 label: "Delete \(name)",
                                 help: "Delete \(name)",
                                 busy: busy, destructive: true) {
                    requestDelete(row)
                }
            }
        }
    }

    // MARK: Detail

    /// The page beside the list (Q58): the selected volume's detail, a summary of several, or an
    /// empty state. Built to the same shape as the containers and machines pages — a header with
    /// identity, the row's own actions and the stepper, then the detail.
    @ViewBuilder
    private var page: some View {
        if let row = shownRow {
            VStack(spacing: 0) {
                detailHeader(for: row)
                Divider()
                VolumeDetailView(model: model, volume: row.volume, host: row.host,
                                 requestedTab: request?.id == row.id ? request?.tab : nil)
                    // Keyed so moving to the next volume rebuilds rather than keeping the
                    // previous one's tab state under a new name.
                    .id(row.detailKey)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .paneStep("volume", "volumes", order: displayedVolumes.map(\.id), current: row.id) { open($0) }
            .id(request?.nonce)
        } else if shown.count > 1, !actionable.isEmpty {
            SelectionSummaryPane(title: "\(actionable.count) volumes selected",
                                 systemImage: Section.volumes.systemImage,
                                 names: actionableRows.map { $0.name + onHost($0) }) { bulkActions }
        } else {
            PaneEmptyState(title: "Choose a volume", systemImage: Section.volumes.systemImage,
                           description: "Its size, where it is mounted and what uses it show here.")
        }
    }

    /// The one volume the page shows, when one is selected.
    private var shownRow: HostedVolume? {
        guard shown.count == 1, let id = shown.first else { return nil }
        return everyRow.first { $0.id == id }
    }

    /// Identity, the row's actions, the stepper and the expand button — no Back: the list is beside it.
    private func detailHeader(for row: HostedVolume) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 19)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(subtitle(for: row))
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(subtitle(for: row))
            }

            Spacer(minLength: 0)
            ActionCluster { rowActions(for: row, place: .header) }
            DetailStepper()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func subtitle(for row: HostedVolume) -> String {
        let volume = row.volume
        var parts = row.host.isLocal ? [] : [row.hostName]
        if let format = volume.format { parts.append(format) }
        if let size = volume.sizeInBytes { parts.append(Self.byteCount(size)) }
        if let source = volume.source { parts.append(source) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func menu(for row: HostedVolume) -> some View {
        let volume = row.volume
        let busy = model.isBusy(row.id, kind: .volume)

        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)`, which greyed out the reads — Inspect, Copy — on the one surface and
        // left them live on the other.
        // First, above Copy: `volume inspect` was allowlisted from the start with nothing able to
        // call it (GAP-06). This is the authoritative record — `options`, `labels`, the on-disk
        // source — rather than the columns this table chose to show.
        Button("Details…") { open(row) }
        // Straight to the tab you wanted, the way the containers menu offers Logs and Inspect.
        Button("Inspect") { open(row, tab: .inspect) }
        if row.host.isLocal {
            Button("Push to Hosts\u{2026}") { pushing = volume }
                .disabled(model.hostMode.trustedHosts.isEmpty)
        }
        Divider()
        // Tags, in the same place on every row menu in the app: after the things you open and
        // before Copy. Not a destructive action, not a read of the runtime — it changes how the
        // row looks to you and nothing about what it is.
        TagMenu(store: model.tags, subject: TagSubject(kind: .volume, id: row.detailKey)) {
            tagSheet = TagSheetTarget(kind: .volume, id: row.detailKey)
        }
        Divider()
        CopyMenu([
            ("Name", volume.name),
            ("Source Path", volume.source),
            ("Format", volume.format),
        ] + (row.host.isLocal ? [] : [("Host", row.hostName)]))
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(row) }
            .disabled(busy)
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button("New Volume…") { showingCreate = true }
        Divider()
        Button("Suggestions…") { model.requestSuggestionsTab(.volumes, host: ui.hostFilter) }
    }

    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ row: HostedVolume) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = row
        } else {
            Task { await model.removeVolume(row.volume, host: row.host) }
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The three buckets `volumeFilters` derives age options from. Mutually exclusive — a volume
/// with a readable `creationDate` falls into exactly one, matching how the choices read as
/// "how old", not "at least how old".
/// Size, the one facet that varies on a real machine today.
///
/// Added after measuring: both volumes on this Mac were created on the same day, so the age
/// facet correctly withheld itself (one bucket is not a filter) and the section still showed no
/// filter button — which is what the owner actually asked for. Their sizes differ by four orders of
/// magnitude (64 MB and 512 GB), so this facet has two genuine options on the very data that
/// defeated the others.
///
/// The boundary is 1 GB because `volume create -s` takes a size with K/M/G/T/P suffixes and a
/// gigabyte is where "scratch" stops and "this holds something" starts. It is a rule of thumb,
/// not a claim about the runtime.
private enum VolumeSizeBucket: CaseIterable {
    case underGigabyte, gigabyteAndOver

    static let boundary: Int64 = 1_073_741_824

    var filterID: String {
        switch self {
        case .underGigabyte: "size-under-1g"
        case .gigabyteAndOver: "size-1g-plus"
        }
    }

    var title: String {
        switch self {
        case .underGigabyte: "Under 1 GB"
        case .gigabyteAndOver: "1 GB and over"
        }
    }

    /// Both verified with `NSImage(systemSymbolName:accessibilityDescription:) != nil`.
    var systemImage: String {
        switch self {
        case .underGigabyte: "shippingbox"
        case .gigabyteAndOver: "externaldrive"
        }
    }
}

private enum VolumeAgeBucket: CaseIterable {
    case last24Hours, last7Days, older

    var filterID: String {
        switch self {
        case .last24Hours: "age-24h"
        case .last7Days: "age-7d"
        case .older: "age-older"
        }
    }

    var title: String {
        switch self {
        case .last24Hours: "Last 24 hours"
        case .last7Days: "Last 7 days"
        case .older: "Older"
        }
    }

    /// All three verified with `NSImage(systemSymbolName:accessibilityDescription:) != nil`
    /// before shipping — an unknown name renders nothing, silently.
    var systemImage: String {
        switch self {
        case .last24Hours: "clock"
        case .last7Days: "calendar"
        case .older: "archivebox"
        }
    }
}

extension ContainerVolume {
    var formatSortKey: String { configuration.format ?? "" }
    var driverSortKey: String { configuration.driver ?? "" }

    /// **Unknown is not zero.** A volume the CLI reports no size for is not a zero-byte
    /// volume — coalescing to 0 would file it among genuinely empty volumes, which is a
    /// different, misleading claim. `-1` sorts clear of every real size (sizes are never
    /// negative) without pretending to know the answer.
    var sizeSortKey: Int64 { configuration.sizeInBytes ?? -1 }

    /// Sortable form of `creationDate`, which the CLI gives as an ISO-8601 *string* that
    /// happens to sort correctly lexicographically. Same rule `Container.creationSortKey`
    /// uses: an absent date sorts last rather than first.
    var creationSortKey: String { configuration.creationDate ?? "9999" }
}

/// One volume on one Mac (PLAN.md Phase C). This Mac's rows keep `ContainerVolume.id` as their id
/// and their bare name as their tag key, so selection, busy state and tags are unchanged for them.
struct HostedVolume: Identifiable {
    let volume: ContainerVolume
    let host: HostRef
    let hostName: String
    /// A host's row that is older than a fresh answer: shown, with its age, rather than hidden.
    var staleSince: Date? = nil

    var id: String { host.rowID(volume.id) }
    /// How the detail screen and tags name the volume: by name, on its Mac.
    var detailKey: String { host.rowID(volume.name) }

    var name: String { volume.name }
    var formatSortKey: String { volume.formatSortKey }
    var driverSortKey: String { volume.driverSortKey }
    var sizeSortKey: Int64 { volume.sizeSortKey }
    var creationSortKey: String { volume.creationSortKey }
}
