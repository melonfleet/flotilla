import SwiftUI
import Foundation
import FlotillaCore

/// The images section: list, pull, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct ImagesView: View {
    let model: AppModel
    let ui: ResourceUIState<HostedImage>

    @State private var selection = Set<HostedImage.ID>()

    /// Free-text filter, matched against the reference and tag. Local to the screen: unlike
    /// the containers table there is no cross-section state to preserve.
    @State private var search = ""

    /// The merged New Image form, and which half it opened on — `nil` when it is closed.
    /// One screen where there were two: see `NewImageView`.
    @State private var newImageMode: NewImageView.Mode?
    /// Browse Docker Hub, and the reference it handed the Pull form.
    @State private var browsing = false
    @State private var pullFromBrowse: String?
    @State private var pendingDelete: HostedImage?
    /// Set from the row menu's Run — presents the run sheet with this reference already in
    /// place, on the image's own Mac. Nothing is launched from here; the sheet's validated
    /// preview still gates it.
    @State private var runImage: RunTarget?
    /// One of This Mac's images, on its way to hosts (PLAN.md Phase D, D2).
    @State private var sendingImage: ContainerImage?

    /// A menu's request for one image's page on a particular tab. Each request is new (`nonce`),
    /// so asking for a tab again after leaving it still lands on it.
    private struct DetailTarget: Hashable {
        let id: HostedImage.ID
        var tab: ImageDetailTab?
        let nonce = UUID()
    }
    @State private var request: DetailTarget?

    /// The rows the page beside the list is showing: `selection`, once the form guard has let it
    /// through (Q58).
    @State private var shown = Set<HostedImage.ID>()

    @State private var taggingImage: HostedImage?
    /// Shared by the Tag form's header and its Cancel, so both ask about this form alone.
    @State private var formToken = UUID()
    @State private var tagTarget = ""
    @State private var tagError: String?

    @State private var showingPrune = false
    @State private var pruning = false
    @State private var pruneError: String?
    @State private var confirmingBulkDelete = false

    private func consumeDetailRequest() {
        guard let subject = model.pendingDetailSubject, model.pendingDetailKind == .image else { return }
        runImage = nil
        sendingImage = nil
        newImageMode = nil
        browsing = false
        taggingImage = nil
        // References are host-qualified by the palette, just like detail keys in this list.
        if let row = everyRow.first(where: { $0.detailKey == subject }) { open(row.id) }
        model.clearPendingDetail()
    }

    var body: some View {
        Group {
            // Embedded form screens, in precedence order — see `FormHeader` for the 9 August
            // reversal. Prune and About stay modal: they are dialogs you acknowledge, not
            // forms you fill in and save.
            if let target = runImage {
                RunSheetView(model: model, initialImage: target.reference, initialHost: target.host) { runImage = nil }
            } else if let image = sendingImage {
                SendImageView(model: model, image: image) { sendingImage = nil }
            } else if let mode = newImageMode {
                NewImageView(model: model, initialMode: mode, initialHost: ui.hostFilter ?? .local,
                             initialReference: pullFromBrowse,
                             onBrowseDockerHub: { newImageMode = nil; pullFromBrowse = nil; browsing = true }) {
                    newImageMode = nil; pullFromBrowse = nil
                }
            } else if browsing {
                RegistryBrowserView(model: model, onPull: { reference in
                    pullFromBrowse = reference
                    browsing = false
                    newImageMode = .pull
                }, dismiss: { browsing = false })
            } else if let image = taggingImage {
                tagScreen(for: image)
            } else {
                // Q58: the list, and the selected image's page beside it.
                SplitPanes(list: "images", pane: ui.pane, showing: shownRow?.id) {
                    VStack(spacing: 0) {
                        toolbar
                        bulkActionBar
                        Divider()
                        // A pull outlives its form, so the list has to be able to say so. Without
                        // this, pressing Back during a 40-second pull looks exactly like the pull
                        // having been cancelled.
                        if let pull = model.activePull {
                            ImagePullStatus(pull: pull, compact: true)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            Divider()
                        }
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
        .task { await model.refreshImages() }
        // `actionable` already stops a hidden row from being acted on; this stops one from being
        // counted. Filter, search and the data itself changing all move the visible set.
        .selection($selection, confinedTo: visibleIDs, showing: existingIDs)
        .paneFollows($selection, into: $shown, guard: model.formGuard, existing: existingIDs)
        // A image asked for by name elsewhere — the window bar's search box. One-shot, as Containers does it.
        .onChange(of: model.pendingDetailSubject) { _, _ in consumeDetailRequest() }
        .onAppear { consumeDetailRequest() }
        // Paired hosts' images kept current while this section is open, as Containers does.
        .task {
            while !Task.isCancelled {
                await model.hostMode.refreshLiveStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingPullForm) { _, requested in
            if requested { newImageMode = .pull; model.pendingPullForm = false }
        }
        .onAppear {
            if model.pendingPullForm { newImageMode = .pull; model.pendingPullForm = false }
        }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingBuildForm) { _, requested in
            if requested { newImageMode = .build; model.pendingBuildForm = false }
        }
        .onAppear {
            if model.pendingBuildForm { newImageMode = .build; model.pendingBuildForm = false }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Tag failed",
               isPresented: Binding(get: { tagError != nil }, set: { if !$0 { tagError = nil } })) {
            Button("OK") { tagError = nil }
        } message: {
            Text(tagError ?? "")
        }
        .alert("Prune failed",
               isPresented: Binding(get: { pruneError != nil }, set: { if !$0 { pruneError = nil } })) {
            Button("OK") { pruneError = nil }
        } message: {
            Text(pruneError ?? "")
        }
        .sheet(isPresented: $showingPrune) { pruneSheet }
        .confirmationDialog(
            "Delete image “\(pendingDelete.map { Self.repository($0.image) } ?? "")”\(pendingDelete.map(onHost) ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    Task { await model.removeImage(row.image, host: row.host) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(actionable.count) image\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Image\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                let rows = actionableRows
                Task {
                    let local = Set(rows.filter(\.host.isLocal).map(\.image.id))
                    if !local.isEmpty { await model.deleteImages(local) }
                    // Other Macs' images one at a time, as Containers acts on its remote rows.
                    for row in rows where !row.host.isLocal {
                        await model.removeImage(row.image, host: row.host)
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
                       searchPrompt: "Search images…",
                       matches: displayedImages.count,
                       updated: model.imagesLastRefresh,
                       leading: {
            ResourceListControls(
                selection: $selection,
                selectable: displayedImages.map(\.id),
                noun: "images",
                sort: ui.sortMenu(default: SortKey.name),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                filters: platformFilters,
                hostFilter: Binding(get: { ui.hostFilter }, set: { ui.hostFilter = $0 }),
                hosts: hostChoices)
        }, trailing: {
            // One control for one intention. It was a hammer and a download arrow — two
            // buttons for "add an image", in a section where every other action is a single
            // control — and both forms were short enough to share one screen.
            ToolbarIconButton(systemImage: "plus", label: "New image — pull or build…") {
                newImageMode = .pull
            }
            ToolbarIconButton(systemImage: "magnifyingglass", label: "Browse Docker Hub…") {
                browsing = true
            }
            ToolbarRefreshButton(label: "Refresh images") {
                Task { await model.refreshImages() }
            }
            Divider().frame(height: 14)
            ToolbarIconButton(systemImage: "trash.slash",
                              label: hostChoices.count > 1 ? "Delete images no container on this Mac is using"
                                                           : "Delete images no container is using",
                              isDestructive: true) {
                showingPrune = true
            }
        })
    }

    /// What the Sort menu orders the rows by — one per column the old table sorted on, with Name
    /// for its Repository column (which sorted the whole reference). Ties break on name, then
    /// host, so one image on two Macs keeps a stable order.
    enum SortKey: String, RowSortKey, Identifiable {
        case name = "Name"
        case tag = "Tag"
        case platform = "Platform"
        case digest = "Digest"
        case size = "Size"
        case created = "Created"
        case host = "Host"
        var id: Self { self }

        func comparators(ascending: Bool) -> [KeyPathComparator<HostedImage>] {
            let order: SortOrder = ascending ? .forward : .reverse
            let ties = [KeyPathComparator(\HostedImage.reference), KeyPathComparator(\HostedImage.hostName)]
            switch self {
            case .name: return [KeyPathComparator(\HostedImage.reference, order: order), ties[1]]
            case .tag: return [KeyPathComparator(\HostedImage.tagSortKey, order: order)] + ties
            case .platform: return [KeyPathComparator(\HostedImage.platformSortKey, order: order)] + ties
            case .digest: return [KeyPathComparator(\HostedImage.digestSortKey, order: order)] + ties
            case .size: return [KeyPathComparator(\HostedImage.sizeSortKey, order: order)] + ties
            case .created: return [KeyPathComparator(\HostedImage.creationSortKey, order: order)] + ties
            case .host: return [KeyPathComparator(\HostedImage.hostName, order: order)] + ties
            }
        }
    }

    /// The Sort menu's choice; Name until one is made.
    private var sortKey: SortKey { ui.sortKey(default: .name) }

    /// This Mac and every trusted host, for the filter's Host section.
    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// " on mini" for a paired host's image, nothing for This Mac's — the suffix every label and
    /// dialog carries so a remote action never reads as a local one.
    private func onHost(_ row: HostedImage) -> String {
        row.host.isLocal ? "" : " on \(row.hostName)"
    }

    /// One option per architecture actually present, plus All.
    ///
    /// Derived, not fixed: on an Apple Silicon Mac that has only ever pulled arm64 images this
    /// yields a single entry and `ResourceListControls` hides the control entirely. It earns its
    /// place the moment a multi-arch or an amd64 image lands — which is exactly when you want to
    /// find them, because those are the ones that will run under emulation or not at all.
    private var platformFilters: [ResourceFilterOption] {
        let architectures = Set(allRows.map(\.image)
            .flatMap { $0.variants?.compactMap { $0.platform?.architecture } ?? [] }
            .filter { $0 != "unknown" })
        guard architectures.count > 1 else { return [] }
        return [ResourceFilterOption(id: "all", title: "All", systemImage: "circle.grid.2x2")]
            + architectures.sorted().map {
                ResourceFilterOption(id: $0, title: $0, systemImage: "cpu")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.imagesState {
        case .idle, .loading:
            ProgressView("Loading images…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as every other screen: a failed load must never render as an
            // empty list — that would look like a healthy, image-less machine.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
            // Every branch fills the pane, so none can size the stack to its content.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where displayedImages.isEmpty:
            // Filtered-empty and genuinely-empty are different states, and this used to test
            // only the second (`model.images.isEmpty`) — so narrowing the filter to nothing
            // rendered an empty table with no message at all, and no way to see which control had
            // hidden the rows. UI-03/UI-04 in the 2026-08-20 audit, and the Containers screen had
            // already solved both; this is that pattern, not a new one.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No images",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "square.stack.3d.up")
            } description: {
                Text(isFiltered
                     ? "No image matches the current filter."
                     : "Pull one to run a container from it.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all"; ui.hostFilter = nil }
                } else {
                    Button("Pull an Image…") { newImageMode = .pull }
                        .buttonStyle(.borderedProminent)
                    Button("Browse Docker Hub…") { browsing = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            rowsList
        }
    }

    /// Two-line rows (Q56), in Containers' shape: the reference as you would type it, chips for
    /// "in use" and another Mac, then size · created · platform · digest.
    ///
    /// What the table this replaced argued for still holds: size is a sort key (the thing you want
    /// when reclaiming disk) and the platform and digest are on screen without opening Inspect.
    /// Repository and tag sort separately, from the Sort menu, rather than as two columns.
    private var rowsList: some View {
        SelectionRevealingList(selection: selection) {
            List(displayedImages, selection: $selection) { row in
                listRow(row)
                    // The row paints its own padding, so its hover wash and the list's selection fill
                    // reach the same edges.
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // On the List, not on a row: this one hands back every selected id.
            .contextMenu(forSelectionType: HostedImage.ID.self) { ids in
                rowContextMenu(for: ids)
            } primaryAction: { ids in
                // Selecting already shows the image (Q58); double-click and Return bring its page
                // forward in a window too narrow for both panes.
                guard ids.count == 1,
                      let row = displayedImages.first(where: { ids.contains($0.id) }) else { return }
                open(row)
            }
        }
    }

    /// One row. The buttons, shown on hover, are the row's share of `rowActions` — the header has the rest.
    private func listRow(_ row: HostedImage) -> some View {
        let users = containersUsing(row)
        return ResourceRow(
            title: Self.displayName(row.image),
            titleHelp: row.reference + onHost(row),
            detail: detailParts(row).joined(separator: " · "),
            detailHelp: detailHelp(row),
            selected: selection.contains(row.id),
            check: RowCheck(row.id, in: $selection),
            summary: rowSummary(row, users: users),
            leading: {
                // The library's logo for this repository, in the containers' 20pt size; the
                // glyph otherwise. Both sit at the slot's trailing edge, so names stay aligned.
                RowLeadingMark {
                    if let logo = model.libraryLogo(for: row.reference) {
                        SuggestionLogo(data: logo, category: nil, size: 20)
                    } else {
                        RowKindGlyph(systemImage: Section.images.systemImage)
                    }
                }
            },
            chips: {
                // Images have no tags (CLAUDE.md: "tag" already means an image reference's).
                if !users.isEmpty {
                    ResourceChip(text: "in use")
                        .help("Used by " + users.joined(separator: ", "))
                }
                if let critical = model.vulnerabilityReport?.image(forAnyOf: row.image.reportDigests)?.counts.critical,
                   critical > 0 {
                    CriticalChip(count: critical)
                }
                if !row.host.isLocal {
                    HostCell(name: row.hostName, staleSince: row.staleSince)
                        .chipStyle()
                        .fixedSize()
                }
            },
            actions: { rowActions(for: row) })
    }

    /// The containers on the image's own Mac that were created from it — what "in use" means,
    /// and the same test the prune preview applies: a reference match, so a container keeps its
    /// image in use whether it is running or not.
    private func containersUsing(_ row: HostedImage) -> [String] {
        model.containers(on: row.host)
            .filter { $0.configuration.image.reference == row.reference }
            .map(\.id)
            .sorted()
    }

    /// Size · created · platform · digest, each only when the runtime reported it. A sentence has
    /// no need of the dash a table cell needed to hold its place. `fullDigest` for a tooltip.
    private func detailParts(_ row: HostedImage, fullDigest: Bool = false) -> [String] {
        let image = row.image
        return [image.displaySize.map(Self.byteCount),
                RelativeDate.relative(image.configuration.creationDate, prefix: "created"),
                Self.platformLabel(image),
                fullDigest ? image.configuration.descriptor?.digest : Self.shortDigest(image)]
            .compactMap { $0 }
            .filter { $0 != "—" }
    }

    /// The second line on hover: the full reference and digest rather than their shortenings.
    private func detailHelp(_ row: HostedImage) -> String {
        ([row.reference] + detailParts(row, fullDigest: true)).joined(separator: " · ")
    }

    /// What VoiceOver reads for the row: "nginx:alpine, image, in use by web, 52 MB, …".
    private func rowSummary(_ row: HostedImage, users: [String]) -> String {
        var parts = [Self.displayName(row.image), "image"]
        if !users.isEmpty { parts.append("in use by " + users.joined(separator: ", ")) }
        parts.append(contentsOf: detailParts(row))
        if !row.host.isLocal { parts.append("on " + row.hostName) }
        return parts.joined(separator: ", ")
    }

    /// The right-click: the row's own menu for one row, the bulk bar's Delete for several, and the
    /// ways to add an image on empty space. The table this replaced offered the menu of
    /// `ids.first` for any selection — an arbitrary member.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<HostedImage.ID>) -> some View {
        if ids.isEmpty {
            Button("New Image…") { newImageMode = .pull }
            Button("Browse Docker Hub…") { browsing = true }
        } else if ids.count == 1, let row = displayedImages.first(where: { ids.contains($0.id) }) {
            menu(for: row)
        } else {
            Button("Delete \(ids.count) Images…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(model.isAnyBusy(ids, kind: .image))
        }
    }

    /// Run and the overflow on the row; in the page's header Tag and the bin as well — the same
    /// order and the same divider before the destructive control as the containers and machines.
    @ViewBuilder
    private func rowActions(for row: HostedImage, place: RowActionPlace = .row) -> some View {
        let image = row.image
        let busy = model.isBusy(row.id, kind: .image)
        let name = Self.repository(image) + onHost(row)
        HStack(spacing: 2) {
            IconActionButton(systemImage: "play.fill",
                             label: "Run \(name)",
                             help: "Run a container from \(image.reference)\(onHost(row))",
                             busy: busy) {
                runImage = RunTarget(reference: image.reference, host: row.host)
            }
            if place == .header {
                IconActionButton(systemImage: "tag",
                                 label: "Tag \(name)",
                                 help: "Tag \(name)",
                                 busy: busy) {
                    tagTarget = ""
                    taggingImage = row
                }
            }

            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(name)")
            .accessibilityLabel("More actions for \(name)")

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

    /// The platform that would actually run here.
    ///
    /// Taking the *first* variant was wrong on multi-arch images: `nginx:alpine` listed
    /// `linux/amd64` first, so the table claimed amd64 on an Apple Silicon Mac while the
    /// container the CLI runs from it is arm64. Prefer the host's architecture, and mark the
    /// image as multi-arch so the single value does not imply there is only one.
    /// `internal`, not `fileprivate`: these four derivations of a reference are what the detail
    /// screen needs too, and a second copy of "split the repository off the tag" is how the sort
    /// key and the column once disagreed about what a tag is.
    nonisolated static func platformLabel(_ image: ContainerImage) -> String {
        let platforms = image.variants?.compactMap(\.platform) ?? []
        guard !platforms.isEmpty else { return "—" }
        let native = platforms.first { $0.architecture?.contains("arm64") == true } ?? platforms[0]
        let label = [native.os, native.architecture].compactMap { $0 }.joined(separator: "/")
        return platforms.count > 1 ? "\(label) +\(platforms.count - 1)" : label
    }

    nonisolated static func shortDigest(_ image: ContainerImage) -> String {
        guard let digest = image.configuration.descriptor?.digest else { return "—" }
        // Drop the `sha256:` prefix and keep the first 12, which is what every registry UI and
        // the CLI's own `image list` show.
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return String(hex.prefix(12))
    }

    /// Hides attestation/provenance manifests (`architecture: "unknown"`) — they're noise
    /// in a list meant to show pullable, runnable images, not build metadata. Only hidden
    /// when EVERY variant is `"unknown"`; a real multi-arch image that happens to carry an
    /// attestation alongside real platforms keeps showing.
    /// Whether anything is currently narrowing the list. Drives the empty state's wording and
    /// its action: "no matches, clear the filter" and "none exist, make one" are different
    /// situations and only one of them is the user's mistake.
    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" || ui.hostFilter != nil
    }

    /// This Mac's images and every paired host's last answer, through the host filter (PLAN.md
    /// Phase C). One image on two Macs is two rows: each is its own thing to run, tag or delete.
    private var allRows: [HostedImage] { rows(through: ui.hostFilter) }

    /// Every Mac's, through no filter: what the page resolves against, so a filter hides rows in
    /// the list and never the page that's open (Kyle, 17 October).
    private var everyRow: [HostedImage] { rows(through: nil) }

    /// Every row with a page, whatever the filters show: what one selected row may be.
    private var existingIDs: Set<HostedImage.ID> { Set(everyRow.map(\.id)) }

    private func rows(through hostFilter: HostRef?) -> [HostedImage] {
        var rows: [HostedImage] = []
        if hostFilter == nil || hostFilter == .local {
            rows += model.images.map { HostedImage(image: $0, host: .local, hostName: model.hostLabel) }
        }
        let now = Date()
        for (peer, snapshot) in model.hostMode.fleetImages {
            let host = HostRef.peer(peer.fingerprint)
            if let only = hostFilter, only != host { continue }
            let stale = snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil
            rows += snapshot.items.map {
                HostedImage(image: $0, host: host, hostName: peer.displayName, staleSince: stale)
            }
        }
        return rows
    }

    private var displayedImages: [HostedImage] {
        var rows = allRows.filter { row in
            guard let variants = row.image.variants, !variants.isEmpty else { return true }
            return !variants.allSatisfy { $0.platform?.architecture == "unknown" }
        }

        if ui.filterID != "all" {
            rows = rows.filter { row in
                row.image.variants?.contains { $0.platform?.architecture == ui.filterID } ?? false
            }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter {
                $0.reference.lowercased().contains(query)
                    || (!$0.host.isLocal && $0.hostName.lowercased().contains(query))
            }
        }

        return rows.sorted(using: sortKey.comparators(ascending: ui.sortAscending))
    }

    private var visibleIDs: Set<HostedImage.ID> { Set(displayedImages.map(\.id)) }

    /// Image ids remain selected when a platform or search filter hides their rows, so the batch
    /// target is always the visible intersection rather than the retained selection itself.
    private var actionable: Set<HostedImage.ID> { selection.intersection(visibleIDs) }

    private var actionableRows: [HostedImage] { displayedImages.filter { actionable.contains($0.id) } }

    private func open(_ row: HostedImage, tab: ImageDetailTab? = nil) {
        open(row.id, tab: tab)
    }

    /// Shows an image's page by selecting it, and only it (Q58) — clearing the filter first if it
    /// is hiding the row, so the page always has a place in the list to step from.
    private func open(_ id: HostedImage.ID, tab: ImageDetailTab? = nil) {
        if !visibleIDs.contains(id) { ui.search = ""; ui.filterID = "all"; ui.hostFilter = nil }
        request = tab.map { DetailTarget(id: id, tab: $0) }
        selection = [id]
        ui.pane.reveal()
    }

    private var selectionBusy: Bool { model.isAnyBusy(actionable, kind: .image) }

    @ViewBuilder
    private var bulkActionBar: some View {
        // From two rows, as the page's summary is (Kamal, 17 October, round 2): one row is its page.
        // And only while that summary is not on screen — `BulkActionBar`.
        if selection.count > 1, !actionable.isEmpty {
            BulkActionBar(title: "\(actionable.count) selected") { bulkActions }
        }
    }

    /// The bulk bar's controls, and the page's when several are ticked — one builder for both.
    private var bulkActions: some View {
        IconActionButton(systemImage: "trash",
                         label: "Delete \(actionable.count) images",
                         help: "Delete \(actionable.count) images",
                         busy: selectionBusy, destructive: true) {
            confirmingBulkDelete = true
        }
    }

    private var trimmedTag: String {
        tagTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An image reference has its own shape, and its own rule text — so "not a valid
    /// imageReference" now comes with "expected something like docker.io/library/alpine:latest".
    private var tagProblem: String? {
        guard !trimmedTag.isEmpty else { return nil }
        return problem(in: ["image", "tag", "placeholder:latest", trimmedTag])
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    /// Parity with the row's own buttons (Tag, Delete) plus the Copy submenu, in the order
    /// `ContextMenus.swift` sets out. "Run" is here because an image you can see is an image
    /// you are likely to want to start — it opens the run sheet pre-filled rather than
    /// launching anything directly, so the command preview still gets the final say.
    @ViewBuilder
    private func menu(for row: HostedImage) -> some View {
        let image = row.image
        let busy = model.isBusy(row.id, kind: .image)

        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)`, which greyed out the reads — Inspect, Copy — on the one surface and
        // left them live on the other.
        Button("Details…") { open(row) }
        Button("Inspect") { open(row, tab: .inspect) }
        Divider()
        Button("Run…") { runImage = RunTarget(reference: image.reference, host: row.host) }
            .disabled(busy)
        if row.host.isLocal {
            Button("Send to Hosts\u{2026}") { sendingImage = image }
                .disabled(model.hostMode.trustedHosts.isEmpty)
        }
        Divider()
        Button("Tag…") {
            tagTarget = ""
            taggingImage = row
        }
        .disabled(busy)
        CopyMenu([
            ("Reference", image.reference),
            ("Repository", Self.repository(image)),
            ("Tag", Self.tag(image)),
            ("Digest", image.configuration.descriptor?.digest),
        ] + (row.host.isLocal ? [] : [("Host", row.hostName)]))
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(row) }
            .disabled(busy)
    }

    // MARK: Detail

    /// The page beside the list (Q58): the selected image's detail, a summary of several, or an
    /// empty state.
    @ViewBuilder
    private var page: some View {
        if let row = shownRow {
            VStack(spacing: 0) {
                detailHeader(for: row)
                Divider()
                ImageDetailView(model: model, image: row.image, host: row.host,
                                requestedTab: request?.id == row.id ? request?.tab : nil)
                    .id(row.detailKey)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .paneStep("image", "images", order: displayedImages.map(\.id), current: row.id) { open($0) }
            .id(request?.nonce)
        } else if shown.count > 1, !actionable.isEmpty {
            SelectionSummaryPane(title: "\(actionable.count) images selected",
                                 systemImage: Section.images.systemImage,
                                 names: actionableRows.map { $0.reference + onHost($0) }) { bulkActions }
        } else {
            PaneEmptyState(title: "Choose an image", systemImage: Section.images.systemImage,
                           description: "Its platforms, layers and the containers using it show here.")
        }
    }

    /// The one image the page shows, when one is selected.
    private var shownRow: HostedImage? {
        guard shown.count == 1, let id = shown.first else { return nil }
        return everyRow.first { $0.id == id }
    }

    /// Identity, the row's actions, the stepper and the expand button — no Back: the list is beside it.
    private func detailHeader(for row: HostedImage) -> some View {
        let image = row.image
        return HStack(spacing: 10) {
            if let logo = model.libraryLogo(for: row.reference) {
                SuggestionLogo(data: logo, category: nil, size: 32)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Self.repository(image)).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(Self.tag(image)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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

    private func subtitle(for row: HostedImage) -> String {
        let image = row.image
        var parts = row.host.isLocal ? [] : [row.hostName]
        parts.append(Self.platformLabel(image))
        if let size = image.displaySize { parts.append(Self.byteCount(size)) }
        parts.append(Self.shortDigest(image))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Tag Image, built to the same shape as every other form in the app.
    ///
    /// It was the last one that was not. This screen had no information rail, a hard
    /// `.frame(width: 440)` and a `Save` button inline in the body — so it sat as a narrow
    /// centred column while Run, New Machine, New Volume, New Network and New Image are all
    /// left-aligned against a rail with the action in a footer. That is exactly the complaint
    /// the owner made about the pull form: *"it doesn't look like any of the other forms… it
    /// needs to be to the left aligned and also has the information rail to the right."* Pull
    /// was fixed and this one was never looked at, because nothing pointed at it.
    private func tagScreen(for image: HostedImage) -> some View {
        VStack(spacing: 0) {
            FormHeader(title: "Tag Image", systemImage: "tag",
                       hasUnsavedChanges: !trimmedTag.isEmpty,
                       onBack: { taggingImage = nil }, token: formToken)
            Divider()
            FormScaffold {
                tagForm(for: image)
            } preview: {
                tagRail(for: image)
            }
            Divider()
            tagFooter(for: image)
        }
    }

    private func tagForm(for image: HostedImage) -> some View {
        FormField("New reference",
                  help: FieldHelp(
                      "The name the image gains. Tagging adds a name; it does not "
                          + "rename or copy anything.",
                      detail: "A reference is `registry/namespace/name:tag`. Leave the registry "
                          + "off and the runtime assumes Docker Hub, so `myapp:v2` and "
                          + "`docker.io/library/myapp:v2` are the same image.",
                      example: "ghcr.io/acme/web:v2",
                      warning: "Reusing a tag that already exists moves it to this image. The "
                          + "old image stays on disk but loses that name."),
                  problem: tagProblem) {
            TextField("myregistry/name:tag", text: $tagTarget)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// The command the button will run, beside the field — the same rail every other form
    /// carries, and the reason it is an answer rather than another field to find at the end.
    private func tagRail(for row: HostedImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text("container image tag \(row.reference) "
                 + (trimmedTag.isEmpty ? "<new reference>" : trimmedTag))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(trimmedTag.isEmpty ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !row.host.isLocal {
                Label("Runs on \(row.hostName)", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tagFooter(for row: HostedImage) -> some View {
        HStack(spacing: 8) {
            Spacer()
            FormCancelButton(token: formToken) { taggingImage = nil }
            Button("Tag") {
                let target = trimmedTag
                let source = row.reference
                let host = row.host
                let where_ = onHost(row)
                taggingImage = nil
                guard !target.isEmpty else { return }
                Task {
                    do {
                        try await model.tagImage(source, as: target, host: host)
                        if host.isLocal { await model.refreshImages() }
                    } catch {
                        tagError = "Tag failed for \(source) \u{2192} \(target)\(where_): "
                            + (host.isLocal ? "\(error)" : HostModeController.describe(error))
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedTag.isEmpty || tagProblem != nil)
        }
        .padding(12)
    }

    /// Every image not referenced by any known container — client-side, since the CLI has
    /// no dry-run/prune-preview output to ask for. This IS the set `deleteImages` below
    /// will delete, by construction (loop over exactly these references), so the preview
    /// can never drift from the outcome. It may not be bit-for-bit what `container image
    /// prune`'s own internal definition of "unused" would remove — that's the trade-off
    /// for a guaranteed-accurate preview over using the CLI's blanket verb. Flagged in the
    /// report as a judgment call, not silently assumed.
    private var pruneCandidates: [ContainerImage] {
        let referenced = Set(model.containers.map(\.configuration.image.reference))
        return model.images.filter { !referenced.contains($0.reference) }
    }

    /// Always shows the preview, regardless of `confirmDestructiveActions` — that setting
    /// governs whether a single delete needs an "are you sure," but the brief is explicit
    /// that a bulk prune must always show exactly what dies, which is more than a yes/no
    /// confirmation.
    private var pruneSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prune Unused Images").font(.headline)
            if pruneCandidates.isEmpty {
                Text("Nothing to prune — every image is referenced by a container.")
                    .foregroundStyle(.secondary)
            } else {
                Text("These \(pruneCandidates.count) image(s) aren't referenced by any "
                     + "container and will be deleted:")
                    .font(.subheadline)
                List(pruneCandidates) { image in
                    HStack {
                        Text(Self.repository(image)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let size = image.displaySize {
                            Text(Self.byteCount(size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingPrune = false }
                Button("Delete \(pruneCandidates.count) Image(s)", role: .destructive) {
                    let targets = pruneCandidates.map(\.reference)
                    showingPrune = false
                    Task {
                        pruning = true
                        let failures = await model.deleteImages(targets)
                        pruning = false
                        if let first = failures.first {
                            if failures.count == 1 {
                                pruneError = "Prune failed for \(first.reference): \(first.error)"
                            } else {
                                pruneError = """
                                    Prune failed for \(failures.count) of \(targets.count) images.

                                    First error: \(first.error)
                                    """
                            }
                        }
                        await model.refreshImages()
                    }
                }
                .disabled(pruneCandidates.isEmpty || pruning)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ row: HostedImage) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = row
        } else {
            Task { await model.removeImage(row.image, host: row.host) }
        }
    }

    /// `ContainerImage` has no separate repository/tag fields — `reference` is one string
    /// like `docker.io/library/nginx:latest`. Split it here for display only; the last
    /// `:` after the last `/` is the tag (so a registry port, e.g. `host:5000/name`,
    /// isn't mistaken for one).
    fileprivate nonisolated static func split(_ reference: String) -> (repository: String, tag: String) {
        // A digest is not a tag. `kindest/node@sha256:<64 hex>` used to split at the digest's own
        // colon, giving the repository "kindest/node@sha256" and a 64-character "tag" — which, as
        // a card's badge, filled the window (5 October). Split at `@` first; a reference with a
        // tag as well keeps the tag, and one with only a digest shows its short form.
        if let at = reference.firstIndex(of: "@") {
            let named = split(String(reference[..<at]))
            let digest = reference[reference.index(after: at)...]
            let hex = digest.split(separator: ":").last.map(String.init) ?? String(digest)
            let hasTag = reference[..<at].lastIndex(of: ":").map { colon in
                !reference[reference.index(after: colon)..<at].contains("/")
            } ?? false
            return (named.repository, hasTag ? named.tag : "@" + hex.prefix(12))
        }
        let searchStart = reference.lastIndex(of: "/").map { reference.index(after: $0) } ?? reference.startIndex
        guard let colon = reference[searchStart...].lastIndex(of: ":") else {
            return (reference, "latest")
        }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    nonisolated static func repository(_ image: ContainerImage) -> String { split(image.reference).repository }

    /// How a row names an image: the reference as you would type it, with Docker Hub's implied
    /// `docker.io/library/` left off the way `docker images` prints it — `nginx:alpine`, not
    /// `docker.io/library/nginx:alpine`. Any other registry keeps its host, because two `web:v2`
    /// from two registries are two different images. Built from `split`, so a digest-only
    /// reference reads `name@1a2b…` as the Tag column did.
    nonisolated static func displayName(_ image: ContainerImage) -> String {
        let (repository, tag) = split(image.reference)
        var name = Substring(repository)
        for prefix in ["docker.io/library/", "docker.io/"] where name.hasPrefix(prefix) {
            name = name.dropFirst(prefix.count)
            break
        }
        return tag.hasPrefix("@") ? name + tag : name + ":" + tag
    }
    nonisolated static func tag(_ image: ContainerImage) -> String { split(image.reference).tag }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension ContainerImage {
    /// Reuses `ImagesView.tag`'s own split so the sort agrees with what the Tag column
    /// actually displays, rather than re-deriving the rule and risking drift.
    var tagSortKey: String { ImagesView.tag(self) }

    /// Reuses `ImagesView.platformLabel` for the same reason — the displayed label already
    /// prefers the host architecture and marks multi-arch images, and the sort should match.
    var platformSortKey: String { ImagesView.platformLabel(self) }

    /// The full digest, not the shortened display form — sorting on 12 truncated hex
    /// characters would collide constantly. Missing digests sort first as `""`.
    var digestSortKey: String { configuration.descriptor?.digest ?? "" }

    /// **Unknown is not zero.** An image with no reported size is not a zero-byte image —
    /// coalescing to 0 would file it among genuinely tiny images, which is a different,
    /// misleading claim. `-1` sorts clear of every real size (sizes are never negative)
    /// without pretending to know the answer.
    var sizeSortKey: Int64 { displaySize ?? -1 }

    /// Sortable form of `creationDate`, which the CLI gives as an ISO-8601 *string* that
    /// happens to sort correctly lexicographically. Same rule `Container.creationSortKey`
    /// uses: an absent date sorts last rather than first.
    var creationSortKey: String { configuration.creationDate ?? "9999" }
}

/// What the Run screen opens with: an image reference, on the Mac the image is on.
private struct RunTarget: Hashable {
    let reference: String
    let host: HostRef
}

/// One image on one Mac (PLAN.md Phase C) — the same image on two Macs is two rows, because each
/// is its own thing to run, tag or delete. This Mac's rows keep `ContainerImage.id` as their id,
/// so selection and busy state are unchanged for them.
struct HostedImage: Identifiable {
    let image: ContainerImage
    let host: HostRef
    let hostName: String
    /// A host's row that is older than a fresh answer: shown, with its age, rather than hidden.
    var staleSince: Date? = nil

    var id: String { host.rowID(image.id) }
    /// How the detail screen names the image: by reference, on its Mac.
    var detailKey: String { host.rowID(image.reference) }

    var reference: String { image.reference }
    var tagSortKey: String { image.tagSortKey }
    var platformSortKey: String { image.platformSortKey }
    var digestSortKey: String { image.digestSortKey }
    var sizeSortKey: Int64 { image.sizeSortKey }
    var creationSortKey: String { image.creationSortKey }
}
