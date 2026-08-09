import SwiftUI
import FlotillaCore

/// The Machines section: the Linux micro-VMs `container` runs containers inside.
///
/// Built to `research/MACHINES-SPEC.md`, and deliberately the **same shapes** as the containers
/// side — the owner asked for that explicitly. `SectionToolbar` for the control band, an embedded
/// detail screen with Back and a prev/next stepper, `ModalCard` for the create form, and the
/// same table/row-action idiom. A machine is a different noun, not a different app.
///
/// Where it differs, it differs because machines *are* different:
///
/// - **Delete is louder.** A machine is the VM every container on this host runs inside, so
///   deleting one destroys the substrate rather than one workload. The confirmation says so.
/// - **The default machine is called out.** `machine set-default` decides where a bare
///   `machine stop` or `machine inspect` lands, and I put the host into a no-default state
///   earlier today simply by deleting a machine — a UI that hides that fact repeats it.
/// - **Config changes need a restart**, which the form states rather than discovering.
struct MachinesView: View {
    let model: AppModel

    /// Owned by `MainWindowView`, not here — see `MachinesUIState`. Presentation, filter,
    /// search, sort and column visibility have to survive a trip to another section.
    let ui: MachinesUIState

    /// Icons rather than words, same as the containers switcher — the glyph reads faster and
    /// the word survives as the tooltip and accessibility label.
    enum Presentation: String, CaseIterable, Identifiable {
        case list = "List"
        case cards = "Cards"
        var id: Self { self }
        var systemImage: String {
            switch self {
            case .list: "list.bullet"
            case .cards: "square.grid.2x2"
            }
        }
    }

    /// A machine is running or it is not — there is no `paused`/`exited`/`created` spread the
    /// way containers have, so three cases is the whole vocabulary.
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

    private static let columnSpecs: [(id: String, title: String)] = [
        ("state", "State"),
        ("cpus", "CPUs"),
        ("memory", "Memory"),
        ("disk", "Disk"),
        ("ip", "IP"),
        ("created", "Created"),
    ]

    @State private var showingColumns = false
    @State private var showingFilter = false
    @State private var selection = Set<ContainerMachine.ID>()
    @State private var detailTarget: DetailTarget?
    @State private var showingCreate = false
    @State private var confirmingDelete: ContainerMachine?

    /// `sheet(item:)` needs `Identifiable` and a bare `String` is not — same small wrapper the
    /// containers screen uses, and keyed by **id** so the screen re-reads live state each pass
    /// rather than showing a frozen copy.
    private struct DetailTarget: Identifiable, Hashable { let id: String }

    var body: some View {
        Group {
            // Create is a screen now, not a sheet — see `MachineFormView`. Checked before the
            // detail so "New Machine" from inside a detail still lands somewhere sensible.
            if showingCreate {
                MachineFormView(model: model) { showingCreate = false }
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
                // Without this the whole stack centres vertically whenever `content` is a
                // `ContentUnavailableView` rather than a table, which floated the control band
                // into the middle of the window. The toolbar is chrome; it stays at the top.
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await model.refreshMachines() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(
            "Delete the machine “\(confirmingDelete?.id ?? "")”?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Machine", role: .destructive) {
                if let machine = confirmingDelete {
                    Task { await model.perform(.delete, on: machine) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(deleteWarning)
        }
    }

    /// Names what is actually at stake — "are you sure?" makes you go back and check which row
    /// you clicked. Extracted from the dialog because inlined it defeated the type-checker.
    private var deleteWarning: String {
        var text = "A machine is the virtual machine containers run inside. Deleting it destroys "
            + "that VM and anything stored in it, and cannot be undone."
        if confirmingDelete?.isDefault == true {
            // I put this Mac into a no-default state earlier today simply by deleting a
            // machine. A dialog that stays silent about it repeats the surprise.
            text += "\n\nThis is also the default machine, so the host will be left without one "
                + "until you set another."
        }
        return text
    }

    // MARK: List

    /// The containers screen's control band, member for member and in the same order: view
    /// switcher, columns, filter, search, updated stamp, then the create/refresh cluster.
    ///
    /// It used to be a bare `SectionToolbar` with only search and refresh, which made Machines
    /// the one section where you could not switch to cards, filter by state, or choose columns.
    /// A section that quietly offers less than its neighbours reads as unfinished rather than
    /// as a deliberate simplification.
    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: Binding(get: { ui.presentation },
                                              set: { ui.presentation = $0 })) {
                ForEach(Presentation.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("\(option.rawValue) view")
                        .help("\(option.rawValue) view")
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            columnsButton
                .disabled(ui.presentation != .list)     // cards have no columns to configure

            filterButton

            TextField("Search machines…",
                      text: Binding(get: { ui.search }, set: { ui.search = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            if let last = model.machinesLastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { showingCreate = true } label: {
                        Label("New Machine…", systemImage: "plus").labelStyle(.iconOnly)
                    }
                    .help("Create a machine…")
                    .accessibilityLabel("Create a machine")

                    Button { Task { await model.refreshMachines() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .help("Refresh machines")
                    .accessibilityLabel("Refresh machines")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var columnsButton: some View {
        Button { showingColumns.toggle() } label: {
            Image(systemName: "rectangle.split.3x1")
        }
        .help("Show or hide columns")
        .accessibilityLabel("Columns")
        .popover(isPresented: $showingColumns, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.columnSpecs, id: \.id) { spec in
                    Toggle(spec.title, isOn: columnBinding(for: spec.id))
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                }
                Divider().padding(.vertical, 6)
                HStack {
                    Button("Hide All") { setAllColumns(.hidden) }
                    Spacer()
                    Button("Show All") { setAllColumns(.visible) }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)
            .frame(width: 200)
        }
    }

    private var filterButton: some View {
        Button { showingFilter.toggle() } label: {
            Image(systemName: ui.filter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .help(ui.filter == .all ? "Filter by state"
              : "Showing \(ui.filter.rawValue.lowercased()) only")
        .accessibilityLabel("Filter by state")
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            Picker("Show", selection: Binding(get: { ui.filter }, set: { ui.filter = $0 })) {
                ForEach(Filter.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(14)
        }
    }

    private func columnBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { ui.columnCustomization[visibility: id] != .hidden },
            set: { ui.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    private func setAllColumns(_ visibility: Visibility) {
        for spec in Self.columnSpecs {
            ui.columnCustomization[visibility: spec.id] = visibility
        }
    }

    private var displayed: [ContainerMachine] {
        var machines = model.machines

        switch ui.filter {
        case .all: break
        case .running: machines = machines.filter { Self.isRunning($0) }
        case .stopped: machines = machines.filter { !Self.isRunning($0) }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // Name **and** image, because a machine's name is often generated and the image is
            // the thing you actually remember about it.
            machines = machines.filter {
                $0.id.lowercased().contains(query)
                || ($0.image?.reference.lowercased().contains(query) ?? false)
            }
        }

        return machines.sorted(using: ui.sortOrder)
    }

    @ViewBuilder
    private var content: some View {
        switch model.machinesState {
        case .idle, .loading where model.machines.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Never render a failed load as an empty list — that would look like a machine-less
            // Mac, which is the offline-detection mistake this project already made once.
            ContentUnavailableView("Can't list machines",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(reason))

        case .loaded where model.machines.isEmpty:
            ContentUnavailableView {
                Label("No machines", systemImage: "server.rack")
            } description: {
                // `ubuntu:24.04` used to be the second example here. It does not boot as a
                // machine — see `MachineCreateSheet.suggestions`. Naming an image that fails is
                // worse than naming none.
                Text("Containers run inside a Linux virtual machine. `container` creates one on "
                     + "demand, and you can also create and size them yourself — a machine is "
                     + "built from a container image, such as `alpine:3.22`, rather than an "
                     + "installer disc.")
            } actions: {
                Button("Create a machine…") { showingCreate = true }
                    .buttonStyle(.borderedProminent)
            }

        // A filter that matches nothing is not the same as having no machines, and must not
        // render as the "No machines" onboarding — that would invite you to create a second
        // machine you already have.
        //
        // The `where` is repeated on **both** patterns deliberately. Written as
        // `case .loaded, .loading where displayed.isEmpty` the condition binds only to the last
        // pattern, so `.loaded` matched unconditionally and the screen said "No matching
        // machines" while two machines sat in the model. Swift accepts that silently.
        case .loaded where displayed.isEmpty, .loading where displayed.isEmpty:
            ContentUnavailableView {
                Label("No matching machines", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(ui.filter == .all
                     ? "No machine matches “\(ui.search)”."
                     : "No \(ui.filter.rawValue.lowercased()) machine matches the current filter.")
            } actions: {
                Button("Clear filters") { ui.search = ""; ui.filter = .all }
            }

        default:
            switch ui.presentation {
            case .list: table
            case .cards: cards
            }
        }
    }

    /// The cards presentation. Same rule the containers cards follow: **identical capabilities**
    /// to the row — name is the link, the overflow menu and the bin are both present. A toggle
    /// that changes what you can do is a trap, and losing the copy menu here was a bug once.
    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(displayed) { machine in
                    machineCard(machine)
                        .contextMenu { machineMenu(for: machine) }
                }
            }
            .padding(12)
        }
    }

    private func machineCard(_ machine: ContainerMachine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Self.stateColor(machine)).frame(width: 7, height: 7)
                Button(machine.id) { detailTarget = DetailTarget(id: machine.id) }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.accentText)
                    .lineLimit(1)
                    .help("Open \(machine.id)")
                if machine.isDefault == true {
                    Text("default")
                        .font(.caption2)
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.accentTint, in: Capsule())
                        .foregroundStyle(Theme.accentText)
                }
                Spacer(minLength: 0)
            }

            Text(machine.status.capitalized)
                .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("CPUs").font(.caption2).foregroundStyle(.tertiary)
                    Text("\(machine.cpus)").font(.caption).monospacedDigit()
                }
                GridRow {
                    Text("Memory").font(.caption2).foregroundStyle(.tertiary)
                    Text(Self.bytes(machine.memory)).font(.caption).monospacedDigit()
                }
                GridRow {
                    Text("IP").font(.caption2).foregroundStyle(.tertiary)
                    Text(machine.ipAddress ?? "—").font(.caption).monospacedDigit()
                }
            }

            Divider()
            rowActions(for: machine)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 9))
    }

    private var table: some View {
        SwiftUI.Table(displayed,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("State", value: \.sortRank) { machine in
                HStack(spacing: 6) {
                    Circle().fill(Self.stateColor(machine)).frame(width: 7, height: 7)
                    Text(machine.status.capitalized)
                }
            }
            .width(min: 76, ideal: 92)
            .customizationID("state")

            TableColumn("Name") { machine in
                HStack(spacing: 6) {
                    Button(machine.id) { detailTarget = DetailTarget(id: machine.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .help("Open \(machine.id)")
                    // Which machine a bare `machine stop` or `inspect` would hit. Not cosmetic.
                    if machine.isDefault == true {
                        Text("default")
                            .font(.caption2)
                            // Without this the badge is the first thing the column sacrifices
                            // and it rendered as "defa…", which reads like a truncated name
                            // rather than a label. A four-character mystery word is worse than
                            // no badge; it has to be the last thing to give.
                            .fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accentTint, in: Capsule())
                            .foregroundStyle(Theme.accentText)
                    }
                }
            }
            // Machine names run longer than container names — `container` generates them with a
            // hash suffix — and at the default width "probe-alpine-latest" wrapped to two lines
            // and pushed the rows out of alignment.
            .width(min: 150, ideal: 210)
            // No `customizationID` — the name is how you identify and open a row, so it is not
            // something to hide. Same reason the containers table pins its Name column.

            TableColumn("CPUs") { machine in
                Text("\(machine.cpus)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 52, ideal: 60)
            .customizationID("cpus")

            TableColumn("Memory") { machine in
                Text(Self.bytes(machine.memory)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 84)
            .customizationID("memory")

            TableColumn("Disk") { machine in
                Text(Self.bytes(machine.diskSize)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 84)
            .customizationID("disk")

            TableColumn("IP") { machine in
                Text(machine.ipAddress ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 120)
            .customizationID("ip")

            TableColumn("Created") { machine in
                Text(RelativeDate.relative(machine.createdDate))
                    .foregroundStyle(.secondary)
                    .help(RelativeDate.absolute(machine.createdDate))
            }
            .width(min: 80, ideal: 100)
            .customizationID("created")

            TableColumn("Actions") { machine in
                rowActions(for: machine)
            }
            .width(min: 108, ideal: 120)
        }
        .contextMenu(forSelectionType: ContainerMachine.ID.self) { ids in
            if let machine = model.machines.first(where: { ids.contains($0.id) }) {
                machineMenu(for: machine)
            }
        } primaryAction: { ids in
            if let id = ids.first { detailTarget = DetailTarget(id: id) }
        }
    }

    /// Same shape as the containers row: start/stop swap, overflow menu, then delete behind a
    /// divider — icon-only with the word kept as tooltip and accessibility label.
    @ViewBuilder
    private func rowActions(for machine: ContainerMachine) -> some View {
        let busy = model.busyMachines.contains(machine.id)
        HStack(spacing: 2) {
            if Self.isRunning(machine) {
                iconButton("stop.fill", "Stop \(machine.id)", busy: busy) {
                    Task { await model.perform(.stop, on: machine) }
                }
            } else {
                iconButton("play.fill", "Start \(machine.id)", busy: busy) {
                    Task { await model.perform(.start, on: machine) }
                }
            }

            Menu {
                machineMenu(for: machine)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel("More actions for \(machine.id)")

            Divider().frame(height: 14)

            iconButton("trash", "Delete \(machine.id)", busy: busy, destructive: true) {
                confirmingDelete = machine
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func machineMenu(for machine: ContainerMachine) -> some View {
        Button("Details…") { detailTarget = DetailTarget(id: machine.id) }
        // Edit opens the machine's own Settings tab rather than a second copy of the form.
        // `machine set` only accepts cpus, memory and home-mount — an "edit" that showed the
        // image and name as though they were changeable would be lying about what the CLI can
        // do, and the Settings tab already states the restart requirement.
        Button("Edit Settings…") {
            model.lastMachineTab[machine.id] = .settings
            detailTarget = DetailTarget(id: machine.id)
        }
        Divider()
        if machine.isDefault != true {
            Button("Set as Default") { Task { await model.perform(.setDefault, on: machine) } }
        }
        if Self.isRunning(machine) {
            Button("Stop") { Task { await model.perform(.stop, on: machine) } }
        } else {
            Button("Start") { Task { await model.perform(.start, on: machine) } }
        }
        Divider()
        CopyMenu([
            ("Name", machine.id),
            ("IP Address", machine.ipAddress),
            ("Image", machine.image?.reference),
        ])
        Divider()
        Button("Delete…", role: .destructive) { confirmingDelete = machine }
    }

    private func iconButton(_ symbol: String, _ label: String, busy: Bool,
                            destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(destructive ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
        .disabled(busy)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Detail

    @ViewBuilder
    private func detailScreen(_ target: DetailTarget) -> some View {
        VStack(spacing: 0) {
            if let machine = model.machines.first(where: { $0.id == target.id }) {
                detailHeader(for: machine)
                Divider()
                MachineDetailView(model: model, machine: machine)
            } else {
                detailHeader(for: nil)
                Divider()
                ContentUnavailableView(
                    "Machine unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("“\(target.id)” is no longer on this Mac. It may have been deleted.")
                )
            }
        }
    }

    @ViewBuilder
    private func detailHeader(for machine: ContainerMachine?) -> some View {
        HStack(spacing: 10) {
            Button { detailTarget = nil } label: { Image(systemName: "chevron.left") }
                .help("Back to Machines")
                .accessibilityLabel("Back to Machines")

            if let machine {
                Image(systemName: "server.rack")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(machine.id).font(.headline)
                        HStack(spacing: 4) {
                            Circle().fill(Self.stateColor(machine)).frame(width: 6, height: 6)
                            Text(machine.status.capitalized).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        if machine.isDefault == true {
                            Text("default").font(.caption2).foregroundStyle(Theme.accentText)
                        }
                    }
                    Text(subtitle(for: machine))
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text("Machine unavailable").font(.headline)
            }

            Spacer()
            stepper
            if let machine {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) { rowActions(for: machine) }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(in: .rect(cornerRadius: 8))
                }
                .fixedSize()
            }
        }
        .padding(12)
    }

    /// Steps through machines as currently shown, same rules as the containers stepper: no
    /// wrapping, buttons disable at the ends, and the position is stated.
    @ViewBuilder
    private var stepper: some View {
        let order = displayed
        let index = order.firstIndex { $0.id == detailTarget?.id }
        HStack(spacing: 2) {
            Button {
                if let index, index > 0 { detailTarget = DetailTarget(id: order[index - 1].id) }
            } label: { Image(systemName: "chevron.up") }
                .disabled(index == nil || index == 0)
                .help("Previous machine")
                .accessibilityLabel("Previous machine")

            Button {
                if let index, index < order.count - 1 {
                    detailTarget = DetailTarget(id: order[index + 1].id)
                }
            } label: { Image(systemName: "chevron.down") }
                .disabled(index == nil || index == order.count - 1)
                .help("Next machine")
                .accessibilityLabel("Next machine")

            if let index {
                Text("\(index + 1) of \(order.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private func subtitle(for machine: ContainerMachine) -> String {
        var parts: [String] = []
        if let image = machine.image?.reference {
            parts.append(ContainerImage.shortReference(image))
        }
        parts.append("\(machine.cpus) CPU\(machine.cpus == 1 ? "" : "s")")
        parts.append(Self.bytes(machine.memory))
        if let ip = machine.ipAddress { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    /// `status`, not `state` — the machine payload spells it differently from `Container`, which
    /// is the sort of detail the captured fixture settled and a guess would have got wrong.
    static func isRunning(_ machine: ContainerMachine) -> Bool {
        machine.status.caseInsensitiveCompare("running") == .orderedSame
    }

    static func stateColor(_ machine: ContainerMachine) -> Color {
        if isRunning(machine) { return Theme.online }
        let status = machine.status.lowercased()
        if status.contains("error") || status.contains("fail") { return Theme.danger }
        if status.contains("start") || status.contains("stopp") { return Theme.warning }
        return .secondary
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}
