import SwiftUI
import Foundation
import FlotillaCore

/// The images section: list, pull, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct ImagesView: View {
    let model: AppModel

    @State private var showingPull = false
    @State private var pullReference = ""
    @State private var pendingDelete: ContainerImage?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await model.refreshImages() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: $showingPull) { pullSheet }
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
        HStack(spacing: 12) {
            Text("Images").font(.title3.bold())
            Spacer()
            Button {
                pullReference = ""
                showingPull = true
            } label: {
                Label("Pull Image…", systemImage: "arrow.down.circle")
            }
            Button {
                Task { await model.refreshImages() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
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
            List(model.images) { image in
                row(for: image)
            }
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
            Button(role: .destructive) {
                requestDelete(image)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.busy.contains(image.id))
        }
        .padding(.vertical, 4)
    }

    private var pullSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pull Image").font(.headline)
            TextField("Image reference, e.g. docker.io/library/nginx:latest", text: $pullReference)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingPull = false }
                Button("Pull") {
                    let reference = pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingPull = false
                    guard !reference.isEmpty else { return }
                    Task { await model.pullImage(reference) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pullReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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
