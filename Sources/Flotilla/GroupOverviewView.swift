import SwiftUI
import FlotillaCore

/// A saved group's live facts. Only the existing draft editor registers unsaved changes.
/// Resolve by id on each refresh; keep an open editor alive even if the saved group disappears.
struct GroupOverviewView<Actions: View>: View {
    let model: AppModel
    let groupID: String
    let openContainer: (String) -> Void
    @ViewBuilder let actions: (ContainerGroup) -> Actions

    @State private var editing = false
    @State private var showsCommands = false

    init(model: AppModel, groupID: String, initiallyEditing: Bool = false,
         openContainer: @escaping (String) -> Void,
         @ViewBuilder actions: @escaping (ContainerGroup) -> Actions) {
        self.model = model
        self.groupID = groupID
        self.openContainer = openContainer
        self.actions = actions
        _editing = State(initialValue: initiallyEditing)
    }

    var body: some View {
        Group {
            if editing {
                GroupFormView(model: model, target: .existing(groupID)) { editing = false }
                    .paneHeaderActions {
                        if let group = model.groups.group(groupID) { actions(group) }
                    }
            } else if let group = model.groups.group(groupID) {
                overview(group)
            } else {
                PaneEmptyState(title: "Group unavailable", systemImage: Section.groupSymbol,
                               description: "This group is no longer saved.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func overview(_ group: ContainerGroup) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    identity(group).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    controls(group)
                }
                VStack(alignment: .leading, spacing: 8) {
                    identity(group)
                    HStack(spacing: 6) {
                        ActionCluster { actions(group) }
                        Button("Edit…") { editing = true }
                    }
                    HStack {
                        Spacer(minLength: 0)
                        DetailStepper()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    unpublishedPorts(group)
                    services(group)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        DetailCard(title: "Network", minHeight: nil) {
                            Button(group.network ?? "default") { model.requestSection(.networks) }
                                .buttonStyle(.link)
                                .accessibilityLabel("Network \(group.network ?? "default"), open Networks")
                        }
                        DetailCard(title: "Where", minHeight: nil) {
                            Text(macName(group))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DetailCard(title: "Startup commands", minHeight: nil) {
                        DisclosureGroup("Show startup commands", isExpanded: $showsCommands) {
                            startupCommands(group)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Members whose port was removed at load (`GroupStore.unpublishedPorts`), with the way to answer.
    @ViewBuilder
    private func unpublishedPorts(_ group: ContainerGroup) -> some View {
        let flagged = model.groups.unpublished(in: group)
        if !flagged.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(flagged.enumerated()), id: \.offset) { _, item in
                    UnpublishedPortsNote(member: item.member.name, ports: item.ports)
                }
                Button("Edit…") { editing = true }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func macName(_ group: ContainerGroup) -> String {
        group.place.isLocal ? "This Mac" : model.groupHostName(group)
    }

    private func summary(_ group: ContainerGroup) -> String {
        let running = model.runningContainerNames(on: group.place)
        let count = group.members.filter { running.contains($0.name) }.count
        return "\(count) of \(group.members.count) services running · \(macName(group))"
    }

    private func identity(_ group: ContainerGroup) -> some View {
        HStack(spacing: 10) {
            RowTypeMark(systemImage: Section.groupSymbol, kind: "Group",
                        logo: model.libraryLogo(for: group),
                        size: model.libraryLogo(for: group) == nil ? 16 : 32) {
                GroupStateDot(state: model.state(of: group), showsCount: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text(summary(group)).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name), \(summary(group))")
    }

    private func controls(_ group: ContainerGroup) -> some View {
        HStack(spacing: 6) {
            ActionCluster { actions(group) }
            Button("Edit…") { editing = true }
                .help("Edit \(group.name)")
            Spacer(minLength: 0)
            DetailStepper()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func services(_ group: ContainerGroup) -> some View {
        let containers = model.containers(on: group.place)
        return DetailCard(title: "Services, in start order", minHeight: nil) {
            if group.members.isEmpty {
                Text("No services. Choose Edit to add one.").foregroundStyle(.secondary)
            }
            ForEach(group.members) { member in
                let container = containers.first { $0.id == member.name }
                let facts = serviceFacts(member, container: container)
                HStack(alignment: .top, spacing: 8) {
                    ServiceStateDot(container: container).frame(width: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.name).font(.body.weight(.medium))
                        Text(facts).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if container != nil {
                        Button { openContainer(group.place.rowID(member.name)) } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                        .help("Open \(member.name)")
                        .accessibilityLabel("Open \(member.name)")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(member.name), \(container?.status.state ?? "Not created yet"), \(facts)")
                .accessibilityActions {
                    if container != nil {
                        Button("Open \(member.name)") { openContainer(group.place.rowID(member.name)) }
                    }
                }
                if member.id != group.members.last?.id { Divider() }
            }
        }
    }

    private func serviceFacts(_ member: GroupMember, container: Container?) -> String {
        var facts = [container?.imageReference ?? member.image]
        if let container {
            facts.append(container.status.state.capitalized)
            facts.append(container.portSummary.map { "Published ports: \($0)" } ?? "No published ports")
        } else {
            facts.append("Not created yet")
            facts.append(member.ports.isEmpty ? "No published ports" : "Published ports: " + member.ports.joined(separator: ", "))
        }
        if let port = member.readyPort { facts.append("Ready port: \(port)") }
        return facts.joined(separator: "\n")
    }

    private func startupCommands(_ group: ContainerGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Start will run").font(.caption).foregroundStyle(Theme.info)
            Text(group.members.isEmpty ? "Add a service to see the commands." : group.members.map {
                GroupFormView.preview(of: $0, network: group.network, redacted: true)
            }.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Text("Values are hidden here. A service whose container already exists is started rather than re-created.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
