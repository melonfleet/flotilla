import SwiftUI
import FlotillaCore

// The Overview's widgets (DECISIONS Q67): what each one draws, at each size it offers. The grid,
// edit mode and persistence are `OverviewView` and `OverviewLayoutStore`; the rules are
// `OverviewLayout` in FlotillaCore.
//
// **Every widget reads what its section already reads.** No widget starts a poll or runs a command
// of its own: the lists come from `AppModel` and `HostModeController`, which the poll loop and
// Overview's own `.task` already keep fresh. A widget is a window onto its section, so clicking it
// opens that section, filtered where the widget showed a subset.

extension OverviewWidgetKind {
    /// The section's own glyph where there is one, so a widget and its sidebar row match.
    /// Every name verified with `NSImage(systemSymbolName:)`, per the `ellipsis.vertical` incident.
    var systemImage: String {
        switch self {
        case .fleet: "gauge.with.dots.needle.33percent"
        case .hosts: Section.hosts.systemImage
        case .containers: Section.containers.systemImage
        case .vulnerabilities: "exclamationmark.shield"
        case .activity: Section.activity.systemImage
        case .machines: Section.machines.systemImage
        case .kubernetes: Section.clusters.systemImage
        case .dns: Section.dns.systemImage
        case .storage: "internaldrive"
        case .tasks: "list.bullet.rectangle"
        case .images: Section.images.systemImage
        case .networks: Section.networks.systemImage
        case .suggestions: Section.suggestions.systemImage
        }
    }
}

/// Where a click on a widget goes. Most are a section; a few open it filtered to what the widget
/// counted, and Tasks has no section — it is the drawer.
enum OverviewLink: Equatable {
    case section(Section)
    case runningContainers
    case runningMachines
    case hostsNeedingAttention
    case tasks
}

// MARK: - The tile

/// One widget's card: header, then content clipped to the tile. The size comes from the grid; the
/// content is written for each size, so nothing here scrolls and nothing grows the page.
struct OverviewTile<Content: View, Controls: View>: View {
    let kind: OverviewWidgetKind
    /// The header's right-hand words — "12 of 21 running", "Today".
    var detail: String?
    /// What the header and a click on the card open; nil for a card that opens nothing.
    var open: (() -> Void)?
    var openHelp: String?
    let editing: Bool
    /// The size control, drawn in the header while editing.
    @ViewBuilder var controls: Controls
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // While arranging, a click is for the arranging; nothing inside fires.
                .allowsHitTesting(!editing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if !editing { open?() } }
    }

    @ViewBuilder
    private var header: some View {
        if editing {
            HStack(spacing: 8) {
                // The grip is in the tile's top-left corner, drawn by the grid (`WidgetGrip`).
                title
                Spacer(minLength: 4)
                controls
            }
        } else if let open {
            Button(action: open) {
                HStack(spacing: 8) {
                    title
                    Spacer(minLength: 4)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(openHelp ?? "Open \(kind.title)")
        } else {
            HStack(spacing: 8) { title; Spacer(minLength: 0) }
        }
    }

    private var title: some View {
        Label {
            Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        } icon: {
            Image(systemName: kind.systemImage).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared pieces

/// A big figure with an optional "of" and a caption under it — `12/21 running`.
struct WidgetFigure: View {
    let value: Int
    var of: Int?
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(value)").font(.system(size: 28, weight: .bold)).foregroundStyle(tint)
                if let of {
                    Text("/\(of)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar for a share of something — CPU, memory, disk. Teal, never the accent: the accent is
/// for controls, and this is data (`design/THEMES.md`).
struct WidgetMeter: View {
    /// 0…1, or nil for "not known", which draws an empty track.
    let fraction: Double?
    let label: String

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Theme.info)
                        .frame(width: proxy.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 5)
            .help(fraction.map { "\(label): \(Int(($0 * 100).rounded()))%" } ?? "\(label): not reported")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "not reported")
    }
}

/// A line in a widget's list: a dot, a name and a short trailing note. The app's row, compact —
/// no checkbox, no hover actions; the section beside it has those.
struct WidgetLine: Identifiable {
    let id: String
    let name: String
    var note: String = ""
    var dot: Color = Theme.online
    var dimmed = false
    var help: String?
    var open: (() -> Void)?
}

struct WidgetLines: View {
    let lines: [WidgetLine]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.element.id) { index, line in
                if index > 0 { Divider().opacity(0.6) }
                row(line)
            }
            if lines.count > limit {
                Text("\(lines.count - limit) more")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func row(_ line: WidgetLine) -> some View {
        let content = HStack(spacing: 8) {
            Circle().fill(line.dot).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(line.name)
                .font(.system(size: 13, weight: line.dimmed ? .regular : .medium))
                .foregroundStyle(line.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(line.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        if let open = line.open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .help(line.help ?? "Open \(line.name)")
        } else {
            content.help(line.help ?? line.name)
        }
    }
}

/// "Nothing yet" in a widget — one quiet line, not an empty card.
struct WidgetEmpty: View {
    let text: String
    var body: some View {
        // Wraps under a line limit, never `fixedSize(vertical:)` — that blanks the window (6 October).
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
    }
}

// MARK: - Content

/// What one widget draws, at its size. `go` is how a click leaves the Overview.
struct OverviewWidgetContent<Controls: View>: View {
    let model: AppModel
    let widget: OverviewWidget
    let editing: Bool
    let go: (OverviewLink) -> Void
    @ViewBuilder var controls: Controls

    private var size: OverviewWidgetSize { widget.size }
    /// How many list lines fit: two under a figure on a small card, more on a tall one.
    private var lineLimit: Int {
        switch size {
        case .small: 2
        case .wide: 3
        case .tall: 8
        case .large: 7
        }
    }

    var body: some View {
        switch widget.kind {
        case .fleet: fleet
        case .hosts: hosts
        case .containers: containers
        case .vulnerabilities: vulnerabilities
        case .activity: activity
        case .machines: machines
        case .kubernetes: kubernetes
        case .dns: dns
        case .storage: storage
        case .tasks: tasks
        case .images: images
        case .networks: networks
        case .suggestions: suggestions
        }
    }

    private func tile<Content: View>(detail: String? = nil, link: OverviewLink?, help: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        OverviewTile(kind: widget.kind, detail: detail, open: link.map { link in { go(link) } },
                     openHelp: help, editing: editing, controls: { controls }, content: content)
    }

    // MARK: Fleet at a glance

    /// This Mac and every paired host, as `Hosts` lists them — imported claims are not Macs yet.
    private var macRows: [HostRow] { model.hostRows.filter { $0.isThisMac || $0.peer != nil } }

    private func facts(_ row: HostRow) -> HostFacts? {
        if row.isThisMac { return model.localHostFacts() }
        return row.peer.flatMap { model.hostMode.facts[$0.fingerprint] }
    }

    private var fleetContainers: [Container] {
        model.containers + model.hostMode.fleetContainers.flatMap(\.snapshot.items)
    }
    private var fleetImages: [ContainerImage] {
        model.images + model.hostMode.fleetImages.flatMap(\.snapshot.items)
    }
    private var fleetClusters: [K8sNode] {
        model.clusters + model.hostMode.fleetClusters.flatMap(\.snapshot.items)
    }

    /// Replaces "Across all hosts" (Q67): the same totals, with the Macs and their load beside them.
    private var fleet: some View {
        let macs = macRows
        let connected = macs.filter(\.connected)
        let containers = fleetContainers
        let running = containers.filter(AppModel.isRunning).count
        let images = fleetImages
        let imageBytes = images.compactMap(\.displaySize).reduce(0, +)
        let machinesRunning = model.machines.filter { $0.state == .running }.count
        let clusterNames = Dictionary(grouping: fleetClusters, by: \.name)
        let ready = clusterNames.values.filter { $0.contains(where: \.isRunning) }.count
        let reports = connected.compactMap(facts)
        let cpu = Self.average(reports.compactMap(\.cpuPercent)).map { $0 / 100 }
        let memory = Self.share(reports.compactMap { f in f.memoryUsedBytes.flatMap { u in f.memoryTotalBytes.map { (u, $0) } } })
        let disk = Self.share(reports.compactMap { f in
            f.diskTotalBytes.flatMap { t in f.diskFreeBytes.map { (t - $0, t) } }
        })
        let onThisMac = macs.count > 1 ? " on This Mac" : ""
        return tile(detail: macs.count > 1 ? "\(macs.count) Macs" : "This Mac", link: .section(.hosts),
                    help: "Open Hosts") {
            switch size {
            case .small:
                WidgetFigure(value: connected.count, of: macs.count, caption: "Macs connected")
            default:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        WidgetFigure(value: connected.count, of: macs.count, caption: "Macs connected")
                        WidgetFigure(value: running, of: containers.count, caption: "containers running")
                        WidgetFigure(value: images.count,
                                     caption: imageBytes > 0 ? "images · \(Self.bytes(imageBytes))" : "images")
                        if size == .large {
                            WidgetFigure(value: model.machines.count, caption: "machines\(onThisMac) · \(machinesRunning) running")
                            WidgetFigure(value: clusterNames.count, caption: "clusters · \(ready) ready")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if size == .large {
                        HStack(alignment: .top, spacing: 12) {
                            WidgetFigure(value: model.volumes.count + model.hostMode.fleetVolumes.reduce(0) { $0 + $1.snapshot.items.count },
                                         caption: "volumes")
                            WidgetFigure(value: model.networks.count + model.hostMode.fleetNetworks.reduce(0) { $0 + $1.snapshot.items.count },
                                         caption: "networks")
                            WidgetFigure(value: model.dnsDomains.count, caption: "DNS domains\(onThisMac)")
                        }
                    }
                    meters(cpu: cpu, memory: memory, disk: disk, stacked: size == .large)
                }
            }
        }
    }

    @ViewBuilder
    private func meters(cpu: Double?, memory: Double?, disk: Double?, stacked: Bool) -> some View {
        let items: [(String, Double?)] = [("CPU", cpu), ("Memory", memory), ("Disk", disk)]
        if stacked {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.0) { item in
                    HStack(spacing: 8) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        WidgetMeter(fraction: item.1, label: "Fleet \(item.0.lowercased())")
                        Text(item.1.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                ForEach(items, id: \.0) { item in
                    Text(item.0).font(.caption).foregroundStyle(.secondary).fixedSize()
                    WidgetMeter(fraction: item.1, label: "Fleet \(item.0.lowercased())")
                }
            }
        }
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func share(_ pairs: [(Int64, Int64)]) -> Double? {
        let total = pairs.reduce(Int64(0)) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return Double(pairs.reduce(Int64(0)) { $0 + $1.0 }) / Double(total)
    }

    /// Decimal, as Finder counts disks and image sizes.
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: Hosts

    /// Replaces the striped Hosts table (Q67): the app's row — status dot, name, This Mac and Admin
    /// chips, model and macOS, a load bar, running count and version — and no columns or stripes.
    private var hosts: some View {
        let rows = macRows
        let connected = rows.filter(\.connected).count
        let attention = rows.contains { !$0.connected && !$0.isPending }
        let limit = size == .large ? 6 : 3
        return tile(detail: "\(connected) of \(rows.count) connected",
                    link: attention ? .hostsNeedingAttention : .section(.hosts),
                    help: attention ? "Open Hosts, showing the Macs that need attention" : "Open Hosts") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.6) }
                    OverviewHostRow(model: model, row: row, facts: facts(row), detailed: size == .large)
                }
                if rows.count > limit {
                    Text("\(rows.count - limit) more").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
        }
    }

    // MARK: Containers

    private var containers: some View {
        let local = model.containers.map { (container: $0, host: HostRef.local) }
        let remote = model.hostMode.fleetContainers.flatMap { entry in
            entry.snapshot.items.map { (container: $0, host: HostRef.peer(entry.host.fingerprint)) }
        }
        // Running first here, unlike the section's name order (Q2): a widget this size is for
        // "what's up", and the section is one click away for the rest.
        let all = (local + remote).sorted { a, b in
            let ra = AppModel.isRunning(a.container), rb = AppModel.isRunning(b.container)
            return ra != rb ? ra : a.container.name.localizedStandardCompare(b.container.name) == .orderedAscending
        }
        let running = all.filter { AppModel.isRunning($0.container) }.count
        let lines = all.map { item in
            let isRunning = AppModel.isRunning(item.container)
            return WidgetLine(id: item.host.rowID(item.container.name), name: item.container.name,
                              note: isRunning ? ContainerImage.shortReference(item.container.imageReference) : "stopped",
                              dot: isRunning ? Theme.online : Color.secondary.opacity(0.45), dimmed: !isRunning,
                              help: "Open \(item.container.name)") {
                model.requestDetail(kind: .container, subject: item.host.rowID(item.container.name))
            }
        }
        return tile(detail: "\(running) of \(all.count) running", link: .runningContainers,
                    help: "Open Containers, showing the running ones") {
            if all.isEmpty {
                WidgetEmpty(text: "No containers yet.")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: running, of: all.count, caption: "running")
                    WidgetLines(lines: lines, limit: 1)
                }
            } else {
                WidgetLines(lines: lines, limit: lineLimit)
            }
        }
    }

    // MARK: Vulnerabilities

    /// What the daily report (Q62) says about the images on these Macs. Advisory, like the card on
    /// an image's page: an image the library does not list was never scanned, so it is not counted
    /// as clean, only left out.
    private var vulnerabilities: some View {
        let report = model.vulnerabilityReport
        let images = model.images.map { (image: $0, host: HostRef.local) }
            + model.hostMode.fleetImages.flatMap { entry in
                entry.snapshot.items.map { (image: $0, host: HostRef.peer(entry.host.fingerprint)) }
            }
        let matched: [(image: ContainerImage, host: HostRef, counts: VulnerabilityReport.Counts)] = report.map { report in
            images.compactMap { item in
                report.image(forAnyOf: item.image.reportDigests).map { (item.image, item.host, $0.counts) }
            }
        } ?? []
        let critical = matched.reduce(0) { $0 + $1.counts.critical }
        let high = matched.reduce(0) { $0 + $1.counts.high }
        let medium = matched.reduce(0) { $0 + $1.counts.medium }
        let affected = matched.filter { $0.counts.total > 0 }
            .sorted { ($0.counts.critical, $0.counts.high) > ($1.counts.critical, $1.counts.high) }
        let generated = report?.generatedDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
        return tile(detail: generated, link: .section(.images), help: "Open Images") {
            if report == nil {
                WidgetEmpty(text: "No report yet. The daily vulnerability report arrives with the suggestions library.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        WidgetFigure(value: critical, caption: "critical", tint: critical > 0 ? Theme.danger : .primary)
                        WidgetFigure(value: high, caption: "high", tint: high > 0 ? Theme.warning : .primary)
                        if size == .tall { WidgetFigure(value: medium, caption: "medium", tint: .secondary) }
                    }
                    Text(affected.first.map { "In \(affected.count) of \(images.count) images · worst: \(ContainerImage.shortReference($0.image.reference))" }
                         ?? "Nothing listed in \(images.count) images")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if size == .tall, !affected.isEmpty {
                        WidgetLines(lines: affected.map { item in
                            WidgetLine(id: item.host.rowID(item.image.reference),
                                       name: ContainerImage.shortReference(item.image.reference),
                                       note: "\(item.counts.critical) critical · \(item.counts.high) high",
                                       dot: item.counts.critical > 0 ? Theme.danger : Theme.warning,
                                       help: "Open \(item.image.reference)") {
                                model.requestDetail(kind: .image, subject: item.host.rowID(item.image.reference))
                            }
                        }, limit: 4)
                    }
                }
            }
        }
    }

    // MARK: Activity

    private var activity: some View {
        let events = model.activity
        let today = events.first.map { Calendar.current.isDateInToday($0.date) } ?? false
        return tile(detail: today ? "Today" : nil, link: .section(.activity)) {
            if events.isEmpty {
                WidgetEmpty(text: "Nothing has changed since Flotilla opened.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Tall wraps each event to two lines (Kamal, round 2), so it lists seven, not eight:
                    // seven two-line events fit the tile, and a cut-off last line reads as a bug.
                    ForEach(Array(events.prefix(size == .small ? 3 : 7).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().opacity(0.6) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.date, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Text("\(Text(event.subject).fontWeight(.semibold)) \(event.summary.lowercased())")
                                .font(.callout)
                                .lineLimit(size == .small ? 1 : 2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        .help("\(event.kind.title): \(event.subject) — \(event.summary)")
                    }
                }
            }
        }
    }

    // MARK: Machines

    private var machines: some View {
        let all = model.machines.sorted { a, b in
            (a.state == .running) != (b.state == .running) ? a.state == .running
                : a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
        let running = all.filter { $0.state == .running }.count
        let lines = all.map { machine in
            let up = machine.state == .running
            return WidgetLine(id: machine.id, name: machine.id,
                              note: up ? "\(machine.cpus) CPU · \(MachinesView.bytes(machine.memory))" : machine.status.lowercased(),
                              dot: up ? Theme.online : Color.secondary.opacity(0.45), dimmed: !up) {
                model.requestDetail(kind: .machine, subject: machine.id)
            }
        }
        return tile(detail: "\(running) of \(all.count) running", link: .runningMachines,
                    help: "Open Machines, showing the running ones") {
            if all.isEmpty {
                WidgetEmpty(text: "No machines on This Mac.")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: running, of: all.count, caption: "running")
                    WidgetLines(lines: lines, limit: 1)
                }
            } else {
                WidgetLines(lines: lines, limit: lineLimit)
            }
        }
    }

    // MARK: Kubernetes

    private var kubernetes: some View {
        let byName = Dictionary(grouping: fleetClusters, by: \.name)
        let names = byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let ready = names.filter { byName[$0]?.contains(where: \.isRunning) == true }
        let lines = names.map { name in
            let nodes = byName[name] ?? []
            let up = nodes.contains(where: \.isRunning)
            return WidgetLine(id: name, name: name,
                              note: up ? "Ready · \(nodes.count) node\(nodes.count == 1 ? "" : "s")" : (nodes.first?.state.lowercased() ?? ""),
                              dot: up ? Theme.online : Color.secondary.opacity(0.45), dimmed: !up)
        }
        return tile(detail: "\(names.count) cluster\(names.count == 1 ? "" : "s")", link: .section(.clusters)) {
            if names.isEmpty {
                WidgetEmpty(text: "No clusters yet.")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: ready.count, of: names.count, caption: "ready")
                    WidgetLines(lines: lines, limit: 1)
                }
            } else {
                WidgetLines(lines: lines, limit: lineLimit)
            }
        }
    }

    // MARK: DNS

    private var dns: some View {
        let domains = model.dnsDomains
        let lines = domains.map { domain in
            WidgetLine(id: domain.id, name: domain.name,
                       note: domain.registersContainers ? "Names containers" : "",
                       dot: domain.resolverInstalled ? Theme.online : Theme.warning,
                       help: domain.resolverInstalled ? domain.name : "\(domain.name) — this Mac doesn't resolve it yet")
        }
        return tile(detail: "\(domains.count) domain\(domains.count == 1 ? "" : "s")", link: .section(.dns)) {
            if domains.isEmpty {
                WidgetEmpty(text: "No local domains. Containers are reached by address.")
            } else {
                WidgetLines(lines: lines, limit: 3)
            }
        }
    }

    // MARK: Storage

    /// This Mac's startup disk, and what images and volumes account for — the figures the Images
    /// and Volumes sections already have. A volume's reported size is its capacity, not its use
    /// (measured 12 September), so volumes are counted, not summed.
    private var storage: some View {
        let local = model.localHostFacts()
        let used = local.diskTotalBytes.flatMap { total in local.diskFreeBytes.map { total - $0 } }
        let fraction = used.flatMap { u in local.diskTotalBytes.map { $0 > 0 ? Double(u) / Double($0) : 0 } }
        let imageBytes = model.images.compactMap(\.displaySize).reduce(0, +)
        return tile(detail: "This Mac", link: .section(.volumes), help: "Open Volumes") {
            VStack(alignment: .leading, spacing: 8) {
                WidgetFigure(value: model.volumes.count, caption: "volumes · images \(Self.bytes(imageBytes))")
                WidgetMeter(fraction: fraction, label: "Startup disk used")
                Text(used.map { u in "\(Self.bytes(u)) of \(OverviewView.disk(local)) used on the startup disk" } ?? "Startup disk not read")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    // MARK: Tasks

    private var tasks: some View {
        let entries = model.tasks.board.entries.sorted { $0.startedAt > $1.startedAt }
        let running = entries.filter { !$0.state.isFinished }.count
        return tile(detail: running > 0 ? "\(running) running" : nil, link: .tasks, help: "Show Tasks") {
            if entries.isEmpty {
                WidgetEmpty(text: "No jobs. Pulls, builds and runs show here while they work.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.prefix(size == .small ? 3 : 8).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.6) }
                        HStack(spacing: 8) {
                            taskMark(entry.state)
                            Text(entry.title).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 5)
                        .help(entry.latestLine ?? entry.title)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func taskMark(_ state: TaskBoard.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityLabel("Running")
        case .succeeded:
            Image(systemName: "checkmark").foregroundStyle(Theme.online).frame(width: 12).accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger).frame(width: 12).accessibilityLabel("Failed")
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).frame(width: 12).accessibilityLabel("Cancelled")
        }
    }

    // MARK: Images

    private var images: some View {
        // Newest first: the creation date is an ISO-8601 string, which sorts as text.
        let all = model.images.sorted { ($0.configuration.creationDate ?? "") > ($1.configuration.creationDate ?? "") }
        let total = all.compactMap(\.displaySize).reduce(0, +)
        let lines = all.map { image in
            WidgetLine(id: image.reference, name: ContainerImage.shortReference(image.reference),
                       note: image.displaySize.map(Self.bytes) ?? "", dot: Theme.info,
                       help: "Open \(image.reference)") {
                model.requestDetail(kind: .image, subject: image.reference)
            }
        }
        return tile(detail: "This Mac", link: .section(.images)) {
            if all.isEmpty {
                WidgetEmpty(text: "No images on This Mac.")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: all.count, caption: "images · \(Self.bytes(total))")
                    WidgetLines(lines: lines, limit: 1)
                }
            } else {
                WidgetLines(lines: lines, limit: lineLimit)
            }
        }
    }

    // MARK: Networks

    private var networks: some View {
        let all = model.networks
        let lines = all.map { network in
            WidgetLine(id: network.id, name: network.name,
                       note: network.isBuiltin ? "built-in" : (network.subnet ?? ""),
                       dot: Theme.info, dimmed: network.isBuiltin)
        }
        return tile(detail: "This Mac", link: .section(.networks)) {
            if all.isEmpty {
                WidgetEmpty(text: "No networks.")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: all.count, caption: all.count == 1 ? "network" : "networks")
                    WidgetLines(lines: lines, limit: 1)
                }
            } else {
                WidgetLines(lines: lines, limit: lineLimit)
            }
        }
    }

    // MARK: Suggestions

    /// A few stacks from the signed library — the Suggestions section's own catalogue, unchanged.
    private var suggestions: some View {
        let picks = SuggestionCatalogue(library: model.suggestionLibrary).matching("", tab: .stacks)
        let shown = Array(picks.prefix(size == .wide ? 3 : 2))
        return tile(link: .section(.suggestions)) {
            if shown.isEmpty {
                WidgetEmpty(text: "No suggestions in this library.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.6) }
                        Button { model.requestSuggestion(item.id) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if size == .wide {
                                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(item.title) in Suggestions")
                    }
                }
            }
        }
    }
}

// MARK: - Hosts row

/// One Mac in the Hosts widget. Large: the row Hosts draws, compact — dot, name, its built-in and
/// own tags, then model and macOS, with the load and the running count and version at the end.
/// Wide: the name and how many are running, or what is wrong.
struct OverviewHostRow: View {
    let model: AppModel
    let row: HostRow
    let facts: HostFacts?
    let detailed: Bool

    var body: some View {
        Button { model.requestDetail(kind: .host, subject: row.id) } label: {
            HStack(spacing: 10) {
                HostStatusDot(model: model, row: row)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        if detailed {
                            ChipLine {
                                TagPillRow(tags: model.tags.tags(on: .host, row.id), compact: true, builtIns: builtIns)
                            }
                        }
                    }
                    if detailed {
                        Text(secondLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if detailed {
                    VStack(alignment: .leading, spacing: 3) {
                        if row.connected {
                            WidgetMeter(fraction: facts?.cpuPercent.map { $0 / 100 }, label: "\(row.name) CPU load")
                        }
                        Text(trailing).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 130, alignment: .leading)
                } else {
                    Text(row.connected ? running : row.status).font(.caption)
                        .foregroundStyle(row.connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, detailed ? 7 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(row.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary)
    }

    private var builtIns: [BuiltInHostTag] {
        BuiltInHostTag.tags(isThisMac: row.isThisMac,
                            role: row.isThisMac ? model.hostMode.mode.rawValue
                                                : row.peer.flatMap { model.hostMode.facts[$0.fingerprint]?.role })
    }

    private var running: String { row.containersRunning.map { "\($0) running" } ?? "—" }

    /// `M3 Max · 16 cores · 64 GB · macOS 27.0.1`, or what is wrong when it is not connected.
    private var secondLine: String {
        if !row.connected { return row.status }
        var parts: [String] = []
        let chip = OverviewView.chip(facts)
        if chip != "—" { parts.append(chip) }
        let memory = OverviewView.memory(facts)
        if memory != "—" { parts.append(memory) }
        if let macOS = facts?.macOSVersion ?? row.macOS { parts.append("macOS " + macOS) }
        return parts.isEmpty ? (row.modelIdentifier ?? "—") : parts.joined(separator: " · ")
    }

    private var trailing: String {
        guard row.connected else { return row.peer?.lastSeen.map { "seen " + OverviewView.checkIn($0) } ?? "—" }
        return [running, row.appVersion].compactMap { $0 }.joined(separator: " · ")
    }

    private var summary: String {
        var parts = [row.name]
        if row.isThisMac { parts.append("this Mac") }
        parts.append(row.status)
        if detailed { parts.append(secondLine) }
        parts.append(row.connected ? running : trailing)
        return parts.joined(separator: ", ")
    }
}
