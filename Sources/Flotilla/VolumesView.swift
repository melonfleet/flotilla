import SwiftUI
import Foundation
import FlotillaCore

/// The volumes section: list, create, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct VolumesView: View {
    let model: AppModel
    /// Owned by `MainWindowView` — see `ResourceUIState`. Search, sort and column visibility
    /// have to outlive a trip to another section.
    let ui: ResourceUIState<ContainerVolume>

    @State private var selection = Set<ContainerVolume.ID>()
    @State private var showingCreate = false
    @State private var newVolumeName = ""
    @State private var newSize = ""
    @State private var newLabels: [String] = []
    @State private var newDriverOptions: [String] = []
    @State private var pendingDelete: ContainerVolume?

    var body: some View {
        Group {
            if showingCreate {
                createScreen
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
                // Same band as Containers and Machines. See `ResourceUIState.activityExpanded`
                // for why it is collapsible: on this section it is usually empty.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  open: { _ in })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshVolumes() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Delete volume “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let volume = pendingDelete {
                    Task { await model.removeVolume(volume) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search volumes…",
                       updated: model.volumesLastRefresh,
                       leading: {
            ResourceListControls<ContainerVolume>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: driverFilters)
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "Create a volume…") {
                newVolumeName = ""
                showingCreate = true
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh volumes") {
                Task { await model.refreshVolumes() }
            }
        })
    }

    /// Free-text filter over the volume name.
    private var displayedVolumes: [ContainerVolume] {
        var volumes = model.volumes

        // The driver filter, when there is more than one driver to choose between.
        if ui.filterID != "all" {
            volumes = volumes.filter { $0.configuration.driver == ui.filterID }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // `name` is non-optional: the real payload nests it under `configuration` where it
            // is always present. It was optional before commit 9245077 fixed the fabricated
            // fixture, and a `?? ""` here was leftover defensive code from that shape.
            volumes = volumes.filter { $0.name.lowercased().contains(query) }
        }

        return volumes.sorted(using: ui.sortOrder)
    }

    /// This section's slice of the one activity feed. Rows do not navigate — you are already
    /// on the section they belong to.
    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .volume).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
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

        case .loaded where model.volumes.isEmpty:
            ContentUnavailableView(
                "No volumes",
                systemImage: "cylinder.split.1x2",
                description: Text("Create one to persist data across container runs.")
            )

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("format", "Format"), ("driver", "Driver"), ("size", "Size"), ("created", "Created"),
    ]

    /// One option per driver actually present, plus All.
    ///
    /// Derived rather than fixed, and `ResourceListControls` hides the control when this yields
    /// fewer than two entries — which is the common case here, since every volume on a stock
    /// install is `local`. A filter whose every setting returns the same rows is worse than no
    /// filter, and "the other sections have one" is not a reason to ship it.
    private var driverFilters: [ResourceFilterOption] {
        let drivers = Set(model.volumes.compactMap { $0.configuration.driver }).sorted()
        guard drivers.count > 1 else { return [] }
        return [ResourceFilterOption(id: "all", title: "All", systemImage: "circle.grid.2x2")]
            + drivers.map {
                ResourceFilterOption(id: $0, title: $0.capitalized, systemImage: "internaldrive")
            }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedVolumes) { volume in
                ResourceCard(
                    title: volume.name,
                    fields: [("Format", volume.configuration.format),
                             ("Driver", volume.configuration.driver),
                             ("Size", volume.sizeInBytes.map(Self.byteCount)),
                             ("Created", RelativeDate.relative(volume.configuration.creationDate))],
                    onOpen: nil
                ) {
                    rowActions(for: volume)
                }
                .contextMenu { menu(for: volume) }
            }
        }
    }

    /// A `Table`, matching Containers and Machines.
    ///
    /// This was a `List` of two-line rows with the metadata crammed into a caption line —
    /// readable for three volumes, useless for thirty, and not sortable by anything. The owner asked
    /// for the sections to look the same, and the deeper reason is that they *are* the same kind
    /// of screen: a list of named things with attributes you want to sort and compare.
    ///
    /// No state column. A volume has no lifecycle — it exists or it does not — so a dot would be
    /// a decoration that always said the same thing.
    private var table: some View {
        SwiftUI.Table(displayedVolumes,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("Name", value: \.name) { volume in
                Text(volume.name).foregroundStyle(Theme.accentText).lineLimit(1)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Format") { volume in
                Text(volume.configuration.format ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 84)
            .customizationID("format")

            TableColumn("Driver") { volume in
                Text(volume.configuration.driver ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID("driver")

            TableColumn("Size") { volume in
                Text(volume.sizeInBytes.map(Self.byteCount) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 74, ideal: 90)
            .customizationID("size")

            TableColumn("Created") { volume in
                Text(RelativeDate.relative(volume.configuration.creationDate))
                    .foregroundStyle(.secondary)
                    .help(RelativeDate.absolute(volume.configuration.creationDate))
            }
            .width(min: 80, ideal: 104)
            .customizationID("created")

            TableColumn("Actions") { volume in
                rowActions(for: volume)
            }
            .width(min: 78, ideal: 88)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: ContainerVolume.ID.self) { ids in
            if let volume = model.volumes.first(where: { ids.contains($0.id) }) {
                menu(for: volume)
            }
        }
    }

    /// Overflow then bin, in that order and with the same divider — the arrangement every other
    /// section uses, so the destructive control is always in the same place.
    @ViewBuilder
    private func rowActions(for volume: ContainerVolume) -> some View {
        let busy = model.busy.contains(volume.id)
        HStack(spacing: 2) {
            Menu {
                menu(for: volume)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel("More actions for \(volume.name)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(volume.name)",
                             help: "Delete \(volume.name)",
                             busy: busy, destructive: true) {
                requestDelete(volume)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(for volume: ContainerVolume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                HStack(spacing: 8) {
                    if let format = volume.format {
                        Text(format).font(.caption).foregroundStyle(.secondary)
                    }
                    if let size = volume.sizeInBytes {
                        Text(Self.byteCount(size)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let createdAt = volume.createdAt {
                        // Age, not a raw ISO timestamp — see `RelativeDate`. The exact value
                        // is one hover away.
                        Text(RelativeDate.relative(createdAt, prefix: "Created"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(RelativeDate.absolute(createdAt))
                    }
                }
            }
            Spacer()
            IconActionButton(systemImage: "trash",
                             label: "Delete \(volume.name)",
                             help: "Delete \(volume.name)",
                             busy: model.busy.contains(volume.id),
                             destructive: true) {
                requestDelete(volume)
            }
        }
        .padding(.vertical, 4)
        // On the whole row (and after `.padding`, so the hit area covers the padding too),
        // not on the label — a menu you can only summon by right-clicking exactly the text
        // reads as no menu at all. Shape per `ContextMenus.swift`: actions, Copy, destructive
        // last.
        .contextMenu { menu(for: volume) }
    }

    @ViewBuilder
    private func menu(for volume: ContainerVolume) -> some View {
        CopyMenu([
            ("Name", volume.name),
            ("Source Path", volume.source),
            ("Format", volume.format),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(volume) }
            .disabled(model.busy.contains(volume.id))
    }

    /// Embedded, not modal — see `MachineFormView` for the 9 August reversal.
    private var createScreen: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Volume", systemImage: "externaldrive.badge.plus",
                       onBack: { showingCreate = false })
            Divider()
            createForm
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-data", text: $newVolumeName)
                    .textFieldStyle(.roundedBorder)
                if let problem = nameProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                TextField("64M, 2G, …", text: $newSize)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                if let problem = sizeProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                } else {
                    // Worth stating: the default is enormous and sparse, which is why the
                    // Size column in the list looks alarming until you set one yourself.
                    Text("Optional. Left empty the driver provisions 512 GiB as a sparse image — it does not consume that, but it is what the size column reports.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueList($newLabels, title: "Labels", placeholder: "team=infra")
                    keyValueList($newDriverOptions, title: "Driver options", placeholder: "type=fast")
                }
                .padding(.top, 8)
            }

            Divider()

            Text((["container"] + ContainerCLI.createVolumeArguments(trimmedName, options: options))
                    .joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Create") {
                    let name = trimmedName
                    let opts = options
                    showingCreate = false
                    Task { await model.createVolume(name, options: opts) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || anyProblem != nil)
            }
        }
    }

    /// Repeatable `key=value` flags, capped at the `Allowlist`'s own maximum of 8 — shown
    /// rather than silently enforced.
    @ViewBuilder
    private func keyValueList(_ list: Binding<[String]>, title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.wrappedValue.count)/8").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { list.wrappedValue.indices.contains(index) ? list.wrappedValue[index] : "" },
                        set: { if list.wrappedValue.indices.contains(index) { list.wrappedValue[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { list.wrappedValue.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove")
                }
            }
            Button { list.wrappedValue.append("") } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(list.wrappedValue.count >= 8)
        }
    }

    private var options: ContainerCLI.VolumeOptions {
        ContainerCLI.VolumeOptions(
            size: newSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : newSize.trimmingCharacters(in: .whitespacesAndNewlines),
            labels: newLabels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            driverOptions: newDriverOptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    private var sizeProblem: String? {
        let value = newSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments("placeholder", options: .init(size: value)))
    }

    /// One pass over the whole command, so Create is disabled for any bad field — labels and
    /// driver options included, not just the two with their own messages.
    private var anyProblem: String? {
        problem(in: ContainerCLI.createVolumeArguments(
            trimmedName.isEmpty ? "placeholder" : trimmedName, options: options))
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    private var trimmedName: String {
        newVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments(trimmedName))
    }

    /// Honours `confirmDestructiveActions` — the whole point of that registry key.
    private func requestDelete(_ volume: ContainerVolume) {
        if model.settingsStore[SettingsKeys.confirmDestructiveActions] {
            pendingDelete = volume
        } else {
            Task { await model.removeVolume(volume) }
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
