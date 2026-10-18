import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlotillaCore

/// Finder-style access to a running LOCAL container. Listing uses `exec … ls -lan` plus `find -print0` because
/// `container copy` cannot enumerate. It needs the Terminal's ExecPolicy.interactiveShell;
/// distroless/scratch images without ls/find cannot be browsed. Copies use `container copy`, with
/// the panel's host endpoint checked by a per-invocation MountPolicy. Open/Share use a private
/// session temporary directory, removed at app termination. No wire capability is introduced.
///
/// Writes are local-owner exec argv through the existing Allowlist, never shell text. `--`
/// separates utility options from paths (the allowlist removes exec's own separator, as the
/// real CLI requires). Delete always names the selection and confirms recursive folder removal.
struct FilesTab: View {
    let model: AppModel
    let container: Container

    @State private var path = "/"
    @State private var history = ["/"]
    @State private var historyIndex = 0
    @State private var entries: [FileEntry] = []
    @State private var cache: [FileEntry.ID: [FileEntry]] = [:]
    @State private var selection = Set<FileEntry.ID>()
    @State private var expanded = Set<FileEntry.ID>()
    @State private var anchor: FileEntry.ID?
    @State private var loading = false
    @State private var busy = false
    @State private var listingFailure: String?
    @State private var actionFailure: String?
    @State private var loadToken = UUID()
    @State private var grouping: FileGrouping = .none
    @State private var sort: FilesSort = .name
    @State private var ascending = true
    @State private var searchText = ""
    @State private var submittedSearch = ""
    @State private var results: [String] = []
    @State private var searchCapped = false
    @State private var edit: FileEdit?
    @State private var editText = ""
    @State private var deleting: [FileEntry] = []
    @State private var overwriteTarget: (url: URL, destination: String)?
    @State private var shareAnchor = NSView()
    @State private var sharingPicker: NSSharingServicePicker?
    @FocusState private var filesFocused: Bool

    private var canWrite: Bool {
        model.cli.execPolicy == .interactiveShell && model.cli.wirePolicy == .localOwner && AppModel.isRunning(container)
    }
    private var mode: FilesViewMode { model.filesViewModes[container.id] ?? .list }
    private var allEntries: [FileEntry] {
        var unique: [FileEntry.ID: FileEntry] = [:]
        for entry in cache.values.flatMap({ $0 }) + entries { unique[entry.id] = entry }
        return Array(unique.values)
    }
    private var selected: [FileEntry] { allEntries.filter { selection.contains($0.id) }.sorted { $0.id.lexicographicallyPrecedes($1.id) } }
    private var sorted: [FileEntry] { sort.sorted(entries, ascending: ascending) }
    private var columnPaths: [String] {
        var paths = ["/"]
        for part in FileCommand.pathComponents(path) {
            paths.append(FileCommand.child(part, in: paths.last ?? "/"))
        }
        return paths
    }
    private var displayed: [FileEntry] {
        if mode == .columns { return columnPaths.flatMap { sort.sorted(cache[Array($0.utf8)] ?? [], ascending: ascending) } }
        return grouping.groups(sorted).flatMap { flatten($0.entries) }.map(\.entry)
    }
    private func flatten(_ items: [FileEntry], depth: Int = 0) -> [FilesRow] {
        items.flatMap { entry in
            [FilesRow(entry: entry, depth: depth)] + (expanded.contains(entry.id)
                ? flatten(sort.sorted(cache[entry.id] ?? [], ascending: ascending), depth: depth + 1) : [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let edit { editor(edit) }
            content
            // The path sits at the bottom with the counts, as Finder's path bar does (Kamal, 18
            // October): the toolbar keeps the controls, the footer says where you are and how much.
            HStack(spacing: 10) {
                // Left-aligned when it fits; a long path scrolls, showing its last folder.
                ViewThatFits(in: .horizontal) {
                    breadcrumbs.frame(maxWidth: .infinity, alignment: .leading)
                    ScrollView(.horizontal) { breadcrumbs }
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(.trailing)
                }
                .layoutPriority(-1)
                Text(submittedSearch.isEmpty ? "\(entries.count) items · \(selection.count) selected" : "\(results.count) results\(searchCapped ? " · first 500 / output limit" : "")")
                    .fixedSize()
                if loading || busy { ProgressView().controlSize(.small) }
                tool("arrow.clockwise", "Reload", disabled: loading || busy) { Task { await load() } }
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: Array(path.utf8)) { await load() }
        .onChange(of: mode) { _, _ in if mode == .columns { Task { await load() } } }
        .alert("File action failed", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
            Button("OK", role: .cancel) { actionFailure = nil }
        } message: { Text(actionFailure ?? "") }
        .confirmationDialog("Delete \(deleting.map { "“\($0.name)”" }.joined(separator: ", "))?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                let items = deleting
                deleting = []
                run {
                    for item in items { try item.requireMutable(); try await model.changeFiles(.delete(path: item.path, directory: item.isDirectory), in: container.id) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: {
            Text("This cannot be undone. " + (deleting.contains(where: \.isDirectory)
                 ? "Folders (\(deleting.filter(\.isDirectory).map(\.name).joined(separator: ", "))) and everything in them will be deleted recursively."
                 : "The selected files will be permanently deleted."))
        }
        .confirmationDialog("Replace “\(overwriteTarget?.url.lastPathComponent ?? "")”?",
                            isPresented: Binding(get: { overwriteTarget != nil }, set: { if !$0 { overwriteTarget = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let target = overwriteTarget { run { try await model.upload(target.url, to: target.destination, in: container.id) } }
                overwriteTarget = nil
            }
            Button("Cancel", role: .cancel) { overwriteTarget = nil }
        } message: { Text("The existing item in \(path) will be replaced. This cannot be undone.") }
    }

    // Exactly PageTabs' regular glass capsule, with ActionCluster's container spacing.
    private var toolbar: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        tool("chevron.left", "Back", disabled: historyIndex == 0) { step(-1) }
                        tool("chevron.right", "Forward", disabled: historyIndex == history.count - 1) { step(1) }
                        Divider().frame(height: 18)
                        ForEach(FilesViewMode.allCases, id: \.self) { candidate in
                            tool(candidate.symbol, candidate.rawValue) { model.filesViewModes[container.id] = candidate }
                                .background(mode == candidate ? Theme.accent.opacity(0.25) : .clear, in: .capsule)
                                .accessibilityAddTraits(mode == candidate ? [.isSelected] : [])
                        }
                        Menu {
                            ForEach(FileGrouping.allCases, id: \.self) { option in
                                Button { grouping = option } label: {
                                    if grouping == option { Label(option.rawValue, systemImage: "checkmark") }
                                    else { Text(option.rawValue) }
                                }
                                .disabled(!option.available)
                                .help(option.available ? "Group by \(option.rawValue.lowercased())" : "A container's files don't record this")
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).fixedSize().help("Group By").accessibilityLabel("Group By")
                        tool("square.and.arrow.up", "Share", disabled: selected.isEmpty || busy) { temporaryAction(.share, items: selected) }
                            .background(FileShareAnchor(view: shareAnchor).allowsHitTesting(false))
                        tool("arrow.down.to.line", "Download to this Mac", disabled: selected.isEmpty || busy) { download(selected) }
                        Menu { actions(for: selected) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().help("File actions").accessibilityLabel("File actions")
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search here", text: $searchText)
                                .textFieldStyle(.plain).frame(width: geometry.size.width > 900 ? 150 : 100)
                                .onSubmit { submittedSearch = searchText; Task { await load() } }
                                .help("Search names below \(path) (Return). Up to 500 results, 10 second timeout.")
                            if !searchText.isEmpty || !submittedSearch.isEmpty {
                                tool("xmark.circle.fill", "Clear search") {
                                    searchText = ""; submittedSearch = ""; Task { await load() }
                                }
                            }
                        }.padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(minWidth: max(0, geometry.size.width - 16))
                    .glassEffect(in: .capsule)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }.scrollIndicators(.hidden)
        }
        .frame(height: 48)

    }

    private func tool(_ symbol: String, _ label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26).contentShape(.capsule)
        }
            .buttonStyle(.plain).disabled(disabled).help(label).accessibilityLabel(label)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 3) {
            Button("/") { navigate("/") }.buttonStyle(.plain)
            ForEach(Array(FileCommand.pathComponents(path).enumerated()), id: \.offset) { index, part in
                Text("›").foregroundStyle(.tertiary)
                Button(String(part)) { navigate("/" + FileCommand.pathComponents(path).prefix(index + 1).joined(separator: "/")) }
                    .buttonStyle(.plain)
            }
        }.font(.caption).lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        if !AppModel.isRunning(container) {
            ContentUnavailableView("Container is not running", systemImage: "folder", description: Text("Start “\(container.id)” to browse its files."))
        } else if model.cli.execPolicy != .interactiveShell || model.cli.wirePolicy != .localOwner {
            ContentUnavailableView("Files are unavailable", systemImage: "lock", description: Text("Browsing needs this Mac's owner's interactive exec permission."))
        } else {
            VStack(spacing: 0) {
                if let listingFailure {
                    ContentUnavailableView {
                        Label("Cannot read these files", systemImage: "exclamationmark.triangle")
                    } description: { Text(listingFailure) } actions: { Button("Try again") { Task { await load() } } }
                } else if !submittedSearch.isEmpty {
                    searchResults
                } else if entries.isEmpty && loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    presentation
                }
            }
        }
    }

    @ViewBuilder private var presentation: some View {
        Group {
            switch mode {
            case .list:
                FilesListView(groups: grouping.groups(sorted).map { FilesRowGroup(name: $0.name, rows: flatten($0.entries)) },
                              selection: $selection, expanded: expanded, sort: sort, ascending: ascending,
                              sortBy: sortBy, toggle: toggle, activate: open, menu: { actions(for: $0) }, entries: allEntries)
            case .icons:
                FilesIconView(groups: grouping.groups(sorted).map { FilesRowGroup(name: $0.name, rows: $0.entries.map { FilesRow(entry: $0, depth: 0) }) },
                              selection: selection, select: select, activate: open, menu: { actions(for: $0) }, selected: selected)
            case .columns:
                FilesColumnView(paths: columnPaths, cache: cache, grouping: grouping, sort: sort, ascending: ascending,
                                selection: selection, select: selectColumn, activate: open, menu: { actions(for: $0) }, selected: selected)
            }
        }
        .focusable().focused($filesFocused)
        .onKeyPress(.return) { open(selected); return .handled }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard mode != .list else { return .ignored }
            let parent = anchor.map { (String(decoding: $0, as: UTF8.self) as NSString).deletingLastPathComponent } ?? path
            let visible = mode == .columns
                ? grouping.groups(sort.sorted(cache[Array(parent.utf8)] ?? [], ascending: ascending)).flatMap(\.entries) : displayed
            guard !visible.isEmpty else { return .ignored }
            let index = visible.firstIndex(where: { $0.id == anchor }) ?? (press.key == .downArrow ? -1 : visible.count)
            let next = max(0, min(visible.count - 1, index + (press.key == .downArrow ? 1 : -1)))
            if press.modifiers.contains(.shift) { selection.insert(visible[next].id) }
            else { selection = [visible[next].id] }
            anchor = visible[next].id
            if mode == .columns, selection.count == 1 { revealColumn(visible[next]) }
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(displayed.map(\.id)); return .handled
        }
    }

    private var searchResults: some View {
        List(results.map { Array($0.utf8) }, id: \.self) { bytes in
            let result = String(decoding: bytes, as: UTF8.self)
            Button {
                let parent = (result as NSString).deletingLastPathComponent
                navigate(parent.isEmpty ? "/" : parent)
                selection = [bytes]
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    VStack(alignment: .leading) {
                        Text((result as NSString).lastPathComponent)
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
        }
        .overlay { if results.isEmpty && !loading { ContentUnavailableView.search(text: submittedSearch) } }
    }

    @ViewBuilder private func actions(for items: [FileEntry]) -> some View {
        let restriction = items.compactMap(\.mutationRestriction).first
        Button("Open") { open(items) }.disabled(items.isEmpty || busy)
        Button("Open With…") { temporaryAction(.openWith, items: items) }.disabled(items.isEmpty || items.contains(where: \.isDirectory) || busy)
        Button("Download…") { download(items) }.disabled(items.isEmpty || busy)
        Button("Copy Path") { Clipboard.copy(items.map(\.path).joined(separator: "\n")) }.disabled(items.isEmpty)
        if canWrite {
            Divider()
            Button("New Folder…") { begin(.newFolder) }.disabled(busy || !submittedSearch.isEmpty)
            Button("Upload a File…") { upload() }.disabled(busy || !submittedSearch.isEmpty)
            Button("Rename…") { if let item = items.first { begin(.rename(item)) } }.disabled(items.count != 1 || busy || restriction != nil).help(restriction ?? "Rename this item")
            Button("Move to…") { begin(.move(items)) }.disabled(items.isEmpty || busy || restriction != nil).help(restriction ?? "Move these items")
            Button("Delete…", role: .destructive) { deleting = items }.disabled(items.isEmpty || busy || restriction != nil).help(restriction ?? "Delete these items")
        }
    }

    private func navigate(_ destination: String, keepingSelection: Bool = false) {
        submittedSearch = ""; searchText = ""; listingFailure = nil; edit = nil
        if !keepingSelection { selection = []; anchor = nil }
        expanded = []
        if Array(destination.utf8) != Array(path.utf8) {
            history = Array(history.prefix(historyIndex + 1)) + [destination]
            historyIndex = history.count - 1
            path = destination
            entries = cache[Array(destination.utf8)] ?? []
        } else { Task { await load() } }
    }
    private func step(_ offset: Int) {
        let next = historyIndex + offset
        guard history.indices.contains(next) else { return }
        historyIndex = next; path = history[next]; entries = cache[Array(path.utf8)] ?? []
        selection = []; expanded = []; submittedSearch = ""; searchText = ""; edit = nil
    }
    private func sortBy(_ key: FilesSort) {
        if sort == key { ascending.toggle() } else { sort = key; ascending = true }
    }
    private func select(_ entry: FileEntry, _ visible: [FileEntry]) {
        filesFocused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor, let start = visible.firstIndex(where: { $0.id == anchor }),
           let end = visible.firstIndex(where: { $0.id == entry.id }) {
            selection.formUnion(visible[min(start, end)...max(start, end)].map(\.id))
        } else if modifiers.contains(.command) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            anchor = entry.id
        } else { selection = [entry.id]; anchor = entry.id }
    }
    private func selectColumn(_ entry: FileEntry, _ visible: [FileEntry]) {
        select(entry, visible)
        if selection.count == 1 { revealColumn(entry) }
    }
    private func revealColumn(_ entry: FileEntry) {
        let directory = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        if Array(directory.utf8) != Array(path.utf8) { navigate(directory, keepingSelection: true) }
    }
    private func toggle(_ entry: FileEntry) {
        if expanded.contains(entry.id) { expanded.remove(entry.id); return }
        expanded.insert(entry.id)
        Task {
            do { cache[entry.id] = try await model.listDirectory(entry.path, in: container.id) }
            catch { actionFailure = "Could not expand “\(entry.name)”: \(error)" }
        }
    }
    private func open(_ items: [FileEntry]) {
        guard !busy else { return }
        if items.count == 1, let item = items.first, item.isDirectory { navigate(item.path) }
        else if !items.isEmpty, !items.contains(where: \.isDirectory) { temporaryAction(.open, items: items) }
    }

    private func load() async {
        guard AppModel.isRunning(container), canWrite else { return }
        let token = UUID(); loadToken = token
        let requestedPath = path, query = submittedSearch
        loading = true; listingFailure = nil
        defer { if loadToken == token { loading = false } }
        do {
            if !query.isEmpty {
                let found = try await model.searchFiles(query, directory: requestedPath, in: container.id)
                guard loadToken == token, !Task.isCancelled else { return }
                results = found.paths; searchCapped = found.capped
            } else {
                let output = try await model.listDirectory(requestedPath, in: container.id)
                guard loadToken == token, !Task.isCancelled else { return }
                entries = output
                cache[Array(requestedPath.utf8)] = entries
                // Discard stale child listings on refresh; expanded folders are fetched again.
                for folder in expanded {
                    let output = try await model.listDirectory(String(decoding: folder, as: UTF8.self), in: container.id)
                    guard loadToken == token, !Task.isCancelled else { return }
                    cache[folder] = output
                }
                if mode == .columns {
                    for directory in columnPaths where cache[Array(directory.utf8)] == nil {
                        let output = try await model.listDirectory(directory, in: container.id)
                        guard loadToken == token, !Task.isCancelled else { return }
                        cache[Array(directory.utf8)] = output
                    }
                }
                selection.formIntersection(Set(allEntries.map(\.id)))
            }
        } catch {
            guard loadToken == token, !Task.isCancelled else { return }
            listingFailure = "\(error)\n\nBrowsing needs ls and find with -print0 inside the image. Distroless or scratch images may not include these utilities."
        }
    }

    // Actions keep errors separate from listing failures so a failed copy leaves the files visible.
    private func run(refresh: Bool = true, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation()
                if refresh { cache = [:]; selection = []; expanded = []; await load() }
            } catch {
                actionFailure = String(describing: error)
                if refresh { await load() }
            }
        }
    }
    private func download(_ items: [FileEntry]) {
        guard !items.isEmpty, !busy else { return }
        var destinations: [(FileEntry, URL)] = []
        if items.count == 1, let item = items.first {
            let panel = NSSavePanel(); panel.nameFieldStringValue = item.name; panel.canCreateDirectories = true
            panel.message = "Download “\(item.name)” from \(container.id)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinations = [(item, url)]
        } else {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.prompt = "Download Here"; panel.message = "Choose a folder for \(items.count) items"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            guard Set(items.map(\.name)).count == items.count else { actionFailure = "Some selected items have the same name. Download them separately."; return }
            destinations = items.map { ($0, folder.appendingPathComponent($0.name)) }
            let existing = destinations.filter { FileManager.default.fileExists(atPath: $0.1.path) }
            if !existing.isEmpty {
                let alert = NSAlert(); alert.messageText = "Replace \(existing.map { "“\($0.0.name)”" }.joined(separator: ", "))?"
                alert.informativeText = "Existing items in the chosen Mac folder will be replaced. This cannot be undone."
                alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        run(refresh: false) { for (item, url) in destinations { try await model.download(item.path, from: container.id, to: url) } }
    }
    private enum TemporaryAction { case open, openWith, share }
    private func temporaryAction(_ action: TemporaryAction, items: [FileEntry]) {
        guard !items.isEmpty, !busy else { return }
        var application: URL?
        if action == .openWith {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "Open With"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            application = url
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                var urls: [URL] = []
                for item in items {
                    let url = try FileTemporaryStore.shared.destination(named: item.name)
                    try await model.download(item.path, from: container.id, to: url); urls.append(url)
                }
                switch action {
                case .share:
                    let picker = NSSharingServicePicker(items: urls); sharingPicker = picker
                    picker.show(relativeTo: shareAnchor.bounds, of: shareAnchor, preferredEdge: .minY)
                case .open:
                    for url in urls where !NSWorkspace.shared.open(url) { throw ContainerCLIError.unsupported("No application could open \(url.lastPathComponent).") }
                case .openWith:
                    if let application { _ = try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) }
                }
            } catch { actionFailure = String(describing: error) }
        }
    }
    private func upload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = "Upload a file to \(container.id):\(path)"; panel.prompt = "Upload"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = FileCommand.child(url.lastPathComponent, in: path)
        if entries.contains(where: { $0.id == Array(destination.utf8) }) { overwriteTarget = (url, destination) }
        else { run { try await model.upload(url, to: destination, in: container.id) } }
    }

    private func begin(_ value: FileEdit) {
        edit = value
        if case .rename(let item) = value { editText = item.name }
        else if case .move = value { editText = path }
        else { editText = "" }
    }
    private func editor(_ edit: FileEdit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(edit.title).font(.headline)
            HStack {
                TextField(edit.placeholder, text: $editText).textFieldStyle(.roundedBorder).onSubmit { submit(edit) }
                Button("Cancel") { self.edit = nil }
                Button(edit.title) { submit(edit) }.disabled(!edit.valid(editText) || busy)
            }
            Text(edit.valid(editText) ? " " : edit.validationMessage).font(.caption).foregroundStyle(.secondary)
        }.padding(10)
    }
    private func submit(_ edit: FileEdit) {
        guard edit.valid(editText), canWrite else { return }
        let value = editText, directory = path
        self.edit = nil
        run {
            switch edit {
            case .newFolder: try await model.changeFiles(.makeDirectory(parent: directory, name: value), in: container.id)
            case .rename(let entry):
                let parent = (entry.path as NSString).deletingLastPathComponent
                try await move(entry, to: FileCommand.child(value, in: parent))
            case .move(let items):
                for item in items { try await move(item, to: FileCommand.child(item.name, in: "/" + FileCommand.pathComponents(value).joined(separator: "/"))) }
            }
        }
    }
    private func move(_ entry: FileEntry, to destination: String) async throws {
        try entry.requireMutable()
        guard Array(destination.utf8) != entry.id else { return }
        let parent = (destination as NSString).deletingLastPathComponent
        let current = try await model.listDirectory(parent, in: container.id)
        guard !current.contains(where: { $0.id == Array(destination.utf8) }) else { throw ContainerCLIError.unsupported("“\((destination as NSString).lastPathComponent)” already exists. Choose another name or folder.") }
        do { try await model.changeFiles(.move(source: entry.path, destination: destination), in: container.id) }
        catch { throw ContainerCLIError.unsupported("Move requires mv -nT for an exact destination. The move failed: \(error)") }
        let sourceParent = (entry.path as NSString).deletingLastPathComponent
        let remaining = try await model.listDirectory(sourceParent, in: container.id)
        let arrived = Array(sourceParent.utf8) == Array(parent.utf8) ? remaining : try await model.listDirectory(parent, in: container.id)
        try entry.verifyMove(to: destination, sourceEntries: remaining, destinationEntries: arrived)
    }
}

private enum FileEdit {
    case newFolder, rename(FileEntry), move([FileEntry])
    var title: String { switch self { case .newFolder: "New Folder"; case .rename: "Rename"; case .move: "Move" } }
    var placeholder: String { if case .move = self { "Absolute destination folder in this container" } else { "Name" } }
    var validationMessage: String { if case .move = self { "Use an absolute container folder path without . or ..." } else { "Use a non-empty name without /, . or ..." } }
    func valid(_ text: String) -> Bool {
        if case .move = self { return (try? FileCommand.validatePath(text, allowRoot: true)) != nil }
        return FileCommand.isValidName(text)
    }
}

private struct FileShareAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
