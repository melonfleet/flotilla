import SwiftUI
import AppKit
import FlotillaCore

/// The DNS section: local domains that give containers names, and names that point at this Mac.
///
/// Built 6 October, after a proof on `container` 1.5.0 (DECISIONS, groups section) showed a
/// domain needs **two** halves to work — macOS's resolver knowing it, and the runtime naming
/// containers under it — that live in different places and need different permissions. The section
/// shows both halves per row, says plainly when only one is there, and offers the missing one.
///
/// The same table setup as every other section — list and cards, search, filter, sortable and
/// hideable columns, row menus that match the context menu, multi-select with bulk actions, tags
/// and the activity band.
///
/// **Two permissions, both asked for in the open** (the owner's answers, 6 October):
///
/// - Creating or deleting a domain writes `/etc/resolver`, which needs an administrator. It shows
///   the standard macOS password prompt and runs exactly the command the form displayed —
///   see `AdminCommandRunner` for what it will and will not run.
/// - Choosing the domain containers are named under edits `config.toml` and restarts the runtime,
///   which stops every container. A dialog says so first, every time.
struct DNSView: View {
    let model: AppModel
    let ui: ResourceUIState<LocalDNSDomain>

    @State private var selection = Set<LocalDNSDomain.ID>()
    @State private var form: DNSFormTarget?
    @State private var formPrefill: DNSSuggestion?
    @State private var showingSuggestions = false
    @State private var pendingDelete: [LocalDNSDomain] = []
    @State private var pendingChange: ContainerDomainChange?
    @State private var working = false
    @State private var actionError: String?
    @State private var tagSheet: TagSheetTarget?
    /// "Set Up on This Mac…" with the DNS helper on: no password prompt follows, so Flotilla asks.
    @State private var pendingSetUp: String?

    private var rows: [LocalDNSDomain] { model.dnsDomains }

    var body: some View {
        Group {
            if let form {
                DNSFormView(model: model, target: form, prefill: formPrefill) {
                    self.form = nil
                    formPrefill = nil
                }
                .id(form)
            } else if showingSuggestions {
                ResourceSuggestionsGallery(
                    intro: "Domains that are safe to use on a Mac — none can ever be a real internet "
                        + "domain. Use one to open New Domain with it filled in. Only one domain at a "
                        + "time names containers.",
                    items: DNSSuggestion.catalogue,
                    use: useSuggestion,
                    dismiss: { showingSuggestions = false })
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    content
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  open: { form = .manage($0) },
                                  canOpen: { name in rows.contains { $0.id == name } })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshDNS() }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        .onChange(of: model.pendingDNSForm) { _, requested in
            if requested { form = .add; model.pendingDNSForm = false }
        }
        .onAppear {
            if model.pendingDNSForm { form = .add; model.pendingDNSForm = false }
        }
        // File ▸ Suggestions ▸ DNS Domains…. One-shot.
        .onChange(of: model.pendingSuggestions) { _, section in
            if section == .dns { model.pendingSuggestions = nil; form = nil; showingSuggestions = true }
        }
        .onAppear {
            if model.pendingSuggestions == .dns {
                model.pendingSuggestions = nil; form = nil; showingSuggestions = true
            }
        }
        .alert("Action failed",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                 set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button(pendingDelete.count == 1 ? "Delete…" : "Delete \(pendingDelete.count)…",
                   role: .destructive) {
                let targets = pendingDelete
                pendingDelete = []
                delete(targets)
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text(DNSCopy.deleteMessage(pendingDelete, helper: model.dnsHelperEnabled))
        }
        .containerDomainConfirmation($pendingChange, model: model) { change in
            perform(change)
        }
        .dnsSetUpConfirmation($pendingSetUp) { create($0) }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? "Delete the local domain “\(pendingDelete[0].name)”?"
            : "Delete \(pendingDelete.count) local domains?"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search domains…",
                       updated: model.dnsLastRefresh,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all domains" : "Select all domains")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<LocalDNSDomain>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: Self.filters)
        }, trailing: {
            if working { ProgressView().controlSize(.small) }
            ToolbarIconMenu(systemImage: "plus", label: "New domain") {
                Button("New Domain…") { formPrefill = nil; form = .add }
                Divider()
                Button("Suggestions…") { showingSuggestions = true }
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh domains") {
                Task { await model.refreshDNS() }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"), ("kind", "Kind"), ("address", "Address"), ("status", "Status"),
    ]

    private static let filters: [ResourceFilterOption] = [
        .init(id: "all", title: "All", systemImage: "circle.grid.2x2"),
        .init(id: "containers", title: "For containers", systemImage: "shippingbox"),
        .init(id: "aliases", title: "Host aliases", systemImage: DNSCopy.hostAliasSymbol),
    ]

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all"
    }

    private var displayedRows: [LocalDNSDomain] {
        var rows = self.rows
        switch ui.filterID {
        case "containers": rows = rows.filter { !$0.isHostAlias }
        case "aliases": rows = rows.filter(\.isHostAlias)
        default: break
        }
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.contains(query)
                    || (row.hostAliasAddress?.contains(query) ?? false)
                    || model.tags.tags(on: .dns, row.id)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }
        return rows.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<LocalDNSDomain.ID> { Set(displayedRows.map(\.id)) }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    private var selectedRows: [LocalDNSDomain] {
        displayedRows.filter { selection.contains($0.id) }
    }

    private var selectedTagSubjects: [TagSubject] {
        selectedRows.map { TagSubject(kind: .dns, id: $0.id) }
    }

    private func selectionToggle(for id: LocalDNSDomain.ID) -> some View {
        Toggle("", isOn: Binding(get: { selection.contains(id) },
                                 set: { on in
                                     if on { selection.insert(id) } else { selection.remove(id) }
                                 }))
            .labelsHidden()
            .accessibilityLabel("Select \(id)")
            .help("Select \(id)")
    }

    // MARK: Bulk

    @ViewBuilder
    private var bulkActionBar: some View {
        if selectedRows.count > 1 {
            let deletable = selectedRows.filter(\.resolverInstalled)
            HStack(spacing: 12) {
                Text("\(selectedRows.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "trash",
                                 label: "Delete \(deletable.count) domains",
                                 help: deletable.isEmpty ? "None of these is set up on this Mac"
                                                         : "Delete \(deletable.count)",
                                 disabled: deletable.isEmpty || working, destructive: true) {
                    pendingDelete = deletable
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .dns).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if case .unavailable(let reason) = model.dnsState {
            ContentUnavailableView("DNS unavailable", systemImage: Section.dns.systemImage,
                                   description: Text(reason))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayedRows.isEmpty {
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No local domains",
                      systemImage: isFiltered ? "line.3.horizontal.decrease"
                                              : Section.dns.systemImage)
            } description: {
                Text(isFiltered
                     ? "No domain matches the current filter."
                     : "A local domain gives your containers names — web.test, db.test — that "
                       + "this Mac and other containers can reach. "
                       + (model.dnsHelperEnabled ? "Flotilla asks you to confirm before it creates one."
                                                 : "Creating one asks for an administrator password."))
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
                } else {
                    VStack(spacing: 14) {
                        Button("New Domain…") { formPrefill = nil; form = .add }
                            .buttonStyle(.borderedProminent)
                        SuggestionQuickPicks(
                            picks: DNSSuggestion.catalogue.map { suggestion in
                                (suggestion.title, { useSuggestion(suggestion) })
                            },
                            more: { showingSuggestions = true })
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                setupNote
                if ui.presentation == .list { table } else { cards }
            }
        }
    }

    /// The two half-set-up states, said once above the table with the fix beside them.
    @ViewBuilder
    private var setupNote: some View {
        if let row = model.containerDNSRow, !row.resolverInstalled {
            note("Containers are named under “\(row.name)”, but this Mac can’t look those names "
                 + "up yet.", systemImage: "exclamationmark.triangle", tint: Theme.warning) {
                Button("Set Up on This Mac…") { setUp(row.name) }
                    .disabled(working)
            }
        } else if model.containerDNSRow == nil, rows.contains(where: { !$0.isHostAlias }) {
            note("No domain is used for containers, so containers aren’t given names.",
                 systemImage: "info.circle", tint: Theme.info) {
                let candidates = rows.filter { !$0.isHostAlias && $0.resolverInstalled }
                if candidates.count == 1 {
                    Button("Use “\(candidates[0].name)” for Containers…") {
                        pendingChange = .use(candidates[0].name)
                    }
                    .disabled(working)
                }
            }
        }
    }

    private func note<Actions: View>(_ text: String, systemImage: String, tint: Color,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.caption).foregroundStyle(tint)
                .lineLimit(2)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var table: some View {
        SwiftUI.Table(displayedRows,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("") { row in
                selectionToggle(for: row.id)
            }
            .width(min: 28, ideal: 30, max: 34)

            TableColumn("Name", value: \.nameSortKey) { row in
                Button(row.name) { form = .manage(row.id) }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                    .lineLimit(1)
                    .help("Open \(row.name)")
            }
            .width(min: 150, ideal: 220)

            TableColumn("Tags") { row in
                TagPillRow(tags: model.tags.tags(on: .dns, row.id), compact: true)
            }
            .width(min: 60, ideal: 110)
            .customizationID("tags")

            TableColumn("Kind", value: \.kindSortKey) { row in
                Text(DNSCopy.kindTitle(row)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 120)
            .customizationID("kind")

            TableColumn("Address") { row in
                Text(DNSCopy.address(row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(DNSCopy.addressHelp(row))
            }
            .width(min: 120, ideal: 190)
            .customizationID("address")

            TableColumn("Status", value: \.statusSortKey) { row in
                DNSStatusLabel(row: row)
            }
            .width(min: 120, ideal: 200)
            .customizationID("status")

            TableColumn("Actions") { row in
                rowActions(for: row)
            }
            .width(min: 78, ideal: 92)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: LocalDNSDomain.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            form = .manage(id)
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedRows) { row in
                ResourceCard(
                    title: row.name,
                    badge: row.registersContainers ? "containers" : nil,
                    fields: [("Kind", DNSCopy.kindTitle(row)),
                             ("Address", DNSCopy.address(row)),
                             ("Status", DNSCopy.statusText(row))],
                    tags: model.tags.tags(on: .dns, row.id),
                    onOpen: { form = .manage(row.id) }
                ) {
                    rowActions(for: row)
                }
                .contextMenu { menu(for: row) }
            }
        }
    }

    // MARK: Row actions and menu

    @ViewBuilder
    private func rowActions(for row: LocalDNSDomain) -> some View {
        HStack(spacing: 2) {
            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(row.name)")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(row.name)",
                             help: row.resolverInstalled
                                 ? (model.dnsHelperEnabled ? "Delete" : "Delete — asks for an administrator password")
                                 : "Not set up on this Mac — stop using it for containers instead",
                             disabled: !row.resolverInstalled || working,
                             destructive: true) {
                requestDelete([row])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(for row: LocalDNSDomain) -> some View {
        Button("Open…") { form = .manage(row.id) }
        Divider()
        if !row.isHostAlias {
            if row.registersContainers {
                Button("Stop Using for Containers…") { pendingChange = .stop(row.name) }
                    .disabled(working)
            } else {
                Button("Use for Containers…") { pendingChange = .use(row.name) }
                    .disabled(working || !row.resolverInstalled)
            }
        }
        if !row.resolverInstalled {
            Button("Set Up on This Mac…") { setUp(row.name) }
                .disabled(working)
        }
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .dns, id: row.id)) {
            tagSheet = TagSheetTarget(kind: .dns, id: row.id)
        }
        Divider()
        CopyMenu([("Domain", row.name),
                  ("Example address", row.containerAddress(for: "web")),
                  ("Host address", row.hostAliasAddress)])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete([row]) }
            .disabled(!row.resolverInstalled || working)
    }

    // MARK: Actions

    private func useSuggestion(_ suggestion: DNSSuggestion) {
        formPrefill = suggestion
        showingSuggestions = false
        form = .add
    }

    /// The password prompt that follows is a confirmation of its own, so a single delete follows
    /// the delete policy like every other section; several always ask. With the DNS helper on there
    /// is no prompt, so every delete asks here (decision 19, amended 7 October).
    private func requestDelete(_ rows: [LocalDNSDomain]) {
        let deletable = rows.filter(\.resolverInstalled)
        guard !deletable.isEmpty else { return }
        if deletable.count == 1, !model.dnsHelperEnabled,
           !model.deletePolicy.requiresConfirmation(.single) {
            delete(deletable)
        } else {
            pendingDelete = deletable
        }
    }

    private func delete(_ rows: [LocalDNSDomain]) {
        working = true
        Task {
            let result = await model.deleteDNSDomains(rows.map(\.name))
            working = false
            selection.subtract(rows.map(\.id))
            if case .failed(let message) = result { actionError = message }
        }
    }

    /// The password prompt is the confirmation without the helper; with it, Flotilla asks.
    private func setUp(_ name: String) {
        if model.dnsHelperEnabled { pendingSetUp = name } else { create(name) }
    }

    /// Re-creates the resolver half for a domain config.toml already names.
    private func create(_ name: String) {
        working = true
        Task {
            let result = await model.createDNSDomain(name, localhost: nil)
            working = false
            if case .failed(let message) = result { actionError = message }
        }
    }

    private func perform(_ change: ContainerDomainChange) {
        working = true
        Task {
            let result = await model.setContainerDNSDomain(change.newDomain)
            working = false
            if case .failed(let message) = result { actionError = message }
        }
    }
}

/// A row's status, the same in the table, the cards and the form.
struct DNSStatusLabel: View {
    let row: LocalDNSDomain

    var body: some View {
        let text = DNSCopy.statusText(row)
        Group {
            if row.registersContainers && row.resolverInstalled {
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.online)
            } else if row.registersContainers {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else {
                Text(text).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .help(DNSCopy.statusHelp(row))
    }
}

/// The section's words, in one place so the table, cards, form and dialogs say the same thing.
enum DNSCopy {
    /// The Mac itself. Verified present, per the `ellipsis.vertical` incident.
    static let hostAliasSymbol = "laptopcomputer"

    static func kindTitle(_ row: LocalDNSDomain) -> String {
        row.isHostAlias ? "Host alias" : "Container names"
    }

    static func address(_ row: LocalDNSDomain) -> String {
        if let ip = row.hostAliasAddress { return "this Mac, via \(ip)" }
        return "<container>.\(row.name)"
    }

    static func addressHelp(_ row: LocalDNSDomain) -> String {
        if row.isHostAlias {
            return "Inside a container, \(row.name) reaches a service running on this Mac."
        }
        return "A container named web is reached as web.\(row.name)."
    }

    static func statusText(_ row: LocalDNSDomain) -> String {
        if row.isHostAlias { return row.resolverInstalled ? "Points to this Mac" : "Not set up" }
        switch (row.registersContainers, row.resolverInstalled) {
        case (true, true): return "In use for containers"
        case (true, false): return "Containers only — not on this Mac"
        case (false, true): return "Not used for containers"
        case (false, false): return "Not set up"
        }
    }

    static func statusHelp(_ row: LocalDNSDomain) -> String {
        if row.isHostAlias {
            return "Containers that look up \(row.name) are sent to this Mac."
        }
        switch (row.registersContainers, row.resolverInstalled) {
        case (true, true):
            return "Containers created since it was chosen are named under it, and this Mac can "
                + "reach them by those names."
        case (true, false):
            return "Containers are named under it and can reach each other, but this Mac can’t "
                + "look the names up. Set it up on this Mac to fix that."
        case (false, true):
            return "This Mac can look names up under it, but containers aren’t named under it. "
                + "Only one domain at a time can be used for containers."
        case (false, false):
            return "Not set up."
        }
    }

    static func deleteMessage(_ rows: [LocalDNSDomain], helper: Bool) -> String {
        var text = (helper ? "Flotilla’s DNS helper removes " : "macOS asks for an administrator password, then removes ")
            + (rows.count == 1 ? "it" : "them") + " from this Mac’s DNS settings."
        if let used = rows.first(where: \.registersContainers) {
            text += " Containers are still named under “\(used.name)” until you stop using it "
                + "for containers — this Mac just can’t look those names up."
        }
        if rows.contains(where: \.isHostAlias) {
            text += " A host alias stops pointing at this Mac."
        }
        return text
    }
}

/// A change to which domain containers are named under — the one action here that restarts the
/// runtime, and so the one that always asks first.
enum ContainerDomainChange: Identifiable, Hashable {
    case use(String)
    case stop(String)

    var id: String {
        switch self {
        case .use(let name): "use:\(name)"
        case .stop(let name): "stop:\(name)"
        }
    }

    var domain: String {
        switch self {
        case .use(let name), .stop(let name): name
        }
    }

    /// The value for `config.toml`: the domain, or none.
    var newDomain: String? {
        if case .use(let name) = self { return name }
        return nil
    }
}

extension View {
    /// "Set Up on This Mac…" when the DNS helper is on — the in-app confirmation that stands in for
    /// the password prompt. Shared by the table and the form.
    func dnsSetUpConfirmation(_ name: Binding<String?>, perform: @escaping (String) -> Void) -> some View {
        confirmationDialog("Set up “\(name.wrappedValue ?? "")” on this Mac?",
                           isPresented: Binding(get: { name.wrappedValue != nil },
                                                set: { if !$0 { name.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: name.wrappedValue) { pending in
            Button("Set Up") { name.wrappedValue = nil; perform(pending) }
            Button("Cancel", role: .cancel) { name.wrappedValue = nil }
        } message: { _ in
            Text("Flotilla’s DNS helper adds it to this Mac’s DNS settings, so this Mac can look up "
                 + "names under it.")
        }
    }

    /// The warning before containers are renamed (the owner's answer, 6 October: "Yes, with a clear
    /// warning"). Shared by the table and the form so it cannot say two different things.
    func containerDomainConfirmation(_ change: Binding<ContainerDomainChange?>, model: AppModel,
                                     perform: @escaping (ContainerDomainChange) -> Void) -> some View {
        confirmationDialog(change.wrappedValue.map { ContainerDomainDialog.title($0) } ?? "",
                           isPresented: Binding(get: { change.wrappedValue != nil },
                                                set: { if !$0 { change.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: change.wrappedValue) { pending in
            Button(ContainerDomainDialog.button(pending, restarting: model.runtimeUsable)) {
                change.wrappedValue = nil
                perform(pending)
            }
            Button("Cancel", role: .cancel) { change.wrappedValue = nil }
        } message: { pending in
            Text(ContainerDomainDialog.message(pending, model: model))
        }
    }
}

enum ContainerDomainDialog {
    static func title(_ change: ContainerDomainChange) -> String {
        switch change {
        case .use(let name): "Name containers under “\(name)”?"
        case .stop(let name): "Stop naming containers under “\(name)”?"
        }
    }

    static func button(_ change: ContainerDomainChange, restarting: Bool) -> String {
        switch change {
        case .use(let name): restarting ? "Restart and Use “\(name)”" : "Use “\(name)”"
        case .stop: restarting ? "Restart and Stop" : "Stop Using"
        }
    }

    @MainActor
    static func message(_ change: ContainerDomainChange, model: AppModel) -> String {
        var parts: [String] = []
        if model.runtimeUsable {
            let running = model.runningContainerCount
            parts.append("container restarts to pick this up, which stops every running container"
                         + (running > 0 ? " (\(running) right now)" : "")
                         + ". Start them again afterwards.")
        } else {
            parts.append("container isn’t running, so nothing stops. It takes effect when "
                         + "container next starts.")
        }
        switch change {
        case .use(let name):
            parts.append("Only containers created from now on get a name — recreate the others "
                         + "to reach them as name.\(name).")
            if let current = model.containerDNSDomain, current != name {
                parts.append("Names under “\(current)” stop working.")
            }
        case .stop(let name):
            parts.append("Names under “\(name)” stop working. The domain stays on this Mac until "
                         + "you delete it.")
        }
        if model.runtimeUsable {
            // Observed on 1.5.0, 6 October: see research/CONTAINER-UPGRADE-1.5.0.md.
            parts.append("If a network stops carrying traffic after the restart, recreating it "
                         + "fixes it.")
        }
        return parts.joined(separator: " ")
    }
}
