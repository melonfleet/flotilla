import SwiftUI
import Foundation
import FlotillaCore

/// The containers section: **the product**.
///
/// Q2 in `DECISIONS.md` made the container list a table; **Q56 amended that**: it is two-line
/// rows now (`ResourceRow`), sortable from a menu, multi-select with a checkbox per row — and the
/// only view: the card grid was scrapped on 17 October. The list is *cross-host* from the outset (a host chip),
/// even though Phase 1 only talks to this Mac: the aggregate view is the differentiator no
/// comparable tool has, and retrofitting a host dimension later is far more painful than
/// carrying it from the start.
///
/// Moved out of `MainWindowView` unchanged when the window became a `NavigationSplitView`
/// (Phase 1 UI contract), then extended here with state filtering, a bulk-action bar, the
/// Created/IP columns, and the detail sheet hook.
struct ContainersView: View {
    let model: AppModel
    /// Held by `MainWindowView` so it outlives this view — see `ContainersUIState`.
    /// Without it, navigating to another section and back reset the user's columns, sort,
    /// filter and search.
    @Bindable var ui: ContainersUIState

    /// What the list is showing. Single-select, and rendered as a **radio group** in the
    /// filter popover.
    ///
    /// This was briefly a multi-select set of checkboxes, matching the Columns menu. Radio is
    /// the better fit and the owner called it: there are exactly three meaningful outcomes and
    /// radio names all three, including `All`. Checkboxes left "All" implicit in *both ticked*
    /// and admitted a fourth, useless state — neither ticked, showing nothing — that then
    /// needed designing around. A control with no degenerate state beats one with a
    /// well-handled degenerate state.
    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .all: "circle.grid.2x2"
            case .running: "play.circle"
            case .stopped: "stop.circle"
            }
        }
    }

    /// What the Sort menu orders the rows by — one per column the old table sorted on.
    ///
    /// A key and a direction rather than a header you click: the rows have no headers. Ties break
    /// on name, so equal rows (every stopped container, every row with no ports) keep a stable,
    /// readable order instead of whatever the sort happened to leave.
    ///
    /// **No CPU or Memory** since the figures left the rows (Q58): a sort on a number the list does
    /// not show reorders the rows under you as the number moves, for a reason you cannot see.
    enum SortKey: String, RowSortKey, Identifiable {
        case name = "Name"
        case state = "State"
        case type = "Type"
        case image = "Image"
        case created = "Created"
        case ports = "Ports"
        case ip = "IP / Network"
        case host = "Host"
        var id: Self { self }

        func comparators(ascending: Bool) -> [KeyPathComparator<ContainerRow>] {
            let order: SortOrder = ascending ? .forward : .reverse
            let byName = KeyPathComparator(\ContainerRow.name)
            switch self {
            case .name: return [KeyPathComparator(\ContainerRow.name, order: order)]
            case .state: return [KeyPathComparator(\ContainerRow.stateRank, order: order), byName]
            case .type: return [KeyPathComparator(\ContainerRow.kindLabel, order: order), byName]
            case .image: return [KeyPathComparator(\ContainerRow.imageSortKey, order: order), byName]
            case .created: return [KeyPathComparator(\ContainerRow.creationSortKey, order: order), byName]
            case .ports: return [KeyPathComparator(\ContainerRow.portSortKey, order: order), byName]
            case .ip: return [KeyPathComparator(\ContainerRow.ipSortKey, order: order), byName]
            case .host: return [KeyPathComparator(\ContainerRow.hostName, order: order), byName]
            }
        }
    }

    @State private var selection = Set<ContainerRow.ID>()

    /// The rows the page beside the list is showing: `selection`, once the form guard has let it
    /// through (`paneFollows`). By row **id** rather than by value, so the page re-reads from the
    /// model on every refresh and shows current state instead of a frozen copy.
    @State private var shown = Set<ContainerRow.ID>()

    /// A menu's request for one container's page on a particular tab — "Logs", "Terminal". The tab
    /// travels with the request rather than through a dictionary the detail view reads once in
    /// `init`, because a request that can be silently dropped is a menu item that sometimes does
    /// nothing; and each request is new (`nonce`), so asking for Logs again after leaving the tab
    /// still lands on it.
    private struct DetailTarget: Hashable {
        let id: String
        var tab: DetailTab?
        var editGroup = false
        let nonce = UUID()
    }
    @State private var request: DetailTarget?
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. A `TagSheetTarget` rather than a
    /// bare `TagSubject` — see that type for why a subject is not `Identifiable`.
    ///
    /// Presented from the view, never from inside the menu: a `.sheet` attached within a `Menu`
    /// never appears, because the menu is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?
    /// Non-nil while a single row's trash button is awaiting confirmation. Destructive
    /// actions confirm with the object *named* (`FEATURES.md`'s destructive-action policy),
    /// which is why this holds the container rather than a bool.
    @State private var confirmingRowDelete: Container?
    @State private var confirmingRemoteDelete: RemoteTarget?
    @State private var showingRun = false
    /// Set when Run was opened from an existing container ("Run Again with Changes…"), and cleared
    /// on dismiss so the next plain Run starts empty.
    @State private var runPrefill: RunPrefill?

    @State private var showingFilter = false

    /// New Group, full width like every other create form, when "+ ▸ New Group…" opened it. An
    /// existing group opens its overview beside the list, with Edit for its draft. Groups live here
    /// since 5 October (to-do item 4).
    @State private var editingGroup: GroupFormTarget?
    /// A group delete awaiting confirmation, and which kind. The owner's rule: a group row's
    /// Delete offers *both* "the group only" and "the group and its containers", and the second
    /// names every container it will remove.
    @State private var pendingGroupDelete: GroupDeleteRequest?

    struct GroupDeleteRequest: Identifiable {
        enum Mode { case ask, groupOnly, withContainers }
        let group: ContainerGroup
        let mode: Mode
        var id: String { group.id }
    }

    /// Embedded, not a sheet, since 9 August — the dimming and the close button went with it.
    private var runScreen: some View {
        RunSheetView(model: model, prefill: runPrefill) {
            showingRun = false
            runPrefill = nil
        }
    }

    /// The page beside the list (Q58): the selected container's detail, a group's overview, a summary
    /// of several, or an empty state.
    ///
    /// It was a slide-in page that replaced the list, with Back and a ‹ › stepper; before that a
    /// sheet, and before that a window. Kamal, 17 October: "the views that we already have for each
    /// item … they'll just show in the right pane instead." So it is the same `ContainerDetailView`
    /// and a live `GroupOverviewView`, with the list beside them.
    ///
    /// Stepping between containers without closing anything is still the workflow persistent
    /// terminal sessions made possible — shells stay alive in `TerminalSessionStore`, so you can
    /// leave a build running in one container, select the next, and come back to it still running.
    /// The detail view keeps its identity as the selection moves, as it did while stepping, so the
    /// tab you are on stays the tab you are on.
    @ViewBuilder
    private var page: some View {
        if let id = shownID {
            rowPage(id)
                .paneStep("item", "items", order: showableIDs, current: id) { select($0) }
                // A new menu request rebuilds the page, so it opens on the tab it asked for.
                .id(request?.nonce)
        } else if shown.count > 1, actionableCount > 0 {
            SelectionSummaryPane(title: "\(selectionNoun) selected", systemImage: "shippingbox",
                                 names: actionableNames) {
                bulkActions
            }
        } else {
            PaneEmptyState(title: "Choose a container", systemImage: "shippingbox",
                           description: "Its state, logs and settings show here.")
        }
    }

    /// The one row the page shows, when there is one and it has a page — resolved against every
    /// row, not the rows on screen (Kyle, 17 October): a filter hides rows in the list, never the
    /// page that's open.
    private var shownRow: ContainerRow? {
        guard shown.count == 1, let id = shown.first,
              let row = rowsByID[id] ?? everyRow.first(where: { $0.id == id }),
              checkUnavailable(row) == nil
        else { return nil }
        return row
    }

    /// The id the page is drawn from. A group's editor is drawn from the id rather than
    /// the row, so a group deleted (or its host forgotten) while its draft has unsaved changes
    /// keeps the form on screen while the guard asks, and after Keep Editing.
    private var shownID: ContainerRow.ID? {
        guard shown.count == 1, let id = shown.first else { return nil }
        return ContainerRow.isGroupRowID(id) || shownRow != nil ? id : nil
    }

    /// Every row with a page, whatever the filters show: what one selected row may be.
    private var existingIDs: Set<ContainerRow.ID> {
        Set(everyRow.filter { checkUnavailable($0) == nil }.map(\.id))
    }

    @ViewBuilder
    private func rowPage(_ id: ContainerRow.ID) -> some View {
        if ContainerRow.isGroupRowID(id) {
            let groupID = ContainerRow.groupID(fromRowID: id)
            GroupOverviewView(model: model, groupID: groupID,
                              initiallyEditing: request?.id == id && request?.editGroup == true,
                              openContainer: { open($0) }) { group in
                groupRowActions(for: group, place: .header)
            }
            .id(groupID)
        } else if let row = shownRow, let container = row.container {
            let tab = request?.id == row.id ? request?.tab : nil
            VStack(spacing: 0) {
                detailHeader(for: container, on: row.host)
                Divider()
                ContainerDetailView(model: model, container: container, host: row.host, requestedTab: tab)
            }
            // Header at the top whatever is below it.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Identity, the lifecycle actions, the stepper and the expand button — the mockup's
    /// `toolbar tall`, without Back: the list is beside it.
    @ViewBuilder
    private func detailHeader(for container: Container, on host: HostRef = .local) -> some View {
        HStack(spacing: 10) {
            if let logo = model.libraryLogo(for: container.imageReference) {
                SuggestionLogo(data: logo, category: nil, size: 32)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(container.id).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Circle().fill(container.stateColor).frame(width: 6, height: 6)
                        Text(container.status.state.capitalized).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                Text(subtitle(for: container, on: host))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle(for: container, on: host))
            }

            Spacer(minLength: 0)

            if host.isLocal {
                ActionCluster { rowActions(for: container, place: .header) }
            } else {
                ActionCluster { remoteRowActions(for: container, on: host, place: .header) }
            }

            DetailStepper()
        }
        // Horizontal 12, vertical 8 — the pair every band under the title bar uses.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func subtitle(for container: Container, on host: HostRef = .local) -> String {
        var parts = [ContainerImage.shortReference(container.imageReference), hostName(host)]
        if AppModel.isRunning(container), let started = container.status.startedDate {
            parts.append(RelativeDate.relative(started, prefix: "up"))
        } else {
            parts.append(RelativeDate.relative(container.configuration.creationDate, prefix: "created"))
        }
        if let ip = container.ipv4 { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    /// Shows a row's page: selects it, and only it. Showing is selecting since the split (Q58), so
    /// every "open" — a menu's Details, Logs or Terminal, the stepper, a request from the menu bar
    /// or the search box — goes through the selection and the form guard with it.
    ///
    /// A row the list is hiding is brought into view first: the filters are cleared and its group
    /// opened, because a page for a row the list cannot show has no place in the list to step from.
    private func open(_ id: ContainerRow.ID, tab: DetailTab? = nil) {
        if !showableIDs.contains(id) {
            ui.search = ""
            ui.filter = .all
            ui.kindFilter = .all
            ui.hostFilter = nil
            if let group = model.groups.groups.first(where: { g in g.memberNames.contains { g.place.rowID($0) == id } }) {
                ui.expandedGroupIDs.insert(group.id)
            }
        }
        request = tab.map { DetailTarget(id: id, tab: $0) }
        select(id)
    }

    /// The stepper's move, and `open`'s last step.
    private func select(_ id: ContainerRow.ID) {
        selection = [id]
        ui.pane.reveal()
    }

    /// Same icon-and-popover shape as `columnsButton` — both answer "what am I looking at",
    /// so both are a glyph with a menu rather than words spread across the toolbar. The
    /// contents differ because the questions differ: columns are independent (checkboxes),
    /// the state filter is one choice (radio).
    ///
    /// The icon fills when a filter is active, so a hidden state is visible from the toolbar
    /// rather than something you discover by wondering where your containers went.
    /// `IconActionButton`, like every other icon control in the app — **not** a bare `Button`
    /// with an `Image`, which is what this was. That is the difference the owner spotted: the shared
    /// button carries the hover tint and the pressed scale, so a filter button that skipped it had
    /// no shading while the columns button beside it did, on the same band. Same glyph, same
    /// accent-when-active rule, same feedback, everywhere.
    private var filterButton: some View {
        let filtering = ui.filter != .all || ui.kindFilter != .all || ui.hostFilter != nil
        return IconActionButton(systemImage: "line.3.horizontal.decrease",
                                label: "Filter",
                                help: filtering ? filterSummary : "Filter by state, kind or host",
                                active: filtering) {
            showingFilter.toggle()
        }
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            // Two radio groups, because they are two independent questions: *what state* and
            // *what kind*. The kind filter is what lets the merged list collapse back to just
            // groups, or just containers — which covers what the separate Groups screen gave.
            VStack(alignment: .leading, spacing: 10) {
                Text("State").font(.caption).foregroundStyle(.secondary)
                Picker("State", selection: $ui.filter) {
                    ForEach(Filter.allCases) { option in
                        Label(option.rawValue, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Divider()
                Text("Show").font(.caption).foregroundStyle(.secondary)
                Picker("Show", selection: $ui.kindFilter) {
                    Label("Groups and containers", systemImage: "square.grid.2x2").tag(ContainerListing.KindFilter.all)
                    Label("Groups only", systemImage: Section.groupSymbol).tag(ContainerListing.KindFilter.groups)
                    Label("Containers only", systemImage: "shippingbox").tag(ContainerListing.KindFilter.containers)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !model.hostMode.hosts.filter(\.isTrusted).isEmpty {
                    Divider()
                    Text("Host").font(.caption).foregroundStyle(.secondary)
                    Picker("Host", selection: $ui.hostFilter) {
                        Label("All hosts", systemImage: "square.stack").tag(HostRef?.none)
                        Label(model.hostLabel, systemImage: "laptopcomputer").tag(HostRef?.some(.local))
                        ForEach(model.hostMode.hosts.filter(\.isTrusted)) { peer in
                            Label(peer.displayName, systemImage: "desktopcomputer")
                                .tag(HostRef?.some(.peer(peer.fingerprint)))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            .padding(14)
        }
    }

    /// The filter button's tooltip while a filter is on, so a hidden row is explained from the
    /// toolbar rather than discovered by wondering where it went.
    private var filterSummary: String {
        var parts: [String] = []
        if ui.filter != .all { parts.append(ui.filter.rawValue.lowercased()) }
        switch ui.kindFilter {
        case .all: break
        case .groups: parts.append("groups only")
        case .containers: parts.append("containers only")
        }
        if let host = ui.hostFilter { parts.append("on " + hostName(host)) }
        return "Showing " + parts.joined(separator: ", ")
    }

    /// The state filter in the shared listing's terms.
    private var stateFilter: ContainerListing.StateFilter {
        switch ui.filter {
        case .all: .all
        case .running: .running
        case .stopped: .stopped
        }
    }

    /// The search text (typed in the window bar's box), read as `SearchQuery`'s grammar: `is:`, `image:`, `host:`, `tag:` and words.
    private var query: SearchQuery { SearchQuery.parse(ui.search) }

    /// The state to list: the filter menu's, narrowed by `is:`. The two together must agree — Running
    /// in the menu and `is:stopped` typed lists nothing, which is what both together say.
    private var effectiveState: ContainerListing.StateFilter? {
        guard let typed = query.state else { return stateFilter }
        let wanted: ContainerListing.StateFilter = typed == .running ? .running : .stopped
        return stateFilter == .all || stateFilter == wanted ? wanted : nil
    }

    /// This Mac's names a `host:` word can match: its computer name, its label, and "this mac".
    private var localHostNames: [String] { [HostModeController.computerName, model.hostLabel, "This Mac"] }

    /// Which rows exist at all: standalone containers and groups, with each group's members,
    /// through the kind, state and search filters. The rules — a grouped container appears only
    /// inside its group, a partly running group is under both Running and Stopped — live in
    /// `ContainerListing`, where tests pin them.
    private var listing: [ContainerListing.Item] { listing(on: .local) }

    /// The same for one Mac: its standalone containers and the groups that run on it (groups on
    /// hosts, the owner, 12 October). A host's container tags are keyed by host and name.
    private func listing(on host: HostRef, filtered: Bool = true) -> [ContainerListing.Item] {
        guard filtered else {
            return ContainerListing.items(containers: model.containers(on: host),
                                          groups: model.groups.groups.filter { $0.place == host },
                                          kind: .all, state: .all)
        }
        let query = query
        let names: [String] = switch host {
        case .local: localHostNames
        case .peer(let fingerprint):
            model.hostMode.hosts.first { $0.fingerprint == fingerprint }.map { [$0.displayName, $0.details.computerName] } ?? []
        }
        guard let state = effectiveState, SearchQuery.all(query.hosts, in: names) else { return [] }
        let containers = model.containers(on: host)
        let groups = model.groups.groups.filter { $0.place == host }
        guard !query.isEmpty else {
            return ContainerListing.items(containers: containers, groups: groups,
                                          kind: ui.kindFilter, state: state)
        }
        // **Tag names are searchable too, on every section.** This is how tags filter: one line
        // per section, the same everywhere, and it composes with whatever filter is already on.
        // `is:` is applied as the state above; `host:` above.
        return ContainerListing.items(
            containers: containers, groups: groups,
            kind: ui.kindFilter, state: state,
            containerMatches: { container in
                let tags = model.tags.tags(on: .container, host.rowID(container.id)).map(\.name)
                return SearchQuery.all(query.images, in: [container.imageReference])
                    && SearchQuery.all(query.tags, in: tags)
                    && query.termsMatch([container.id, container.status.state, container.imageReference] + names + tags)
            },
            groupMatches: { group in
                let tags = model.tags.tags(on: .group, group.id).map(\.name)
                return SearchQuery.all(query.images, in: group.members.map(\.image))
                    && SearchQuery.all(query.tags, in: tags)
                    && query.termsMatch([group.name] + names + tags)
            },
            memberMatches: { member in
                let tags = model.tags.tags(on: .container, host.rowID(member.name)).map(\.name)
                return SearchQuery.all(query.images, in: [member.image])
                    && SearchQuery.all(query.tags, in: tags)
                    && query.termsMatch([member.name, member.image] + names + tags)
            })
    }

    /// The rows the list shows, in order: each top-level row, followed by its members when the
    /// group is open. See `sortedRows`.
    private var rows: [ContainerRow] { sortedRows }

    /// The containers on screen, in on-screen order — standalone ones and the members of open
    /// groups. The detail stepper walks this, so "next" is always the next container you can see.
    private var sorted: [Container] { rows.compactMap(\.container) }

    /// Whether anything the user chose is hiding rows, so an empty state can say so.
    private var isFiltered: Bool {
        !ui.search.isEmpty || ui.filter != .all || ui.kindFilter != .all || ui.hostFilter != nil
    }

    private func hostName(_ host: HostRef) -> String {
        switch host {
        case .local: model.hostLabel
        case .peer(let fingerprint): model.hostMode.hosts.first { $0.fingerprint == fingerprint }?.displayName ?? "a host"
        }
    }

    /// What a bulk action may actually touch: the selection **intersected with the selectable
    /// rows on screen**. `.selection(_:confinedTo:)` keeps `selection` to the same set, so the two
    /// agree once it has run; every bulk path still acts on this, never `selection`, so a frame in
    /// between cannot act on a row that has just gone.
    private var actionable: Set<ContainerRow.ID> { selection.intersection(selectableIDs) }

    /// The groups in the actionable selection.
    private var actionableGroups: [ContainerGroup] {
        model.groups.groups.filter { actionable.contains(ContainerRow.groupRowID($0.id)) }
    }

    /// The containers in the actionable selection: standalone rows and existing members. A
    /// member of a selected group is left out, so selecting a group and one of its members does
    /// not start that member twice.
    private var actionableContainerIDs: Set<Container.ID> {
        // This Mac's groups only: a host's group member shares a name, not a container, with this Mac's.
        let ownedBySelectedGroups = Set(actionableGroups.filter { $0.place.isLocal }.flatMap(\.memberNames))
        let existing = Set(model.containers.map(\.id))
        return Set(actionable.filter { !ContainerRow.isGroupRowID($0) })
            .intersection(existing)
            .subtracting(ownedBySelectedGroups)
    }

    /// True while any actionable container has an action in flight, so a second click cannot
    /// fire a duplicate operation on top of the first.
    private var selectionBusy: Bool { model.isAnyBusy(actionableContainerIDs, kind: .container) }

    /// Other Macs' containers in the actionable selection. Acted on host by host, after this Mac's.
    private var actionableRemote: [ContainerRow] { remoteRows(in: actionable, besides: actionableGroups) }

    /// Other Macs' container rows among `ids`, leaving out members of `groups` — a selected
    /// group acts on its own members, so they must not be acted on twice (Kyle, 12 October).
    private func remoteRows(in ids: Set<ContainerRow.ID>, besides groups: [ContainerGroup]) -> [ContainerRow] {
        let groupIDs = Set(groups.map(\.id))
        return ids.compactMap { rowsByID[$0] }.filter { row in
            !row.host.isLocal && row.container != nil && !(row.group.map { groupIDs.contains($0.id) } ?? false)
        }
    }

    /// Runs one action on each remote row, in order — a host does one thing at a time per row.
    private func performRemote(_ action: AppModel.Action, on rows: [ContainerRow],
                               where applies: (Container) -> Bool = { _ in true }) async {
        for row in rows {
            guard let container = row.container, applies(container) else { continue }
            await model.perform(action, on: container, host: row.host)
        }
    }

    /// The names the page's summary lists: the same de-duplicated set the count and the actions
    /// take, in list order. A member of a selected group is acted on through its group, so it is
    /// named once, as the group — listing it as well said "1 group" over two names (Kyle, 17 October).
    private var actionableNames: [String] {
        let groups = Set(actionableGroups.map { ContainerRow.groupRowID($0.id) })
        let remote = Set(actionableRemote.map(\.id))
        let local = actionableContainerIDs
        return rows.filter { row in
            guard actionable.contains(row.id) else { return false }
            if row.kind == .group { return groups.contains(row.id) }
            guard let container = row.container else { return false }
            return row.host.isLocal ? local.contains(container.id) : remote.contains(row.id)
        }.map(\.name)
    }

    /// What the bulk bar would count. It shows only above zero: a selection with nothing a bulk
    /// action can take is no selection, and "0 containers selected" was the bar saying so.
    private var actionableCount: Int {
        actionableContainerIDs.count + actionableRemote.count + actionableGroups.count
    }

    /// How the bulk bar and the bulk menu describe the selection: "3 containers", "1 group",
    /// "2 containers and 1 group".
    private var selectionNoun: String {
        let c = actionableContainerIDs.count + actionableRemote.count, g = actionableGroups.count
        let containers = "\(c) container\(c == 1 ? "" : "s")"
        let groups = "\(g) group\(g == 1 ? "" : "s")"
        switch (c, g) {
        case (_, 0): return containers
        case (0, _): return groups
        default: return "\(containers) and \(groups)"
        }
    }

    /// A container's actions: on its row, start or stop and `⋮`; in its page's header, Restart and
    /// the bin as well.
    ///
    /// Rules this follows deliberately:
    /// - **On the row, on hover** (Kamal, 17 October), like Mail. This used to be "always visible,
    ///   never hover-revealed", for `research/FEATURES.md`'s accessibility baseline; `ResourceRow`
    ///   now keeps that baseline another way — a selected row shows them, VoiceOver always sees
    ///   them, and every one is in the right-click menu and the page header too.
    /// - **Labelled.** Icon-only buttons carry `accessibilityLabel` plus `help` — a glyph with
    ///   no name is invisible to VoiceOver and ambiguous to everyone else.
    /// - **Start and Stop swap, they do not both show.** Offering Stop on a stopped container
    ///   would be a control that does nothing, which is the failure mode this whole pass is
    ///   about.
    @ViewBuilder
    private func rowActions(for container: Container, place: RowActionPlace = .row) -> some View {
        let busy = model.isBusy(container.id, kind: .container)
        let running = AppModel.isRunning(container)

        HStack(spacing: 2) {
            if running {
                iconButton("stop.fill", "Stop \(container.id)", busy: busy) {
                    Task { await model.perform(.stop, on: container) }
                }
                if place == .header {
                    iconButton("arrow.clockwise", "Restart \(container.id)", busy: busy) {
                        Task { await model.perform(.restart, on: container) }
                    }
                }
            } else {
                iconButton("play.fill", "Start \(container.id)", busy: busy) {
                    Task { await model.perform(.start, on: container) }
                }
            }

            // The **same** builder the right-click menu uses. It used to be its own two-item
            // menu — Details and Copy — so the three dots and a right-click on the same row
            // offered different things, and everything in between (Logs, Terminal, Inspect, Run
            // Again, Force Kill, Delete) was reachable only by right-click. Two menus for one row
            // is two menus to keep in step, and they had already drifted.
            RowOverflowMenu(label: "More actions for \(container.id)") {
                actions(for: container)
            }

            if place == .header {
                Divider().frame(height: 14)

                iconButton("trash", "Delete \(container.id)", busy: busy, destructive: true) {
                    requestDelete(container)
                }
            }
        }
    }

    /// A paired host's container: the same controls in the same places as This Mac's — start or
    /// stop, restart, the menu, delete — acting on that host.
    @ViewBuilder
    private func remoteRowActions(for container: Container, on host: HostRef, place: RowActionPlace = .row) -> some View {
        let busy = model.isBusy(host.rowID(container.id), kind: .container)
        let running = AppModel.isRunning(container)
        HStack(spacing: 2) {
            if running {
                iconButton("stop.fill", "Stop \(container.id) on \(hostName(host))", busy: busy) {
                    Task { await model.perform(.stop, on: container, host: host) }
                }
                if place == .header {
                    iconButton("arrow.clockwise", "Restart \(container.id) on \(hostName(host))", busy: busy) {
                        Task { await model.perform(.restart, on: container, host: host) }
                    }
                }
            } else {
                iconButton("play.fill", "Start \(container.id) on \(hostName(host))", busy: busy) {
                    Task { await model.perform(.start, on: container, host: host) }
                }
            }
            RowOverflowMenu(label: "More actions for \(container.id) on \(hostName(host))") {
                remoteActions(for: container, on: host)
            }

            if place == .header {
                Divider().frame(height: 14)

                iconButton("trash", "Delete \(container.id) on \(hostName(host))", busy: busy, destructive: true) {
                    if model.deletePolicy.requiresConfirmation(.single) {
                        confirmingRemoteDelete = RemoteTarget(container: container, host: host)
                    } else {
                        Task { await model.perform(.delete, on: container, host: host) }
                    }
                }
            }
        }
    }

    /// The menu for a paired host's container: the lifecycle, tags and Copy, as This Mac's has.
    /// Items that open this Mac's own tools — Terminal, Files, Run Again — are not offered.
    @ViewBuilder
    private func remoteActions(for container: Container, on host: HostRef) -> some View {
        let busy = model.isBusy(host.rowID(container.id), kind: .container)
        let running = AppModel.isRunning(container)
        Button("Start") { Task { await model.perform(.start, on: container, host: host) } }
            .disabled(running || busy)
        Button("Stop") { Task { await model.perform(.stop, on: container, host: host) } }
            .disabled(!running || busy)
        Button("Restart") { Task { await model.perform(.restart, on: container, host: host) } }
            .disabled(!running || busy)
        Button("Force Kill") { Task { await model.perform(.kill, on: container, host: host) } }
            .disabled(!running || busy)
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .container, id: host.rowID(container.id))) {
            tagSheet = TagSheetTarget(kind: .container, id: host.rowID(container.id))
        }
        Divider()
        CopyMenu([
            ("Name", container.id),
            ("Image", container.configuration.image.reference),
            ("Ports", container.portSummary),
            ("Host", hostName(host)),
        ])
        Divider()
        Button("Delete…", role: .destructive) {
            confirmingRemoteDelete = RemoteTarget(container: container, host: host)
        }
        .disabled(busy)
    }

    struct RemoteTarget: Identifiable {
        let container: Container
        let host: HostRef
        var id: String { host.rowID(container.id) }
    }

    /// Every single-container delete enters here, and `model.deletePolicy` is the only thing that
    /// decides whether it stops to ask. Containers previously ignored
    /// `confirmDestructiveActions` entirely: the trash button confirmed unconditionally, the
    /// context menu never confirmed at all, and the preference governed neither.
    private func requestDelete(_ container: Container) {
        if model.deletePolicy.requiresConfirmation(.single) {
            confirmingRowDelete = container
        } else {
            Task { await model.perform(.delete, on: container) }
        }
    }

    /// `label` names the row — "Stop web", not "Stop" — and is both what VoiceOver reads and the
    /// tooltip, the shape `MachinesView` already had. A bare verb was announced identically on
    /// every row, so nobody listening could tell which container a button acted on.
    private func iconButton(
        _ symbol: String, _ label: String,
        busy: Bool, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        // Delegates to the shared button so the containers rows, the machines rows and the
        // section toolbars all give the same feedback. See `IconActionButton`.
        IconActionButton(systemImage: symbol, label: label, help: label,
                         busy: busy, destructive: destructive, action: action)
    }

    /// The context menu for a right-click that landed on one or more rows.
    ///
    /// `ids` comes from the list itself, so everything in it is on screen by construction —
    /// this is the one bulk path that does not need intersecting with what is visible.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<ContainerRow.ID>) -> some View {
        if ids.isEmpty {
            // Right-click on empty space still deserves the primary actions rather than an
            // empty menu that looks like a bug — the same two the toolbar's "+" offers.
            addMenuItems
        } else if ids.count == 1, let id = ids.first, let row = rowsByID[id] {
            switch row.kind {
            case .group:
                if let group = row.group { groupMenu(for: group) }
            case .container, .member:
                if let container = row.container, !row.host.isLocal {
                    remoteActions(for: container, on: row.host)
                } else if let container = row.container {
                    actions(for: container)
                } else if let group = row.group {
                    // A member not created yet: its group is the thing you can act on.
                    groupMenu(for: group)
                }
            }
        } else {
            let groups = model.groups.groups.filter { ids.contains(ContainerRow.groupRowID($0.id)) }
            // This Mac's containers by name, less the members of selected local groups; other
            // Macs' rows by host, as the bulk bar does it (Kyle, 12 October: a mixed selection
            // used to act on This Mac's alone).
            let ownedLocally = Set(groups.filter { $0.place.isLocal }.flatMap(\.memberNames))
            let containers = Set(ids.filter { !ContainerRow.isGroupRowID($0) })
                .intersection(Set(model.containers.map(\.id)))
                .subtracting(ownedLocally)
            let remote = remoteRows(in: ids, besides: groups)
            let busy = model.isAnyBusy(containers, kind: .container)
            Button("Start \(ids.count)") {
                Task {
                    await startSelected(containers, groups)
                    await performRemote(.start, on: remote) { !$0.isRunning }
                }
            }
            .disabled(busy)
            Button("Stop \(ids.count)") {
                Task {
                    await stopSelected(containers, groups)
                    await performRemote(.stop, on: remote) { $0.isRunning }
                }
            }
            .disabled(busy)
            Button("Restart \(ids.count)") {
                Task {
                    await restartSelected(containers, groups)
                    await performRemote(.restart, on: remote) { $0.isRunning }
                }
            }
            .disabled(busy)
            Divider()
            Button("Delete \(ids.count)…", role: .destructive) {
                selection = ids            // so the confirmation counts what was right-clicked
                confirmingBulkDelete = true
            }
            .disabled(busy)
        }
    }

    private func openNewGroupFromMenu() {
        model.pendingGroupForm = false
        showingRun = false
        editingGroup = .new
    }

    /// "Run Container…" and "New Group…": the two ways to add to this list, in the toolbar's "+"
    /// menu, the empty-space right-click and the empty state alike.
    @ViewBuilder
    private var addMenuItems: some View {
        Button("Run Container…") { showingRun = true }
        Button("New Group…") { editingGroup = .new }
        Divider()
        Button("Suggestions…") { model.requestSuggestionsTab(.apps, host: ui.hostFilter) }
    }

    private var rowsByID: [ContainerRow.ID: ContainerRow] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Bulk lifecycle across containers and groups

    /// Containers first, then groups, each the way its own row would do it. A group is started
    /// with its own ordered start (`startGroup`), never as a bag of containers, because order is
    /// the one thing a group is for.
    private func startSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.start, on: containers) }
        if !groups.isEmpty { await model.startGroups(groups.filter(canStart)) }
    }

    private func stopSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.stop, on: containers) }
        if !groups.isEmpty { await model.stopGroups(groups.filter(canStop)) }
    }

    private func restartSelected(_ containers: Set<Container.ID>, _ groups: [ContainerGroup]) async {
        if !containers.isEmpty { await model.performBulk(.restart, on: containers) }
        for group in groups where canStop(group) { await model.restartGroup(group) }
    }

    // MARK: Group rows

    private func canStart(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return model.canReach(group) && state != .empty && state != .running
    }

    private func canStop(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return model.canReach(group) && state != .empty && state != .stopped && state != .notCreated
    }

    /// A group's actions. In its page's header, Start and Stop together, then the overflow, then
    /// the bin — both lifecycle buttons rather than one that swaps, because a partly running group
    /// needs both. On its row, on hover, one of them, as a container's row has: Stop while anything
    /// in it is running, Start otherwise; the other is in `⋮`.
    @ViewBuilder
    private func groupRowActions(for group: ContainerGroup, place: RowActionPlace = .row) -> some View {
        HStack(spacing: 2) {
            // Labels name the group, as the retired Groups screen's did: VoiceOver reads the label,
            // and a row of buttons all called "Delete" does not say which row they act on.
            if place == .header || !canStop(group) {
                IconActionButton(systemImage: "play.fill", label: "Start \(group.name)",
                                 help: model.state(of: group) == .empty
                                     ? "Add a service before starting this group"
                                     : "Start every service in \(group.name)",
                                 disabled: !canStart(group)) {
                    Task { await model.startGroup(group) }
                }
            }
            if place == .header || canStop(group) {
                IconActionButton(systemImage: "stop.fill", label: "Stop \(group.name)",
                                 help: "Stop every running service in \(group.name)",
                                 disabled: !canStop(group)) {
                    Task { await model.stopGroup(group) }
                }
            }

            if place == .header {
                IconActionButton(systemImage: "arrow.clockwise", label: "Restart \(group.name)",
                                 help: "Restart every service in \(group.name)", disabled: !canStop(group)) {
                    Task { await model.restartGroup(group) }
                }
            }

            // The **same** builder the right-click menu uses, which `check-menu-parity.sh` holds
            // every row to.
            RowOverflowMenu(label: "More actions for \(group.name)") {
                groupMenu(for: group)
            }

            if place == .header {
                Divider().frame(height: 14)

                // The bin asks which delete you mean; the menu names each one directly.
                IconActionButton(systemImage: "trash", label: "Delete \(group.name)",
                                 help: "Delete \(group.name)", destructive: true) {
                    pendingGroupDelete = GroupDeleteRequest(group: group, mode: .ask)
                }
            }
        }
    }

    /// A group row's menu, shared by its `⋯` and a right-click.
    @ViewBuilder
    private func groupMenu(for group: ContainerGroup) -> some View {
        // Editing is explicit; selecting the row opens its live overview.
        Button("Edit…") {
            model.formGuard.confirmLeaving {
                let id = ContainerRow.groupRowID(group.id)
                open(id)
                request = DetailTarget(id: id, tab: nil, editGroup: true)
            }
        }
        Divider()
        Button("Start") { Task { await model.startGroup(group) } }
            .disabled(!canStart(group))
        Button("Stop") { Task { await model.stopGroup(group) } }
            .disabled(!canStop(group))
        Button("Restart") { Task { await model.restartGroup(group) } }
            .disabled(!canStop(group))
        Divider()
        // Q29: the group, its network and the volumes it mounts, as a file to share.
        Button("Save to File…") { Task { await model.saveGroupToFile(group) } }
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .group, id: group.id)) {
            tagSheet = TagSheetTarget([TagSubject(kind: .group, id: group.id)])
        }
        Divider()
        CopyMenu([
            ("Name", group.name),
            ("Services", group.members.isEmpty ? nil : group.memberNames.joined(separator: " ")),
            ("Images", group.members.isEmpty ? nil : group.members.map(\.image).joined(separator: " ")),
            ("Network", group.network ?? "default"),
        ])
        Divider()
        // Two deletes, named for exactly what each removes (the owner, 5 October).
        Button("Delete Group…", role: .destructive) {
            pendingGroupDelete = GroupDeleteRequest(group: group, mode: .groupOnly)
        }
        Button("Delete Group and Containers…", role: .destructive) {
            pendingGroupDelete = GroupDeleteRequest(group: group, mode: .withContainers)
        }
        .disabled(existingMembers(of: group).isEmpty)
    }

    /// The members of a group that exist as containers right now — what "Delete Group and
    /// Containers" would remove.
    private func existingMembers(of group: ContainerGroup) -> [String] {
        let existing = model.existingContainerNames(on: group.place)
        return group.memberNames.filter(existing.contains)
    }

    /// Start/stop/restart/delete for one container: the row's `⋯` and its right-click, from one
    /// definition, so the two cannot offer different things.
    @ViewBuilder
    private func actions(for container: Container) -> some View {
        let busy = model.isBusy(container.id, kind: .container)
        let running = AppModel.isRunning(container)
        Button("Details…") { open(container.id) }

        // Jump straight to the tab you actually wanted. The machines menu has done this since
        // "Edit Settings…" existed; containers offered Details and left you to find the tab, on
        // the screen with the most tabs. Logs and Terminal are the two people go looking for.
        Button("Logs") { open(container.id, tab: .logs) }
        Button("Terminal") { open(container.id, tab: .terminal) }
            // A shell needs a running process to attach to.
            .disabled(!running)
        Button("Inspect") { open(container.id, tab: .inspect) }

        Divider()
        // Every lifecycle item, always, with the ones that do not apply greyed out rather than
        // absent — the rule the status bar's runtime menu follows, in the same order, and carried here
        // so containers and machines answer a right-click the same way. The old shape showed
        // Stop/Restart/Force Kill *or* Start, so which item sat under the pointer depended on the
        // row you happened to open it on.
        Button("Start") { Task { await model.perform(.start, on: container) } }
            .disabled(running || busy)
        Button("Stop") { Task { await model.perform(.stop, on: container) } }
            .disabled(!running || busy)
        Button("Restart") { Task { await model.perform(.restart, on: container) } }
            .disabled(!running || busy)
        // Below Stop and Restart, and named plainly. For the container that ignores its stop
        // signal, the only alternative used to be deleting it.
        Button("Force Kill") { Task { await model.perform(.kill, on: container) } }
            .disabled(!running || busy)

        // The nearest thing to "Edit Settings…" that the CLI can actually back. There is no
        // `container update`: a container's configuration is fixed at creation, so the only way to
        // change one is to create another. This opens Run prefilled from this container — see
        // `RunPrefill` for what it carries and what it deliberately does not.
        //
        // Named for what it does rather than "Edit Settings…", which would promise an edit. It
        // does not delete the original; that stays a separate, confirmed decision.
        Button("Run Again with Changes…") {
            // Host ports every *other* container already publishes. The source's own ports count
            // too while it is still running, which is the whole point: copying them verbatim
            // produced a container that could not bind and died immediately.
            let taken = Set(model.containers
                                 .filter { $0.isRunning }
                                 .flatMap { $0.publishedPorts.map(\.hostPort) })
            runPrefill = RunPrefill(from: container,
                                    existingNames: Set(model.containers.map(\.id)),
                                    usedHostPorts: taken)
            showingRun = true
        }

        Divider()
        // Tags, in the same place on every row menu in the app: after the things you open and
        // operate on, and before Copy. Not a destructive action, not a read of the runtime — it
        // changes how the row looks to you and nothing about what it is.
        TagMenu(store: model.tags, subject: TagSubject(kind: .container, id: container.id)) {
            tagSheet = TagSheetTarget(kind: .container, id: container.id)
        }

        Divider()
        // Containers were the **only** section without this. Machines, volumes, networks and
        // images all offer it, and the ids and ports here are the most copied values in the app.
        CopyMenu([
            ("Name", container.id),
            ("Image", container.configuration.image.reference),
            // The same two labels the table renders, not a second derivation of them —
            // `portSummary` lives on the model and `ipNetworkLabel` is this view's own.
            ("Ports", container.portSummary),
            ("IP / Network", Self.ipNetworkLabel(container)),
            // Carried over from `CopyMenu.forContainer`, which the old cards used until this menu
            // became the single definition. It is the one entry that list had and this one did
            // not, and the useful form is something you can paste into a browser rather than the
            // mapping. Dropped by `CopyMenu` when the container publishes no ports.
            ("Port URL", container.publishedPorts.first.map { "http://localhost:\($0.hostPort)" }),
        ])
        Divider()
        // Destructive, and deliberately only in the main window — never the popover.
        //
        // This used to call `model.perform(.delete, …)` directly, so right-click → Delete destroyed
        // a container **with no dialog at all** while the row's trash button two lines away always
        // asked. Not in the audit; found while centralising the decision, which is the argument for
        // centralising it — the inconsistency was invisible until the five call sites were read
        // side by side.
        Button("Delete", role: .destructive) { requestDelete(container) }
            .disabled(busy)
    }

    /// The tab a `requestDetail` asked for, resolved against **this** screen's own tab type.
    ///
    /// A title this screen does not have resolves to nil and the detail opens on its default tab,
    /// which is the point of carrying a title rather than an index: a request naming a tab only
    /// the other detail screen has can never land on an arbitrary third one.
    private var requestedTab: DetailTab? {
        model.pendingDetailTab.flatMap(DetailTab.init(rawValue:))
    }

    var body: some View {
        Group {
            if showingRun {
                runScreen
            } else if let target = editingGroup {
                // Embedded, like every other create form (`CLAUDE.md`, 9 August).
                GroupFormView(model: model, target: target) { editingGroup = nil }
            } else {
                // Q58: the list, and the selected row's page beside it.
                SplitPanes(list: "containers", pane: ui.pane, showing: shownID) {
                    VStack(spacing: 0) {
                        toolbar
                        bulkActionBar
                        Divider()
                        // apple/container#2051: a network that has lost its bridge (Q30).
                        DisconnectedNetworksBanner(model: model)
                        UnpublishedPortsBanner(model: model) { open(ContainerRow.groupRowID($0.id)) }
                        content
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } detail: {
                    page
                }
            }
        }
        // Paired hosts' containers kept current while this section is open — each host on its own
        // schedule, backing off one that does not answer (PLAN.md Phase C).
        .task {
            while !Task.isCancelled {
                await model.hostMode.refreshLiveStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        // "Open in Flotilla" from the menu-bar popover names a subject, not just a section.
        // One-shot: cleared on consumption so a rebuild does not reopen it.
        .onChange(of: model.pendingDetailSubject) { _, subject in
            // Only this section's own requests — containers, and since 5 October groups, which
            // the menu bar names by name. See `AppModel.requestDetail`.
            guard let subject else { return }
            consumeDetailRequest(subject)
        }
        .onAppear {
            if let subject = model.pendingDetailSubject { consumeDetailRequest(subject) }
        }
        // "Run…" in the menu-bar popover. One-shot: consumed and cleared, so the sheet does
        // not reopen every time this view is rebuilt.
        .onChange(of: model.pendingRunSheet) { _, requested in
            if requested { showingRun = true; model.pendingRunSheet = false }
        }
        // A container Greta drafted (Q52): the Run form, filled in, for the user to review.
        .onChange(of: model.pendingRunPrefill) { _, draft in
            if let draft { runPrefill = draft; showingRun = true; model.pendingRunPrefill = nil }
        }
        .onAppear {
            if model.pendingRunSheet { showingRun = true; model.pendingRunSheet = false }
            if let draft = model.pendingRunPrefill { runPrefill = draft; showingRun = true; model.pendingRunPrefill = nil }
        }
        // File ▸ New Group…. One-shot, like the run sheet.
        .onChange(of: model.pendingGroupForm) { _, requested in
            if requested { openNewGroupFromMenu() }
        }
        .onAppear {
            if model.pendingGroupForm { openNewGroupFromMenu() }
        }
        // `actionable` already stops a hidden row from being *acted on*; this stops one
        // from being *counted*. It covers every way the selectable set moves out from under
        // the selection — filter, search, a closed group, the data itself changing (a bulk
        // delete leaves the dead ids behind otherwise) — and every way a row the bar cannot
        // take gets in: a click, ⇧-click or ⌘A on a member not created yet.
        // `existingIDs`, not the rows on screen: a filter hides rows, never the page that's open.
        .selection($selection, confinedTo: Set(selectableIDs), showing: existingIDs)
        .paneFollows($selection, into: $shown, guard: model.formGuard, existing: existingIDs)
        // Single-row delete, from the trash button. Names the container — a dialog that just
        // says "are you sure" makes you go back and check which row you clicked.
        .confirmationDialog(
            "Delete “\(confirmingRowDelete?.id ?? "")”?",
            isPresented: Binding(get: { confirmingRowDelete != nil },
                                 set: { if !$0 { confirmingRowDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = confirmingRowDelete {
                    Task { await model.perform(.delete, on: target) }
                }
                confirmingRowDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingRowDelete = nil }
        } message: {
            Text(confirmingRowDelete?.isRunning == true
                 ? "It is running and will be stopped first. This cannot be undone."
                 : "This cannot be undone.")
        }
        .confirmationDialog(
            "Delete “\(confirmingRemoteDelete?.container.id ?? "")” on \(confirmingRemoteDelete.map { hostName($0.host) } ?? "")?",
            isPresented: Binding(get: { confirmingRemoteDelete != nil },
                                 set: { if !$0 { confirmingRemoteDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemoteDelete
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await model.perform(.delete, on: target.container, host: target.host) }
                confirmingRemoteDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoteDelete = nil }
        } message: { target in
            Text(target.container.isRunning
                 ? "It is running on \(hostName(target.host)) and will be stopped first. This cannot be undone."
                 : "This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(selectionNoun)?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectionNoun)", role: .destructive) {
                let containers = actionableContainerIDs, groups = actionableGroups, remote = actionableRemote
                Task {
                    if !containers.isEmpty { await model.performBulk(.delete, on: containers) }
                    for group in groups { model.deleteGroup(group) }
                    await performRemote(.delete, on: remote)
                }
            }
            // Only when groups are in the selection: their containers go too, which the button
            // above deliberately does not do.
            if !actionableGroups.isEmpty, !actionableGroups.flatMap(existingMembers).isEmpty {
                Button("Delete Including the Groups' Containers", role: .destructive) {
                    // Each group's containers on its own Mac; a host group's names never reach
                    // This Mac's delete (Kyle, 12 October: they could delete an unrelated `db`).
                    let groups = actionableGroups, remote = actionableRemote
                    let containers = actionableContainerIDs
                        .union(groups.filter { $0.place.isLocal }.flatMap(existingMembers))
                    Task {
                        await model.performBulk(.delete, on: containers)
                        for group in groups where !group.place.isLocal {
                            await model.deleteContainers(Set(existingMembers(of: group)), of: group)
                        }
                        for group in groups { model.deleteGroup(group) }
                        await performRemote(.delete, on: remote)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(bulkDeleteMessage)
        }
        .confirmationDialog(
            pendingGroupDelete.map(groupDeleteTitle) ?? "",
            isPresented: Binding(get: { pendingGroupDelete != nil },
                                 set: { if !$0 { pendingGroupDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingGroupDelete
        ) { request in
            let members = existingMembers(of: request.group)
            if request.mode != .withContainers {
                Button("Delete Group Only", role: .destructive) {
                    model.deleteGroup(request.group)
                    pendingGroupDelete = nil
                }
            }
            if request.mode != .groupOnly, !members.isEmpty {
                Button("Delete Group and \(members.count) Container\(members.count == 1 ? "" : "s")",
                       role: .destructive) {
                    let group = request.group
                    Task {
                        await model.deleteContainers(Set(members), of: group)
                        model.deleteGroup(group)
                    }
                    pendingGroupDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingGroupDelete = nil }
        } message: { request in
            Text(groupDeleteMessage(request))
        }
    }

    // MARK: Delete wording

    private func groupDeleteTitle(_ request: GroupDeleteRequest) -> String {
        switch request.mode {
        case .withContainers: "Delete the group “\(request.group.name)” and its containers?"
        case .ask, .groupOnly: "Delete the group “\(request.group.name)”?"
        }
    }

    /// Names every container a delete would remove — the owner's condition for offering it.
    private func groupDeleteMessage(_ request: GroupDeleteRequest) -> String {
        let members = existingMembers(of: request.group)
        let keep = "Deleting the group only removes the grouping: its containers stay, as standalone rows, and running ones keep running."
        guard !members.isEmpty else { return keep + " None of its containers exists yet." }
        let named = "This would delete: " + members.joined(separator: ", ") + "."
        let running = members.filter(model.runningContainerNames(on: request.group.place).contains)
        let stopNote = running.isEmpty ? "" : " Running ones are stopped first."
        switch request.mode {
        case .groupOnly: return keep
        case .withContainers: return named + stopNote + " This cannot be undone."
        case .ask: return keep + "\n\nOr delete the containers too. " + named + stopNote + " That cannot be undone."
        }
    }

    private var bulkDeleteMessage: String {
        var parts: [String] = []
        if runningInSelection > 0 {
            parts.append("\(runningInSelection) of the containers \(runningInSelection == 1 ? "is" : "are") running and will be stopped first.")
        }
        if !actionableGroups.isEmpty {
            parts.append("Deleting a group removes only the grouping; its containers stay unless you delete them too.")
        }
        // The Macs, when any is not this one. Groups are This Mac's until Phase D.
        let local = (actionableContainerIDs.isEmpty && actionableGroups.isEmpty) ? [] : [(HostRef.local, model.hostLabel)]
        if let macs = FleetWording.onMacs(local + actionableRemote.map { ($0.host, $0.hostName) }) {
            parts.insert(macs, at: 0)
        }
        parts.append("This cannot be undone.")
        return parts.joined(separator: " ")
    }

    // MARK: Requests and activity

    /// Opens what a menu-bar "Open in Flotilla" named, and clears the request either way — a
    /// request for something since deleted must not wait to be applied to the next one.
    private func consumeDetailRequest(_ subject: String) {
        switch model.pendingDetailKind {
        case .container:
            showingRun = false
            editingGroup = nil
            open(subject, tab: requestedTab)
            model.clearPendingDetail()
        case .group:
            showingRun = false
            editingGroup = nil
            // Palette picks use stable ids; older menu requests can still name a group.
            if let group = model.groups.groups.first(where: { $0.id == subject })
                ?? model.groups.groups.first(where: { $0.name == subject }) {
                open(ContainerRow.groupRowID(group.id))
            }
            model.clearPendingDetail()
        default:
            break
        }
    }

    /// How many of the containers about to be deleted are running.
    private var runningInSelection: Int {
        actionableContainerIDs.compactMap { id in model.containers.first { $0.id == id } }.count { $0.isRunning }
    }

    /// **The shared band, not a copy of it.** This screen used to hand-roll the same
    /// arrangement, and three sections doing that independently is exactly why the owner felt the UI
    /// move as he switched between them. Measured: Activity's search field was 260pt where this
    /// one was 280, and the trailing clusters on Machines and Activity were missing the
    /// `h8/v4 + glassEffect` this one applied — so the same controls sat at different sizes and
    /// different heights on three screens. Worse, Run and Refresh here were raw `Button`s, which
    /// made them the only action controls in the app with no hover or pressed feedback at all.
    ///
    /// One definition owns the padding, the search width, the status slot and the glass cluster
    /// now; each section supplies only what is genuinely its own.
    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search containers and groups…",
                       matches: rows.count,
                       updated: model.lastRefresh,
                       searchHelp: SearchQuery.help,
                       leading: {
            // At the left, above the rows' checkboxes. It covers what is on screen — closed groups'
            // members are not, so it does not reach into them.
            PaneModeButton()
            SelectAllCheckbox(selection: $selection, ids: selectableIDs, noun: "containers and groups")

            // Sort replaces the table's clickable headers, which the rows do not have.
            RowSortMenu(key: $ui.sortKey, ascending: $ui.sortAscending)

            filterButton
        }, trailing: {
            // A menu since groups joined this list (the owner, 5 October): two ways to add to it,
            // under the one glyph that means "add".
            ToolbarIconMenu(systemImage: "plus", label: "Run a container, create a group or use a suggestion") {
                addMenuItems
            }
            ToolbarRefreshButton(label: "Refresh now") {
                Task { await model.reload() }
            }
        })
    }

    /// The selected rows as tag subjects, in the table's own order.
    ///
    /// Built from `actionable`, not from `selection`: filtering does not clear a table's
    /// selection, so a row you selected and then filtered away is still in the set — and tagging
    /// something the user cannot see is the same mistake the bulk delete bars guard against.
    private var selectedTagSubjects: [TagSubject] {
        actionableContainerIDs.sorted().map { TagSubject(kind: .container, id: $0) }
            + actionableGroups.map { TagSubject(kind: .group, id: $0.id) }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        // 2+, as the page's summary is (Kamal, 17 October, round 2): one row is its page, which
        // has that row's actions. And only while that summary is not on screen — `BulkActionBar`.
        if selection.count > 1, actionableCount > 0 {
            BulkActionBar(title: "\(selectionNoun) selected") { bulkActions }
        }
    }

    /// What a selection can do: the bulk bar's controls, and the page's when several are ticked.
    /// One builder, so the two cannot offer different things.
    @ViewBuilder
    private var bulkActions: some View {
        // Tags first in the cluster, before the lifecycle controls: it is the one action here
        // that changes nothing about what the selection *is*.
        BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
            tagSheet = TagSheetTarget(selectedTagSubjects)
        }
        Divider().frame(height: 14)
        // The rows' glyphs, not words — the same four actions must not look like different
        // controls depending on how many things you selected. A group in the selection is
        // started and stopped the way its own row would do it.
        let containers = actionableContainerIDs, groups = actionableGroups, remote = actionableRemote
        iconButton("play.fill", "Start \(selectionNoun)", busy: selectionBusy) {
            Task {
                await startSelected(containers, groups)
                await performRemote(.start, on: remote) { !$0.isRunning }
            }
        }
        iconButton("stop.fill", "Stop \(selectionNoun)", busy: selectionBusy) {
            Task {
                await stopSelected(containers, groups)
                await performRemote(.stop, on: remote) { $0.isRunning }
            }
        }
        iconButton("arrow.clockwise", "Restart \(selectionNoun)", busy: selectionBusy) {
            Task {
                await restartSelected(containers, groups)
                await performRemote(.restart, on: remote) { $0.isRunning }
            }
        }
        iconButton("trash", "Delete \(selectionNoun)",
                   busy: selectionBusy, destructive: true) {
            confirmingBulkDelete = true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Distinguish "cannot see the fleet" from "the fleet is empty". Showing an
            // empty table on a failed poll is the exact class of bug that made an
            // unreachable printer look healthy in a sibling tool.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )
            // Fills the pane like the empty state below, so the page stays bounded
            // when the runtime is unreachable too.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded where rows.isEmpty:
            // An empty state that carries the primary action, per `FEATURES.md`. Until the
            // run sheet existed there was nothing to offer here; now "no containers" has an
            // obvious next step, and a filtered-empty list can undo the thing hiding rows
            // rather than leaving the user to work out which control did it.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No containers", systemImage: "tray")
            } description: {
                Text(isFiltered
                     ? "Nothing matches the current filter."
                     : "Nothing is running on this Mac yet. Run a container, or create a group to start several together.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") {
                        ui.search = ""
                        ui.filter = .all
                        ui.kindFilter = .all
                    }
                } else {
                    VStack(spacing: 14) {
                        HStack {
                            Button("Run a Container…") { showingRun = true }
                                .buttonStyle(.borderedProminent)
                            Button("New Group…") { editingGroup = .new }
                        }
                        // A few Suggestions, as decided: an empty list is where a ready-made
                        // stack is most useful.
                        SuggestionQuickPicks(
                            picks: model.suggestionLibrary.entries.filter { $0.kind == .stack }.prefix(3).map { stack in
                                (stack.title, { model.requestSuggestion(SuggestionItem.library(stack).id, host: ui.hostFilter) })
                            },
                            more: { model.requestSuggestionsTab(.stacks, host: ui.hostFilter) })
                    }
                }
            }
            // Fills the pane, the same way the loading branch above and the table below do.
            // Without it `content` sizes to this view's intrinsic height, the enclosing VStack
            // shrinks to less than the pane, and SwiftUI centres it — which put a large blank
            // band *above the toolbar* and another below the list. A tester reported
            // it as "a huge gap on the top of the screen between the controls and the toolbar",
            // and noticed it only here because the other sections were not empty at the time.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            rowsList
        }
    }

    /// One list row: a container, a group or a group's member, with the sort keys the Sort menu
    /// orders by. The sampled CPU and memory it used to carry left with the figures (Q58).
    struct ContainerRow: Identifiable {
        /// Since 5 October a row is a standalone container, a group, or a member under an open
        /// group (to-do item 4). One type, because `Table` has one value type; a branch on
        /// `kind` in each cell, because the three genuinely differ.
        enum Kind { case container, group, member }

        let kind: Kind
        /// The container behind the row: the container itself, or a member's if it exists yet.
        /// `nil` for a group, and for a member the group has not created.
        let container: Container?
        /// The group, for a group row and for each of its members.
        let group: ContainerGroup?
        let member: GroupMember?
        let groupState: GroupState?
        let id: String
        /// Which Mac the row is on (PLAN.md Phase C). Groups and their members are This Mac's —
        /// a group is a saved form on this Mac until Phase D deploys it.
        let host: HostRef
        let hostName: String
        /// A host's row that is older than a fresh answer: shown, with its age, rather than hidden.
        let staleSince: Date?

        // MARK: Sort keys, one per sortable column, valid for every kind

        let name: String
        let stateRank: Int
        let kindLabel: String
        let imageSortKey: String
        let creationSortKey: String
        /// The lowest published host port, or `Int.max` when nothing is published, so those
        /// gather at one end. Numeric, because as text "8080" sorts before "9".
        let portSortKey: Int
        /// Octets zero-padded, so `.9` sorts before `.10`.
        let ipSortKey: String

        /// A group's row id is namespaced, because a group and a container could otherwise share a
        /// name; a container's and a member's id is the container name, which is unique, since a
        /// grouped container never also appears as a standalone row.
        static func groupRowID(_ groupID: String) -> String { "group:" + groupID }
        static func isGroupRowID(_ id: String) -> Bool { id.hasPrefix("group:") }
        static func groupID(fromRowID id: String) -> String { String(id.dropFirst("group:".count)) }

        init(container: Container, kind: Kind = .container, group: ContainerGroup? = nil,
             member: GroupMember? = nil,
             host: HostRef = .local, hostName: String = "This Mac", staleSince: Date? = nil) {
            self.kind = kind
            self.container = container
            self.group = group
            self.member = member
            self.groupState = nil
            self.host = host
            self.hostName = hostName
            self.staleSince = staleSince
            self.id = host.rowID(container.id)
            self.name = container.id
            self.stateRank = container.sortRank * 2
            self.kindLabel = "Container"
            self.imageSortKey = container.imageReference
            self.creationSortKey = container.creationSortKey
            self.portSortKey = container.publishedPorts.map(\.hostPort).min() ?? .max
            self.ipSortKey = Self.paddedIP(container.ipv4)
        }

        /// A member the group has not created yet.
        init(uncreated member: GroupMember, in group: ContainerGroup, hostName: String = "This Mac") {
            self.kind = .member
            self.container = nil
            self.group = group
            self.member = member
            self.groupState = nil
            self.host = group.place
            self.hostName = hostName
            self.staleSince = nil
            self.id = group.place.rowID(member.name)
            self.name = member.name
            self.stateRank = GroupState.notCreated.sortRank
            self.kindLabel = "Container"
            self.imageSortKey = member.image
            self.creationSortKey = "9999"
            self.portSortKey = .max
            self.ipSortKey = ""
        }

        init(group: ContainerGroup, state: GroupState,
             hostName: String = "This Mac", staleSince: Date? = nil) {
            self.kind = .group
            self.container = nil
            self.group = group
            self.member = nil
            self.groupState = state
            self.host = group.place
            self.hostName = hostName
            self.staleSince = staleSince
            self.id = Self.groupRowID(group.id)
            self.name = group.name
            self.stateRank = state.sortRank
            self.kindLabel = "Group"
            self.imageSortKey = ""
            self.creationSortKey = "9999"
            self.portSortKey = .max
            self.ipSortKey = ""
        }

        private static func paddedIP(_ ip: String?) -> String {
            guard let ip else { return "" }
            return ip.split(separator: ".").map { String(format: "%03d", Int($0) ?? 0) }.joined(separator: ".")
        }
    }

    private func containerRow(_ container: Container, kind: ContainerRow.Kind = .container,
                              group: ContainerGroup? = nil, member: GroupMember? = nil) -> ContainerRow {
        ContainerRow(container: container, kind: kind, group: group, member: member,
                     hostName: model.hostLabel)
    }

    /// The listing, as rows, for every Mac the host filter shows: top-level rows sorted by
    /// whatever header was clicked, and each open group's members under it, **sorted by the same
    /// header** (the owner, 5 October). A group never splits apart: its members always sit
    /// directly under it. A host that stopped answering keeps its rows, marked with their age. Since 12 October a host's groups are listed with it.
    private var sortedRows: [ContainerRow] { listRows(filtered: true) }

    /// Every row there is, on every Mac, through no filter and with every group open: what the
    /// page resolves against, so a filter hides rows in the list and never the page that's open
    /// (Kyle, 17 October). Only a row that has really gone — deleted, or its host forgotten — is
    /// missing from it.
    private var everyRow: [ContainerRow] { listRows(filtered: false) }

    private func listRows(filtered: Bool) -> [ContainerRow] {
        let hostFilter = filtered ? ui.hostFilter : nil
        var top: [ContainerRow] = []
        var children: [ContainerRow.ID: [ContainerRow]] = [:]
        var places: [(host: HostRef, name: String, stale: Date?)] = []
        if hostFilter == nil || hostFilter == .local { places.append((.local, model.hostLabel, nil)) }
        let now = Date()
        for (peer, snapshot) in model.hostMode.fleetContainers {
            let host = HostRef.peer(peer.fingerprint)
            if let only = hostFilter, only != host { continue }
            places.append((host, peer.displayName,
                           snapshot.isStale(at: now, freshFor: HostModeController.freshFor) ? snapshot.fetchedAt : nil))
        }
        // A group whose host is no longer trusted — forgotten, blocked — still has a row, so it
        // can be seen, saved and deleted; its Start and Stop are off (Kyle, 12 October).
        for host in Set(model.groups.groups.map(\.place)) where !host.isLocal
            && !places.contains(where: { $0.host == host }) && (hostFilter == nil || hostFilter == host) {
            places.append((host, model.hostMode.hostName(host, local: model.hostLabel) + " (not connected)", nil))
        }
        for place in places {
            func row(_ container: Container, kind: ContainerRow.Kind = .container,
                     group: ContainerGroup? = nil, member: GroupMember? = nil) -> ContainerRow {
                guard !place.host.isLocal else {
                    return containerRow(container, kind: kind, group: group, member: member)
                }
                return ContainerRow(container: container, kind: kind, group: group, member: member,
                                    host: place.host, hostName: place.name, staleSince: place.stale)
            }
            for item in listing(on: place.host, filtered: filtered) {
                switch item {
                case .container(let container):
                    top.append(row(container))
                case .group(let group, let members, let expandForSearch):
                    let memberRows = members.map { m in
                        m.container.map { row($0, kind: .member, group: group, member: m.member) }
                            ?? ContainerRow(uncreated: m.member, in: group, hostName: place.name)
                    }
                    let groupRow = ContainerRow(group: group, state: model.state(of: group),
                                                hostName: place.name, staleSince: place.stale)
                    top.append(groupRow)
                    if !filtered || ui.expandedGroupIDs.contains(group.id) || expandForSearch {
                        children[groupRow.id] = memberRows.sorted(using: ui.sortOrder)
                    }
                }
            }
        }
        return top.sorted(using: ui.sortOrder).flatMap { [$0] + (children[$0.id] ?? []) }
    }

    /// The rows, filling the pane.
    ///
    /// A `List` for the things that cost a hand-rolled `LazyVStack` real work and would be got
    /// wrong: native multi-selection (⌘-click, ⇧-click, ⌘A), ↑/↓, Return to open, type-select, and
    /// the right-click that lands on the whole selection. Rows are as tall as their two lines
    /// make them — no height is written down (the table's `count * 28 + 32` is the cautionary
    /// tale) — and the list takes whatever the pane gives it, like every other branch of
    /// `content`.
    ///
    /// Sorting is `sortedRows`, the same array the page's stepper walks, so ↓ goes to the next
    /// row you can see.
    private var rowsList: some View {
        SelectionRevealingList(selection: selection) {
            List(rows, selection: $selection) { row in
                listRow(row)
                    // The row paints its own padding, so its hover wash and the list's selection fill
                    // reach the same edges.
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            // On the List, not on a row: a row's `.contextMenu` covers that row for one click and
            // knows nothing about the selection. This one hands back every selected id.
            .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
                rowContextMenu(for: ids)
            } primaryAction: { ids in
                // Selecting already shows the row (Q58); double-click and Return bring its page forward
                // in a window too narrow for both panes — but only when the activation names exactly
                // ONE row: with several selected, `ids.first` is an arbitrary member. (Found by Grok
                // 4.6 in review, 2026-08-18.)
                guard ids.count == 1, let id = ids.first, showableIDs.contains(id) else { return }
                open(id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One two-line row. The layout is `ResourceRow`'s; this supplies what a container, a group
    /// and a member each have to say. The buttons, shown on hover, are the row's share of
    /// `rowActions`, `remoteRowActions` and `groupRowActions` — the header has the rest.
    @ViewBuilder
    private func listRow(_ row: ContainerRow) -> some View {
        let selected = selection.contains(row.id)
        ResourceRow(
            title: row.name,
            titleHelp: titleHelp(for: row),
            detail: detailLine(row),
            detailHelp: detailHelp(row),
            selected: selected,
            check: RowCheck(row.id, in: $selection, unavailable: checkUnavailable(row)),
            indent: row.kind == .member ? 28 : 0,
            summary: rowSummary(row),
            dimsTitle: row.kind == .member && row.container == nil,
            leading: { stateMark(row) },
            chips: { rowChips(row) },
            actions: { rowTrailingActions(row) })
    }

    /// A member its group has not created yet is the one row a bulk action cannot take: there is
    /// no container to start or delete, and the group's own Start is what makes it.
    private func checkUnavailable(_ row: ContainerRow) -> String? {
        row.kind == .member && row.container == nil ? "Not created yet — starting the group creates it" : nil
    }

    /// The rows on screen the select-all box covers, in list order.
    private var selectableIDs: [ContainerRow.ID] {
        rows.filter { checkUnavailable($0) == nil }.map(\.id)
    }

    /// The rows with a page, in list order — what the stepper walks. The same rows a bulk action
    /// can take: a member not created yet has neither.
    private var showableIDs: [ContainerRow.ID] { selectableIDs }

    /// The caret slot (kept for every row so names line up), then what the row is — the group
    /// glyph or the container's, the sidebar's and the detail header's — with its state dot on the
    /// corner. The glyph replaced a "Group" / "Container" chip on the first line (Kamal, 17 October).
    @ViewBuilder
    private func stateMark(_ row: ContainerRow) -> some View {
        let logo = row.kind == .group
            ? row.group.flatMap { model.libraryLogo(for: $0) }
            : (row.container?.imageReference ?? row.member?.image).flatMap { model.libraryLogo(for: $0) }
        RowGroupMark(markWidth: 20) {
            if row.kind == .group, let group = row.group {
                caret(for: group)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        } mark: {
            switch row.kind {
            case .group:
                RowTypeMark(systemImage: Section.groupSymbol, kind: "Group", logo: logo, size: 20, symbolSize: 16) {
                    if let state = row.groupState { GroupStateDot(state: state, showsCount: false) }
                }
            case .member:
                RowTypeMark(systemImage: "shippingbox", kind: "Container", logo: logo, size: 20, symbolSize: 16) {
                    ServiceStateDot(container: row.container)
                }
            case .container:
                RowTypeMark(systemImage: "shippingbox", kind: "Container", logo: logo, size: 20, symbolSize: 16) {
                    if let c = row.container {
                        Circle()
                            .fill(c.stateColor)
                            .help(c.status.state.capitalized)
                    }
                }
            }
        }
    }

    /// The tags and — only for another Mac's row — the host, each a chip `ChipLine` may drop.
    @ViewBuilder
    private func rowChips(_ row: ContainerRow) -> some View {
        TagPillRow(tags: tags(for: row), compact: true)
        if !row.host.isLocal {
            HostCell(name: row.hostName, staleSince: row.staleSince)
                .chipStyle()
                .fixedSize()
        }
    }

    private func tags(for row: ContainerRow) -> [Tag] {
        if row.kind == .group, let group = row.group { return model.tags.tags(on: .group, group.id) }
        return model.tags.tags(on: .container, row.id)
    }

    /// Image · ports · IP/network, each only when there is one. The table showed an em dash for a
    /// missing value because the column had to hold something; a sentence has no such need.
    private func detailParts(_ row: ContainerRow) -> [String] {
        switch row.kind {
        case .group:
            guard let group = row.group else { return [] }
            var parts = [group.members.isEmpty ? "No services" : "\(group.members.count) service\(group.members.count == 1 ? "" : "s")"]
            if let state = row.groupState, case .partial = state { parts.append(state.title.lowercased()) }
            parts.append("network " + (group.network ?? "default"))
            return parts
        case .container, .member:
            guard let container = row.container else {
                return [Self.imageLabel(row.member?.image ?? "")]
            }
            var parts = [Self.imageLabel(container.configuration.image.reference)]
            if let ports = container.portSummary { parts.append(ports) }
            let network = Self.ipNetworkLabel(container)
            if network != "—" { parts.append(network) }
            return parts
        }
    }

    private func detailLine(_ row: ContainerRow) -> String { detailParts(row).joined(separator: " · ") }

    /// The whole second line on hover, with the full image reference rather than its shortening.
    private func detailHelp(_ row: ContainerRow) -> String {
        if row.kind == .group, let group = row.group, !group.members.isEmpty {
            return group.members.map { "\($0.name) — \($0.image)" }.joined(separator: "\n")
        }
        let reference = row.container?.configuration.image.reference ?? row.member?.image ?? ""
        return ([reference] + detailParts(row).dropFirst()).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func titleHelp(for row: ContainerRow) -> String? {
        row.kind == .member && row.container == nil
            ? "Not created yet — starting “\(row.group?.name ?? "")” creates it" : nil
    }

    @ViewBuilder
    private func rowTrailingActions(_ row: ContainerRow) -> some View {
        switch row.kind {
        case .group:
            if let group = row.group { groupRowActions(for: group) }
        case .container, .member:
            if let container = row.container, !row.host.isLocal {
                remoteRowActions(for: container, on: row.host)
            } else if let container = row.container {
                rowActions(for: container)
            } else {
                // A member the group has not created yet has nothing to act on; its
                // group's own Start is what creates it.
                Text("Not created")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Starting the group creates this container")
            }
        }
    }

    /// What VoiceOver reads for the row: "web, running, Container, nginx, port 8080→80, …".
    private func rowSummary(_ row: ContainerRow) -> String {
        var parts = [row.name]
        switch row.kind {
        case .group:
            parts.append(row.groupState?.title.lowercased() ?? "")
            parts.append("Group")
        case .container, .member:
            parts.append(row.container?.status.state ?? "not created")
            parts.append("Container")
        }
        parts.append(contentsOf: detailParts(row).map { $0.replacingOccurrences(of: "→", with: " to ") })
        let tagNames = tags(for: row).map(\.name)
        if !tagNames.isEmpty { parts.append("tags " + tagNames.joined(separator: ", ")) }
        if !row.host.isLocal { parts.append("on " + row.hostName) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The disclosure caret. A group with no services has none — an empty disclosure is the
    /// control-that-does-nothing failure in miniature — but keeps the space, so names line up.
    @ViewBuilder
    private func caret(for group: ContainerGroup) -> some View {
        if group.members.isEmpty {
            Color.clear.frame(width: 16, height: 16)
        } else {
            let open = ui.expandedGroupIDs.contains(group.id)
            RowGroupDisclosure(
                open: open,
                label: open ? "Hide the containers in \(group.name)" : "Show the containers in \(group.name)",
                help: open ? "Hide containers" : "Show \(Plural.count(group.members.count, "container"))"
            ) {
                if open { ui.expandedGroupIDs.remove(group.id) } else { ui.expandedGroupIDs.insert(group.id) }
            }
        }
    }

    /// Shortening lives in `FlotillaCore` (`ContainerImage.shortReference`) so its awkward
    /// cases — digests, registry ports — are covered by tests this target cannot have.
    private static func imageLabel(_ reference: String) -> String {
        ContainerImage.shortReference(reference)
    }

    private static func ipNetworkLabel(_ c: Container) -> String {
        switch (c.ipv4, c.status.networks?.first?.network) {
        case let (ip?, network?): "\(ip) (\(network))"
        case let (ip?, nil): ip
        case let (nil, network?): network
        case (nil, nil): "—"
        }
    }
}
