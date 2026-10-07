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

    /// One row per Mac: This Mac, then every paired host — a table, so thirty minis read as well as
    /// three (the owner, 8 October). The name opens that Mac's page under Hosts.
    struct HostLine: Identifiable {
        /// `HostRow`'s id: This Mac's fixed one, or a host's fingerprint.
        let id: String
        let name: String
        let state: String
        let color: Color
        let connected: Bool
        let facts: HostFacts?
        let model: String?
        let macOS: String?
    }

    private var hostLines: [HostLine] {
        let local = model.localHostFacts()
        var lines = [HostLine(id: HostRow.thisMacID, name: model.hostLabel,
                              state: model.runtimeUsable ? "connected" : "runtime unavailable",
                              color: model.runtimeUsable ? Theme.online : Theme.warning,
                              connected: model.runtimeUsable, facts: local,
                              model: local.model, macOS: local.macOSVersion)]
        for peer in model.hostMode.trustedHosts {
            let status = model.hostMode.live[peer.fingerprint]
            let (state, color, connected): (String, Color, Bool) = switch status?.state {
            case .connected?: ("connected", Theme.online, true)
            case .failed?: ("not answering", Theme.warning, false)
            case .checking?, nil: ("checking…", Color.secondary, false)
            }
            let facts = model.hostMode.facts[peer.fingerprint]
            lines.append(HostLine(id: peer.fingerprint.hex, name: peer.displayName,
                                  state: state, color: color, connected: connected, facts: facts,
                                  model: facts?.model ?? peer.details.model,
                                  macOS: facts?.macOSVersion ?? peer.details.macOSVersion))
        }
        return lines
    }

    private var hosts: some View {
        let lines = hostLines
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hosts").font(.headline)
                Spacer()
                Text("\(lines.filter(\.connected).count) of \(lines.count) connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            hostTable(lines)
                // As Utilisation's card: the table draws its own header and insets.
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    /// Up to ten rows, then it scrolls — the same height whatever the fleet, past ten.
    private func hostTable(_ lines: [HostLine]) -> some View {
        SwiftUI.Table(lines) {
            TableColumn("Host") { line in
                HStack(spacing: 7) {
                    Circle().fill(line.color).frame(width: 8, height: 8)
                        .help(line.state)
                    Button(line.name) { model.requestDetail(kind: .host, subject: line.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.link)
                        .lineLimit(1)
                        .help("Open \(line.name)")
                }
            }
            .width(min: 140, ideal: 190)
            TableColumn("Model") { line in
                Text(line.model ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("CPU") { line in
                Text(Self.chip(line.facts)).lineLimit(1)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Memory") { line in
                Text(Self.memory(line.facts)).monospacedDigit().lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Disk") { line in
                Text(Self.disk(line.facts)).monospacedDigit().lineLimit(1)
                    .help("The startup disk's capacity")
            }
            .width(min: 110, ideal: 150)
            TableColumn("macOS") { line in
                Text(line.macOS ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        // 24 a row plus the header and its rule, measured off the rendered table.
        .frame(height: CGFloat(min(max(lines.count, 1), 10)) * 24 + 40)
        // Only a fleet past ten rows scrolls; below that a scroller is a promise of rows not there.
        .scrollIndicators(lines.count > 10 ? .automatic : .never)
    }

    /// `Apple M1 · 8 cores`.
    static func chip(_ facts: HostFacts?) -> String {
        guard let facts else { return "—" }
        let cores = facts.cores.map { "\($0) cores" }
        let text = [facts.chip, cores].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "—" : text
    }

    /// What the Mac has installed — `64 GB`, `8 GB` — and nothing about how much is in use: this is
    /// an overview (the owner, 8 October). Binary units, as Apple counts RAM.
    static func memory(_ facts: HostFacts?) -> String {
        guard let total = facts?.memoryTotalBytes, total > 0 else { return "—" }
        return "\(Int((Double(total) / Double(1 << 30)).rounded())) GB"
    }

    /// The startup disk's size — `995 GB`, `2 TB` — without free space, for the same reason.
    /// Decimal units, as Finder counts disks.
    static func disk(_ facts: HostFacts?) -> String {
        guard let total = facts?.diskTotalBytes, total > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: total)
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
        // Versions that differ from This Mac's: `container` by a minor release or more, which can
        // change what a command accepts, and Flotilla by any build (PLAN.md Phase C).
        for peer in fleet.trustedHosts {
            let host = HostRef.peer(peer.fingerprint)
            if let warning = model.containerSkewWarning(host) { items.append((warning, .hosts)) }
            if let skew = model.appSkew(host), skew.level != .same,
               let theirs = fleet.live[peer.fingerprint]?.appVersion {
                items.append(("\(peer.displayName) runs \(skew.otherIsOlder ? "an older" : "a newer") Flotilla "
                              + "(\(theirs); This Mac \(HostModeController.appVersion)).", .hosts))
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
