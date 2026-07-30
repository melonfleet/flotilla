import SwiftUI
import Foundation
import FlotillaCore

/// The networks section: list, create, delete — same shape as `VolumesView`.
struct NetworksView: View {
    let model: AppModel

    @State private var showingCreate = false
    @State private var newNetworkName = ""
    @State private var pendingDelete: ContainerNetwork?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task { await model.refreshNetworks() }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: $showingCreate) { createSheet }
        .confirmationDialog(
            "Delete network “\(pendingDelete?.id ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let network = pendingDelete {
                    Task { await model.removeNetwork(network) }
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
            Text("Networks").font(.title3.bold())
            Spacer()
            Button {
                newNetworkName = ""
                showingCreate = true
            } label: {
                Label("New Network…", systemImage: "plus")
            }
            Button {
                Task { await model.refreshNetworks() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.networksState {
        case .idle, .loading:
            ProgressView("Loading networks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Same rule as containers and volumes: a failed load must never render as an
            // empty list — that would look like a healthy, network-less fleet.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .loaded where model.networks.isEmpty:
            ContentUnavailableView(
                "No networks",
                systemImage: "network",
                description: Text("Create one to give containers an isolated network.")
            )

        case .loaded:
            List(model.networks) { network in
                row(for: network)
            }
        }
    }

    private func row(for network: ContainerNetwork) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.id)
                HStack(spacing: 8) {
                    if let mode = network.mode {
                        Text(mode).font(.caption).foregroundStyle(.secondary)
                    }
                    if let subnet = network.subnet {
                        Text(subnet).font(.caption).foregroundStyle(.secondary)
                    }
                    if let state = network.state {
                        Text(state).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                requestDelete(network)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.busy.contains(network.id))
        }
        .padding(.vertical, 4)
        .contextMenu { menu(for: network) }
    }

    @ViewBuilder
    private func menu(for network: ContainerNetwork) -> some View {
        CopyMenu([
            ("Name", network.id),
            ("Subnet", network.subnet),
            ("Gateway", network.gateway),
        ])
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(network) }
            .disabled(model.busy.contains(network.id))
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Network").font(.headline)
            TextField("Network name", text: $newNetworkName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingCreate = false }
                Button("Create") {
                    let name = newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingCreate = false
                    guard !name.isEmpty else { return }
                    Task { await model.createNetwork(name) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// Honours `confirmDestructiveActions` — the whole point of that registry key.
    private func requestDelete(_ network: ContainerNetwork) {
        if model.settingsStore[SettingsKeys.confirmDestructiveActions] {
            pendingDelete = network
        } else {
            Task { await model.removeNetwork(network) }
        }
    }
}
