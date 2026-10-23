import SwiftUI
import FlotillaCore

/// One discovery section (Q66). Use only opens an existing form; its commit owns execution.
struct SuggestionsView: View {
    let model: AppModel
    @Bindable var ui: SuggestionsUIState
    @State private var form: SuggestionItem?
    @State private var runPrefill: RunPrefill?
    @State private var batch: SuggestionBatch?
    @State private var preparing = false
    @State private var preparationID = UUID()

    private var library: SuggestionLibrary { model.suggestionLibrary }
    private var catalogue: SuggestionCatalogue { SuggestionCatalogue(library: library) }
    private var shown: [SuggestionItem] { catalogue.matching(ui.query, tab: ui.tab, category: ui.category) }
    private var shownIDs: [String] { shown.map(\.id) }
    private var selectedItems: [SuggestionItem] { shown.filter { ui.selection.contains($0.id) } }
    private var selected: SuggestionItem? { selectedItems.count == 1 ? selectedItems.first : nil }
    private var counts: [SuggestionTab: Int] { catalogue.counts(ui.query, category: ui.category) }
    private var canUse: Bool { !preparing && SuggestionCatalogue.canUseTogether(selectedItems, on: ui.host) }
    private var clashNotes: [String] { SuggestionPorts.clashNotes(for: selectedItems.compactMap(\.libraryEntry)) }

    var body: some View {
        VStack(spacing: 0) {
            if let form {
                creationForm(form).id(form.id)
            } else {
                browser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { openRequestedEntry() }
        .onDisappear { closeForm() }
        .onChange(of: ui.host) { _, _ in closeForm() }
        .onChange(of: model.pendingSuggestionEntry) { _, _ in openRequestedEntry() }
        .onChange(of: model.pendingSuggestionTab) { _, _ in openRequestedEntry() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil },
                                                     set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: { Text(model.actionError ?? "") }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                PageTabs(items: SuggestionTab.allCases.map {
                    .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage, count: counts[$0])
                }, selection: $ui.tab, label: "Suggestion kinds", showsTitles: true)
            }
            .scrollIndicators(.hidden)
            .frame(height: 52)
            SplitPanes(list: "suggestions", pane: ui.pane, showing: selected?.id,
                       clearing: { ui.selection = [] }) { listPane } detail: { detailPane }
        }
        .searchesFromToolbar(prompt: "Search all suggestions",
                             text: Binding(get: { [weak ui] in ui?.query ?? "" },
                                           set: { [weak ui] in ui?.query = $0 }),
                             matches: counts[.all] ?? 0)
        .selection($ui.selection, confinedTo: Set(shownIDs))
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SelectAllCheckbox(selection: $ui.selection, ids: shownIDs, noun: "suggestions")
                    .alignedWithRowChecks()
                PaneModeButton()
                Picker("Category", selection: $ui.category) {
                    Text("All categories").tag(String?.none)
                    ForEach(SuggestionLibrary.categories.filter { name in library.entries.contains { $0.categories.contains(name) } }, id: \.self) {
                        Text($0).tag(String?.some($0))
                    }
                }
                .labelsHidden()
            }
            Picker("Create on", selection: $ui.host) {
                Text(model.hostLabel).tag(HostRef.local)
                ForEach(model.hostMode.trustedHosts) {
                    Text($0.displayName).tag(HostRef.peer($0.fingerprint))
                }
            }
            if preparing { ProgressView("Preparing suggestion…").controlSize(.small) }
            Text("\(shown.count) suggestions · library \(library.version)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(clashNotes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
            }
            if ui.selection.count > 1 {
                BulkActionBar(title: "\(ui.selection.count) selected") { batchAction }
            }
            // Back where it was after a form (Q66): the row that was at the top, or with none
            // recorded, the first selected one — several selected rows included.
            SelectionRevealingList(selection: ui.selection,
                                   restoring: ui.scrollAnchor ?? shownIDs.first(where: ui.selection.contains)) {
                List(shown, selection: $ui.selection) { item in
                    SuggestionRow(item: item, model: model, selection: $ui.selection) {
                        RowOverflowMenu(label: "More actions for \(item.title)") { suggestionMenu(item) }
                    }
                    .contextMenu { suggestionMenu(item) }
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .scrollView).midY }) {
                        ui.rowMoved(item.id, middle: $0)
                    }
                    .onDisappear { ui.rowGone(item.id) }
                    .tag(item.id)
                    .listRowInsets(EdgeInsets())
                }
                .listStyle(.inset)
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("No matching suggestions", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try another kind or change the search.")
                    } actions: {
                        if (counts[.all] ?? 0) > 0 {
                            Button("Show all matches") { ui.tab = .all }
                        }
                    }
                }
            }
            // In the list pane, under the rows that draw the logos, whatever the selection or the page
            // beside it: a hidden list takes its footer with it, and the page then carries its own.
            LogoAttributionFooter(lines: model.libraryLogoAttributions)
        }
        .padding(16)
    }

    @ViewBuilder private var detailPane: some View {
        if ui.selection.count > 1 {
            SelectionSummaryPane(title: "\(ui.selection.count) suggestions selected", systemImage: "sparkles",
                                 names: selectedItems.map(\.title)) {
                batchAction
                if !canUse { Text("Use apps and stacks together, or choose one resource.").font(.caption) }
            }
        } else if let item = selected {
            VStack(spacing: 0) {
                HStack {
                    Text(item.title).font(.headline).lineLimit(1)
                    Spacer()
                    ActionCluster {
                        IconActionButton(systemImage: "play.fill", label: "Use…", help: "Use this suggestion…",
                                         busy: preparing, disabled: !canUse) { use(item) }
                    }
                    DetailStepper()
                }.padding(12)
                Divider()
                if !item.supports(ui.host) {
                    Text("Machines can only be created on This Mac. Choose This Mac to use this suggestion.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                if let entry = item.libraryEntry {
                    libraryDetail(entry)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.summary).font(.callout).foregroundStyle(.secondary)
                            ForEach(Array(item.details.enumerated()), id: \.offset) { _, line in
                                detailLine(line.0, line.1)
                            }
                            Text("Opens the existing create form. Review or change its values before creating.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
            .paneStep("suggestion", "suggestions", order: shownIDs, current: item.id) { ui.selection = [$0] }
        } else {
            ContentUnavailableView("Choose a suggestion", systemImage: "sparkles",
                                   description: Text("Its purpose and settings show here. Use opens a form to review."))
        }
    }

    private var batchAction: some View {
        Button("Use \(ui.selection.count) Suggestions…") { startBatch() }
            .buttonStyle(.borderedProminent).disabled(!canUse)
    }

    private func suggestionMenu(_ item: SuggestionItem) -> some View {
        Button(ui.selection.contains(item.id) && ui.selection.count > 1 ? "Use \(ui.selection.count) Suggestions…" : "Use…") {
            if ui.selection.contains(item.id), ui.selection.count > 1 { startBatch() } else { use(item) }
        }
        .disabled(preparing || !item.supports(ui.host)
                  || (ui.selection.contains(item.id) && ui.selection.count > 1 && !canUse))
    }

    @ViewBuilder private func creationForm(_ item: SuggestionItem) -> some View {
        switch item {
        case .library(let entry):
            if let stack = entry.stackSuggestion {
                StackFormView(model: model, stack: stack, back: closeForm, done: { advanceBatch() },
                              progressLabel: batch?.progressLabel,
                              onSkip: batch == nil ? nil : { advanceBatch() },
                              onCreated: batch == nil ? nil : { advanceBatch(claiming: $0) },
                              extraAvoidedPorts: batch?.claimedPorts ?? [], initialHost: ui.host)
            } else if let runPrefill {
                RunSheetView(model: model, initialHost: ui.host, prefill: runPrefill,
                             progressLabel: batch?.progressLabel,
                             onSkip: batch == nil ? nil : { advanceBatch() },
                             onRan: batch == nil ? nil : { advanceBatch(claiming: $0) }, dismiss: closeForm)
            }
        case .volume(let value):
            NewVolumeView(model: model, dismiss: closeForm, prefill: value, initialHost: ui.host)
        case .network(let value):
            NewNetworkView(model: model, dismiss: closeForm, prefill: value, initialHost: ui.host)
        case .domain(let value):
            DNSFormView(model: model, target: .add, prefill: value, initialHost: ui.host, dismiss: closeForm)
        case .machine(let value):
            MachineFormView(model: model, prefill: value, dismiss: closeForm)
        case .cluster(let value):
            NewClusterView(model: model, dismiss: closeForm, prefill: value, initialHost: ui.host)
        }
    }

    private func openRequestedEntry() {
        guard model.pendingSuggestionEntry != nil || model.pendingSuggestionTab != nil else { return }
        closeForm()
        ui.query = ""
        ui.category = nil
        if let host = model.pendingSuggestionHost { ui.host = host }
        if let tab = model.pendingSuggestionTab { ui.tab = tab; ui.selection = [] }
        if let id = model.pendingSuggestionEntry,
           let item = catalogue.items.first(where: { $0.id == id || $0.libraryEntry?.id == id }) {
            ui.tab = item.tab
            ui.selection = [item.id]
        }
        model.pendingSuggestionEntry = nil
        model.pendingSuggestionTab = nil
        model.pendingSuggestionHost = nil
    }

    private func use(_ item: SuggestionItem) {
        guard item.supports(ui.host), !preparing else { return }
        if let container = item.libraryEntry?.container {
            preparing = true
            let token = UUID()
            preparationID = token
            let host = ui.host
            Task {
                await model.prepareSuggestions(on: host)
                let avoiding = (batch?.claimedPorts ?? []).union(model.stackTaken(on: host).hostPorts)
                let ports = await Blocking.run {
                    SuggestionPorts.publishSpecs(for: container, avoiding: avoiding,
                                                 isPortFree: { host.isLocal ? AppModel.isPortFree($0) : true })
                }
                guard preparationID == token else { return }
                var prefill = makeRunPrefill(container, ports: ports.specs, host: host)
                prefill.unavailablePorts = ports.unavailablePorts
                runPrefill = prefill
                preparing = false
                form = item
            }
        } else if item.libraryEntry != nil {
            form = item
        } else {
            preparing = true
            let token = UUID()
            preparationID = token
            let host = ui.host
            Task {
                if host.isLocal {
                    switch item {
                    case .volume: await model.refreshVolumes()
                    case .network: await model.refreshNetworks()
                    case .domain: await model.refreshDNS()
                    case .machine: await model.refreshMachines()
                    case .cluster: await model.refreshClusters()
                    case .library: break
                    }
                } else {
                    await model.prepareSuggestions(on: host)
                }
                guard preparationID == token else { return }
                preparing = false
                form = item
            }
        }
    }

    private func startBatch() {
        guard canUse, selectedItems.count > 1 else { return }
        let entries = selectedItems.compactMap(\.libraryEntry)
        batch = SuggestionBatch(queue: entries.map(\.id))
        if let first = entries.first { use(.library(first)) }
    }

    private func advanceBatch(claiming ports: Set<Int> = []) {
        form = nil
        runPrefill = nil
        guard var walk = batch else { return }
        walk.advance(claiming: ports)
        batch = walk.isFinished ? nil : walk
        if let id = batch?.currentID, let entry = library.entries.first(where: { $0.id == id }) {
            use(.library(entry))
        }
    }

    private func closeForm() {
        preparationID = UUID()
        preparing = false
        form = nil
        runPrefill = nil
        batch = nil
    }

    private func makeRunPrefill(_ container: LibraryContainer, ports: [String], host: HostRef) -> RunPrefill {
        let taken = model.stackTaken(on: host)
        var name = container.name
        var counter = 2
        while taken.containerNames.contains(name) || container.volumes.contains(where: { taken.volumes.contains("\(name)-\($0.suffix)") }) {
            name = "\(container.name)-\(counter)"; counter += 1
        }
        let env = container.env + container.secretEnv.map { "\($0)=\(GroupSecrets.generatePassword())" }
        return RunPrefill(draftImage: container.image, name: name, ports: ports, env: env,
                          volumes: container.volumes.map { "\(name)-\($0.suffix):\($0.path)" },
                          command: container.command, source: .library,
                          volumeOwners: Dictionary(uniqueKeysWithValues: container.volumes.compactMap { volume in
                              volume.volumeOwner.map { ("\(name)-\(volume.suffix):\(volume.path)", $0) }
                          }))
    }

    private func logo(_ entry: LibraryEntry) -> some View {
        SuggestionLogo(data: model.libraryLogo(for: entry), category: entry.categories.first)
    }

    static func stats(_ entry: LibraryEntry) -> String {
        var parts = [entry.categories.joined(separator: ", ")]
        if let stack = entry.stack { parts.append(stack.services.map(\.title).joined(separator: " · ")) }
        if let container = entry.container { parts.append(shortImage(container.image)) }
        parts.append(entry.tested.map { "Tested \($0.date)" } ?? "Not tested yet")
        return parts.joined(separator: " · ")
    }

    static func shortImage(_ image: String) -> String {
        image.replacingOccurrences(of: "docker.io/library/", with: "").replacingOccurrences(of: "docker.io/", with: "")
    }
    private func libraryDetail(_ entry: LibraryEntry) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        logo(entry)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                            Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.categories.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            // The page draws the logo large, and with the list hidden the gallery's
                            // footer is not on screen: its owner's attribution goes with it here
                            // (Redis's permission covers the footer only for rows, search and small
                            // tiles — Kyle, beta 6).
                            if let attribution = model.libraryLogoAttribution(for: entry) {
                                Text(verbatim: attribution)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
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
    var initialHost: HostRef = .local

    @State private var name = ""
    @State private var network: StackChoices.Network = .new
    @State private var webPorts: [String: String] = [:]
    @State private var options: [String: String] = [:]
    @State private var usedPorts: Set<Int> = []
    @State private var prepared = false
    @State private var edits = FormEditTracker()
    /// The header's guard registration: Back and ✕ (and a Skip) ask about this form alone.
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
                       onBack: back, progress: progressLabel, token: formToken, actions: actions)
            Divider()
            FormScaffold {
                VStack(alignment: .leading, spacing: 20) { fields }
            } preview: {
                railPreview
            }
        }
        .task { host = initialHost; await prepare() }
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
                .disabled(progressLabel != nil)
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

    // MARK: Rail and header actions

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

    /// ▶ Create; Skip, inside a run of suggestions, in ⋯; the spinner while it prepares.
    private var actions: FormActions {
        var more: [FormActions.Extra] = []
        if let onSkip {
            more.append(.init("Skip") {
                if let formGuard { formGuard.confirmLeaving(form: formToken, onSkip) } else { onSkip() }
            })
        }
        return FormActions(.startsJob("Create", isDisabled: !canCreate) { create() }, more: more,
                           isWorking: !prepared, workingHelp: "Preparing suggestions…")
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
