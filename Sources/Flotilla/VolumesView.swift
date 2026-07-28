import SwiftUI
import Foundation
import FlotillaCore

/// The volumes section: list, create, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct VolumesView: View {
    let model: AppModel

    @State private var showingCreate = false
    @State private var newVolumeName = ""
    @State private var pendingDelete: ContainerVolume?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await model.refreshVolumes() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: $showingCreate) { createSheet }
        .confirmationDialog(
            "Delete volume “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let volume = pendingDelete {
                    Task { await model.removeVolume(volume) }
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
            Text("Volumes").font(.title3.bold())
            Spacer()
            Button {
                newVolumeName = ""
                showingCreate = true
            } label: {
                Label("New Volume…", systemImage: "plus")
            }
            Button {
                Task { await model.refreshVolumes() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.volumesState {
        case .idle, .loading:
            ProgressView("Loading volumes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as containers: a failed load must never render as an empty list.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .loaded where model.volumes.isEmpty:
            ContentUnavailableView(
                "No volumes",
                systemImage: "cylinder.split.1x2",
                description: Text("Create one to persist data across container runs.")
            )

        case .loaded:
            List(model.volumes) { volume in
                row(for: volume)
            }
        }
    }

    private func row(for volume: ContainerVolume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                HStack(spacing: 8) {
                    if let format = volume.format {
                        Text(format).font(.caption).foregroundStyle(.secondary)
                    }
                    if let size = volume.sizeInBytes {
                        Text(Self.byteCount(size)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let createdAt = volume.createdAt {
                        Text(createdAt).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                requestDelete(volume)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.busy.contains(volume.id))
        }
        .padding(.vertical, 4)
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Volume").font(.headline)
            TextField("Volume name", text: $newVolumeName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingCreate = false }
                Button("Create") {
                    let name = newVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingCreate = false
                    guard !name.isEmpty else { return }
                    Task { await model.createVolume(name) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newVolumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// Honours `confirmDestructiveActions` — the whole point of that registry key.
    private func requestDelete(_ volume: ContainerVolume) {
        if model.settingsStore[SettingsKeys.confirmDestructiveActions] {
            pendingDelete = volume
        } else {
            Task { await model.removeVolume(volume) }
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
