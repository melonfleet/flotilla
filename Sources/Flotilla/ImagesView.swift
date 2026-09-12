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

    /// The merged New Image form, and which half it opened on — `nil` when it is closed.
    /// One screen where there were two: see `NewImageView`.
    @State private var newImageMode: NewImageView.Mode?
    @State private var pendingDelete: ContainerImage?
    /// Set from the row menu's Run — presents the run sheet with this reference already in
    /// place. Nothing is launched from here; the sheet's validated preview still gates it.
    @State private var runImage: String?

    /// Which image the detail screen is showing, and optionally which tab to open it on.
    private struct DetailTarget: Identifiable, Hashable {
        let id: String
        var tab: ImageDetailTab?
    }

    /// The image whose detail screen is showing, or nil for the list. Keyed on the **reference**,
    /// which is how this section identifies an image everywhere else — `ContainerImage.id` is the
    /// digest.
    @State private var detailTarget: DetailTarget?

    @State private var taggingImage: ContainerImage?
    @State private var tagTarget = ""
    @State private var tagError: String?

    @State private var showingPrune = false
    @State private var pruning = false
    @State private var pruneError: String?
    @State private var confirmingBulkDelete = false

    var body: some View {
        Group {
            // Embedded form screens, in precedence order — see `FormHeader` for the 9 August
            // reversal. Prune and About stay modal: they are dialogs you acknowledge, not
            // forms you fill in and save.
            if let reference = runImage {
                RunSheetView(model: model, initialImage: reference) { runImage = nil }
            } else if let mode = newImageMode {
                NewImageView(model: model, initialMode: mode) { newImageMode = nil }
            } else if let image = taggingImage {
                tagScreen(for: image)
            } else if let target = detailTarget {
                detailScreen(target)
            } else {
                VStack(spacing: 0) {
                    toolbar
                    bulkActionBar
                    Divider()
                    // A pull outlives its form, so the list has to be able to say so. Without
                    // this, pressing Back during a 40-second pull looks exactly like the pull
                    // having been cancelled.
                    if let pull = model.activePull {
                        ImagePullStatus(pull: pull, compact: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    content
                }
                // Same band as Containers and Machines. See `ResourceUIState.activityExpanded`
                // for why it is collapsible: on this section it is usually empty.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ActivityStrip(title: "Recent activity",
                                  entries: activityEntries,
                                  isExpanded: Binding(get: { ui.activityExpanded },
                                                      set: { ui.activityExpanded = $0 }),
                                  // The detail screen, as in every other section. It used to
                                  // select the row, because images had nowhere to go — they do
                                  // now.
                                  //
                                  // Keyed on `reference`, **not** `id`: the feed records images
                                  // by `configuration.name` while `ContainerImage.id` is the
                                  // digest, so matching on `id` would never hit and every row
                                  // would read as dead.
                                  open: { detailTarget = DetailTarget(id: $0) },
                                  canOpen: { reference in
                                      model.images.contains { $0.reference == reference }
                                  })
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshImages() }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingPullForm) { _, requested in
            if requested { newImageMode = .pull; model.pendingPullForm = false }
        }
        .onAppear {
            if model.pendingPullForm { newImageMode = .pull; model.pendingPullForm = false }
        }
        // Menu-bar command. One-shot: consumed and cleared, so a rebuild does not reopen it.
        .onChange(of: model.pendingBuildForm) { _, requested in
            if requested { newImageMode = .build; model.pendingBuildForm = false }
        }
        .onAppear {
            if model.pendingBuildForm { newImageMode = .build; model.pendingBuildForm = false }
        }
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
        .confirmationDialog(
            "Delete \(actionable.count) image\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Image\(actionable.count == 1 ? "" : "s")",
                   role: .destructive) {
                Task { await model.deleteImages(actionable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search images…",
                       updated: model.imagesLastRefresh,
                       leading: {
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { selection.formUnion(visibleIDs) }
                                         else { selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(ui.presentation != .list || visibleIDs.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all images" : "Select all images")
                .help(allVisibleSelected ? "Deselect all" : "Select all \(visibleIDs.count)")

            ResourceListControls<ContainerImage>(
                presentation: Binding(get: { ui.presentation }, set: { ui.presentation = $0 }),
                filterID: Binding(get: { ui.filterID }, set: { ui.filterID = $0 }),
                columnCustomization: Binding(get: { ui.columnCustomization },
                                             set: { ui.columnCustomization = $0 }),
                columns: Self.columnSpecs,
                filters: platformFilters)
        }, trailing: {
            // One control for one intention. It was a hammer and a download arrow — two
            // buttons for "add an image", in a section where every other action is a single
            // control — and both forms were short enough to share one screen.
            ToolbarIconButton(systemImage: "plus", label: "New image — pull or build…") {
                newImageMode = .pull
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

    /// This section's slice of the one activity feed. Rows do not navigate — you are already
    /// on the section they belong to.
    private var activityEntries: [ActivityStrip.Entry] {
        model.events(ofKind: .image).map {
            ActivityStrip.Entry(id: $0.id, subject: $0.subject, event: $0)
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

        case .loaded where displayedImages.isEmpty:
            // Filtered-empty and genuinely-empty are different states, and this used to test
            // only the second (`model.images.isEmpty`) — so narrowing the filter to nothing
            // rendered an empty table with no message at all, and no way to see which control had
            // hidden the rows. UI-03/UI-04 in the 2026-08-20 audit, and the Containers screen had
            // already solved both; this is that pattern, not a new one.
            ContentUnavailableView {
                Label(isFiltered ? "No matches" : "No images",
                      systemImage: isFiltered ? "line.3.horizontal.decrease" : "square.stack.3d.up")
            } description: {
                Text(isFiltered
                     ? "No image matches the current filter."
                     : "Pull one to run a container from it.")
            } actions: {
                if isFiltered {
                    Button("Clear Filter") { ui.search = ""; ui.filterID = "all" }
                } else {
                    Button("Pull an Image…") { newImageMode = .pull }
                        .buttonStyle(.borderedProminent)
                }
            }

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
                    onOpen: { detailTarget = DetailTarget(id: image.reference) }
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
            TableColumn("") { image in
                selectionToggle(for: image.id)
            }
            .width(min: 28, ideal: 30, max: 34)

            TableColumn("Repository", value: \.reference) { image in
                // The way in, as in every other table. This was plain text, because until now
                // there was nowhere for it to go.
                Button(Self.repository(image)) {
                    detailTarget = DetailTarget(id: image.reference)
                }
                .buttonStyle(.link)
                .foregroundStyle(Theme.rowName(selected: selection.contains(image.id)))
                .lineLimit(1).truncationMode(.middle)
                .help(image.reference)
            }
            .width(min: 170, ideal: 260)

            TableColumn("Tag", value: \.tagSortKey) { image in
                Text(Self.tag(image)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 96)
            .customizationID("tag")

            TableColumn("Platform", value: \.platformSortKey) { image in
                Text(Self.platformLabel(image)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 84, ideal: 100)
            .customizationID("platform")

            TableColumn("Digest", value: \.digestSortKey) { image in
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

            TableColumn("Size", value: \.sizeSortKey) { image in
                Text(image.displaySize.map(Self.byteCount) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 74, ideal: 90)
            .customizationID("size")

            TableColumn("Created", value: \.creationSortKey) { image in
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
        } primaryAction: { ids in
            guard ids.count == 1,
                  let image = model.images.first(where: { ids.contains($0.id) }) else { return }
            detailTarget = DetailTarget(id: image.reference)
        }
    }

    /// Run, tag, overflow, then bin — the same order and the same divider before the
    /// destructive control as the containers and machines rows.
    @ViewBuilder
    private func rowActions(for image: ContainerImage) -> some View {
        let busy = model.isBusy(image.id, kind: .image)
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
    /// `internal`, not `fileprivate`: these four derivations of a reference are what the detail
    /// screen needs too, and a second copy of "split the repository off the tag" is how the sort
    /// key and the column once disagreed about what a tag is.
    nonisolated static func platformLabel(_ image: ContainerImage) -> String {
        let platforms = image.variants?.compactMap(\.platform) ?? []
        guard !platforms.isEmpty else { return "—" }
        let native = platforms.first { $0.architecture?.contains("arm64") == true } ?? platforms[0]
        let label = [native.os, native.architecture].compactMap { $0 }.joined(separator: "/")
        return platforms.count > 1 ? "\(label) +\(platforms.count - 1)" : label
    }

    nonisolated static func shortDigest(_ image: ContainerImage) -> String {
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
    /// Whether anything is currently narrowing the list. Drives the empty state's wording and
    /// its action: "no matches, clear the filter" and "none exist, make one" are different
    /// situations and only one of them is the user's mistake.
    private var isFiltered: Bool { !ui.search.trimmingCharacters(in: .whitespaces).isEmpty || ui.filterID != "all" }

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

    private var visibleIDs: Set<ContainerImage.ID> { Set(displayedImages.map(\.id)) }

    /// Image ids remain selected when a platform or search filter hides their rows, so the batch
    /// target is always the visible intersection rather than the retained selection itself.
    private var actionable: Set<ContainerImage.ID> { selection.intersection(visibleIDs) }

    private func selectionToggle(for id: ContainerImage.ID) -> some View {
        let isOn = Binding<Bool>(
            get: { selection.contains(id) },
            set: { on in
                if on { selection.insert(id) } else { selection.remove(id) }
            })
        return Toggle("", isOn: isOn)
            .labelsHidden()
            .accessibilityLabel("Select \(id)")
            .help("Select \(id)")
    }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selection)
    }

    private var selectionBusy: Bool { model.isAnyBusy(actionable, kind: .image) }

    @ViewBuilder
    private var bulkActionBar: some View {
        // Tag, Run and Prune have deliberately different scopes; multi-selection adds only the
        // row's existing delete action.
        if actionable.count > 1 {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                IconActionButton(systemImage: "trash",
                                 label: "Delete \(actionable.count) images",
                                 help: "Delete \(actionable.count) images",
                                 busy: selectionBusy, destructive: true) {
                    confirmingBulkDelete = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
    }

    private var trimmedTag: String {
        tagTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An image reference has its own shape, and its own rule text — so "not a valid
    /// imageReference" now comes with "expected something like docker.io/library/alpine:latest".
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
                             busy: model.isBusy(image.id, kind: .image)) {
                tagTarget = ""
                taggingImage = image
            }
            IconActionButton(systemImage: "trash",
                             label: "Delete \(Self.repository(image))",
                             help: "Delete \(Self.repository(image))",
                             busy: model.isBusy(image.id, kind: .image),
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
        let busy = model.isBusy(image.id, kind: .image)

        // Guarded item by item rather than by disabling the whole menu from the row, so the
        // `⋯` button and a right-click render **identically**. The row used to wrap this in
        // `.disabled(busy)`, which greyed out the reads — Inspect, Copy — on the one surface and
        // left them live on the other.
        Button("Details…") { detailTarget = DetailTarget(id: image.reference) }
        Button("Inspect") { detailTarget = DetailTarget(id: image.reference, tab: .inspect) }
        Divider()
        Button("Run…") { runImage = image.reference }
            .disabled(busy)
        Divider()
        Button("Tag…") {
            tagTarget = ""
            taggingImage = image
        }
        .disabled(busy)
        CopyMenu([
            ("Reference", image.reference),
            ("Repository", Self.repository(image)),
            ("Tag", Self.tag(image)),
            ("Digest", image.configuration.descriptor?.digest),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(image) }
            .disabled(busy)
    }

    // MARK: Detail

    @ViewBuilder
    private func detailScreen(_ target: DetailTarget) -> some View {
        VStack(spacing: 0) {
            if let image = model.images.first(where: { $0.reference == target.id }) {
                detailHeader(for: image)
                Divider()
                ImageDetailView(model: model, image: image, requestedTab: target.tab)
                    .id(image.reference)
            } else {
                detailHeader(for: nil)
                Divider()
                ContentUnavailableView(
                    "Image unavailable",
                    systemImage: "questionmark.square.dashed",
                    description: Text("\u{201C}\(target.id)\u{201D} is no longer on this Mac. It may have been deleted.")
                )
            }
        }
    }

    @ViewBuilder
    private func detailHeader(for image: ContainerImage?) -> some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back to Images",
                             help: "Back to Images") { detailTarget = nil }

            if let image {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Self.repository(image)).font(.headline)
                        Text(Self.tag(image)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(subtitle(for: image))
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text("Image unavailable").font(.headline)
            }

            Spacer()
            stepper
            if let image {
                ActionCluster { rowActions(for: image) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stepper: some View {
        let order = displayedImages
        let index = order.firstIndex { $0.reference == detailTarget?.id }
        HStack(spacing: 2) {
            Button {
                if let index, index > 0 {
                    detailTarget = DetailTarget(id: order[index - 1].reference)
                }
            } label: { Image(systemName: "chevron.up") }
                .disabled(index == nil || index == 0)
                .help("Previous image")
                .accessibilityLabel("Previous image")

            Button {
                if let index, index < order.count - 1 {
                    detailTarget = DetailTarget(id: order[index + 1].reference)
                }
            } label: { Image(systemName: "chevron.down") }
                .disabled(index == nil || index == order.count - 1)
                .help("Next image")
                .accessibilityLabel("Next image")

            if let index {
                Text("\(index + 1) of \(order.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private func subtitle(for image: ContainerImage) -> String {
        var parts = [Self.platformLabel(image)]
        if let size = image.displaySize { parts.append(Self.byteCount(size)) }
        parts.append(Self.shortDigest(image))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Tag Image, built to the same shape as every other form in the app.
    ///
    /// It was the last one that was not. This screen had no information rail, a hard
    /// `.frame(width: 440)` and a `Save` button inline in the body — so it sat as a narrow
    /// centred column while Run, New Machine, New Volume, New Network and New Image are all
    /// left-aligned against a rail with the action in a footer. That is exactly the complaint
    /// the owner made about the pull form: *"it doesn't look like any of the other forms… it
    /// needs to be to the left aligned and also has the information rail to the right."* Pull
    /// was fixed and this one was never looked at, because nothing pointed at it.
    private func tagScreen(for image: ContainerImage) -> some View {
        VStack(spacing: 0) {
            FormHeader(title: "Tag Image", systemImage: "tag",
                       hasUnsavedChanges: !trimmedTag.isEmpty,
                       onBack: { taggingImage = nil })
            Divider()
            FormScaffold {
                tagForm(for: image)
            } preview: {
                tagRail(for: image)
            }
            Divider()
            tagFooter(for: image)
        }
    }

    private func tagForm(for image: ContainerImage) -> some View {
        FormField("New reference",
                  help: FieldHelp(
                      "The name the image gains. Tagging adds a name; it does not "
                          + "rename or copy anything.",
                      detail: "A reference is `registry/namespace/name:tag`. Leave the registry "
                          + "off and the runtime assumes Docker Hub, so `myapp:v2` and "
                          + "`docker.io/library/myapp:v2` are the same image.",
                      example: "ghcr.io/acme/web:v2",
                      warning: "Reusing a tag that already exists moves it to this image. The "
                          + "old image stays on disk but loses that name."),
                  problem: tagProblem) {
            TextField("myregistry/name:tag", text: $tagTarget)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// The command the button will run, beside the field — the same rail every other form
    /// carries, and the reason it is an answer rather than another field to find at the end.
    private func tagRail(for image: ContainerImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text("container image tag \(image.reference) "
                 + (trimmedTag.isEmpty ? "<new reference>" : trimmedTag))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(trimmedTag.isEmpty ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tagFooter(for image: ContainerImage) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { taggingImage = nil }
            Button("Tag") {
                let target = trimmedTag
                let source = image.reference
                taggingImage = nil
                guard !target.isEmpty else { return }
                Task {
                    do {
                        try await model.tagImage(source, as: target)
                        await model.refreshImages()
                    } catch {
                        tagError = "Tag failed for \(source) \u{2192} \(target): \(error)"
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedTag.isEmpty || tagProblem != nil)
        }
        .padding(12)
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

    /// Defers to `model.deletePolicy`, the one authority. This used to read the setting key
    /// directly, which is how three screens ended up with three copies of the rule and two more
    /// screens with none.
    private func requestDelete(_ image: ContainerImage) {
        if model.deletePolicy.requiresConfirmation(.single) {
            pendingDelete = image
        } else {
            Task { await model.removeImage(image) }
        }
    }

    /// `ContainerImage` has no separate repository/tag fields — `reference` is one string
    /// like `docker.io/library/nginx:latest`. Split it here for display only; the last
    /// `:` after the last `/` is the tag (so a registry port, e.g. `host:5000/name`,
    /// isn't mistaken for one).
    fileprivate nonisolated static func split(_ reference: String) -> (repository: String, tag: String) {
        let searchStart = reference.lastIndex(of: "/").map { reference.index(after: $0) } ?? reference.startIndex
        guard let colon = reference[searchStart...].lastIndex(of: ":") else {
            return (reference, "latest")
        }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    nonisolated static func repository(_ image: ContainerImage) -> String { split(image.reference).repository }
    nonisolated static func tag(_ image: ContainerImage) -> String { split(image.reference).tag }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension ContainerImage {
    /// Reuses `ImagesView.tag`'s own split so the sort agrees with what the Tag column
    /// actually displays, rather than re-deriving the rule and risking drift.
    var tagSortKey: String { ImagesView.tag(self) }

    /// Reuses `ImagesView.platformLabel` for the same reason — the displayed label already
    /// prefers the host architecture and marks multi-arch images, and the sort should match.
    var platformSortKey: String { ImagesView.platformLabel(self) }

    /// The full digest, not the shortened display form — sorting on 12 truncated hex
    /// characters would collide constantly. Missing digests sort first as `""`.
    var digestSortKey: String { configuration.descriptor?.digest ?? "" }

    /// **Unknown is not zero.** An image with no reported size is not a zero-byte image —
    /// coalescing to 0 would file it among genuinely tiny images, which is a different,
    /// misleading claim. `-1` sorts clear of every real size (sizes are never negative)
    /// without pretending to know the answer.
    var sizeSortKey: Int64 { displaySize ?? -1 }

    /// Sortable form of `creationDate`, which the CLI gives as an ISO-8601 *string* that
    /// happens to sort correctly lexicographically. Same rule `Container.creationSortKey`
    /// uses: an absent date sorts last rather than first.
    var creationSortKey: String { configuration.creationDate ?? "9999" }
}

/// Wraps a reference so `.sheet(item:)` has something `Identifiable` to key on — a bare
/// `String` is not, and keying on the value itself would re-present the sheet if the same
/// image were chosen twice in a row.
private struct RunTarget: Identifiable {
    let reference: String
    var id: String { reference }
    init(_ reference: String) { self.reference = reference }
}
