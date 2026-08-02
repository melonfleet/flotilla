import SwiftUI
import Foundation
import FlotillaCore

/// The volumes section: list, create, delete — the same loading/unavailable/empty/loaded
/// shape as every other screen, and every action routes through `AppModel`, never
/// `ContainerCLI` or an argv directly.
struct VolumesView: View {
    let model: AppModel

    @State private var search = ""
    @State private var showingCreate = false
    @State private var newVolumeName = ""
    @State private var newSize = ""
    @State private var newLabels: [String] = []
    @State private var newDriverOptions: [String] = []
    @State private var pendingDelete: ContainerVolume?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        SectionToolbar(search: $search,
                       searchPrompt: "Search volumes…",
                       updated: model.volumesLastRefresh) {
            ToolbarIconButton(systemImage: "plus", label: "Create a volume…") {
                newVolumeName = ""
                showingCreate = true
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh volumes") {
                Task { await model.refreshVolumes() }
            }
        }
    }

    /// Free-text filter over the volume name.
    private var displayedVolumes: [ContainerVolume] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.volumes }
        return model.volumes.filter { ($0.name ?? "").lowercased().contains(query) }
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
            List(displayedVolumes) { volume in
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
                        // Age, not a raw ISO timestamp — see `RelativeDate`. The exact value
                        // is one hover away.
                        Text(RelativeDate.relative(createdAt, prefix: "Created"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(RelativeDate.absolute(createdAt))
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
        // On the whole row (and after `.padding`, so the hit area covers the padding too),
        // not on the label — a menu you can only summon by right-clicking exactly the text
        // reads as no menu at all. Shape per `ContextMenus.swift`: actions, Copy, destructive
        // last.
        .contextMenu { menu(for: volume) }
    }

    @ViewBuilder
    private func menu(for volume: ContainerVolume) -> some View {
        CopyMenu([
            ("Name", volume.name),
            ("Source Path", volume.source),
            ("Format", volume.format),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(volume) }
            .disabled(model.busy.contains(volume.id))
    }

    private var createSheet: some View {
        ModalCard(title: "New Volume", onClose: { showingCreate = false }) {
            createForm.padding(20)
        }
        .frame(width: 440)
        .onAppear { model.formDidOpen() }
        .onDisappear { model.formDidClose() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-data", text: $newVolumeName)
                    .textFieldStyle(.roundedBorder)
                if let problem = nameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                TextField("64M, 2G, …", text: $newSize)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                if let problem = sizeProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    // Worth stating: the default is enormous and sparse, which is why the
                    // Size column in the list looks alarming until you set one yourself.
                    Text("Optional. Left empty the driver provisions 512 GiB as a sparse image — it does not consume that, but it is what the size column reports.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 10) {
                    keyValueList($newLabels, title: "Labels", placeholder: "team=infra")
                    keyValueList($newDriverOptions, title: "Driver options", placeholder: "type=fast")
                }
                .padding(.top, 8)
            }

            Divider()

            Text((["container"] + ContainerCLI.createVolumeArguments(trimmedName, options: options))
                    .joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Create") {
                    let name = trimmedName
                    let opts = options
                    showingCreate = false
                    Task { await model.createVolume(name, options: opts) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || anyProblem != nil)
            }
        }
    }

    /// Repeatable `key=value` flags, capped at the `Allowlist`'s own maximum of 8 — shown
    /// rather than silently enforced.
    @ViewBuilder
    private func keyValueList(_ list: Binding<[String]>, title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(list.wrappedValue.count)/8").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { list.wrappedValue.indices.contains(index) ? list.wrappedValue[index] : "" },
                        set: { if list.wrappedValue.indices.contains(index) { list.wrappedValue[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { list.wrappedValue.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove")
                }
            }
            Button { list.wrappedValue.append("") } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(list.wrappedValue.count >= 8)
        }
    }

    private var options: ContainerCLI.VolumeOptions {
        ContainerCLI.VolumeOptions(
            size: newSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : newSize.trimmingCharacters(in: .whitespacesAndNewlines),
            labels: newLabels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            driverOptions: newDriverOptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    private var sizeProblem: String? {
        let value = newSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments("placeholder", options: .init(size: value)))
    }

    /// One pass over the whole command, so Create is disabled for any bad field — labels and
    /// driver options included, not just the two with their own messages.
    private var anyProblem: String? {
        problem(in: ContainerCLI.createVolumeArguments(
            trimmedName.isEmpty ? "placeholder" : trimmedName, options: options))
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    private var trimmedName: String {
        newVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments(trimmedName))
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
