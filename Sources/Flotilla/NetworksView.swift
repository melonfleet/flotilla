import SwiftUI
import Foundation
import FlotillaCore

/// The networks section: list, create, delete — same shape as `VolumesView`.
struct NetworksView: View {
    let model: AppModel

    @State private var showingCreate = false
    @State private var newNetworkName = ""
    @State private var newSubnet = ""
    @State private var newInternal = false
    @State private var pendingDelete: ContainerNetwork?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .labelStyle(.iconOnly)
            }
            .help("Create a network")
            .accessibilityLabel("New Network")
            Button {
                Task { await model.refreshNetworks() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh networks")
            .accessibilityLabel("Refresh")
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
                HStack(spacing: 6) {
                    Text(network.name)
                    // Apple's own `default` network carries a builtin role label. Worth
                    // marking: deleting it is not the same kind of act as deleting your own.
                    if network.isBuiltin {
                        Text("built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                // Subnet and gateway come from `status`, and are what actually answers "what
                // is this network for" — the old row could show none of it, because the model
                // did not match the CLI's real shape.
                HStack(spacing: 8) {
                    if let mode = network.mode {
                        Text(mode).font(.caption).foregroundStyle(.secondary)
                    }
                    if let subnet = network.subnet {
                        Text(subnet).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let gateway = network.gateway {
                        Text("gw \(gateway)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                requestDelete(network)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.busy.contains(network.id) || network.isBuiltin)
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

    /// The **only** moment a network's settings can be chosen.
    ///
    /// `container network` has create, delete, list, inspect and prune — no update, edit or
    /// set. A network is immutable once it exists, so a subnet not set here is assigned
    /// automatically and the only route to a different one is delete and recreate. That is
    /// why this sheet is worth more than a name field, and why the note says so on screen.
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Network").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $newNetworkName)
                    .textFieldStyle(.roundedBorder)
                if let problem = nameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Subnet — optional, e.g. 10.10.0.0/24", text: $newSubnet)
                    .textFieldStyle(.roundedBorder)
                if let problem = subnetProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Leave empty to have one assigned. This cannot be changed later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle("Host-only (no external access)", isOn: $newInternal)
                .toggleStyle(.checkbox)

            // Same idea as the run sheet: show the command, validated, before it runs.
            Text((["container"] + ContainerCLI.createNetworkArguments(
                    trimmedName, subnet: trimmedSubnet, isInternal: newInternal))
                    .joined(separator: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { showingCreate = false }
                Button("Create") {
                    let name = trimmedName
                    let subnet = trimmedSubnet
                    let hostOnly = newInternal
                    showingCreate = false
                    Task { await model.createNetwork(name, subnet: subnet, isInternal: hostOnly) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || nameProblem != nil || subnetProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var trimmedName: String {
        newNetworkName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedSubnet: String? {
        let value = newSubnet.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Validated **here**, against the same `Allowlist` the execution path uses, so an invalid
    /// name is refused with the reason while it is still being typed. Previously the only
    /// feedback was an "Action failed" alert after the fact, whose message named the verdict
    /// and not the rule — "'Test 1' is not a valid identifier" led to the wrong conclusion
    /// that capitals were the problem. They are not; the space was.
    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }   // don't scold an empty field
        return problem(in: ContainerCLI.createNetworkArguments(trimmedName))
    }

    private var subnetProblem: String? {
        guard let subnet = trimmedSubnet else { return nil }
        // Validate the subnet alone, with a name known to be fine, so the message can only be
        // about the subnet.
        return problem(in: ContainerCLI.createNetworkArguments("placeholder", subnet: subnet))
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
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
