import SwiftUI
import FlotillaCore

/// Suggestions for Containers: the suggestions library (DECISIONS Q28, Q54) — ready-made stacks and
/// single containers, browsed like Images ▸ Browse Docker Hub (the owner, 12 October): search and a
/// category on the left, the chosen entry on the right, Use… in the footer.
///
/// Reached from the "+" menu and from the empty Containers list. A stack opens its form and is
/// created as a group; a container opens the Run form filled in. Either way the form validates it
/// like anything typed — a library entry is a suggestion, not a command.
///
/// Two or more ticked rows offer **Use N Suggestions…**, which walks the same forms one by one
/// (TODO item 15): Save runs and opens the next, Skip advances without running, Cancel stops the
/// walk. Single Use… is unchanged.
struct SuggestionsView: View {
    let model: AppModel
    let dismiss: () -> Void
    /// Opened straight into one stack's form — from the empty state's quick picks.
    @State var chosen: StackSuggestion?

    /// Typed in the window bar's search box (Q55), which this page lends it while the list is showing.
    @State private var queryText = PageSearchText()
    private var query: String { queryText.value }
    @State private var category: String?
    /// The list's own selection — checkboxes are a view of it (Q56), not a second set.
    @State private var selection = Set<LibraryEntry.ID>()
    /// In-flight multi-suggest walk; nil while browsing or on a single Use….
    @State private var batch: SuggestionBatch?
    /// Prefill for a container step inside a batch (Run lives here so the walk can continue).
    @State private var batchRunPrefill: RunPrefill?

    private var library: SuggestionLibrary { model.suggestionLibrary }

    private var shown: [LibraryEntry] {
        library.entries.filter { entry in
            (category == nil || entry.categories.contains(category!)) && entry.matches(query)
        }
    }

    private var shownIDs: [LibraryEntry.ID] { shown.map(\.id) }
    private var selectedEntries: [LibraryEntry] {
        shown.filter { selection.contains($0.id) }
    }
    private var selected: LibraryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.entries.first { $0.id == id }
    }
    private var clashNotes: [String] { SuggestionPorts.clashNotes(for: selectedEntries) }

    var body: some View {
        if let batch, let entry = library.entries.first(where: { $0.id == batch.currentID }) {
            batchStep(entry, batch: batch)
                .id("\(batch.index)-\(entry.id)")
        } else if let chosen {
            StackFormView(model: model, stack: chosen, back: { self.chosen = nil }, done: dismiss)
                .id(chosen.id)
        } else {
            VStack(spacing: 0) {
                FormHeader(title: "Suggestions", systemImage: "sparkles",
                           hasUnsavedChanges: false, onBack: dismiss)
                Divider()
                SplitPanes("suggestions", item: selected?.id, clearing: { selection = [] }) { listPane } detail: { detailPane }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .searchesFromToolbar(prompt: "Search suggestions",
                                 text: Binding(get: { [weak queryText] in queryText?.value ?? "" },
                                               set: { [weak queryText] in queryText?.value = $0 }),
                                 matches: shown.count)
            .onAppear { openRequestedEntry() }
            .onChange(of: model.pendingSuggestionEntry) { _, _ in openRequestedEntry() }
            // Use… checks a container's new volumes against what is here, so the list must be.
            .task { if model.volumesState != .loaded { await model.refreshVolumes() } }
            .selection($selection, confinedTo: Set(shownIDs))
        }
    }

    // MARK: Multi-suggest step-through

    @ViewBuilder
    private func batchStep(_ entry: LibraryEntry, batch: SuggestionBatch) -> some View {
        if let stack = entry.stackSuggestion {
            StackFormView(model: model, stack: stack,
                          back: cancelBatch,
                          done: { advanceBatch() },
                          progressLabel: batch.progressLabel,
                          onSkip: { advanceBatch() },
                          onCreated: { ports in advanceBatch(claiming: ports) },
                          extraAvoidedPorts: batch.claimedPorts)
        } else if let prefill = batchRunPrefill {
            RunSheetView(model: model, prefill: prefill,
                         progressLabel: batch.progressLabel,
                         onSkip: { advanceBatch() },
                         onRan: { ports in advanceBatch(claiming: ports) },
                         dismiss: cancelBatch)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await openBatchStep(entry) }
        }
    }

    private func openRequestedEntry() {
        guard let id = model.pendingSuggestionEntry else { return }
        category = nil
        queryText.value = ""
        selection = [id]
        model.pendingSuggestionEntry = nil
    }

    private func startBatch() {
        let queue = shownIDs.filter { selection.contains($0) }
        guard queue.count >= 2 else { return }
        batch = SuggestionBatch(queue: queue)
        batchRunPrefill = nil
    }

    private func openBatchStep(_ entry: LibraryEntry) async {
        if entry.stackSuggestion != nil {
            batchRunPrefill = nil
            return
        }
        guard let container = entry.container else {
            advanceBatch()
            return
        }
        await model.prepareSuggestions()
        if model.volumesState != .loaded { await model.refreshVolumes() }
        let avoiding = (batch?.claimedPorts ?? []).union(model.stackTaken(on: .local).hostPorts)
        let ports = await Blocking.run {
            SuggestionPorts.publishSpecs(for: container, avoiding: avoiding, isPortFree: AppModel.isPortFree)
        }
        var prefill = runPrefill(for: container, ports: ports.specs)
        prefill.unavailablePorts = ports.unavailablePorts
        batchRunPrefill = prefill
    }

    private func advanceBatch(claiming ports: Set<Int> = []) {
        batchRunPrefill = nil
        guard var walk = batch else { return }
        walk.advance(claiming: ports)
        if walk.isFinished {
            finishBatch()
        } else {
            batch = walk
        }
    }

    private func cancelBatch() {
        batch = nil
        batchRunPrefill = nil
    }

    private func finishBatch() {
        batch = nil
        batchRunPrefill = nil
        selection = []
        dismiss()
    }

    // MARK: List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PaneModeButton()
                SelectAllCheckbox(selection: $selection, ids: shownIDs, noun: "suggestions")
                // The search is the window bar's box now (Q55).
                Picker("", selection: $category) {
                    Text("All categories").tag(String?.none)
                    Divider()
                    ForEach(SuggestionLibrary.categories.filter { name in library.entries.contains { $0.categories.contains(name) } },
                            id: \.self) { name in
                        Text("\(name) (\(library.entries.count { $0.categories.contains(name) }))").tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("\(shown.count) of \(library.entries.count) · library \(library.version)")
                .font(.caption).foregroundStyle(.secondary)
            if !clashNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(clashNotes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SelectionRevealingList(selection: selection) {
                List(shown, selection: $selection) { entry in
                    row(entry)
                        .tag(entry.id)
                        .listRowInsets(EdgeInsets())
                }
                .listStyle(.inset)
            }
            .overlay {
                if shown.isEmpty { ContentUnavailableView.search(text: query) }
            }
        }
        .padding(16)
    }

    private func row(_ entry: LibraryEntry) -> some View {
        ResourceRow(
            title: entry.title,
            detail: entry.summary,
            thirdLine: Self.stats(entry),
            selected: selection.contains(entry.id),
            check: RowCheck(entry.id, in: $selection),
            summary: "\(entry.title), \(entry.kind == .stack ? "Stack" : "Container"), \(entry.summary), \(Self.stats(entry))\(entry.licenceNote == nil ? "" : ", Licence")",
            leading: { logo(entry) },
            chips: {
                badge(entry.kind == .stack ? "Stack" : "Container")
                if entry.licenceNote != nil { badge("Licence") }
            },
            actions: {
                Menu { suggestionMenu(entry) } label: { RowOverflowLabel() }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("More actions for \(entry.title)")
            })
        .contextMenu { suggestionMenu(entry) }
    }

    private func suggestionMenu(_ entry: LibraryEntry) -> some View {
        Button(selection.contains(entry.id) && selection.count > 1 ? "Use \(selection.count) Suggestions…" : "Use…") {
            if selection.contains(entry.id), selection.count > 1 { startBatch() }
            else { use(entry) }
        }
    }

    private func logo(_ entry: LibraryEntry) -> some View {
        SuggestionLogo(data: entry.icon.flatMap { model.libraryUpdater.icons[$0.sha256] },
                       category: entry.categories.first)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.info.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.info)
    }

    static func stats(_ entry: LibraryEntry) -> String {
        var parts = [entry.categories.joined(separator: ", ")]
        if let stack = entry.stack { parts.append(stack.services.map(\.title).joined(separator: " · ")) }
        if let container = entry.container { parts.append(shortImage(container.image)) }
        parts.append(entry.tested.map { "Tested \($0.date)" } ?? "Not tested yet")
        return parts.joined(separator: " · ")
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if selection.count > 1 {
            SelectionSummaryPane(title: "\(selection.count) suggestions selected",
                                 systemImage: "sparkles",
                                 names: selectedEntries.map(\.title)) {
                Button("Use \(selection.count) Suggestions…") { startBatch() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let entry = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        logo(entry)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                            Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.categories.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let stack = entry.stack {
                        section("Services") {
                            ForEach(stack.services, id: \.role) { service in
                                detailLine(service.title, Self.shortImage(service.image))
                            }
                        }
                        if !stack.notes.isEmpty {
                            section("Once it's running") {
                                ForEach(stack.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let container = entry.container {
                        section("Container") {
                            detailLine("Image", Self.shortImage(container.image))
                            if !container.ports.isEmpty { detailLine("Ports", container.ports.joined(separator: ", ")) }
                            ForEach(container.volumes, id: \.path) { detailLine("Data", $0.path) }
                            if !container.secretEnv.isEmpty {
                                detailLine("Passwords", container.secretEnv.joined(separator: ", ") + " — generated")
                            }
                        }
                        if let note = container.note {
                            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SuggestionAdvisory(model: model, entry: entry)
                    if let licence = entry.licenceNote {
                        Label(licence, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(entry.tested.map { "Run and checked by Flotilla on \($0.date), on \($0.macs) Mac\($0.macs == 1 ? "" : "s")." }
                         ?? "Not live-tested yet.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else {
            ContentUnavailableView("Choose a suggestion", systemImage: "sparkles",
                                   description: Text("What it runs and what it needs show here."))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).padding(.top, 6)
            content()
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(selection.count >= 2
                 ? "Each opens its form in turn. Save runs it; Skip goes on; Cancel stops the rest."
                 : "A stack is created as a group, left ready to start. A container opens in the Run form.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            if selection.count >= 2 {
                Button("Use \(selection.count) Suggestions…") { startBatch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Use…") { use() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func use() {
        guard let entry = selected else { return }
        use(entry)
    }

    private func use(_ entry: LibraryEntry) {
        if let stack = entry.stackSuggestion {
            chosen = stack
        } else if let container = entry.container {
            model.pendingRunPrefill = runPrefill(for: container,
                                                 ports: container.ports.map { "127.0.0.1:\($0)" })
            dismiss()
        }
    }

    /// Into the Run form: a free name, generated passwords, published on 127.0.0.1. The volumes
    /// it mounts are always new — a volume named after an existing one would hand that data to
    /// the image (Kyle, 13 October).
    private func runPrefill(for container: LibraryContainer, ports: [String]) -> RunPrefill {
        let taken = model.existingContainerNames(on: .local).union(model.groups.claimedNames(on: .local))
        let volumes = Set(model.volumes.map(\.name))
        var name = container.name
        var counter = 2
        while taken.contains(name) || container.volumes.contains(where: { volumes.contains("\(name)-\($0.suffix)") }) {
            name = "\(container.name)-\(counter)"; counter += 1
        }
        let env = container.env + container.secretEnv.map { "\($0)=\(GroupSecrets.generatePassword())" }
        return RunPrefill(
            draftImage: container.image, name: name, ports: ports, env: env,
            volumes: container.volumes.map { "\(name)-\($0.suffix):\($0.path)" },
            command: container.command, source: .library,
            volumeOwners: Dictionary(uniqueKeysWithValues: container.volumes.compactMap { volume in
                volume.volumeOwner.map { ("\(name)-\(volume.suffix):\(volume.path)", $0) }
            }))
    }

    /// `docker.io/library/postgres:18.6` → `postgres:18.6`.
    static func shortImage(_ image: String) -> String {
        image.replacingOccurrences(of: "docker.io/library/", with: "")
            .replacingOccurrences(of: "docker.io/", with: "")
    }
}

/// One stack's form: what it will be called, where it goes, and its few choices — every one with a
/// working default, so Create works untouched (the owner, 6 October: fields the user can
/// pre-select, bound to the stack once built).
struct StackFormView: View {
    let model: AppModel
    let stack: StackSuggestion
    let back: () -> Void
    let done: () -> Void
    /// "1 of N" while walking several suggestions; nil for a normal Use….
    var progressLabel: String? = nil
    /// Skip this suggestion without creating — only set during a multi-suggest walk.
    var onSkip: (() -> Void)? = nil
    /// After Create during a multi-suggest walk: claim these web host ports for later steps.
    var onCreated: ((Set<Int>) -> Void)? = nil
    /// Ports already claimed by earlier saved steps in a multi-suggest walk.
    var extraAvoidedPorts: Set<Int> = []

    @State private var name = ""
    @State private var network: StackChoices.Network = .new
    @State private var webPorts: [String: String] = [:]
    @State private var options: [String: String] = [:]
    @State private var usedPorts: Set<Int> = []
    @State private var prepared = false
    @State private var edits = FormEditTracker()
    /// Shared by the header and the Cancel button, so both ask about this form alone.
    @State private var formToken = UUID()
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    /// Which Mac the stack is created on (the owner, 12 October).
    @State private var host: HostRef = .local
    /// For a stack on a host: its web pages open from other Macs too. On by default there, since
    /// a stack is put on a host to be used from elsewhere; This Mac's stay on 127.0.0.1.
    @State private var webFromOtherMacs = true

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var hostName: String { model.hostMode.hostName(host, local: model.hostLabel) }
    private var networks: [ContainerNetwork] { model.networks(on: host) ?? [] }
    /// The address "Open" uses for a host's stack: the one its owner typed, when known; never this
    /// Mac's loopback for a page on another Mac. Kept on the host's own 127.0.0.1, it opens only there.
    private var openAddress: String? {
        guard case .peer(let fingerprint) = host else { return "127.0.0.1" }
        guard webFromOtherMacs else { return nil }
        return model.hostMode.probeAddress(for: fingerprint)
    }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        return StackPlanner.nameProblem(trimmedName, stack: stack, network: network,
                                        taken: model.stackTaken(on: host),
                                        groupNames: Set(model.groups.book.groups.map(\.name)))
    }

    private func portProblem(_ role: String) -> String? {
        let text = (webPorts[role] ?? "").trimmingCharacters(in: .whitespaces)
        if text.isEmpty, let web = stack.services.first(where: { $0.role == role })?.webPort {
            return SuggestionPorts.unavailableMessage(near: SuggestionPorts.preferredWebHostPort(web))
        }
        guard let port = Int(text), (1024...65535).contains(port) else {
            return "Use a port from 1024 to 65535."
        }
        if usedPorts.contains(port) {
            return host.isLocal ? "Something on this Mac already uses \(port)." : "Something on \(hostName) already uses \(port)."
        }
        let others = webPorts.filter { $0.key != role }.compactMap { Int($0.value) }
        if others.contains(port) { return "Two pages can't share a port." }
        return nil
    }

    private func optionProblem(_ option: StackOption) -> String? {
        option.problem(with: (options[option.id] ?? option.defaultValue).trimmingCharacters(in: .whitespaces))
    }

    private var choices: StackChoices {
        StackChoices(name: trimmedName, network: network,
                     webPorts: webPorts.compactMapValues { Int($0.trimmingCharacters(in: .whitespaces)) },
                     options: options, webFromOtherMacs: !host.isLocal && webFromOtherMacs,
                     openAddress: openAddress)
    }

    private var webServices: [StackService] { stack.services.filter { $0.webPort != nil } }

    private var canCreate: Bool {
        prepared && !trimmedName.isEmpty && nameProblem == nil
            && webServices.allSatisfy { portProblem($0.role) == nil }
            && stack.options.allSatisfy { optionProblem($0) == nil }
    }

    /// The plan as it will be, for the rail. A new network's gateway is not known until it exists,
    /// so the rail names it rather than guessing an address.
    private var previewPlan: StackPlan? {
        guard !trimmedName.isEmpty else { return nil }
        let wiring: StackWiring = model.stackWiringDomain(on: host).map { .names(domain: $0) }
            ?? .gateway(existingGateway ?? "gateway")
        return try? StackPlanner.plan(stack, choices: choices, wiring: wiring,
                                      usedHostPorts: model.stackTaken(on: host).hostPorts)
    }

    private var existingGateway: String? {
        guard case .existing(let id) = network else { return nil }
        return networks.first { $0.id == id }?.gateway.flatMap { Readiness.address(fromIPv4: $0) }
    }

    private var editSignature: String {
        [name, "\(network)", host.token, "\(webFromOtherMacs)", webPorts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(),
         options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined()]
            .joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: stack.title, systemImage: Section.groupSymbol,
                       hasUnsavedChanges: prepared && edits.isDirty(editSignature),
                       onBack: back, token: formToken) {
                if let progressLabel {
                    Text(progressLabel).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            FormScaffold {
                VStack(alignment: .leading, spacing: 20) { fields }
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .task { await prepare() }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        if !model.hostMode.trustedHosts.isEmpty {
            FormField("Run on",
                      help: FieldHelp("Which Mac the stack is created on.",
                                      detail: "Its network, volumes and containers are made there, and its group runs there. Passwords stay in this Mac's Keychain.",
                                      warning: "Chosen once: moving a stack later means moving its containers and data too.")) {
                Picker("", selection: Binding(get: { host }, set: { chosen in
                    host = chosen
                    network = .new
                    Task { await prepare() }
                })) {
                    Text(model.hostLabel).tag(HostRef.local)
                    ForEach(model.hostMode.trustedHosts) { peer in
                        Text(peer.displayName).tag(HostRef.peer(peer.fingerprint))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        FormField("Name",
                  help: FieldHelp(
                      "What the group is called, and the start of every name it creates.",
                      detail: "Containers are named after it and their role, and so are the volumes "
                          + "and the network: blog → blog-db, blog-site, blog-db-data, blog-net.",
                      example: "blog\nshop-dev"),
                  problem: nameProblem) {
            TextField(stack.id, text: $name)
                .textFieldStyle(.roundedBorder)
                .monospaced()
        }

        FormField("Network",
                  help: FieldHelp(
                      "Where the stack's containers live.",
                      detail: "A network of its own keeps the stack apart from everything else — "
                          + "networks are isolated from one another. Choose an existing one to put "
                          + "it beside containers already there.",
                      warning: "Fixed once the containers exist: moving it means recreating them.")) {
            Picker("", selection: $network) {
                Text("New: \(StackPlanner.networkName(trimmedName.isEmpty ? stack.id : trimmedName))")
                    .tag(StackChoices.Network.new)
                if !networks.isEmpty { Divider() }
                ForEach(networks, id: \.id) { existing in
                    Text(existing.id).tag(StackChoices.Network.existing(existing.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }

        if !host.isLocal, !webServices.isEmpty {
            FormField("Open from other Macs",
                      help: FieldHelp("Whether its pages can be opened from this Mac and others on your network.",
                                      detail: "On: published on every interface of \(hostName). Off: on its 127.0.0.1 only, so only someone at \(hostName) can open them. Databases are never published to the network either way.")) {
                Toggle("", isOn: $webFromOtherMacs).labelsHidden()
            }
        }

        ForEach(webServices) { service in
            FormField(host.isLocal ? "\(service.title) on this Mac" : "\(service.title) on \(hostName)",
                      help: FieldHelp(
                          host.isLocal || !webFromOtherMacs ? "The port its page opens on, at 127.0.0.1."
                                                            : "The port its page opens on, at \(hostName)'s address.",
                          detail: host.isLocal ? "This Mac only — not your network. Suggested as one nothing here uses yet."
                                               : "Suggested as one nothing on \(hostName) uses yet.",
                          example: "http://\(openAddress ?? "\(hostName)'s address"):\(webPorts[service.role] ?? "8080")"),
                      problem: prepared ? portProblem(service.role) : nil) {
                TextField("8080", text: Binding(get: { webPorts[service.role] ?? "" },
                                                set: { webPorts[service.role] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(width: 100)
            }
        }

        if !stack.options.isEmpty {
            FormSectionHeader(title: "Settings", note: "Each has a default that works.")
            ForEach(stack.options) { option in
                FormField(option.label, help: FieldHelp(option.help), problem: optionProblem(option)) {
                    TextField(option.defaultValue,
                              text: Binding(get: { options[option.id] ?? option.defaultValue },
                                            set: { options[option.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .frame(maxWidth: 320)
                }
            }
        }

        FormSectionHeader(title: "Wiring")
        FormField("Services find each other",
                  help: FieldHelp(
                      host.isLocal ? "Decided by this Mac's DNS setting, not per stack." : "Through the network's gateway on \(hostName).",
                      detail: "container names every container under one domain for the whole Mac. "
                          + "With one in use, services reach each other by name; without one, "
                          + "Flotilla publishes each database on the network's gateway — reachable "
                          + "from this Mac and its containers, never from your network.")) {
            VStack(alignment: .leading, spacing: 6) {
                if let domain = model.stackWiringDomain(on: host) {
                    Text("By name — \(StackPlanner.containerName(trimmedName.isEmpty ? stack.id : trimmedName, stack.services[0].role)), "
                         + "or \(StackPlanner.containerName(trimmedName.isEmpty ? stack.id : trimmedName, stack.services[0].role)).\(domain) from this Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                } else if !host.isLocal {
                    Text("Through the network's gateway on \(hostName). Each database is published there, reachable from \(hostName)'s own containers and never from your network.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Through the network's gateway: no DNS domain is in use for containers.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up a Domain…") { model.requestDNSForm() }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.link)
                }
            }
        }

        let secrets = GroupSecrets.secretNames(in: ContainerGroup(name: "", members: stack.services.map {
            GroupMember(name: $0.role, image: $0.image, secretEnv: $0.secretEnv)
        }))
        if !secrets.isEmpty {
            FormField("Passwords",
                      help: FieldHelp("Generated now and kept in this Mac's Keychain.",
                                      detail: "Shown on the group's screen with Copy. Never written "
                                          + "to Flotilla's settings, and never in an export.")) {
                Text(secrets.joined(separator: ", "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }

        if let licence = stack.licenceNote {
            Label(licence, systemImage: "doc.text")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rail and footer

    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will create", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if let plan = previewPlan {
                let lines: [String] =
                    (plan.createsNetwork ? ["network  \(plan.network)"] : [])
                    + plan.volumes.map { "volume   \($0)" }
                    + plan.group.members.map { "service  \($0.name)  \(SuggestionsView.shortImage($0.image))" }
                    + ["group    \(plan.group.name)"]
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let missing = stack.images.filter { image in !model.images(on: host).contains { $0.reference == image } }
                if !missing.isEmpty {
                    Text("Pulls first: \(missing.map(SuggestionsView.shortImage).joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Left ready to start, from its row in Containers.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Give it a name to see what it creates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !prepared { ProgressView().controlSize(.small).help("Preparing suggestions…") }
            Spacer()
            FormCancelButton(token: formToken, action: back)
            if let onSkip {
                Button("Skip") {
                    if let formGuard { formGuard.confirmLeaving(form: formToken, onSkip) } else { onSkip() }
                }
            }
            Button("Create") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    /// Reads what the plan must avoid, then fills in defaults that avoid it.
    private func prepare() async {
        prepared = false
        await model.prepareSuggestions(on: host)
        if host.isLocal, model.imagesState != .loaded { await model.refreshImages() }
        let used = await model.stackUsedPorts(for: stack, on: host).union(extraAvoidedPorts)
        usedPorts = used
        name = StackPlanner.suggestedName(for: stack, taken: model.stackTaken(on: host),
                                          groupNames: Set(model.groups.book.groups.map(\.name)))
        webPorts = StackPlanner.defaultWebPorts(for: stack, avoiding: used).mapValues(String.init)
        prepared = true
        edits.open(editSignature)
    }

    private func create() {
        guard canCreate else { return }
        let chosen = choices
        // Multi-suggest: onCreated advances the walk (and claims ports). Single Use…: done dismisses.
        // Calling both would skip an entry.
        if let onCreated {
            onCreated(Set(chosen.webPorts.values))
        } else {
            done()
        }
        let place = host
        Task { await model.createStack(stack, choices: chosen, on: place) }
    }
}

/// Suggestions for Volumes, Networks and Clusters: the same gallery as Containers', where "Use…"
/// opens the section's own create form, filled in (Q28).
struct ResourceSuggestionsGallery<Suggestion: ResourceSuggestion>: View {
    let intro: String
    let items: [Suggestion]
    let use: (Suggestion) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Suggestions", systemImage: "sparkles",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            // No `fixedSize(vertical:)` here — see `SuggestionsView`.
            Text(intro)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 12)
            ResourceCardGrid {
                ForEach(items) { item in
                    ResourceCard(title: item.title,
                                 fields: [("About", item.summary)] + item.details.map { ($0.0, Optional($0.1)) },
                                 showsTags: false,
                                 onOpen: { use(item) }) {
                        Button("Use…") { use(item) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The empty-state row every section shares: a few suggestions by name, and "More…".
struct SuggestionQuickPicks: View {
    /// Title and action for each pick shown.
    let picks: [(title: String, action: () -> Void)]
    let more: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text("Or start from a suggestion:")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                    Button(pick.title, action: pick.action)
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.link)
                }
                Button("More…", action: more)
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.link)
            }
        }
    }
}
