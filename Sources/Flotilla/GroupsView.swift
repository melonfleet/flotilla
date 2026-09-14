import SwiftUI
import Foundation
import FlotillaCore

/// The Groups section: saved sets of containers that start and stop together.
///
/// Reuses `ResourceUIState<ContainerGroup>` rather than growing a fourth near-identical state
/// class, for the reason that type's own docstring gives.
///
/// **What is deliberately not here yet**, so nobody reads its absence as an oversight: tags on a
/// group, the cards presentation, multi-select with a bulk bar, and the recent-activity band.
/// Every one of those is a pattern this app already has and Groups should eventually wear; none
/// of them is load-bearing for the first question a group has to answer, which is whether four
/// containers can be started with one click.
struct GroupsView: View {
    let model: AppModel
    let ui: ResourceUIState<ContainerGroup>

    /// The group being created or edited, or nil for the list. One state for both, because the
    /// form is the same form — `nil` id inside means "new".
    @State private var editing: GroupFormTarget?
    @State private var pendingDelete: ContainerGroup?

    var body: some View {
        Group {
            if let target = editing {
                GroupFormView(model: model, target: target) { editing = nil }
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The list is derived from live containers, so it needs them even when you land here
        // first — without this a group reads "not created" until you visit Containers.
        .task { await model.refresh() }
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
                if let group = pendingDelete { model.groups.deleteGroup(group.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            // The one thing a user will assume and be wrong about.
            Text("The containers it names are left exactly as they are — running ones keep running. This deletes the grouping, not the containers.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search groups…",
                       status: model.groups.groups.isEmpty
                           ? nil
                           : "\(model.groups.groups.count) group\(model.groups.groups.count == 1 ? "" : "s")",
                       leading: { EmptyView() },
                       trailing: {
            IconActionButton(systemImage: "plus",
                             label: "New group",
                             help: "New group") {
                editing = .new
            }
        })
    }

    // MARK: Rows

    private var isFiltered: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var displayedGroups: [ContainerGroup] {
        var groups = model.groups.groups
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // A group is found by its own name *or* by a service in it — "what was the group
            // with redis in it" is the question you actually have.
            groups = groups.filter {
                $0.name.lowercased().contains(query)
                    || $0.members.contains { member in
                        member.name.lowercased().contains(query)
                            || member.image.lowercased().contains(query)
                    }
            }
        }
        return groups.sorted(using: ui.sortOrder)
    }

    @ViewBuilder
    private var content: some View {
        if displayedGroups.isEmpty {
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No groups",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "rectangle.3.group")
            } description: {
                Text(isFiltered
                     ? "No group matches the current search."
                     : "A group remembers several containers — a database, a cache, a web server — so you can start and stop them together.")
            } actions: {
                if isFiltered {
                    Button("Clear Search") { ui.search = "" }
                } else {
                    Button("New Group") { editing = .new }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(displayedGroups, sortOrder: Binding(get: { ui.sortOrder },
                                                     set: { ui.sortOrder = $0 })) {
                TableColumn("Name", value: \.name) { group in
                    Text(group.name).fontWeight(.medium)
                }
                .width(min: 120, ideal: 160)

                TableColumn("Services") { group in
                    // The names, not just a count: "db, cache, web" answers what the group is
                    // in the width a number would waste.
                    Text(group.members.isEmpty
                         ? "none yet"
                         : group.memberNames.joined(separator: ", "))
                        .foregroundStyle(group.members.isEmpty ? .secondary : .primary)
                        .help(group.members.map { "\($0.name) — \($0.image)" }
                            .joined(separator: "\n"))
                }
                .width(min: 140, ideal: 240)

                TableColumn("Network") { group in
                    Text(group.network ?? "Default")
                        .foregroundStyle(group.network == nil ? .secondary : .primary)
                }
                .width(min: 80, ideal: 110)

                TableColumn("State") { group in
                    GroupStateBadge(state: model.state(of: group))
                }
                .width(min: 90, ideal: 120)

                TableColumn("Actions") { group in
                    rowActions(for: group)
                }
                .width(min: 120, ideal: 140)
            }
            .tableStyle(.inset)
        }
    }

    @ViewBuilder
    private func rowActions(for group: ContainerGroup) -> some View {
        let state = model.state(of: group)
        HStack(spacing: 6) {
            // Start and Stop are separate buttons rather than one that changes meaning: a
            // partly-running group needs both, and a single toggle would have to pick one.
            IconActionButton(systemImage: "play.fill",
                             label: "Start \(group.name)",
                             help: state == .empty
                                 ? "Add a service before starting this group"
                                 : "Start every service in \(group.name)",
                             disabled: state == .empty || state == .running) {
                Task { await model.startGroup(group) }
            }
            IconActionButton(systemImage: "stop.fill",
                             label: "Stop \(group.name)",
                             help: "Stop every running service in \(group.name)",
                             disabled: state == .empty || state == .stopped || state == .notCreated) {
                Task { await model.stopGroup(group) }
            }
            IconActionButton(systemImage: "pencil",
                             label: "Edit \(group.name)",
                             help: "Edit \(group.name)") {
                editing = .existing(group.id)
            }
            IconActionButton(systemImage: "trash",
                             label: "Delete \(group.name)",
                             help: "Delete \(group.name)",
                             destructive: true) {
                pendingDelete = group
            }
        }
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

/// How much of a group is up, in one glance.
///
/// Deliberately spells out "3 of 4 running" rather than drawing a part-filled bar: the number is
/// the thing you act on, and a bar at 75% does not tell you which one is down.
struct GroupStateBadge: View {
    let state: GroupState

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .help(explanation)
    }

    private var title: String {
        switch state {
        case .empty: "No services"
        case .notCreated: "Not created"
        case .stopped: "Stopped"
        case .partial(let running, let total): "\(running) of \(total) running"
        case .running: "Running"
        }
    }

    private var symbol: String {
        switch state {
        case .empty: "tray"
        case .notCreated: "circle.dashed"
        case .stopped: "stop.circle"
        case .partial: "exclamationmark.circle"
        case .running: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .empty, .notCreated: .secondary
        case .stopped: .secondary
        case .partial: Theme.warning
        case .running: Theme.online
        }
    }

    /// "Not created" is the one state a user will misread, so it explains itself.
    private var explanation: String {
        switch state {
        case .empty: "This group has no services in it yet."
        case .notCreated: "None of these containers exists on this Mac yet. Starting the group creates them."
        case .stopped: "Every container exists and none is running."
        case .partial: "Some of this group is running and some is not."
        case .running: "Every service in this group is running."
        }
    }
}
