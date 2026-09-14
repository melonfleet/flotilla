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
    let ui: ResourceUIState<ContainerGroup>

    @State private var selection = Set<ContainerGroup.ID>()
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

            ResourceListControls<ContainerGroup>(
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
        return groups.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<ContainerGroup.ID> { Set(displayedGroups.map(\.id)) }

    /// Search and the state filter can hide selected rows without clearing their ids, so every
    /// bulk action is constrained to what is still on screen — the same guard the other sections'
    /// bulk bars use.
    private var actionable: Set<ContainerGroup.ID> {
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

    private func selectionToggle(for id: ContainerGroup.ID) -> some View {
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
        Table(displayedGroups,
              sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
              columnCustomization: Binding(get: { ui.columnCustomization },
                                           set: { ui.columnCustomization = $0 })) {
            TableColumn("") { group in
                selectionToggle(for: group.id)
            }
            .width(min: 28, ideal: 30, max: 34)

            // State goes **here**, between the checkbox and the name, because that is where
            // Containers and Machines put theirs — a coloured dot you read without looking at.
            // It was a labelled column over on the right, which made Groups the one table where
            // you had to hunt for the thing you came to check.
            //
            // Unsortable, for the reason the Tags column is: `TableColumn(value:)` needs a key
            // path on the **row**, and a group's state is derived from the live container list
            // rather than stored on it. Sorting by it would mean caching a value that is wrong
            // the moment somebody stops a member from a terminal.
            TableColumn("") { group in
                GroupStateDot(state: model.state(of: group))
            }
            .width(min: 30, ideal: 46, max: 56)
            .customizationID("state")

            TableColumn("Name", value: \.name) { group in
                // The name is the way in, as it is in every other table.
                Button(group.name) { editing = .existing(group.id) }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.rowName(selected: selection.contains(group.id)))
                    .lineLimit(1)
                    .help("Edit \(group.name)")
            }
            .width(min: 120, ideal: 170)

            // Beside the name, the way Finder puts a tag beside a filename. Unsorted for the
            // reason the Volumes table gives: sorting takes a key path on the row, and tags live
            // in `TagStore` rather than on the model.
            TableColumn("Tags") { group in
                TagPillRow(tags: model.tags.tags(on: .group, group.id), compact: true)
            }
            .width(min: 60, ideal: 130)
            .customizationID("tags")

            TableColumn("Services", value: \.serviceSortKey) { group in
                Text(group.members.isEmpty ? "none yet" : group.memberNames.joined(separator: ", "))
                    .foregroundStyle(group.members.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .help(group.members.map { "\($0.name) — \($0.image)" }.joined(separator: "\n"))
            }
            .width(min: 140, ideal: 220)
            .customizationID("services")

            TableColumn("Network", value: \.networkSortKey) { group in
                Text(group.network ?? "Default")
                    .foregroundStyle(group.network == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("network")

            TableColumn("Actions") { group in
                rowActions(for: group)
            }
            .width(min: 120, ideal: 140)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: ContainerGroup.ID.self) { ids in
            if let group = model.groups.groups.first(where: { ids.contains($0.id) }) {
                menu(for: group)
            }
        } primaryAction: { ids in
            // Double-click edits — but only when the activation names exactly one row. `ids` is
            // a `Set`, so with several selected `first` is an arbitrary member, and opening the
            // wrong group is worse than opening none.
            guard ids.count == 1,
                  let group = model.groups.groups.first(where: { ids.contains($0.id) })
            else { return }
            editing = .existing(group.id)
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

extension ContainerGroup {
    /// Sort keys for the table. `Table`'s sorting needs a `Comparable` key path on the row, and
    /// "Default" has to sort with the named networks rather than as an empty string at one end.
    var serviceSortKey: String { memberNames.joined(separator: ", ") }
    var networkSortKey: String { network ?? "Default" }
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
