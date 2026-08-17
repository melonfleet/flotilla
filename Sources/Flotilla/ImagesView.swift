import SwiftUI
import Foundation
import FlotillaCore

/// The images section: list, pull, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct ImagesView: View {
    let model: AppModel
    let ui: ResourceUIState<ContainerImage>

    @State private var selection = Set<ContainerImage.ID>()

    /// Free-text filter, matched against the reference and tag. Local to the screen: unlike
    /// the containers table there is no cross-section state to preserve.
    @State private var search = ""

    @State private var showingPull = false
    @State private var showingBuild = false
    @State private var pullReference = ""
    @State private var pendingDelete: ContainerImage?
    /// Set from the row menu's Run — presents the run sheet with this reference already in
    /// place. Nothing is launched from here; the sheet's validated preview still gates it.
    @State private var runImage: String?

    @State private var taggingImage: ContainerImage?
    @State private var tagTarget = ""
    @State private var tagError: String?

    @State private var showingPrune = false
    @State private var pruning = false
    @State private var pruneError: String?

    var body: some View {
        Group {
            // Embedded form screens, in precedence order — see `FormHeader` for the 9 August
            // reversal. Prune and About stay modal: they are dialogs you acknowledge, not
            // forms you fill in and save.
            if let reference = runImage {
                RunSheetView(model: model, initialImage: reference) { runImage = nil }
            } else if showingBuild {
                BuildImageView(model: model) { showingBuild = false }
            } else if showingPull {
                pullScreen
            } else if let image = taggingImage {
                tagScreen(for: image)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshImages() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Tag failed",
               isPresented: Binding(get: { tagError != nil }, set: { if !$0 { tagError = nil } })) {
            Button("OK") { tagError = nil }
        } message: {
            Text(tagError ?? "")
        }
        .alert("Prune failed",
               isPresented: Binding(get: { pruneError != nil }, set: { if !$0 { pruneError = nil } })) {
            Button("OK") { pruneError = nil }
        } message: {
            Text(pruneError ?? "")
        }
        .sheet(isPresented: $showingPrune) { pruneSheet }
        .confirmationDialog(
            "Delete image “\(pendingDelete.map(Self.repository) ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let image = pendingDelete {
                    Task { await model.removeImage(image) }
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
                       searchPrompt: "Search images…",
                       updated: model.imagesLastRefresh,
                       leading: {
            ResourceListControls<ContainerImage>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: platformFilters)
        }, trailing: {
            ToolbarIconButton(systemImage: "hammer", label: "Build an image from a Dockerfile…") {
                showingBuild = true
            }
            ToolbarIconButton(systemImage: "arrow.down.circle", label: "Pull an image…") {
                pullReference = ""
                showingPull = true
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh images") {
                Task { await model.refreshImages() }
            }
            Divider().frame(height: 14)
            ToolbarIconButton(systemImage: "trash.slash",
                              label: "Delete images no container is using",
                              isDestructive: true) {
                showingPrune = true
            }
        })
    }

    private static let columnSpecs: [(id: String, title: String)] = [
        ("tag", "Tag"), ("platform", "Platform"), ("digest", "Digest"),
        ("size", "Size"), ("created", "Created"),
    ]

    /// One option per architecture actually present, plus All.
    ///
    /// Derived, not fixed: on an Apple Silicon Mac that has only ever pulled arm64 images this
    /// yields a single entry and `ResourceListControls` hides the control entirely. It earns its
    /// place the moment a multi-arch or an amd64 image lands — which is exactly when you want to
    /// find them, because those are the ones that will run under emulation or not at all.
    private var platformFilters: [ResourceFilterOption] {
        let architectures = Set(model.images
            .flatMap { $0.variants?.compactMap { $0.platform?.architecture } ?? [] }
            .filter { $0 != "unknown" })
        guard architectures.count > 1 else { return [] }
        return [ResourceFilterOption(id: "all", title: "All", systemImage: "circle.grid.2x2")]
            + architectures.sorted().map {
                ResourceFilterOption(id: $0, title: $0, systemImage: "cpu")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.imagesState {
        case .idle, .loading:
            ProgressView("Loading images…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as every other screen: a failed load must never render as an
            // empty list — that would look like a healthy, image-less machine.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .loaded where model.images.isEmpty:
            ContentUnavailableView(
                "No images",
                systemImage: "square.stack.3d.up",
                description: Text("Pull one to run a container from it.")
            )

        case .loaded:
            if ui.presentation == .list { table } else { cards }
        }
    }

    private var cards: some View {
        ResourceCardGrid {
            ForEach(displayedImages) { image in
                ResourceCard(
                    title: Self.repository(image),
                    badge: Self.tag(image),
                    fields: [("Platform", Self.platformLabel(image)),
                             ("Digest", Self.shortDigest(image)),
                             ("Size", image.displaySize.map(Self.byteCount)),
                             ("Created", RelativeDate.relative(image.configuration.creationDate))],
                    onOpen: nil
                ) {
                    rowActions(for: image)
                }
                .contextMenu { menu(for: image) }
            }
        }
    }

    /// A `Table`, matching every other section — repository, tag, platform, digest, size, age.
    ///
    /// The `List` version put the tag and size in a caption under the repository, which meant
    /// you could not sort by size (the thing you actually want when reclaiming disk) and could
    /// not see the platform or digest at all without opening Inspect.
    ///
    /// Repository and tag are separate columns rather than one reference string: sorting by
    /// repository groups an image's tags together, which a combined `nginx:alpine` string does
    /// only by luck of alphabetisation.
    private var table: some View {
        SwiftUI.Table(displayedImages,
                      selection: $selection,
                      sortOrder: Binding(get: { ui.sortOrder }, set: { ui.sortOrder = $0 }),
                      columnCustomization: Binding(get: { ui.columnCustomization },
                                                   set: { ui.columnCustomization = $0 })) {
            TableColumn("Repository", value: \.reference) { image in
                Text(Self.repository(image))
                    .foregroundStyle(Theme.accentText)
                    .lineLimit(1).truncationMode(.middle)
                    .help(image.reference)
            }
            .width(min: 170, ideal: 260)

            TableColumn("Tag") { image in
                Text(Self.tag(image)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 96)
            .customizationID("tag")

            TableColumn("Platform") { image in
                Text(Self.platformLabel(image)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 84, ideal: 100)
            .customizationID("platform")

            TableColumn("Digest") { image in
                // Short form. A digest is a public content hash, not a secret — see the
                // `Redactor(excluding:)` note on the Inspect tab — but 71 characters of it in a
                // table cell is noise, and the full value is one hover away.
                Text(Self.shortDigest(image))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help(image.configuration.descriptor?.digest ?? "no digest reported")
            }
            .width(min: 96, ideal: 116)
            .customizationID("digest")

            TableColumn("Size") { image in
                Text(image.displaySize.map(Self.byteCount) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 74, ideal: 90)
            .customizationID("size")

            TableColumn("Created") { image in
                Text(RelativeDate.relative(image.configuration.creationDate))
                    .foregroundStyle(.secondary)
                    .help(RelativeDate.absolute(image.configuration.creationDate))
            }
            .width(min: 80, ideal: 104)
            .customizationID("created")

            TableColumn("Actions") { image in
                rowActions(for: image)
            }
            .width(min: 108, ideal: 118)
        }
        .frame(maxHeight: .infinity)
        .contextMenu(forSelectionType: ContainerImage.ID.self) { ids in
            if let image = model.images.first(where: { ids.contains($0.id) }) {
                menu(for: image)
            }
        }
    }

    /// Run, tag, overflow, then bin — the same order and the same divider before the
    /// destructive control as the containers and machines rows.
    @ViewBuilder
    private func rowActions(for image: ContainerImage) -> some View {
        let busy = model.busy.contains(image.id)
        HStack(spacing: 2) {
            IconActionButton(systemImage: "play.fill",
                             label: "Run \(Self.repository(image))",
                             help: "Run a container from \(image.reference)",
                             busy: busy) {
                runImage = image.reference
            }
            IconActionButton(systemImage: "tag",
                             label: "Tag \(Self.repository(image))",
                             help: "Tag \(Self.repository(image))",
                             busy: busy) {
                tagTarget = ""
                taggingImage = image
            }

            Menu {
                menu(for: image)
            } label: {
                RowOverflowLabel()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel("More actions for \(Self.repository(image))")

            Divider().frame(height: 14)

            IconActionButton(systemImage: "trash",
                             label: "Delete \(Self.repository(image))",
                             help: "Delete \(Self.repository(image))",
                             busy: busy, destructive: true) {
                requestDelete(image)
            }
            Spacer(minLength: 0)
        }
    }

    /// The platform that would actually run here.
    ///
    /// Taking the *first* variant was wrong on multi-arch images: `nginx:alpine` listed
    /// `linux/amd64` first, so the table claimed amd64 on an Apple Silicon Mac while the
    /// container the CLI runs from it is arm64. Prefer the host's architecture, and mark the
    /// image as multi-arch so the single value does not imply there is only one.
    private static func platformLabel(_ image: ContainerImage) -> String {
        let platforms = image.variants?.compactMap(\.platform) ?? []
        guard !platforms.isEmpty else { return "—" }
        let native = platforms.first { $0.architecture?.contains("arm64") == true } ?? platforms[0]
        let label = [native.os, native.architecture].compactMap { $0 }.joined(separator: "/")
        return platforms.count > 1 ? "\(label) +\(platforms.count - 1)" : label
    }

    private static func shortDigest(_ image: ContainerImage) -> String {
        guard let digest = image.configuration.descriptor?.digest else { return "—" }
        // Drop the `sha256:` prefix and keep the first 12, which is what every registry UI and
        // the CLI's own `image list` show.
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return String(hex.prefix(12))
    }

    /// Hides attestation/provenance manifests (`architecture: "unknown"`) — they're noise
    /// in a list meant to show pullable, runnable images, not build metadata. Only hidden
    /// when EVERY variant is `"unknown"`; a real multi-arch image that happens to carry an
    /// attestation alongside real platforms keeps showing.
    private var displayedImages: [ContainerImage] {
        let visible = model.images.filter { image in
            guard let variants = image.variants, !variants.isEmpty else { return true }
            return !variants.allSatisfy { $0.platform?.architecture == "unknown" }
        }
        var images = visible

        if ui.filterID != "all" {
            images = images.filter { image in
                image.variants?.contains { $0.platform?.architecture == ui.filterID } ?? false
            }
        }

        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            images = images.filter { $0.reference.lowercased().contains(query) }
        }

        return images.sorted(using: ui.sortOrder)
    }

    private var trimmedPull: String {
        pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedTag: String {
        tagTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An image reference has its own shape, and its own rule text — so "not a valid
    /// imageReference" now comes with "expected something like docker.io/library/alpine:latest".
    private var pullProblem: String? {
        guard !trimmedPull.isEmpty else { return nil }
        return problem(in: ["image", "pull", trimmedPull])
    }
    private var tagProblem: String? {
        guard !trimmedTag.isEmpty else { return nil }
        return problem(in: ["image", "tag", "placeholder:latest", trimmedTag])
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    private func row(for image: ContainerImage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.repository(image))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(Self.tag(image)).font(.caption).foregroundStyle(.secondary)
                    if let size = image.displaySize {
                        Text(Self.byteCount(size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            // `IconActionButton` rather than bare `Button`s: these had a tooltip and nothing
            // else, so hovering and clicking both looked like nothing. Same fix as the
            // containers and machines rows — the sections must not differ in how responsive
            // they feel.
            IconActionButton(systemImage: "tag",
                             label: "Tag \(Self.repository(image))",
                             help: "Tag \(Self.repository(image))",
                             busy: model.busy.contains(image.id)) {
                tagTarget = ""
                taggingImage = image
            }
            IconActionButton(systemImage: "trash",
                             label: "Delete \(Self.repository(image))",
                             help: "Delete \(Self.repository(image))",
                             busy: model.busy.contains(image.id),
                             destructive: true) {
                requestDelete(image)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { menu(for: image) }
    }

    /// Parity with the row's own buttons (Tag, Delete) plus the Copy submenu, in the order
    /// `ContextMenus.swift` sets out. "Run" is here because an image you can see is an image
    /// you are likely to want to start — it opens the run sheet pre-filled rather than
    /// launching anything directly, so the command preview still gets the final say.
    @ViewBuilder
    private func menu(for image: ContainerImage) -> some View {
        Button("Run…") { runImage = image.reference }
        Divider()
        Button("Tag…") {
            tagTarget = ""
            taggingImage = image
        }
        .disabled(model.busy.contains(image.id))
        CopyMenu([
            ("Reference", image.reference),
            ("Repository", Self.repository(image)),
            ("Tag", Self.tag(image)),
            ("Digest", image.configuration.descriptor?.digest),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(image) }
            .disabled(model.busy.contains(image.id))
    }

    /// Header + body, the embedded counterpart of `ModalCard`. Local to this file because
    /// only the two image forms need the wrapper shape; the header itself is shared.
    @ViewBuilder
    private func embeddedForm<Content: View>(
        title: String, systemImage: String, onBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            FormHeader(title: title, systemImage: systemImage, onBack: onBack)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func tagScreen(for image: ContainerImage) -> some View {
        embeddedForm(title: "Tag Image", systemImage: "tag", onBack: { taggingImage = nil }) {
            tagForm(for: image).padding(20)
        }
        .frame(width: 440)
    }

    private func tagForm(for image: ContainerImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(image.reference)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 4) {
                TextField("myregistry/name:tag", text: $tagTarget)
                    .textFieldStyle(.roundedBorder)
                if let problem = tagProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            HStack {
                Spacer()
                Button("Tag") {
                    let target = tagTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                    let source = image.reference
                    taggingImage = nil
                    guard !target.isEmpty else { return }
                    Task {
                        do {
                            try await model.tagImage(source, as: target)
                            await model.refreshImages()
                        } catch {
                            tagError = "Tag failed for \(source) → \(target): \(error)"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tagTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Every image not referenced by any known container — client-side, since the CLI has
    /// no dry-run/prune-preview output to ask for. This IS the set `deleteImages` below
    /// will delete, by construction (loop over exactly these references), so the preview
    /// can never drift from the outcome. It may not be bit-for-bit what `container image
    /// prune`'s own internal definition of "unused" would remove — that's the trade-off
    /// for a guaranteed-accurate preview over using the CLI's blanket verb. Flagged in the
    /// report as a judgment call, not silently assumed.
    private var pruneCandidates: [ContainerImage] {
        let referenced = Set(model.containers.map(\.configuration.image.reference))
        return model.images.filter { !referenced.contains($0.reference) }
    }

    /// Always shows the preview, regardless of `confirmDestructiveActions` — that setting
    /// governs whether a single delete needs an "are you sure," but the brief is explicit
    /// that a bulk prune must always show exactly what dies, which is more than a yes/no
    /// confirmation.
    private var pruneSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prune Unused Images").font(.headline)
            if pruneCandidates.isEmpty {
                Text("Nothing to prune — every image is referenced by a container.")
                    .foregroundStyle(.secondary)
            } else {
                Text("These \(pruneCandidates.count) image(s) aren't referenced by any "
                     + "container and will be deleted:")
                    .font(.subheadline)
                List(pruneCandidates) { image in
                    HStack {
                        Text(Self.repository(image)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let size = image.displaySize {
                            Text(Self.byteCount(size)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingPrune = false }
                Button("Delete \(pruneCandidates.count) Image(s)", role: .destructive) {
                    let targets = pruneCandidates.map(\.reference)
                    showingPrune = false
                    Task {
                        pruning = true
                        let failures = await model.deleteImages(targets)
                        pruning = false
                        if let first = failures.first {
                            if failures.count == 1 {
                                pruneError = "Prune failed for \(first.reference): \(first.error)"
                            } else {
                                pruneError = """
                                    Prune failed for \(failures.count) of \(targets.count) images.

                                    First error: \(first.error)
                                    """
                            }
                        }
                        await model.refreshImages()
                    }
                }
                .disabled(pruneCandidates.isEmpty || pruning)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var pullScreen: some View {
        embeddedForm(title: "Pull Image", systemImage: "arrow.down.circle",
                     onBack: { showingPull = false }) {
            pullForm.padding(20)
        }
        .frame(width: 440)
    }

    private var pullForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("docker.io/library/nginx:latest", text: $pullReference)
                    .textFieldStyle(.roundedBorder)
                if let problem = pullProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            HStack {
                Spacer()
                Button("Pull") {
                    let reference = pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingPull = false
                    guard !reference.isEmpty else { return }
                    Task { await model.pullImage(reference) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedPull.isEmpty || pullProblem != nil)
            }
        }
    }

    /// Honours `confirmDestructiveActions` — the whole point of that registry key.
    private func requestDelete(_ image: ContainerImage) {
        if model.settingsStore[SettingsKeys.confirmDestructiveActions] {
            pendingDelete = image
        } else {
            Task { await model.removeImage(image) }
        }
    }

    /// `ContainerImage` has no separate repository/tag fields — `reference` is one string
    /// like `docker.io/library/nginx:latest`. Split it here for display only; the last
    /// `:` after the last `/` is the tag (so a registry port, e.g. `host:5000/name`,
    /// isn't mistaken for one).
    private static func split(_ reference: String) -> (repository: String, tag: String) {
        let searchStart = reference.lastIndex(of: "/").map { reference.index(after: $0) } ?? reference.startIndex
        guard let colon = reference[searchStart...].lastIndex(of: ":") else {
            return (reference, "latest")
        }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    private static func repository(_ image: ContainerImage) -> String { split(image.reference).repository }
    private static func tag(_ image: ContainerImage) -> String { split(image.reference).tag }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Wraps a reference so `.sheet(item:)` has something `Identifiable` to key on — a bare
/// `String` is not, and keying on the value itself would re-present the sheet if the same
/// image were chosen twice in a row.
private struct RunTarget: Identifiable {
    let reference: String
    var id: String { reference }
    init(_ reference: String) { self.reference = reference }
}
