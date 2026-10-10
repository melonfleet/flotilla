import SwiftUI
import AppKit
import FlotillaCore

/// The Registries section: where images come from, and which of them this Mac is signed in to.
///
/// **Moved out of Settings into the sidebar under Images** (the owner, 5 October), with the same
/// table setup as every other section — list and cards, search, filter, sortable and hideable
/// columns, row menus that match the context menu, multi-select with bulk actions, tags and the
/// activity band. Settings ▸ Registries is gone; the default registry is set from the table.
///
/// **The honest framing still matters more than the table** (decision Q20). Apple's `container`
/// has no supported-registry list — it pulls from anything that speaks the OCI distribution API,
/// and the host in the image reference decides where an image comes from. So the list is a
/// convenience: registries you do not have to remember the hostname of, plus your own, plus
/// whatever this Mac is actually signed in to. The empty state and the column help say so.
struct RegistriesView: View {
    let model: AppModel
    let ui: ResourceUIState<RegistryRow>

    @State private var selection = Set<RegistryRow.ID>()
    /// The embedded form: Add, or managing one row.
    @State private var form: RegistryFormTarget?
    @State private var pendingRemove: [RegistryRow] = []
    @State private var pendingSignOut: [RegistryRow] = []
    @State private var actionError: String?
    @State private var tagSheet: TagSheetTarget?

    private var rows: [RegistryRow] { model.registryRows }

    var body: some View {
        Group {
            if let form {
                RegistryFormView(model: model, target: form) { self.form = nil }
                    .id(form)
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
                                  canOpen: { host in rows.contains { $0.id == host } })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshRegistries() }
        .sheet(item: $tagSheet) { target in
            NewTagSheet(store: model.tags, applyTo: target.subjects) { tagSheet = nil }
        }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingRegistryForm) { _, requested in
            if requested { form = .add; model.pendingRegistryForm = false }
        }
        .onAppear {
            if model.pendingRegistryForm { form = .add; model.pendingRegistryForm = false }
        }
        .alert("Action failed",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog(removeTitle,
                            isPresented: Binding(get: { !pendingRemove.isEmpty },
                                                 set: { if !$0 { pendingRemove = [] } }),
                            titleVisibility: .visible) {
            Button(pendingRemove.count == 1 ? "Remove" : "Remove \(pendingRemove.count)",
                   role: .destructive) {
                model.removeRegistries(pendingRemove.map(\.id))
                selection.subtract(pendingRemove.map(\.id))
                pendingRemove = []
            }
            Button("Cancel", role: .cancel) { pendingRemove = [] }
        } message: {
            // Says what it does *not* do. Removing a row and destroying a credential are
            // different decisions; a login survives this and keeps the row visible.
            Text(pendingRemove.contains(where: \.isSignedIn)
                 ? "This only removes it from the list. You stay signed in, so a signed-in "
                   + "registry still appears here until you sign out."
                 : "This only removes it from the list. Nothing is deleted, and Add offers it again.")
        }
        .confirmationDialog(signOutTitle,
                            isPresented: Binding(get: { !pendingSignOut.isEmpty },
                                                 set: { if !$0 { pendingSignOut = [] } }),
                            titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                let targets = pendingSignOut
                pendingSignOut = []
                Task { await signOut(targets) }
            }
            Button("Cancel", role: .cancel) { pendingSignOut = [] }
        } message: {
            Text("The stored credentials are deleted from this Mac’s Keychain. Public images "
                 + "still pull from registries that allow it.")
        }
    }

    private var removeTitle: String {
        pendingRemove.count == 1
            ? "Remove “\(pendingRemove[0].name)” from the list?"
            : "Remove \(pendingRemove.count) registries from the list?"
    }

    private var signOutTitle: String {
        pendingSignOut.count == 1
            ? "Sign out of “\(pendingSignOut[0].name)”?"
            : "Sign out of \(pendingSignOut.count) registries?"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search registries…",
                       updated: model.registriesLastRefresh,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all registries" : "Select all registries")
                .help(ui.presentation != .list ? "Switch to list view to select"
                      : allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<RegistryRow>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: Self.filters)
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "Add a registry…") { form = .add }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh registries") {
                Task { await model.refreshRegistries() }
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"), ("server", "Server"), ("signIn", "Sign-in"),
        ("status", "Status"), ("type", "Type"),
    ]

    private static let filters: [ResourceFilterOption] = [
        .init(id: "all", title: "All", systemImage: "circle.grid.2x2"),
        .init(id: "signedIn", title: "Signed in", systemImage: "checkmark.circle"),
        .init(id: "notSignedIn", title: "Not signed in", systemImage: "circle.dashed"),
        .init(id: "required", title: "Sign-in required", systemImage: "lock"),
        .init(id: "yours", title: "Added by you", systemImage: "person"),
    ]

    private var isFiltered: Bool {
        !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all"
    }

    private var displayedRows: [RegistryRow] {
        var rows = self.rows
        switch ui.filterID {
        case "signedIn": rows = rows.filter(\.isSignedIn)
        case "notSignedIn": rows = rows.filter { !$0.isSignedIn && $0.canSignIn }
        case "required": rows = rows.filter { $0.signInNeed == .required }
        case "yours": rows = rows.filter(\.isUserAdded)
        default: break
        }
        // Name, server, account and tag names, like every other section's search.
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.lowercased().contains(query)
                    || row.id.lowercased().contains(query)
                    || (row.username?.lowercased().contains(query) ?? false)
                    || model.tags.tags(on: .registry, row.id)
                        .contains { $0.name.lowercased().contains(query) }
            }
        }
        return rows.sorted(using: ui.sortOrder)
    }

    private var visibleIDs: Set<RegistryRow.ID> { Set(displayedRows.map(\.id)) }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    /// The selection, limited to what is on screen — filtering does not clear a table's selection.
    private var selectedRows: [RegistryRow] {
        displayedRows.filter { selection.contains($0.id) }
    }

    private var selectedTagSubjects: [TagSubject] {
        selectedRows.map { TagSubject(kind: .registry, id: $0.id) }
    }

    private func selectionToggle(for id: RegistryRow.ID) -> some View {
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
            let signedIn = selectedRows.filter(\.isSignedIn)
            let listed = selectedRows.filter(\.isListed)
            HStack(spacing: 12) {
                Text("\(selectedRows.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                BulkTagMenu(store: model.tags, subjects: selectedTagSubjects) {
                    tagSheet = TagSheetTarget(selectedTagSubjects)
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "person.crop.circle.badge.xmark",
                                 label: "Sign out of \(signedIn.count) registries",
                                 help: signedIn.isEmpty ? "None of these is signed in"
                                     : !model.runtimeUsable ? "Start the container system to sign out"
                                     : "Sign out of \(signedIn.count)",
                                 disabled: signedIn.isEmpty || !model.runtimeUsable) {
                    pendingSignOut = signedIn
                }
                IconActionButton(systemImage: "trash",
                                 label: "Remove \(listed.count) registries from the list",
                                 help: listed.isEmpty ? "None of these is in your list"
                                                      : "Remove \(listed.count) from the list",
                                 disabled: listed.isEmpty, destructive: true) {
                    pendingRemove = listed
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .registry).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if displayedRows.isEmpty {
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No registries",
                      systemImage: isFiltered ? "line.3.horizontal.decrease"
                                              : Section.registries.systemImage)
            } description: {
                // The sentence the whole section exists to prevent someone getting wrong.
                Text(isFiltered
                     ? "No registry matches the current filter."
                     : "Flotilla can pull from any OCI registry — this list isn't a restriction. "
                       + "Add the ones you use to sign in and set a default.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
                } else {
                    Button("Add Registry…") { form = .add }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                runtimeNote
                if ui.presentation == .list { table } else { cards }
            }
        }
    }

    /// The list is local and always shows; only who you are signed in as needs the runtime. Said
    /// once, above the table, rather than as "Not signed in" on every row, which would be a claim
    /// about the Keychain nobody checked.
    @ViewBuilder
    private var runtimeNote: some View {
        switch model.registriesState {
        case .unavailable(let reason), .failed(let reason):
            Label("Sign-in status unknown: \(reason)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        default:
            EmptyView()
        }
    }

    private var statusKnown: Bool { model.registriesState == .loaded }

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
                HStack(spacing: 6) {
                    Button(row.name) { form = .manage(row.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.rowName(selected: selection.contains(row.id)))
                        .lineLimit(1)
                        .help("Open \(row.name)")
                    badges(for: row)
                }
            }
            .width(min: 170, ideal: 240)

            TableColumn("Tags") { row in
                TagPillRow(tags: model.tags.tags(on: .registry, row.id), compact: true)
            }
            .width(min: 60, ideal: 110)
            .customizationID("tags")

            TableColumn("Server", value: \.hostSortKey) { row in
                Text(row.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.id)
            }
            .width(min: 120, ideal: 180)
            .customizationID("server")

            TableColumn("Sign-in", value: \.signInSortKey) { row in
                Text(row.signInNeed.title)
                    .foregroundStyle(row.signInNeed == .required ? .primary : .secondary)
                    .help(row.signInUnavailableReason ?? signInHelp(row.signInNeed))
            }
            .width(min: 70, ideal: 90)
            .customizationID("signIn")

            TableColumn("Status", value: \.statusSortKey) { row in
                if statusKnown || row.isSignedIn {
                    RegistryStatusLabel(row: row)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                        .help("Sign-in status needs the container runtime")
                }
            }
            .width(min: 110, ideal: 170)
            .customizationID("status")

            TableColumn("Type", value: \.kindSortKey) { row in
                Text(row.kindTitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            .customizationID("type")

            TableColumn("Actions") { row in
                rowActions(for: row)
            }
            .width(min: 78, ideal: 92)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: RegistryRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                menu(for: row)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first else { return }
            form = .manage(id)
        }
    }

    private func signInHelp(_ need: SignInNeed) -> String {
        switch need {
        case .required: "Nothing can be pulled from it without an account."
        case .optional: "Public images pull without an account; signing in reaches private ones."
        case .notNeeded: "It has no accounts at all."
        }
    }

    /// Two different "defaults", and they stay two badges. `default` is the registry
    /// **Flotilla's** Pull form completes a bare name against, which you choose; `CLI default` is
    /// what the **runtime** resolves a bare name to, which you cannot. One badge for both would
    /// claim the setting changes the runtime.
    @ViewBuilder
    private func badges(for row: RegistryRow) -> some View {
        if row.id == model.defaultRegistry {
            badge("default")
                .help("Flotilla's Pull uses this for image names with no registry")
        } else if row.known?.isImplicitDefault == true {
            badge("CLI default")
        }
        if row.isUserAdded { badge("yours") }
        if !row.isListed { badge("not in your list") }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedRows) { row in
                ResourceCard(
                    title: row.name,
                    badge: row.id == model.defaultRegistry ? "default"
                        : (row.isListed ? nil : "not in your list"),
                    fields: [("Server", row.id),
                             ("Sign-in", row.signInNeed.title),
                             ("Status", statusKnown || row.isSignedIn ? row.statusText : nil),
                             ("Type", row.kindTitle)],
                    tags: model.tags.tags(on: .registry, row.id),
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
    private func rowActions(for row: RegistryRow) -> some View {
        HStack(spacing: 2) {
            Menu {
                menu(for: row)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(row.name)")
            .accessibilityLabel("More actions for \(row.name)")

            Divider().frame(height: 14)

            // The one primary action a registry has. Absent, not greyed, where there is no
            // account to sign in to.
            if row.canSignIn {
                IconActionButton(systemImage: "key",
                                 label: row.isSignedIn ? "Switch account on \(row.name)"
                                                       : "Sign in to \(row.name)",
                                 help: !model.runtimeUsable ? "Start the container system to sign in"
                                     : row.isSignedIn ? "Sign in as a different account"
                                     : "Sign in to \(row.name)",
                                 disabled: !model.runtimeUsable) {
                    form = .manage(row.id)
                }
            }
            IconActionButton(systemImage: "trash",
                             label: "Remove \(row.name) from the list",
                             help: row.isListed ? "Remove from the list. Does not sign out."
                                                : "Not in your list — sign out to remove it",
                             disabled: !row.isListed,
                             destructive: true) {
                requestRemove([row])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(for row: RegistryRow) -> some View {
        Button(row.canSignIn ? (row.isSignedIn ? "Switch Account…" : "Sign In…") : "Open…") {
            form = .manage(row.id)
        }
        .disabled(row.canSignIn && !model.runtimeUsable)
        if row.isSignedIn {
            Button("Sign Out…") { pendingSignOut = [row] }
                .disabled(!model.runtimeUsable)
        }
        Divider()
        // From the table, as the owner asked: any row can be the default, which is what
        // Flotilla's own Pull form completes a bare name against.
        Button("Set as Default") { model.setDefaultRegistry(row.id) }
            .disabled(row.id == model.defaultRegistry)
        if let url = row.browseURL {
            Button("Browse \(row.name) in Browser") { NSWorkspace.shared.open(url) }
        }
        if let url = row.tokenURL {
            Button("Create a Token in Browser") { NSWorkspace.shared.open(url) }
        }
        Divider()
        TagMenu(store: model.tags, subject: TagSubject(kind: .registry, id: row.id)) {
            tagSheet = TagSheetTarget(kind: .registry, id: row.id)
        }
        Divider()
        CopyMenu([("Server", row.id), ("Name", row.name), ("Username", row.username)])
        Divider()
        if row.isListed {
            Button("Remove from List…", role: .destructive) { requestRemove([row]) }
        } else {
            Button("Add to List") { addToList(row) }
        }
    }

    // MARK: Actions

    /// Removing from the list deletes nothing — it is the delete policy's "single" case all the
    /// same, so someone who turned confirmations off is not asked.
    private func requestRemove(_ rows: [RegistryRow]) {
        let listed = rows.filter(\.isListed)
        guard !listed.isEmpty else { return }
        if listed.count == 1, !model.deletePolicy.requiresConfirmation(.single) {
            model.removeRegistries(listed.map(\.id))
        } else {
            pendingRemove = listed
        }
    }

    private func addToList(_ row: RegistryRow) {
        if let known = KnownRegistry.catalogue.first(where: {
            KnownRegistry.canonicalHost($0.id) == KnownRegistry.canonicalHost(row.id)
        }) {
            model.addRegistry(known: known)
        } else {
            model.addRegistry(host: row.id, name: "", summary: "",
                              kind: RegistryKind.inferred(fromHost: row.id),
                              usesHTTP: false, signInRequired: true)
        }
    }

    private func signOut(_ rows: [RegistryRow]) async {
        var failures: [String] = []
        for row in rows {
            if let error = await model.signOut(registry: row.credentialHost) {
                failures.append("\(row.name): \(error)")
            }
        }
        await model.refreshRegistries()
        if !failures.isEmpty { actionError = failures.joined(separator: "\n") }
    }
}
