import SwiftUI
import AppKit
import FlotillaCore

/// Browse a running container's filesystem and copy files out of it.
///
/// **Both halves were checked against the live CLI before any of this was written.**
/// `container copy` exists and works in both directions, but it cannot *enumerate* — so
/// listing goes through `exec … ls -la`, which is why this needs the same
/// `ExecPolicy.interactiveShell` the Terminal tab does. Downloading goes through
/// `container copy`, whose host endpoint the allowlist checks against `MountPolicy`, because a
/// well-formed path is exactly how you would overwrite something you did not mean to.
///
/// Scope is the mockup's own: *"browse and download first. Editing and drag-and-drop only if
/// they prove useful."* Nothing here writes into the container.
///
/// The honest limitation, stated in the UI rather than discovered: **listing needs a shell in
/// the image.** A distroless or scratch container has no `ls`, so browsing fails there even
/// though `container copy` would still work if you knew the path. That is a property of the
/// container, not of Flotilla, and the error says so.
struct FilesTab: View {
    let model: AppModel
    let container: Container

    @State private var path = "/"
    @State private var entries: [FileEntry] = []
    @State private var loading = false
    @State private var failure: String?
    /// Set when an upload would replace an existing file, so the confirmation can name it.
    @State private var overwriteTarget: (url: URL, name: String)?

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            content
        }
        // `.top`, or the whole tab floats in the middle of the pane: with a short body the
        // VStack does not fill, and the default centre alignment then pushes the control bar
        // down the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: path) { await load() }
        // A path in one container means nothing in the next.
        .onChange(of: container.id) { _, _ in path = "/" }
        .confirmationDialog(
            "Replace “\(overwriteTarget?.name ?? "")”?",
            isPresented: Binding(get: { overwriteTarget != nil },
                                 set: { if !$0 { overwriteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let target = overwriteTarget { perform(upload: target.url, named: target.name) }
                overwriteTarget = nil
            }
            Button("Cancel", role: .cancel) { overwriteTarget = nil }
        } message: {
            Text("A file with that name already exists in \(path) inside \(container.id). "
                 + "Replacing it cannot be undone.")
        }
    }

    // MARK: Chrome

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button { path = parentPath } label: { Image(systemName: "chevron.left") }
                .disabled(path == "/")
                .help("Up one directory")
                .accessibilityLabel("Up one directory")

            breadcrumbs

            Spacer()

            // The mockup badges this "read-only browse". That stopped being true the moment
            // upload landed, and a lock icon over a tab that writes files would be worse than
            // no badge at all — so it says what it now does.
            Label("browse · download · upload", systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button { upload() } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(!AppModel.isRunning(container))
                .help("Copy a file from this Mac into \(path)")
                .accessibilityLabel("Upload a file")

            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(loading)
                .help("Refresh")
                .accessibilityLabel("Refresh")
        }
        .padding(12)
    }

    /// Clickable path components, so you can jump back several levels at once instead of
    /// pressing Up repeatedly.
    private var breadcrumbs: some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 3) {
            Button("/") { path = "/" }
                .buttonStyle(.plain)
                .foregroundStyle(path == "/" ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.accentText))
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text("›").foregroundStyle(.tertiary)
                let target = "/" + parts[0...index].joined(separator: "/")
                Button(part) { path = target }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == parts.count - 1
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.accentText))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        if !AppModel.isRunning(container) {
            ContentUnavailableView {
                Label("Container is not running", systemImage: "folder")
            } description: {
                Text("Browsing reads the filesystem from inside the container, so it has to be "
                     + "running. Start “\(container.id)” to look around.")
            }
        } else if let failure {
            ContentUnavailableView {
                Label("Cannot list this directory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if loading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView("Empty directory", systemImage: "folder")
        } else {
            table
        }
    }

    private var table: some View {
        SwiftUI.Table(entries) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(entry.name)
                    if let link = entry.symlinkTarget {
                        Text("→ \(link)").foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .contentShape(.rect)
                // Double-click to descend, matching Finder. Single-click stays selection.
                .onTapGesture(count: 2) { if entry.isDirectory { descend(into: entry) } }
            }
            // An em dash for directories: `ls` reports the size of the directory entry itself,
            // which is 4096 on almost everything and tells you nothing about the contents.
            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "—" : entry.sizeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            TableColumn("Modified") { entry in
                Text(entry.modified).foregroundStyle(.secondary)
            }
            TableColumn("") { entry in
                if entry.isDirectory {
                    Button { descend(into: entry) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Open \(entry.name)")
                } else {
                    Button("Download…") { download(entry) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.accentText)
                        .help("Copy \(entry.name) out of the container")
                }
            }
            .width(90)
        }
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) {
                if entry.isDirectory {
                    Button("Open") { descend(into: entry) }
                } else {
                    Button("Download…") { download(entry) }
                }
                Divider()
                Button("Copy path") { Clipboard.copy(fullPath(of: entry)) }
            }
        }
    }

    // MARK: Actions

    private func descend(into entry: FileEntry) { path = fullPath(of: entry) }

    private var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func fullPath(of entry: FileEntry) -> String {
        path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
    }

    /// A save panel, so the destination is somewhere the user chose. The allowlist still checks
    /// it against `MountPolicy` — the panel decides intent, the policy decides permission, and
    /// conflating the two is how a file dialog becomes an exfiltration primitive in Phase 2.
    private func download(_ entry: FileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.message = "Copy “\(entry.name)” out of \(container.id)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await model.download(fullPath(of: entry), from: container.id, to: url)
            } catch {
                failure = "Could not copy \(entry.name): \(error)"
                model.record("Download failed for \(container.id):\(fullPath(of: entry)): \(error)",
                             subsystem: "files")
            }
        }
    }

    /// Copies a file from this Mac into the directory being browsed.
    ///
    /// Same `container copy` as download, reversed. **Not scp and not a network transfer** —
    /// it is local IPC to the container runtime, and the allowlist checks the host end against
    /// `MountPolicy` in this direction too, because reading a file to upload is host access
    /// just as much as writing one is.
    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Copy a file into \(container.id) at \(path)"
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let name = url.lastPathComponent
        // Overwriting is the destructive case and the listing already knows whether it will
        // happen, so ask rather than discover it afterwards. `FEATURES.md`'s destructive-action
        // policy: name the thing, and say what cannot be undone.
        if entries.contains(where: { $0.name == name && !$0.isDirectory }) {
            overwriteTarget = (url, name)
            return
        }
        perform(upload: url, named: name)
    }

    private func perform(upload url: URL, named name: String) {
        let destination = path == "/" ? "/\(name)" : "\(path)/\(name)"
        Task {
            do {
                try await model.upload(url, to: destination, in: container.id)
                await load()
            } catch {
                failure = "Could not upload \(name): \(error)"
                model.record("Upload failed for \(container.id):\(destination): \(error)",
                             subsystem: "files")
            }
        }
    }

    private func load() async {
        guard AppModel.isRunning(container) else { return }
        loading = true
        failure = nil
        do {
            let output = try await model.listDirectory(path, in: container.id)
            entries = FileEntry.parse(output)
        } catch {
            entries = []
            // The commonest cause by far is an image with no shell, and the raw error
            // ("executable file not found") does not say that.
            failure = "\(error)\n\nBrowsing runs `ls` inside the container. An image built "
                + "without a shell — distroless or scratch — cannot be browsed, though "
                + "individual files can still be copied out if you know the path."
        }
        loading = false
    }
}

/// One row of `ls -la`.
///
/// Parsed rather than modelled in `FlotillaCore` because the format is the *container's* `ls`,
/// not the CLI's: busybox and coreutils differ, and a decoder in the portable core would imply
/// a stability that does not exist.
struct FileEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let symlinkTarget: String?
    let sizeBytes: Int64?
    let modified: String

    var sizeLabel: String {
        guard let sizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// `drwxr-xr-x 2 root root 4096 Jul 15 23:31 name`
    ///
    /// Split into at most nine fields so a filename containing spaces survives — splitting on
    /// every space is the classic way to lose `My Documents`.
    static func parse(_ output: String) -> [FileEntry] {
        output.split(separator: "\n").compactMap { line -> FileEntry? in
            let text = String(line)
            // `total 16` header, and anything too short to be a row.
            guard !text.hasPrefix("total ") else { return nil }

            var fields: [String] = []
            var remainder = Substring(text)
            while fields.count < 8, let space = remainder.firstIndex(of: " ") {
                let field = remainder[remainder.startIndex..<space]
                if !field.isEmpty { fields.append(String(field)) }
                remainder = remainder[remainder.index(after: space)...]
                while remainder.first == " " { remainder = remainder.dropFirst() }
            }
            guard fields.count == 8, !remainder.isEmpty else { return nil }

            let permissions = fields[0]
            var name = String(remainder)
            // `.` and `..` are navigation the breadcrumbs already provide.
            guard name != ".", name != ".." else { return nil }

            var target: String?
            if permissions.hasPrefix("l"), let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[name.startIndex..<arrow.lowerBound])
            }

            return FileEntry(
                id: name,
                name: name,
                // A symlink to a directory is still worth descending into; `ls -la` does not
                // say which it points at, so links are treated as files and the target shown.
                isDirectory: permissions.hasPrefix("d"),
                isSymlink: permissions.hasPrefix("l"),
                symlinkTarget: target,
                sizeBytes: Int64(fields[4]),
                modified: "\(fields[5]) \(fields[6]) \(fields[7])"
            )
        }
    }
}
