import SwiftUI
import Foundation
import FlotillaCore

/// The images section: list, pull, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct ImagesView: View {
    let model: AppModel

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
        SectionToolbar(search: $search,
                       searchPrompt: "Search images…",
                       updated: model.imagesLastRefresh) {
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
            List(displayedImages) { image in
                row(for: image)
            }
        }
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
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return visible }
        return visible.filter { $0.reference.lowercased().contains(query) }
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
            Button {
                tagTarget = ""
                taggingImage = image
            } label: {
                Image(systemName: "tag")
            }
            .accessibilityLabel("Tag \(Self.repository(image))")
            .disabled(model.busy.contains(image.id))
            Button(role: .destructive) {
                requestDelete(image)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete \(Self.repository(image))")
            .disabled(model.busy.contains(image.id))
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
