import SwiftUI
import Foundation
import FlotillaCore

/// The Groups section: saved sets of containers that start and stop together.
///
/// Wears the same clothes as every other section — list/cards, hideable columns, a state filter,
/// row selection with a bulk bar, tags beside the name, and the recent-activity band — because a
/// section that looks like the others is one you already know how to use. `ResourceUIState`
/// carries the view state, for the reason its own docstring gives.
struct GroupsView: View {
    let model: AppModel
    let ui: ResourceUIState<GroupRow>

    @State private var selection = Set<GroupRow.ID>()
    @State private var editing: GroupFormTarget?
    @State private var pendingDelete: ContainerGroup?
    @State private var confirmingBulkDelete = false

    /// The "New Tag…" sheet, when a row's Tags menu opened it. Presented from the view and never
    /// from inside the menu — a `.sheet` attached within a `Menu` never appears, because the menu
    /// is gone by the time the state changes.
    @State private var tagSheet: TagSheetTarget?

    /// Hideable columns, in the order the popover lists them. The checkbox, Name and Actions are
    /// not here: a table you cannot select from, identify or act on is not a shorter table.
    static let columnSpecs: [(id: String, title: String)] = [
        ("state", "State"), ("tags", "Tags"), ("services", "Services"), ("network", "Network"),
    ]

    var body: some View {
        Group {
            if let target = editing {
                GroupFormView(model: model, target: target) { editing = nil }
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  // A feed row names the group; opening it edits that group,
                                  // which is the only detail a group has.
                                  open: { name in
                                      if let match = model.groups.groups.first(where: { $0.name == name }) {
                                          editing = .existing(match.id)
                                      }
                                  },
                                  canOpen: { name in model.groups.groups.contains { $0.name == name } })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Group state is derived from live containers, so this section needs them even when you
        // land here first — without it every group reads "Not created" until you visit Containers.
        .task { await model.refresh() }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        // "Open in Flotilla" from the menu-bar popover names a group, not just this section.
        // One-shot: cleared on consumption so a rebuild does not reopen it. A group's detail is
        // its form, so that is where the request lands.
        //
        // The menu bar names a group by **name**, because that is what it shows; the editor is
        // addressed by id. Resolved here rather than by having the popover carry ids around.
        .onChange(of: model.pendingDetailSubject) { _, subject in
            // Only this section's own requests. See `AppModel.requestDetail`.
            guard let subject, model.pendingDetailKind == .group else { return }
            openFromRequest(subject)
        }
        .onAppear {
            if let subject = model.pendingDetailSubject, model.pendingDetailKind == .group {
                openFromRequest(subject)
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
            "Delete the group “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if let group = pendingDelete { model.deleteGroup(group) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(Self.deleteWarning)
        }
        .confirmationDialog(
            "Delete \(actionable.count) group\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Group\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                for group in selectedGroups { model.deleteGroup(group) }
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteWarning)
        }
    }

    /// Opens the editor for a group named by a menu-bar request, and clears the request either
    /// way — a request that names a group somebody has since deleted must not sit there waiting
    /// to be applied to the next one.
    private func openFromRequest(_ name: String) {
        if let match = model.groups.groups.first(where: { $0.name == name }) {
            editing = .existing(match.id)
        }
        model.clearPendingDetail()
    }

    /// The one thing a user will assume and be wrong about, in both dialogs.
    private static let deleteWarning =
        "The containers named in it are left exactly as they are — running ones keep running. This deletes the grouping, not the containers."

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search groups…",
                       status: statusLine,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all groups" : "Select all groups")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<GroupRow>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: stateFilters)
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "New group…") { editing = .new }
            // Groups hold no runtime state of their own, so this refreshes what they are
            // *derived* from — the container list.
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh containers") {
                Task { await model.refresh() }
            }
        })
    }

    private var statusLine: String? {
        let total = model.groups.groups.count
        guard total > 0 else { return nil }
        let running = model.groups.groups.filter { model.state(of: $0) == .running }.count
        return running == 0
            ? "\(total) group\(total == 1 ? "" : "s")"
            : "\(running) of \(total) running"
    }

    /// Only states that are actually on screen, so the menu never offers a setting that returns
    /// nothing — the rule `ResourceListControls` states and this section has to honour too.
    private var stateFilters: [ResourceFilterOption] {
        var options: [ResourceFilterOption] = []
        let present = Set(model.groups.groups.map { Self.filterID(for: model.state(of: $0)) })
        guard present.count > 1 else { return [] }
        options.append(ResourceFilterOption(id: "all", title: "All groups",
                                            systemImage: "rectangle.3.group"))
        for option in Self.filterOrder where present.contains(option.id) { options.append(option) }
        return options
    }

    private static let filterOrder: [ResourceFilterOption] = [
        ResourceFilterOption(id: "running", title: "Running", systemImage: "checkmark.circle.fill"),
        ResourceFilterOption(id: "partial", title: "Partly running", systemImage: "exclamationmark.circle"),
        ResourceFilterOption(id: "stopped", title: "Stopped", systemImage: "stop.circle"),
        ResourceFilterOption(id: "notCreated", title: "Not created", systemImage: "circle.dashed"),
        ResourceFilterOption(id: "empty", title: "No services", systemImage: "tray"),
    ]

    private static func filterID(for state: GroupState) -> String {
        switch state {
        case .running: "running"
        case .partial: "partial"
        case .stopped: "stopped"
        case .notCreated: "notCreated"
        case .empty: "empty"
        }
    }

    // MARK: Rows

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all"
    }

    private var displayedGroups: [ContainerGroup] {
        var groups = model.groups.groups

        if ui.filterID != "all" {
            groups = groups.filter { Self.filterID(for: model.state(of: $0)) == ui.filterID }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // By the group's name, by a service in it, or by a tag — "what was the group with
            // redis in it" is the question you actually have.
            groups = groups.filter { group in
                group.name.lowercased().contains(query)
                    || group.members.contains {
                        $0.name.lowercased().contains(query) || $0.image.lowercased().contains(query)
                    }
                    || model.tags.tags(on: .group, group.id)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }
        return groups
    }

    /// The table's rows: every group, each followed by its services when expanded.
    ///
    /// Built here rather than handed to `Table` as a tree. `DisclosureTableRow` needs parent and
    /// children to be the *same* type, and a group and a service are not — a service has a
    /// container behind it with its own state, tags and actions, and squeezing both into one
    /// model to satisfy the API would make every cell a pair of branches anyway. Splicing the
    /// rows keeps the branch in one place: `GroupRow.service`.
    ///
    /// Only the **group** rows are sorted. Services keep the order the group starts them in,
    /// which is the one order that means something — sorting them alphabetically would put the
    /// web tier above the database it waits for and quietly imply that is what happens.
    private var displayedRows: [GroupRow] {
        var groupRows = displayedGroups.map { GroupRow(group: $0, service: nil) }
        groupRows.sort(using: ui.sortOrder)
        return groupRows.flatMap { row -> [GroupRow] in
            guard ui.expandedIDs.contains(row.group.id) else { return [row] }
            return [row] + row.group.members.map { GroupRow(group: row.group, service: $0) }
        }
    }

    private var visibleIDs: Set<GroupRow.ID> { Set(displayedGroups.map(\.id)) }

    /// Search and the state filter can hide selected rows without clearing their ids, so every
    /// bulk action is constrained to what is still on screen — the same guard the other sections'
    /// bulk bars use.
    /// Group rows only — a service row can be selected by the same click, and starting "two
    /// groups" that were really one group and one of its services is not what the bar says.
    private var actionable: Set<GroupRow.ID> {
        Set(displayedGroups.lazy.filter { selection.contains($0.id) }.map(\.id))
    }

    private var selectedGroups: [ContainerGroup] {
        displayedGroups.filter { actionable.contains($0.id) }
    }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    /// Tags key on the group's **id**, not its name: a group can be renamed, and keying on the
    /// name would drop every pill the moment it was.
    private var selectedTagSubjects: [TagSubject] {
        selectedGroups.map { TagSubject(kind: .group, id: $0.id) }
    }

    private func selectionToggle(for id: GroupRow.ID) -> some View {
        let isOn = Binding<Bool>(
            get: { selection.contains(id) },
            set: { on in if on { selection.insert(id) } else { selection.remove(id) } })
        let name = model.groups.group(id)?.name ?? id
        return Toggle("", isOn: isOn)
            .labelsHidden()
            .accessibilityLabel("Select \(name)")
            .help("Select \(name)")
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        // A single group already has all of these in its own row.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "play.fill",
                                 label: "Start \(actionable.count) groups",
                                 help: "Start \(actionable.count) groups, one after another",
                                 disabled: !selectedGroups.contains { canStart($0) }) {
                    let groups = selectedGroups.filter { canStart($0) }
                    Task { await model.startGroups(groups) }
                }
                IconActionButton(systemImage: "stop.fill",
                                 label: "Stop \(actionable.count) groups",
                                 help: "Stop \(actionable.count) groups",
                                 disabled: !selectedGroups.contains { canStop($0) }) {
                    let groups = selectedGroups.filter { canStop($0) }
                    Task { await model.stopGroups(groups) }
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "trash",
                                 label: "Delete \(actionable.count) groups",
                                 help: "Delete \(actionable.count) groups",
                                 destructive: true) {
                    confirmingBulkDelete = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    /// This section's slice of the one activity feed.
    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .group).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
    }

    private func canStart(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return state != .empty && state != .running
    }

    private func canStop(_ group: ContainerGroup) -> Bool {
        let state = model.state(of: group)
        return state != .empty && state != .stopped && state != .notCreated
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if displayedGroups.isEmpty {
            emptyState
        } else {
            switch ui.presentation {
            case .list: table
            case .cards: cards
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(isFiltered ? "No matches" : "No groups",
                  systemImage: isFiltered ? "line.3.horizontal.decrease" : "rectangle.3.group")
        } description: {
            Text(isFiltered
                 ? "No group matches the current filter."
                 : "A group remembers several containers — a database, a cache, a web server — so you can start and stop them together.")
        } actions: {
            if isFiltered {
                Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
            } else {
                Button("New Group") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(displayedRows,
              selection: $selection,
              sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
              columnCustomization: Binding(get: { ui.columnCustomization },
                                           set: { ui.columnCustomization = $0 })) {
            TableColumn("") { row in
                // Services are not separately selectable: the checkbox drives the bulk bar, and
                // "start 2 groups" meaning one group and somebody else's database is a lie the
                // bar would have no way to tell.
                if row.service == nil { selectionToggle(for: row.id) }
            }
            .width(min: 28, ideal: 30, max: 34)

            // State sits between the checkbox and the name, where Containers and Machines put
            // theirs. A service shows its **container's** state, from the same live list the
            // group's own state is derived from, so a row and its parent can never disagree.
            TableColumn("") { row in
                if let member = row.service {
                    ServiceStateDot(container: model.containers.first { $0.id == member.name })
                } else {
                    GroupStateDot(state: model.state(of: row.group))
                }
            }
            .width(min: 30, ideal: 46, max: 56)
            .customizationID("state")

            TableColumn("Name", value: \.name) { row in
                if let member = row.service {
                    serviceNameCell(member, in: row.group)
                } else {
                    groupNameCell(row.group)
                }
            }
            .width(min: 150, ideal: 200)

            TableColumn("Tags") { row in
                // A service's tags are its **container's** tags — the same pills the Containers
                // table shows for that row, not a second vocabulary for the same object.
                if let member = row.service {
                    TagPillRow(tags: model.tags.tags(on: .container, member.name), compact: true)
                } else {
                    TagPillRow(tags: model.tags.tags(on: .group, row.group.id), compact: true)
                }
            }
            .width(min: 60, ideal: 130)
            .customizationID("tags")

            TableColumn("Services", value: \.serviceSortKey) { row in
                if let member = row.service {
                    // The image, which is the question you have about a service and not about a
                    // group: "what is this one made from".
                    Text(member.image)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(member.image)
                } else {
                    Text(row.group.members.isEmpty
                         ? "none yet" : row.group.memberNames.joined(separator: ", "))
                        .foregroundStyle(row.group.members.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .help(row.group.members.map { "\($0.name) — \($0.image)" }
                            .joined(separator: "\n"))
                }
            }
            .width(min: 140, ideal: 220)
            .customizationID("services")

            TableColumn("Network", value: \.networkSortKey) { row in
                // Blank on a service: it is on the group's network by construction, and
                // repeating it down every child row says it is a per-service choice.
                if row.service == nil {
                    Text(row.group.network ?? "Default")
                        .foregroundStyle(row.group.network == nil ? .secondary : .primary)
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("network")

            TableColumn("Actions") { row in
                if let member = row.service {
                    serviceActions(member)
                } else {
                    rowActions(for: row.group)
                }
            }
            .width(min: 120, ideal: 140)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: GroupRow.ID.self) { ids in
            if let group = model.groups.groups.first(where: { ids.contains($0.id) }) {
                menu(for: group)
            }
        } primaryAction: { ids in
            // Double-click edits — but only when the activation names exactly one group row.
            // `ids` is a `Set`, so with several selected `first` is an arbitrary member.
            guard ids.count == 1,
                  let group = model.groups.groups.first(where: { ids.contains($0.id) })
            else { return }
            editing = .existing(group.id)
        }
    }

    /// The group's name, behind the disclosure chevron that shows its services.
    ///
    /// The chevron is a button of its own rather than the whole row being clickable: the name is
    /// already the way into the editor everywhere else in the app, and making a click mean two
    /// different things depending on which pixel it landed on is how you lose both.
    ///
    /// A group with no services has no chevron — an empty disclosure that opens onto nothing is
    /// the control-that-does-nothing failure in miniature. The space is still reserved so the
    /// names line up.
    private func groupNameCell(_ group: ContainerGroup) -> some View {
        HStack(spacing: 4) {
            if group.members.isEmpty {
                Color.clear.frame(width: 16, height: 16)
            } else {
                let open = ui.expandedIDs.contains(group.id)
                Button {
                    if open { ui.expandedIDs.remove(group.id) }
                    else { ui.expandedIDs.insert(group.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open
                    ? "Hide the services in \(group.name)"
                    : "Show the services in \(group.name)")
                .help(open ? "Hide services" : "Show \(group.members.count) services")
            }
            Button(group.name) { editing = .existing(group.id) }
                .buttonStyle(.link)
                .foregroundStyle(Theme.rowName(selected: selection.contains(group.id)))
                .lineLimit(1)
                .help("Edit \(group.name)")
        }
    }

    /// A service's name, indented under its group, and a way into the container itself.
    ///
    /// Clicking it opens the **container's** detail rather than the group's editor: by the time
    /// you have expanded a group and are looking at one service, the thing you want is its logs
    /// or its shell. A service whose container does not exist yet has nothing to open, so it is
    /// plain text — not a link that would take you to a page about nothing.
    private func serviceNameCell(_ member: GroupMember, in group: ContainerGroup) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 18, height: 16)
            if model.containers.contains(where: { $0.id == member.name }) {
                Button(member.name) { model.requestDetail(kind: .container, subject: member.name) }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.rowName(selected: selection.contains(member.id)))
                    .lineLimit(1)
                    .help("Open \(member.name)")
            } else {
                Text(member.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Not created yet — starting “\(group.name)” creates it")
            }
        }
    }

    /// One service's own controls: the container lifecycle, for that container alone.
    ///
    /// Start and Stop rather than the group's pair, because from here you are acting on one
    /// thing. Both are disabled until the container exists — `container start` needs something
    /// to start, and a group that has never run has nothing yet.
    @ViewBuilder
    private func serviceActions(_ member: GroupMember) -> some View {
        let container = model.containers.first { $0.id == member.name }
        let running = container.map(AppModel.isRunning) ?? false
        HStack(spacing: 2) {
            IconActionButton(systemImage: "play.fill",
                             label: "Start \(member.name)",
                             help: container == nil
                                 ? "This container does not exist yet"
                                 : "Start \(member.name)",
                             busy: model.isBusy(member.name, kind: .container),
                             disabled: container == nil || running) {
                if let container { Task { await model.perform(.start, on: container) } }
            }
            IconActionButton(systemImage: "stop.fill",
                             label: "Stop \(member.name)",
                             help: container == nil
                                 ? "This container does not exist yet"
                                 : "Stop \(member.name)",
                             busy: model.isBusy(member.name, kind: .container),
                             disabled: container == nil || !running) {
                if let container { Task { await model.perform(.stop, on: container) } }
            }
            IconActionButton(systemImage: "text.alignleft",
                             label: "Logs for \(member.name)",
                             help: container == nil
                                 ? "This container does not exist yet"
                                 : "Open the logs for \(member.name)",
                             disabled: container == nil) {
                model.requestDetail(kind: .container, subject: member.name)
            }
            Spacer(minLength: 0)
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedGroups) { group in
                ResourceCard(
                    title: group.name,
                    badge: model.state(of: group).badge,
                    fields: [
                        ("Services", group.members.isEmpty
                            ? "none yet" : group.memberNames.joined(separator: ", ")),
                        ("Network", group.network ?? "Default"),
                        ("Images", group.members.isEmpty
                            ? "—" : group.members.map(\.image).joined(separator: ", ")),
                    ],
                    tags: model.tags.tags(on: .group, group.id),
                    onOpen: { editing = .existing(group.id) }
                ) {
                    rowActions(for: group)
                }
                // On the whole card, not just the title: a menu you can only summon by
                // right-clicking exactly the text reads as no menu at all. Same builder the
                // `⋯` uses, which `check-menu-parity.sh` holds us to.
                .contextMenu { menu(for: group) }
            }
        }
    }

    /// Lifecycle, then overflow, then bin — the arrangement every other section uses, so the
    /// destructive control is always in the same place and the `⋯` is always beside it.
    ///
    /// Start and Stop stay as buttons because they are what you came to the row to do. Edit,
    /// Tags and Copy live in the menu: Edit opens a whole screen, which is not a one-click
    /// action, and a fifth glyph in a table cell reads as a toolbar rather than a row.
    @ViewBuilder
    private func rowActions(for group: ContainerGroup) -> some View {
        HStack(spacing: 2) {
            // Separate buttons rather than one that changes meaning: a partly running group
            // needs both, and a single toggle would have to pick one.
            IconActionButton(systemImage: "play.fill",
                             label: "Start \(group.name)",
                             help: model.state(of: group) == .empty
                                 ? "Add a service before starting this group"
                                 : "Start every service in \(group.name)",
                             disabled: !canStart(group)) {
                Task { await model.startGroup(group) }
            }
            IconActionButton(systemImage: "stop.fill",
                             label: "Stop \(group.name)",
                             help: "Stop every running service in \(group.name)",
                             disabled: !canStop(group)) {
                Task { await model.stopGroup(group) }
            }

            Menu {
                menu(for: group)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(group.name)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(group.name)",
                             help: "Delete \(group.name)",
                             destructive: true) {
                pendingDelete = group
            }
            Spacer(minLength: 0)
        }
    }

    /// The row menu, shared by the `⋯` button and a right-click so the two render identically —
    /// the drift `VolumesView.menu(for:)` documents.
    @ViewBuilder
    private func menu(for group: ContainerGroup) -> some View {
        // First, above everything: the thing this row opens. A group's detail *is* its form.
        Button("Edit…") { editing = .existing(group.id) }
        Divider()
        // Tags, in the same place as on every other row menu: after what you open and before
        // Copy. Not destructive, not a read of the runtime — it changes how the row looks to you
        // and nothing about what it is.
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
        Button("Delete…", role: .destructive) { pendingDelete = group }
    }
}

/// One line of the Groups table: a group, or one service inside an expanded group.
///
/// A single type because `Table` has a single `Value`, and a branch on `service` because a group
/// and a service genuinely differ — a service has a container behind it with its own state, tags
/// and lifecycle. The alternative was a protocol with two conformances and a cast in every cell,
/// which is the same branch with more ceremony.
///
/// `id` namespaces a service under its group. Two groups may not own a service of the same name
/// (`GroupBook` refuses it), but the id is what `selection` holds, and deriving it from the
/// member alone would make a row's identity depend on a rule enforced somewhere else.
struct GroupRow: Identifiable {
    let group: ContainerGroup
    /// `nil` for the group's own row.
    let service: GroupMember?

    var id: String { service.map { "\(group.id)/\($0.id)" } ?? group.id }

    /// Sort keys. Only group rows are ever sorted — see `GroupsView.displayedRows` — so these
    /// read from the group, and a service row's values are never consulted.
    var name: String { group.name }
    var serviceSortKey: String { group.memberNames.joined(separator: ", ") }
    /// "Default" sorts among the named networks rather than as an empty string at one end.
    var networkSortKey: String { group.network ?? "Default" }
}

/// A service's state, read from its container rather than from the group.
///
/// A container that does not exist yet is a hollow ring, not a grey dot: "stopped" and "never
/// created" are different answers to "why is this not running", and the group's own badge already
/// distinguishes them.
struct ServiceStateDot: View {
    let container: Container?

    var body: some View {
        Group {
            if let container {
                Circle()
                    .fill(container.stateColor)
                    .frame(width: 8, height: 8)
                    .help(container.status.state.capitalized)
                    .accessibilityLabel(container.status.state.capitalized)
            } else {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
                    .help("Not created yet")
                    .accessibilityLabel("Not created")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Which group the form is editing, or that it is making a new one.
enum GroupFormTarget: Identifiable, Hashable {
    case new
    case existing(String)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let groupID): groupID
        }
    }
}

/// A group's state as the coloured dot every other table uses, in the same place.
///
/// A dot alone would lose the one thing a group's state has that a container's does not: a
/// **count**. "Some of it is running" is not actionable; "3 of 4" is. So a partly-running group
/// carries the numbers beside the dot and every other state is the bare dot, which keeps the
/// column as narrow as the others for the states that do not need the room.
struct GroupStateDot: View {
    let state: GroupState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.tint)
                .frame(width: 8, height: 8)
            if case .partial(let running, let total) = state {
                Text("\(running)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(state.title) — \(state.explanation)")
        .accessibilityLabel(state.title)
    }
}

/// How a group's state is *drawn*. In the app target, not beside `GroupState` in `FlotillaCore`,
/// for the reason `ActivityKind` gives: the Foundation-only core has no business knowing SF
/// Symbol names or colours.
///
/// One place rather than one per surface — the dot, its tooltip and a card's badge are three
/// readings of the same five states, and three copies is how a tooltip ends up disagreeing with
/// the badge beside it.
extension GroupState {
    var title: String {
        switch self {
        case .empty: "No services"
        case .notCreated: "Not created"
        case .stopped: "Stopped"
        case .partial(let running, let total): "\(running) of \(total) running"
        case .running: "Running"
        }
    }

    var tint: Color {
        switch self {
        case .empty, .notCreated, .stopped: .secondary
        case .partial: Theme.warning
        case .running: Theme.online
        }
    }

    /// "Not created" is the one state a user will misread, so it explains itself.
    var explanation: String {
        switch self {
        case .empty: "This group has no services in it yet."
        case .notCreated: "None of these containers exists on this Mac yet. Starting the group creates them."
        case .stopped: "Every container exists and none is running."
        case .partial: "Some of this group is running and some is not."
        case .running: "Every service in this group is running."
        }
    }

    /// A card's badge: short, because it sits beside the name. Nil where there is nothing worth
    /// saying — an empty or never-started group is described by its fields already, and a badge
    /// reading "Not created" on every card in a fresh list is noise.
    var badge: String? {
        switch self {
        case .running: "Running"
        case .partial(let running, let total): "\(running)/\(total)"
        case .stopped: "Stopped"
        case .notCreated, .empty: nil
        }
    }
}
