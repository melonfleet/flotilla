import SwiftUI
import FlotillaCore

/// Overview — the fleet at a glance (the owner, 6 October). Numbers only: which hosts are
/// connected, what they hold in total, and what needs attention. Per-Mac charts and tables moved
/// to each host's landing page under Hosts.
///
/// Today the fleet is one host, This Mac; the shape is the fleet's so host mode only fills it in.
struct OverviewView: View {
    let model: AppModel
    let go: (Section) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hosts
                totals
                attention
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The totals read lists the poll refreshes only every sixth tick or on a section's visit,
        // so Overview loads them itself rather than showing zeros on a fresh launch.
        .task {
            await model.refreshImages()
            await model.refreshVolumes()
            await model.refreshNetworks()
            await model.refreshMachines()
            await model.refreshClusters()
            await model.refreshDNS()
        }
    }

    // MARK: Hosts

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hosts").font(.headline)
            Button { go(.hosts) } label: {
                HStack(spacing: 10) {
                    Circle().fill(model.runtimeUsable ? Theme.online : Theme.warning)
                        .frame(width: 9, height: 9)
                    Text(model.hostLabel).font(.body.weight(.medium))
                    Text(model.runtimeUsable ? "connected" : "runtime unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("1 of 1 connected").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help("Open This Mac's page")
        }
    }

    // MARK: Totals

    private var totals: some View {
        let running = model.containers.filter(AppModel.isRunning).count
        let machinesRunning = model.machines.filter { MachinesView.isRunning($0) }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Across all hosts").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                tile("Containers", "\(running)", detail: "running of \(model.containers.count)", .containers)
                tile("Groups", "\(model.groups.book.groups.count)", detail: "saved", .containers)
                tile("Images", "\(model.images.count)", detail: "stored", .images)
                tile("Volumes", "\(model.volumes.count)", detail: "", .volumes)
                tile("Networks", "\(model.networks.count)", detail: "", .networks)
                tile("DNS domains", "\(model.dnsDomains.count)", detail: "", .dns)
                tile("Machines", "\(machinesRunning)", detail: "running of \(model.machines.count)", .machines)
                tile("Clusters", "\(Set(model.clusters.map(\.name)).count)", detail: "", .clusters)
            }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String, _ section: Section) -> some View {
        Button { go(section) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: section.systemImage)
                    .font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Open \(section.title)")
    }

    // MARK: Attention

    private var attentionItems: [(String, Section)] {
        var items: [(String, Section)] = []
        if !model.runtimeUsable { items.append(("The container runtime on \(model.hostLabel) isn't running.", .hosts)) }
        for network in model.disconnectedNetworks {
            items.append(("\(network) has lost its connection to \(model.hostLabel).", .networks))
        }
        let flagged = model.containers.filter(\.needsAttention)
        if !flagged.isEmpty {
            items.append(("\(flagged.count) container\(flagged.count == 1 ? " is" : "s are") in an unknown state.", .containers))
        }
        return items
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs attention").font(.headline)
            if attentionItems.isEmpty {
                Label("Nothing needs attention.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(attentionItems.enumerated()), id: \.offset) { _, item in
                    Button { go(item.1) } label: {
                        Label(item.0, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Hosts — every Mac Flotilla manages, each with its own landing page. Today that is This Mac,
/// whose page is the per-Mac dashboard that used to be the app's front page.
struct HostsView: View {
    let model: AppModel
    let go: (Section) -> Void
    @State private var openHost: String?

    var body: some View {
        if openHost != nil {
            VStack(spacing: 0) {
                FormHeader(title: model.hostLabel, systemImage: Section.hosts.systemImage,
                           hasUnsavedChanges: false, onBack: { openHost = nil })
                Divider()
                DashboardView(model: model, go: go)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ResourceCardGrid {
                ResourceCard(
                    title: model.hostLabel,
                    badge: "this Mac",
                    fields: [("Status", model.runtimeUsable ? "Connected" : "Runtime unavailable"),
                             ("Containers", "\(model.containers.filter(AppModel.isRunning).count) running of \(model.containers.count)"),
                             ("Machines", "\(model.machines.count)")],
                    showsTags: false,
                    onOpen: { openHost = model.hostLabel }
                ) {
                    Button("Open") { openHost = model.hostLabel }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
