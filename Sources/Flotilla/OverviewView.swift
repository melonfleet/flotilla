import SwiftUI
import FlotillaCore

/// Overview — the fleet at a glance (the owner, 6 October). Numbers only: which hosts are
/// connected, what they hold in total, and what needs attention. Per-Mac charts and tables moved
/// to each host's landing page under Hosts.
///
/// Since Phase C the numbers are the fleet's: This Mac plus what each paired host last reported.
/// Groups, DNS domains, machines and clusters stay This Mac's until Phase D pushes them, and their
/// tiles say so once there is another Mac to confuse them with.
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
        // Paired hosts are asked alongside, not first: a host that is slow to answer must not hold
        // This Mac's numbers at zero.
        .task {
            async let hosts: Void = model.hostMode.refreshLiveStatus()
            await model.refreshImages()
            await model.refreshVolumes()
            await model.refreshNetworks()
            await model.refreshMachines()
            await model.refreshClusters()
            await model.refreshDNS()
            await hosts
        }
    }

    // MARK: Hosts

    /// One line per Mac: This Mac, then every paired host, each with its state.
    private struct HostLine: Identifiable {
        let id: String
        let name: String
        let state: String
        let color: Color
        let connected: Bool
    }

    private var hostLines: [HostLine] {
        var lines = [HostLine(id: "local", name: model.hostLabel,
                              state: model.runtimeUsable ? "connected" : "runtime unavailable",
                              color: model.runtimeUsable ? Theme.online : Theme.warning,
                              connected: model.runtimeUsable)]
        for peer in model.hostMode.trustedHosts {
            let status = model.hostMode.live[peer.fingerprint]
            let (state, color, connected): (String, Color, Bool) = switch status?.state {
            case .connected?: ("connected", Theme.online, true)
            case .failed?: ("not answering", Theme.warning, false)
            case .checking?, nil: ("checking…", Color.secondary, false)
            }
            lines.append(HostLine(id: peer.fingerprint.hex, name: peer.displayName,
                                  state: state, color: color, connected: connected))
        }
        return lines
    }

    private var hosts: some View {
        let lines = hostLines
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hosts").font(.headline)
                Spacer()
                Text("\(lines.filter(\.connected).count) of \(lines.count) connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { go(.hosts) } label: {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider().padding(.leading, 31) }
                        HStack(spacing: 10) {
                            Circle().fill(line.color).frame(width: 9, height: 9)
                            Text(line.name).font(.body.weight(.medium))
                            Text(line.state).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if index == 0 {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .contentShape(Rectangle())
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help("Open Hosts")
        }
    }

    // MARK: Totals

    private var totals: some View {
        let fleet = model.hostMode
        // This Mac's lists plus each paired host's last answer — the same rows the sections list.
        let containers = model.containers + fleet.fleetContainers.flatMap(\.snapshot.items)
        let running = containers.filter(AppModel.isRunning).count
        let images = model.images.count + fleet.fleetImages.reduce(0) { $0 + $1.snapshot.items.count }
        let volumes = model.volumes.count + fleet.fleetVolumes.reduce(0) { $0 + $1.snapshot.items.count }
        let networks = model.networks.count + fleet.fleetNetworks.reduce(0) { $0 + $1.snapshot.items.count }
        let machinesRunning = model.machines.filter { MachinesView.isRunning($0) }.count
        // "on 3 Macs" where the number spans the fleet; "on This Mac" where it does not yet.
        let macs = 1 + fleet.trustedHosts.count
        let across = macs > 1 ? " · \(macs) Macs" : ""
        let thisMacOnly = macs > 1 ? "on This Mac" : ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("Across all hosts").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                tile("Containers", "\(running)", detail: "running of \(containers.count)" + across, .containers)
                tile("Groups", "\(model.groups.book.groups.count)",
                     detail: macs > 1 ? "saved on This Mac" : "saved", .containers)
                tile("Images", "\(images)", detail: "stored" + across, .images)
                tile("Volumes", "\(volumes)", detail: String(across.dropFirst(3)), .volumes)
                tile("Networks", "\(networks)", detail: String(across.dropFirst(3)), .networks)
                tile("DNS domains", "\(model.dnsDomains.count)", detail: thisMacOnly, .dns)
                tile("Machines", "\(machinesRunning)",
                     detail: "running of \(model.machines.count)" + (macs > 1 ? " on This Mac" : ""), .machines)
                tile("Clusters", "\(Set(model.clusters.map(\.name)).count)", detail: thisMacOnly, .clusters)
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
        let fleet = model.hostMode
        // A paired host that has stopped answering, or is waiting to be let in.
        for peer in fleet.trustedHosts {
            if case .failed(let reason)? = fleet.live[peer.fingerprint]?.state {
                items.append(("\(peer.displayName) isn\u{2019}t answering: \(reason)", .hosts))
            }
        }
        let waiting = fleet.hosts.filter { $0.status == .pending }.count
        if waiting > 0 {
            items.append(("\(waiting) Mac\(waiting == 1 ? " is" : "s are") waiting for your approval.", .hosts))
        }
        let flagged = (model.containers + fleet.fleetContainers.flatMap(\.snapshot.items)).filter(\.needsAttention)
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
