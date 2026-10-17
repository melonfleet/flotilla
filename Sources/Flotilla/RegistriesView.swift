import SwiftUI
import AppKit
import FlotillaCore

/// The Registries section: where images come from, and which of them this Mac is signed in to.
///
/// **Moved out of Settings into the sidebar under Images** (the owner, 5 October), with the same
/// setup as every other section — rows, search, filter, a Sort menu, row menus that match the
/// context menu, checkboxes with bulk actions and tags. Settings ▸ Registries is
/// gone; the default registry is set from the list. Two-line rows since Q56.
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
        // Filtering, searching and removal hide rows without clearing their ids; the bulk bar and
        // menu must not count rows nobody can see.
        .onChange(of: visibleIDs) { _, ids in selection.formIntersection(ids) }
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
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search registries…",
                       matches: displayedRows.count,
                       updated: model.registriesLastRefresh,
                       leading: {
            ResourceListControls(
                selection: $selection,
                selectable: selectableIDs,
                noun: "registries",
                sort: ui.sortMenu(default: SortKey.name),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                filters: Self.filters)
        }, trailing: {
            ToolbarIconButton(systemImage: "plus", label: "Add a registry…") { form = .add }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh registries") {
                Task { await model.refreshRegistries() }
            }
        })
    }

    /// The old table's sortable columns. Ties break on name.
    enum SortKey: String, RowSortKey {
        case name = "Name"
        case server = "Server"
        case signIn = "Sign-in"
        case status = "Status"
        case type = "Type"
    }

    private var sortOrder: [KeyPathComparator<RegistryRow>] {
        let order: SortOrder = ui.sortAscending ? .forward : .reverse
        let byName = KeyPathComparator(\RegistryRow.nameSortKey)
        switch ui.sortKey(default: SortKey.name) {
        case .name: return [KeyPathComparator(\RegistryRow.nameSortKey, order: order)]
        case .server: return [KeyPathComparator(\RegistryRow.hostSortKey, order: order), byName]
        case .signIn: return [KeyPathComparator(\RegistryRow.signInSortKey, order: order), byName]
        case .status: return [KeyPathComparator(\RegistryRow.statusSortKey, order: order), byName]
        case .type: return [KeyPathComparator(\RegistryRow.kindSortKey, order: order), byName]
        }
    }

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
        return rows.sorted(using: sortOrder)
    }

    private var visibleIDs: Set<RegistryRow.ID> { Set(displayedRows.map(\.id)) }

    /// Every row on screen: each can be tagged, so each can be in a selection.
    private var selectableIDs: [RegistryRow.ID] { displayedRows.map(\.id) }

    /// The selection, limited to what is on screen — filtering does not clear the list's selection.
    private var selectedRows: [RegistryRow] {
        displayedRows.filter { selection.contains($0.id) }
    }

    private var selectedTagSubjects: [TagSubject] {
        selectedRows.map { TagSubject(kind: .registry, id: $0.id) }
    }

    // MARK: Bulk

    @ViewBuilder
    private var bulkActionBar: some View {
        // From one row: a ticked box is a selection made on purpose (Kamal, 17 October).
        if !selectedRows.isEmpty {
            let signedIn = selectedRows.filter(\.isSignedIn)
            let listed = selectedRows.filter(\.isListed)
            BulkActionBar(title: "\(selectedRows.count) selected") {
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
                rowsList
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

    /// The rows, filling the pane — `ResourceRow`'s two lines, the list's own selection. Rows are
    /// as tall as their content; nothing here writes a height down.
    private var rowsList: some View {
        List(displayedRows, selection: $selection) { row in
            listRow(row)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: RegistryRow.ID.self) { ids in
            rowContextMenu(for: ids)
        } primaryAction: { ids in
            // Only when the activation names exactly one row — with several selected,
            // `ids.first` is an arbitrary member.
            guard ids.count == 1, let id = ids.first else { return }
            form = .manage(id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ row: RegistryRow) -> some View {
        ResourceRow(
            title: row.name,
            opens: { form = .manage(row.id) },
            detail: detailParts(row).joined(separator: " · "),
            detailHelp: row.signInUnavailableReason ?? row.summary,
            selected: selection.contains(row.id),
            check: RowCheck(row.id, in: $selection),
            summary: rowSummary(row),
            reservesMetrics: false,
            leading: { stateMark(row) },
            chips: { rowChips(row) },
            metrics: { EmptyView() },
            actions: { rowActions(for: row) })
    }

    /// Green when this Mac holds a login for it; grey otherwise, which includes "we could not
    /// look" — the runtime note above the list says that once rather than per row.
    private func stateMark(_ row: RegistryRow) -> some View {
        Circle()
            .fill(row.isSignedIn ? Theme.online : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .help(statusKnown || row.isSignedIn ? row.statusText : "Sign-in status needs the container runtime")
    }

    /// Server · type · who you are signed in as. The hosts a registry is signed in on are not here:
    /// `registry login` is local-only (Q20), so there is only ever This Mac.
    private func detailParts(_ row: RegistryRow) -> [String] {
        var parts = [row.id, row.kindTitle]
        if statusKnown || row.isSignedIn {
            parts.append(row.statusText)
        } else if row.signInNeed == .required {
            parts.append("Sign-in required")
        }
        return parts
    }

    private func rowSummary(_ row: RegistryRow) -> String {
        var parts = [row.name, row.id, row.kindTitle]
        if statusKnown || row.isSignedIn { parts.append(row.statusText) }
        if row.id == model.defaultRegistry { parts.append("default registry") }
        else if row.known?.isImplicitDefault == true { parts.append("CLI default") }
        if row.isUserAdded { parts.append("added by you") }
        if !row.isListed { parts.append("not in your list") }
        if row.signInNeed == .required, !row.isSignedIn { parts.append("sign-in required") }
        let tagNames = model.tags.tags(on: .registry, row.id).map(\.name)
        if !tagNames.isEmpty { parts.append("tags " + tagNames.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }

    /// Default / CLI default / yours / not in your list, and Sign-in required when it is, then the
    /// tags. Built-in is the absence of "yours", so it gets no chip of its own.
    ///
    /// Two different "defaults", and they stay two chips. `default` is the registry **Flotilla's**
    /// Pull form completes a bare name against, which you choose; `CLI default` is what the
    /// **runtime** resolves a bare name to, which you cannot. One chip for both would claim the
    /// setting changes the runtime.
    @ViewBuilder
    private func rowChips(_ row: RegistryRow) -> some View {
        HStack(spacing: 4) {
            if row.id == model.defaultRegistry {
                ResourceChip(text: "default")
                    .help("Flotilla's Pull uses this for image names with no registry")
            } else if row.known?.isImplicitDefault == true {
                ResourceChip(text: "CLI default")
            }
            if row.isUserAdded { ResourceChip(text: "yours") }
            if !row.isListed { ResourceChip(text: "not in your list") }
            if row.signInNeed == .required, !row.isSignedIn, row.canSignIn {
                ResourceChip(text: "Sign-in required", systemImage: "lock")
                    .help(signInHelp(.required))
            }
            TagPillRow(tags: model.tags.tags(on: .registry, row.id), compact: true)
        }
    }

    /// What a right-click offers: the row's own menu for one row, the bulk actions for several,
    /// and nothing for empty space.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<RegistryRow.ID>) -> some View {
        let picked = displayedRows.filter { ids.contains($0.id) }
        if picked.count == 1, let row = picked.first {
            menu(for: row)
        } else if picked.count > 1 {
            let subjects = picked.map { TagSubject(kind: .registry, id: $0.id) }
            let signedIn = picked.filter(\.isSignedIn)
            let listed = picked.filter(\.isListed)
            BulkTagMenu(store: model.tags, subjects: subjects) {
                tagSheet = TagSheetTarget(subjects)
            }
            Divider()
            Button("Sign Out of \(signedIn.count)…") { pendingSignOut = signedIn }
                .disabled(signedIn.isEmpty || !model.runtimeUsable)
            Button("Remove \(listed.count) from List…", role: .destructive) { pendingRemove = listed }
                .disabled(listed.isEmpty)
        }
    }


    private func signInHelp(_ need: SignInNeed) -> String {
        switch need {
        case .required: "Nothing can be pulled from it without an account."
        case .optional: "Public images pull without an account; signing in reaches private ones."
        case .notNeeded: "It has no accounts at all."
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
