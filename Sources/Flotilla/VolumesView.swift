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
    /// Name of the volume whose inspect record is on screen, or nil. A name rather than the value:
    /// the sheet refetches, so holding a stale struct would show old data next to a live command.
    @State private var inspecting: String?
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
        .sheet(isPresented: Binding(get: { inspecting != nil },
                                    set: { if !$0 { inspecting = nil } })) {
            if let name = inspecting {
                InspectSheet(title: name,
                             command: "container volume inspect \(name)",
                             load: { try await model.fetchVolumeInspectJSON(for: name) },
                             dismiss: { inspecting = nil })
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
                filters: volumeFilters)
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
    /// Whether anything is currently narrowing the list. Drives the empty state's wording and
    /// its action: "no matches, clear the filter" and "none exist, make one" are different
    /// situations and only one of them is the user's mistake.
    private var isFiltered: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" }

    private var displayedVolumes: [ContainerVolume] {
        var volumes = model.volumes

        // The one filter control covers two independent facets — age and label — because
        // `ResourceUIState.filterID` is a single selected string, not a set of facets. The id
        // itself says which facet fired: an age bucket's id round-trips through `VolumeAgeBucket`,
        // anything else is checked against the `label:` prefix.
        if let bucket = VolumeSizeBucket.allCases.first(where: { $0.filterID == ui.filterID }) {
            volumes = volumes.filter { Self.sizeBucket(for: $0) == bucket }
        } else if let bucket = VolumeAgeBucket.allCases.first(where: { $0.filterID == ui.filterID }) {
            volumes = volumes.filter { Self.ageBucket(for: $0) == bucket }
        } else if ui.filterID.hasPrefix(Self.labelFilterPrefix) {
            let pair = ui.filterID.dropFirst(Self.labelFilterPrefix.count)
            if let separator = pair.firstIndex(of: "=") {
                let key = String(pair[..<separator])
                let value = String(pair[pair.index(after: separator)...])
                volumes = volumes.filter { $0.configuration.labels?[key] == value }
            }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // `name` is non-optional: the real payload nests it under `configuration` where it
            // is always present. It was optional before commit c258911 fixed the fabricated
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
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
                } else {
                    Button("New Volume…") { showingCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            }

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("format", "Format"), ("driver", "Driver"), ("size", "Size"), ("created", "Created"),
    ]

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
        let total = model.volumes.count

        // Age. A volume with no readable `creationDate` is its own (unlabelled) category —
        // "unknown", never "old" — so it still makes a bucket meaningful even when every dated
        // volume falls in the same one: selecting that bucket would exclude the undated volumes.
        // Only when literally everything (dated or not) lands in one category does a bucket
        // filter nothing, and that is when it is withheld.
        let presentBuckets = Set(model.volumes.compactMap(Self.ageBucket(for:)))
        let hasUnknownAge = model.volumes.contains { Self.ageBucket(for: $0) == nil }
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
        let pairCounts = model.volumes
            .flatMap { ($0.configuration.labels ?? [:]).map { "\($0.key)=\($0.value)" } }
            .reduce(into: [String: Int]()) { counts, pair in counts[pair, default: 0] += 1 }
        let labelOptions = pairCounts.keys.sorted().compactMap { pair -> ResourceFilterOption? in
            guard pairCounts[pair] ?? 0 < total else { return nil }
            return ResourceFilterOption(id: Self.labelFilterPrefix + pair, title: pair, systemImage: "tag")
        }

        // Size. Same rule as age: offered only when the volumes actually straddle the boundary,
        // so selecting a bucket can never produce an empty list.
        let presentSizes = Set(model.volumes.compactMap(Self.sizeBucket(for:)))
        let hasUnknownSize = model.volumes.contains { Self.sizeBucket(for: $0) == nil }
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

            TableColumn("Format", value: \.formatSortKey) { volume in
                Text(volume.configuration.format ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 84)
            .customizationID("format")

            TableColumn("Driver", value: \.driverSortKey) { volume in
                Text(volume.configuration.driver ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            .customizationID("driver")

            TableColumn("Size", value: \.sizeSortKey) { volume in
                Text(volume.sizeInBytes.map(Self.byteCount) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 74, ideal: 90)
            .customizationID("size")

            TableColumn("Created", value: \.creationSortKey) { volume in
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
        // First, above Copy: `volume inspect` was allowlisted from the start with nothing able to
        // call it (GAP-06). This is the authoritative record — `options`, `labels`, the on-disk
        // source — rather than the columns this table chose to show.
        Button("Inspect…") { inspecting = volume.name }
        Divider()
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

    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ volume: ContainerVolume) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = volume
        } else {
            Task { await model.removeVolume(volume) }
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
