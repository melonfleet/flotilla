import SwiftUI
import FlotillaCore

// The Overview's widgets (DECISIONS Q67): what each one draws, at each of the four sizes, for each
// thing it can show. The grid, edit mode and persistence are `OverviewView` and
// `OverviewLayoutStore`; the rules are `OverviewLayout` in FlotillaCore.
//
// **Every widget reads what its section already reads.** No widget starts a poll or runs a command
// of its own: the lists come from `AppModel` and `HostModeController`, which the poll loop and
// Overview's own `.task` already keep fresh. A Show choice (round 3) is a filter or an order over
// those same lists. A widget is a window onto its section, so clicking it opens that section,
// filtered to match where the section has the filter.
//
// **Each size is its own layout** (Kamal, round 3), and every one is bounded: a size knows how many
// rows it has room for, rows are one line (or two at Large) and truncate, and nothing in a tile
// sizes the tile. The tile clips as a last resort; it is not how anything is meant to fit.

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

/// Where a click on a widget goes: its section, set to the filter matching what the widget shows
/// where the section has one (round 3). Tasks has no section — it is the drawer.
///
/// **A section with a host picker is given the host the widget's data came from** (Kyle, beta 6):
/// `.local` for a widget of This Mac's, nil for one that counts the fleet. Left alone, a picker set
/// to another Mac on an earlier visit would open on that Mac's rows under a widget about this one.
enum OverviewLink: Equatable {
    case section(Section)
    case containers(ContainersView.Filter)
    case machines(MachinesView.Filter)
    case hosts(filterID: String)
    case dns(filterID: String, host: HostRef?)
    case networks(filterID: String, host: HostRef?)
    case images(host: HostRef?)
    case volumes(host: HostRef?)
    case clusters(host: HostRef?)
    case suggestions(SuggestionTab, host: HostRef?)
    case tasks
}

// MARK: - The tile

/// One widget's card: header, then content clipped to the tile. The size comes from the grid; the
/// content is written for each size, so nothing here scrolls and nothing grows the page.
struct OverviewTile<Content: View>: View {
    let widget: OverviewWidget
    let store: OverviewLayoutStore
    /// What the ⋯ menu offers — the kind's choices, less any this Mac cannot honour now.
    let shows: [OverviewWidgetShow]
    /// The header's right-hand words — "12 of 21 running", "Today".
    var detail: String?
    /// What the header and a click on the card open; nil for a card that opens nothing.
    var open: (() -> Void)?
    var openHelp: String?
    let editing: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // While arranging, a click is for the arranging; nothing inside fires.
                .allowsHitTesting(!editing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if !editing { open?() } }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            if editing {
                // The grip is in the tile's top-left corner, drawn by the grid (`WidgetGrip`).
                title
                Spacer(minLength: 4)
                OverviewSizeControl(size: widget.size) { size in store.update { $0.resize(widget.id, to: size) } }
            } else if let open {
                Button(action: open) {
                    HStack(spacing: 8) {
                        title.layoutPriority(1)
                        Spacer(minLength: 4)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(openHelp ?? "Open \(widget.kind.title)")
            } else {
                title
                Spacer(minLength: 0)
            }
            WidgetOptionsMenu(widget: widget, store: store, shows: shows)
        }
    }

    private var title: some View {
        Label {
            Text(widget.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: widget.kind.systemImage).foregroundStyle(.secondary)
        }
    }
}

/// The ⋯ on every widget (round 3): what it shows, its size, and Remove — the same choices Edit
/// Widgets and the right-click give, so changing a widget never needs edit mode.
struct WidgetOptionsMenu: View {
    let widget: OverviewWidget
    let store: OverviewLayoutStore
    let shows: [OverviewWidgetShow]

    var body: some View {
        Menu {
            if shows.count > 1 {
                // A saved choice this Mac cannot honour now (This Mac's Site with no site) reads as
                // the first offered, which is what the widget is drawing.
                Picker("Show", selection: Binding(get: { widget.show.flatMap { shows.contains($0) ? $0 : nil } ?? shows[0] },
                                                  set: { choice in store.update { $0.setShow(widget.id, to: choice) } })) {
                    ForEach(shows, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Picker("Size", selection: Binding(get: { widget.size },
                                              set: { size in store.update { $0.resize(widget.id, to: size) } })) {
                ForEach(widget.kind.sizes, id: \.self) { size in
                    Text("\(size.title) (\(size.columns)×\(size.rows))").tag(size)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Remove \(widget.title)") { store.update { $0.remove(widget.id) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(shows.count > 1 ? "Choose what \(widget.title) shows, and its size" : "Choose the size of \(widget.title)")
        .accessibilityLabel("Options for \(widget.title)")
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
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(minWidth: 0, alignment: .leading)
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

/// A labelled meter on one line — `CPU ▬▬▬── 42%`.
struct WidgetMeterRow: View {
    let title: String
    let fraction: Double?
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 52, alignment: .leading)
            WidgetMeter(fraction: fraction, label: label)
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }
}

/// Wide's shape: the figure on the left, a few rows beside it.
struct WidgetSplit<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            left.frame(width: 118, alignment: .topLeading)
            right.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A row in a widget's list: a dot, a name, a short trailing note and, at Large, a second line.
/// The app's row, compact — no checkbox, no hover actions; the section beside it has those.
/// `heading` rows are the group titles of a By Host list.
struct WidgetLine: Identifiable {
    let id: String
    let name: String
    var note: String = ""
    var detail: String?
    var dot: Color = Theme.online
    var dimmed = false
    var heading = false
    var help: String?
    var open: (() -> Void)?

    static func heading(_ title: String, note: String = "") -> WidgetLine {
        WidgetLine(id: "heading:" + title, name: title, note: note, heading: true)
    }
}

struct WidgetLines: View {
    let lines: [WidgetLine]
    let limit: Int
    /// "N more" under the rows. Off under a Small tile's figure, which already gives the count and
    /// has no height to spare.
    var countsMore = true

    var body: some View {
        var shown = Array(lines.prefix(limit))
        // A group title with nothing under it reads as an empty group.
        if lines.count > limit, shown.last?.heading == true { shown.removeLast() }
        let more = lines.dropFirst(shown.count).filter { !$0.heading }.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, line in
                if index > 0, !line.heading, !shown[index - 1].heading { Divider().opacity(0.6) }
                if line.heading { heading(line, first: index == 0) } else { row(line) }
            }
            if countsMore, more > 0 {
                Text("\(more) more")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func heading(_ line: WidgetLine, first: Bool) -> some View {
        HStack(spacing: 6) {
            Text(line.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Spacer(minLength: 4)
            Text(line.note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.top, first ? 0 : 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func row(_ line: WidgetLine) -> some View {
        let content = HStack(spacing: 8) {
            Circle().fill(line.dot).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.name)
                    .font(.system(size: 13, weight: line.dimmed ? .regular : .medium))
                    .foregroundStyle(line.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1).truncationMode(.middle)
                if let detail = line.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            // The name keeps its room first; the note gives way.
            .layoutPriority(1)
            Spacer(minLength: 6)
            Text(line.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, line.detail == nil ? 5 : 4)
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

/// What one widget draws, at its size and for its Show choice. `go` is how a click leaves the
/// Overview.
struct OverviewWidgetContent: View {
    let model: AppModel
    let widget: OverviewWidget
    /// The size to draw: the widget's own, or narrower when the grid has fewer columns than it.
    let size: OverviewWidgetSize
    let editing: Bool
    let go: (OverviewLink) -> Void

    private var store: OverviewLayoutStore { model.overviewLayout }
    private var show: OverviewWidgetShow? { widget.show }

    // Room, in rows, at each size — from the tile's fixed height (`OverviewGrid.rowHeight`) and a
    // one-line row of about 27pt or a two-line row of about 43pt, with space kept for "N more".
    /// One-line rows in a Tall tile.
    private static let tallRows = 8
    /// Two-line rows in a Large tile.
    private static let largeRows = 6
    /// One-line rows beside the figure in a Wide tile.
    private static let wideRows = 3

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
                                     shows: [OverviewWidgetShow]? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        OverviewTile(widget: widget, store: store, shows: shows ?? widget.kind.shows, detail: detail,
                     open: link.map { link in { go(link) } }, openHelp: help, editing: editing,
                     content: content)
    }

    /// The shape every list widget shares: Small a figure and the top row, Wide the figure beside a
    /// few rows, Tall a list, Large a list of two-line rows. `large` is the same rows with their
    /// second lines; nil uses `lines`.
    @ViewBuilder
    private func listLayout(figure: WidgetFigure, lines: [WidgetLine], large: [WidgetLine]? = nil,
                            smallRows: Int = 1, empty: String) -> some View {
        if lines.isEmpty {
            switch size {
            case .small, .tall: VStack(alignment: .leading, spacing: 8) { figure; WidgetEmpty(text: empty) }
            case .wide, .large: WidgetSplit { figure } right: { WidgetEmpty(text: empty) }
            }
        } else {
            switch size {
            case .small:
                VStack(alignment: .leading, spacing: 8) {
                    figure
                    if smallRows > 0 { WidgetLines(lines: lines.filter { !$0.heading }, limit: smallRows, countsMore: false) }
                }
            case .wide:
                WidgetSplit { figure } right: { WidgetLines(lines: lines, limit: Self.wideRows) }
            case .tall:
                WidgetLines(lines: lines, limit: Self.tallRows)
            case .large:
                WidgetLines(lines: large ?? lines, limit: Self.largeRows)
            }
        }
    }

    // MARK: Fleet at a glance

    /// This Mac and every paired host, as `Hosts` lists them — imported claims are not Macs yet.
    private var macRows: [HostRow] { model.hostRows.filter { $0.isThisMac || $0.peer != nil } }

    private func facts(_ row: HostRow) -> HostFacts? {
        if row.isThisMac { return model.localHostFacts() }
        return row.peer.flatMap { model.hostMode.facts[$0.fingerprint] }
    }

    private var fleetContainers: [(container: Container, host: HostRef, hostName: String)] {
        model.containers.map { ($0, HostRef.local, "This Mac") }
            + model.hostMode.fleetContainers.flatMap { entry in
                entry.snapshot.items.map { ($0, HostRef.peer(entry.host.fingerprint), entry.host.displayName) }
            }
    }
    private var fleetImages: [(image: ContainerImage, host: HostRef, hostName: String)] {
        model.images.map { ($0, HostRef.local, "This Mac") }
            + model.hostMode.fleetImages.flatMap { entry in
                entry.snapshot.items.map { ($0, HostRef.peer(entry.host.fingerprint), entry.host.displayName) }
            }
    }
    private var fleetClusters: [K8sNode] {
        model.clusters + model.hostMode.fleetClusters.flatMap(\.snapshot.items)
    }

    private static func cpuFraction(_ facts: HostFacts?) -> Double? { facts?.cpuPercent.map { $0 / 100 } }
    private static func memoryFraction(_ facts: HostFacts?) -> Double? {
        guard let f = facts, let used = f.memoryUsedBytes, let total = f.memoryTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    /// Replaces "Across all hosts" (Q67): the totals, the Macs' load, or both (round 3).
    private var fleet: some View {
        let macs = macRows
        let connected = macs.filter(\.connected)
        let containers = fleetContainers.map(\.container)
        let running = containers.filter(AppModel.isRunning).count
        let images = fleetImages.map(\.image)
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
        let volumes = model.volumes.count + model.hostMode.fleetVolumes.reduce(0) { $0 + $1.snapshot.items.count }
        let networks = model.networks.count + model.hostMode.fleetNetworks.reduce(0) { $0 + $1.snapshot.items.count }

        let macsFigure = WidgetFigure(value: connected.count, of: macs.count, caption: "Macs connected")
        let containersFigure = WidgetFigure(value: running, of: containers.count, caption: "containers running")
        let imagesFigure = WidgetFigure(value: images.count, caption: imageBytes > 0 ? "images · \(Self.bytes(imageBytes))" : "images")
        let machinesFigure = WidgetFigure(value: model.machines.count, caption: "machines\(onThisMac) · \(machinesRunning) running")
        let clustersFigure = WidgetFigure(value: clusterNames.count, caption: "clusters · \(ready) ready")
        let meters = VStack(alignment: .leading, spacing: 8) {
            WidgetMeterRow(title: "CPU", fraction: cpu, label: "Fleet CPU")
            WidgetMeterRow(title: "Memory", fraction: memory, label: "Fleet memory")
            WidgetMeterRow(title: "Disk", fraction: disk, label: "Fleet disk")
        }
        // Each Mac's own CPU and memory, for the Load view's taller sizes.
        let perMac = connected.map { row in
            let f = facts(row)
            let cpuText = Self.cpuFraction(f).map { "CPU \(Int(($0 * 100).rounded()))%" } ?? "CPU —"
            let memText = Self.memoryFraction(f).map { "memory \(Int(($0 * 100).rounded()))%" } ?? "memory —"
            return WidgetLine(id: row.id, name: row.name, note: cpuText,
                              detail: "\(cpuText) · \(memText)", dot: Theme.online,
                              help: "Open \(row.name)") {
                model.requestDetail(kind: .host, subject: row.id)
            }
        }
        let shown = show ?? .both

        return tile(detail: macs.count > 1 ? "\(macs.count) Macs" : "This Mac", link: .section(.hosts),
                    help: "Open Hosts") {
            switch (shown, size) {
            // Counts
            case (.counts, .small):
                HStack(alignment: .top, spacing: 12) { macsFigure; containersFigure }
            case (.counts, .wide):
                HStack(alignment: .top, spacing: 12) { macsFigure; containersFigure; imagesFigure; machinesFigure }
            case (.counts, .tall):
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow { macsFigure; containersFigure }
                    GridRow { imagesFigure; machinesFigure }
                    GridRow { clustersFigure; WidgetFigure(value: volumes, caption: "volumes") }
                }
            case (.counts, .large):
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 18) {
                    GridRow { macsFigure; containersFigure; imagesFigure }
                    GridRow { machinesFigure; clustersFigure; WidgetFigure(value: volumes, caption: "volumes") }
                    GridRow {
                        WidgetFigure(value: networks, caption: "networks")
                        WidgetFigure(value: model.dnsDomains.count, caption: "DNS domains\(onThisMac)")
                        Color.clear.frame(height: 0)
                    }
                }
            // Load
            case (.load, .small), (.load, .wide):
                VStack(alignment: .leading, spacing: 10) {
                    meters
                    Text(connected.count == macs.count ? "Average of \(connected.count) Mac\(connected.count == 1 ? "" : "s")"
                                                       : "\(connected.count) of \(macs.count) Macs reporting")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            case (.load, .tall):
                VStack(alignment: .leading, spacing: 12) {
                    meters
                    WidgetLines(lines: perMac, limit: 5)
                }
            case (.load, .large):
                VStack(alignment: .leading, spacing: 12) {
                    meters
                    WidgetLines(lines: perMac.map { var l = $0; l.note = ""; return l }, limit: 4)
                }
            // Both — round 2's layouts
            case (_, .small):
                VStack(alignment: .leading, spacing: 10) {
                    containersFigure
                    VStack(alignment: .leading, spacing: 6) {
                        WidgetMeterRow(title: "CPU", fraction: cpu, label: "Fleet CPU")
                        WidgetMeterRow(title: "Memory", fraction: memory, label: "Fleet memory")
                    }
                }
            case (_, .wide):
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) { macsFigure; containersFigure; imagesFigure }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    inlineMeters(cpu: cpu, memory: memory, disk: disk)
                }
            case (_, .tall):
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 14) {
                        GridRow { macsFigure; containersFigure }
                        GridRow { imagesFigure; machinesFigure }
                    }
                    meters
                }
            case (_, .large):
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        macsFigure; containersFigure; imagesFigure; machinesFigure; clustersFigure
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top, spacing: 12) {
                        WidgetFigure(value: volumes, caption: "volumes")
                        WidgetFigure(value: networks, caption: "networks")
                        WidgetFigure(value: model.dnsDomains.count, caption: "DNS domains\(onThisMac)")
                    }
                    meters
                }
            }
        }
    }

    private func inlineMeters(cpu: Double?, memory: Double?, disk: Double?) -> some View {
        let items: [(String, Double?)] = [("CPU", cpu), ("Memory", memory), ("Disk", disk)]
        return HStack(spacing: 10) {
            ForEach(items, id: \.0) { item in
                Text(item.0).font(.caption).foregroundStyle(.secondary).fixedSize()
                WidgetMeter(fraction: item.1, label: "Fleet \(item.0.lowercased())")
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

    /// The Site category, and This Mac's value in it — what "This Mac's Site" filters on. Nil when
    /// there is no Site category or This Mac has no site, and then the choice is not offered.
    private var thisMacSite: (category: HostCategory, value: String)? {
        guard let category = model.hostCategories.categories.first(where: {
            $0.name.caseInsensitiveCompare("Site") == .orderedSame
        }), let value = model.hostCategories.value(category, for: HostRow.thisMacID) else { return nil }
        return (category, value)
    }

    /// Replaces the striped Hosts table (Q67): the app's row — status dot, name, This Mac and Admin
    /// chips, model and macOS, a load bar, running count and version — and no columns or stripes.
    private var hosts: some View {
        let site = thisMacSite
        // A saved "This Mac's Site" with no site to match shows every Mac rather than none.
        let shown: OverviewWidgetShow = show == .thisSite && site == nil ? .all : (show ?? .all)
        let all = macRows
        // "Problems" is the Hosts section's own Needs attention filter, so a click lands on the same Macs.
        let isProblem: (HostRow) -> Bool = { !$0.connected && !$0.isPending }
        let rows: [HostRow] = switch shown {
        case .problems: all.filter(isProblem)
        case .thisSite: all.filter { row in site.map { model.hostCategories.value($0.category, for: row.id) == $0.value } ?? true }
        default: all
        }
        let connected = rows.filter(\.connected).count
        let problems = all.filter(isProblem).count
        let link: OverviewLink = shown == .problems ? .hosts(filterID: "attention") : .hosts(filterID: "all")
        let style: OverviewHostRow.Style = switch size {
        case .small, .wide: .compact
        case .tall: .twoLine
        case .large: .detailed
        }
        // Two-line and detailed rows are about 47pt; five, and "N more", fill a tall tile.
        let limit = switch size {
        case .small: 1
        case .wide: 3
        case .tall, .large: 5
        }
        let figure = shown == .problems
            ? WidgetFigure(value: problems, of: all.count, caption: problems == 1 ? "Mac needs attention" : "Macs need attention",
                           tint: problems > 0 ? Theme.warning : .primary)
            // The site is in the title ("Hosts · This Mac's Site").
            : WidgetFigure(value: connected, of: rows.count, caption: "Macs connected")
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.6) }
                OverviewHostRow(model: model, row: row, facts: facts(row), style: style)
            }
            // Not at Small: the figure gives the count, and there is no height for it.
            if size != .small, rows.count > limit {
                Text("\(rows.count - limit) more").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }
        var shows = widget.kind.shows
        if site == nil { shows.removeAll { $0 == .thisSite } }
        return tile(detail: shown == .problems ? nil : "\(connected) of \(rows.count) connected", link: link,
                    help: shown == .problems ? "Open Hosts, showing the Macs that need attention" : "Open Hosts",
                    shows: shows) {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    figure
                    WidgetEmpty(text: shown == .problems ? "Every Mac is connected." : "No Macs at this site.")
                }
            } else {
                switch size {
                case .small: VStack(alignment: .leading, spacing: 8) { figure; list }
                case .wide, .tall, .large: list
                }
            }
        }
    }

    // MARK: Containers

    private var containers: some View {
        let shown = show ?? .all
        let everything = fleetContainers
        let running = everything.filter { AppModel.isRunning($0.container) }.count
        let stopped = everything.count - running
        let items = everything.filter { item in
            switch shown {
            case .running: AppModel.isRunning(item.container)
            case .stopped: !AppModel.isRunning(item.container)
            default: true
            }
        }
        // Running first, unlike the section's name order (Q2): a widget this size is for "what's
        // up", and the section is one click away for the rest.
        let sorted = items.sorted { a, b in
            let ra = AppModel.isRunning(a.container), rb = AppModel.isRunning(b.container)
            return ra != rb ? ra : a.container.name.localizedStandardCompare(b.container.name) == .orderedAscending
        }
        let manyMacs = everything.contains { !$0.host.isLocal }
        func line(_ item: (container: Container, host: HostRef, hostName: String), detailed: Bool) -> WidgetLine {
            let isRunning = AppModel.isRunning(item.container)
            let image = ContainerImage.shortReference(item.container.imageReference)
            return WidgetLine(id: item.host.rowID(item.container.name), name: item.container.name,
                              note: detailed ? (isRunning ? "running" : "stopped") : (isRunning ? image : "stopped"),
                              detail: detailed ? (manyMacs ? "\(image) · \(item.hostName)" : image) : nil,
                              dot: isRunning ? Theme.online : Color.secondary.opacity(0.45), dimmed: !isRunning,
                              help: "Open \(item.container.name)") {
                model.requestDetail(kind: .container, subject: item.host.rowID(item.container.name))
            }
        }
        func grouped(detailed: Bool) -> [WidgetLine] {
            let hosts = Dictionary(grouping: sorted, by: \.hostName)
            let order = hosts.keys.sorted { a, b in a == "This Mac" ? true : b == "This Mac" ? false
                : a.localizedStandardCompare(b) == .orderedAscending }
            return order.flatMap { name -> [WidgetLine] in
                let members = hosts[name] ?? []
                let up = members.filter { AppModel.isRunning($0.container) }.count
                return [WidgetLine.heading(name, note: "\(up) of \(members.count) running")]
                    + members.map { line($0, detailed: detailed) }
            }
        }
        let lines: [WidgetLine]
        let large: [WidgetLine]
        let wideLines: [WidgetLine]
        if shown == .byHost {
            lines = grouped(detailed: false)
            large = grouped(detailed: true)
            // Wide: one row per Mac.
            wideLines = Dictionary(grouping: sorted, by: \.hostName)
                .sorted { $0.key == "This Mac" || ($1.key != "This Mac" && $0.key.localizedStandardCompare($1.key) == .orderedAscending) }
                .map { name, members in
                    let up = members.filter { AppModel.isRunning($0.container) }.count
                    return WidgetLine(id: name, name: name, note: "\(up) of \(members.count) running",
                                      dot: up > 0 ? Theme.online : Color.secondary.opacity(0.45))
                }
        } else {
            lines = sorted.map { line($0, detailed: false) }
            large = sorted.map { line($0, detailed: true) }
            // Wide: the strip of the most recently created.
            wideLines = sorted.sorted { ($0.container.configuration.creationDate ?? "") > ($1.container.configuration.creationDate ?? "") }
                .map { line($0, detailed: false) }
        }
        let macs = Set(everything.map(\.hostName)).count
        let figure: WidgetFigure = switch shown {
        case .stopped: WidgetFigure(value: stopped, of: everything.count, caption: "stopped")
        case .byHost: WidgetFigure(value: running, of: everything.count, caption: "running on \(macs) Mac\(macs == 1 ? "" : "s")")
        default: WidgetFigure(value: running, of: everything.count, caption: "running")
        }
        let link: OverviewLink = switch shown {
        case .running: .containers(.running)
        case .stopped: .containers(.stopped)
        default: .containers(.all)
        }
        let empty = switch shown {
        case .running: everything.isEmpty ? "No containers yet." : "Nothing running."
        case .stopped: everything.isEmpty ? "No containers yet." : "Nothing stopped."
        default: "No containers yet."
        }
        return tile(detail: "\(running) of \(everything.count) running", link: link,
                    help: shown == .running ? "Open Containers, showing the running ones"
                        : shown == .stopped ? "Open Containers, showing the stopped ones" : "Open Containers") {
            if size == .wide, !lines.isEmpty {
                WidgetSplit { figure } right: { WidgetLines(lines: wideLines, limit: Self.wideRows) }
            } else {
                // Small is the count alone (Kamal): the figure says it, and a row would crowd it.
                listLayout(figure: figure, lines: lines, large: large, smallRows: 0, empty: empty)
            }
        }
    }

    // MARK: Vulnerabilities

    private typealias Scanned = (image: ContainerImage, host: HostRef, hostName: String, counts: VulnerabilityReport.Counts)

    /// Every image on these Macs the daily report lists. An image it does not list was never
    /// scanned, so it is not counted as clean, only left out.
    private var scanned: [Scanned] {
        guard let report = model.vulnerabilityReport else { return [] }
        return fleetImages.compactMap { item in
            report.image(forAnyOf: item.image.reportDigests).map { (item.image, item.host, item.hostName, $0.counts) }
        }
    }

    private static func worstFirst(_ a: Scanned, _ b: Scanned) -> Bool {
        (a.counts.critical, a.counts.high, a.counts.medium) > (b.counts.critical, b.counts.high, b.counts.medium)
    }

    private func vulnerableLine(_ item: Scanned, detailed: Bool) -> WidgetLine {
        WidgetLine(id: item.host.rowID(item.image.reference),
                   name: ContainerImage.shortReference(item.image.reference),
                   note: "\(item.counts.critical) critical · \(item.counts.high) high",
                   detail: detailed ? "\(item.counts.medium) medium · \(item.counts.low) low · \(item.hostName)" : nil,
                   dot: item.counts.critical > 0 ? Theme.danger : Theme.warning,
                   help: "Open \(item.image.reference)") {
            model.requestDetail(kind: .image, subject: item.host.rowID(item.image.reference))
        }
    }

    /// What the daily report (Q62) says about the images on these Macs. Advisory, like the card on
    /// an image's page.
    private var vulnerabilities: some View {
        let report = model.vulnerabilityReport
        let imageCount = fleetImages.count
        let matched = scanned
        let critical = matched.reduce(0) { $0 + $1.counts.critical }
        let high = matched.reduce(0) { $0 + $1.counts.high }
        let medium = matched.reduce(0) { $0 + $1.counts.medium }
        let low = matched.reduce(0) { $0 + $1.counts.low }
        let affected = matched.filter { $0.counts.total > 0 }.sorted(by: Self.worstFirst)
        let generated = report?.generatedDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
        let criticalFigure = WidgetFigure(value: critical, caption: "critical", tint: critical > 0 ? Theme.danger : .primary)
        let highFigure = WidgetFigure(value: high, caption: "high", tint: high > 0 ? Theme.warning : .primary)
        let mediumFigure = WidgetFigure(value: medium, caption: "medium", tint: .secondary)
        let lowFigure = WidgetFigure(value: low, caption: "low", tint: .secondary)
        let summary = Text(affected.first.map { "In \(affected.count) of \(imageCount) images · worst: \(ContainerImage.shortReference($0.image.reference))" }
                           ?? "Nothing listed in \(imageCount) images")
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        return tile(detail: size == .small ? nil : generated, link: .images(host: nil), help: "Open Images") {
            if report == nil {
                WidgetEmpty(text: "No report yet. The daily vulnerability report arrives with the suggestions library.")
            } else if show == .worst {
                listLayout(figure: WidgetFigure(value: affected.count, of: matched.count, caption: "scanned images affected",
                                                tint: affected.isEmpty ? .primary : Theme.warning),
                           lines: affected.map { vulnerableLine($0, detailed: false) },
                           large: affected.map { vulnerableLine($0, detailed: true) },
                           empty: "Nothing listed in \(imageCount) images.")
            } else {
                switch size {
                case .small:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 16) { criticalFigure; highFigure }
                        summary
                    }
                case .wide:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 16) { criticalFigure; highFigure; mediumFigure; lowFigure }
                        summary
                    }
                case .tall:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) { criticalFigure; highFigure }
                        HStack(alignment: .top, spacing: 16) { mediumFigure; lowFigure }
                        summary
                        WidgetLines(lines: affected.map { vulnerableLine($0, detailed: false) }, limit: 3)
                    }
                case .large:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) { criticalFigure; highFigure; mediumFigure; lowFigure }
                        summary
                        WidgetLines(lines: affected.map { vulnerableLine($0, detailed: false) }, limit: 5)
                    }
                }
            }
        }
    }

    // MARK: Activity

    /// Paired Macs' names, which is how an event's subject says it happened elsewhere.
    private var knownHosts: Set<String> { Set(model.hostMode.hosts.map(\.displayName)) }

    /// What the Problems choice keeps: something that stopped or failed without Flotilla being asked
    /// to stop it — an observed transition out of running, or into a failed state. The feed records
    /// no failure actions of its own, so an action (a Stop the owner clicked) is never a problem.
    static func isProblem(_ event: ContainerEvent) -> Bool {
        guard event.action == nil else { return false }
        let to = event.to.lowercased()
        if ["failed", "error", "exited", "unknown"].contains(to) { return true }
        return event.from.lowercased() == "running" && to != "running" && to != "absent"
    }

    private var activity: some View {
        let hosts = knownHosts
        let events = model.activity.filter { event in
            switch show {
            case .problems: Self.isProblem(event)
            case .thisMac:
                event.hostName(hosts: hosts) == nil && event.kind != .host
                    && !(event.kind == .runtime && hosts.contains(event.subject))
            default: true
            }
        }
        let today = events.filter { Calendar.current.isDateInToday($0.date) }.count
        let empty = switch show {
        case .problems: "Nothing has stopped unexpectedly since Flotilla opened."
        case .thisMac: "Nothing has changed on This Mac since Flotilla opened."
        default: "Nothing has changed since Flotilla opened."
        }
        return tile(detail: events.first.map { Calendar.current.isDateInToday($0.date) } == true ? "Today" : nil,
                    link: .section(.activity)) {
            if events.isEmpty {
                WidgetEmpty(text: empty)
            } else {
                switch size {
                case .small:
                    eventList(events, limit: 3, lines: 1)
                case .wide:
                    WidgetSplit {
                        WidgetFigure(value: today, caption: show == .problems ? "problems today" : "changes today",
                                     tint: show == .problems && today > 0 ? Theme.warning : .primary)
                    } right: {
                        eventList(events, limit: 3, lines: 1)
                    }
                case .tall:
                    // Two lines an event (Kamal, round 2), so seven, not eight: seven two-line events
                    // fit the tile, and a cut-off last line reads as a bug.
                    eventList(events, limit: 7, lines: 2)
                case .large:
                    largeEvents(events, hosts: hosts)
                }
            }
        }
    }

    private func eventList(_ events: [ContainerEvent], limit: Int, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.prefix(limit).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().opacity(0.6) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text("\(Text(event.subject).fontWeight(.semibold)) \(event.summary.lowercased())")
                        .font(.callout)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                .help("\(event.kind.title): \(event.subject) — \(event.summary)")
            }
        }
    }

    /// Large: the app's activity row — the kind's glyph, the headline, and what, where and when.
    private func largeEvents(_ events: [ContainerEvent], hosts: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.prefix(Self.largeRows).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().opacity(0.6) }
                HStack(spacing: 10) {
                    Image(systemName: event.kind.systemImage).foregroundStyle(.secondary)
                        .frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.headline(hosts: hosts)).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text([event.kind.title, event.hostName(hosts: hosts) ?? "This Mac"].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    Text(event.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .help("\(event.kind.title): \(event.subject) — \(event.summary)")
            }
        }
    }

    // MARK: Machines

    private var machines: some View {
        let everything = model.machines
        let running = everything.filter { $0.state == .running }.count
        let shown = (show == .running ? everything.filter { $0.state == .running } : everything).sorted { a, b in
            (a.state == .running) != (b.state == .running) ? a.state == .running
                : a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
        func line(_ machine: ContainerMachine, detailed: Bool) -> WidgetLine {
            let up = machine.state == .running
            let resources = "\(machine.cpus) CPU · \(MachinesView.bytes(machine.memory))"
            let image = machine.image.map { ContainerImage.shortReference($0.reference) }
            return WidgetLine(id: machine.id, name: machine.id,
                              note: detailed ? machine.status.lowercased() : (up ? resources : machine.status.lowercased()),
                              detail: detailed ? ([image, resources, machine.ipAddress].compactMap { $0 }.joined(separator: " · ")) : nil,
                              dot: up ? Theme.online : Color.secondary.opacity(0.45), dimmed: !up) {
                model.requestDetail(kind: .machine, subject: machine.id)
            }
        }
        return tile(detail: "\(running) of \(everything.count) running",
                    link: .machines(show == .running ? .running : .all),
                    help: show == .running ? "Open Machines, showing the running ones" : "Open Machines") {
            listLayout(figure: WidgetFigure(value: running, of: everything.count, caption: "running"),
                       lines: shown.map { line($0, detailed: false) }, large: shown.map { line($0, detailed: true) },
                       empty: everything.isEmpty ? "No machines on This Mac." : "No machines running.")
        }
    }

    // MARK: Kubernetes

    private var kubernetes: some View {
        let byName = Dictionary(grouping: fleetClusters, by: \.name)
        let names = byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let ready = names.filter { byName[$0]?.contains(where: \.isRunning) == true }
        let shown = show == .ready ? ready : names
        func line(_ name: String, detailed: Bool) -> WidgetLine {
            let nodes = byName[name] ?? []
            let up = nodes.contains(where: \.isRunning)
            let count = "\(nodes.count) node\(nodes.count == 1 ? "" : "s")"
            let roles = Set(nodes.flatMap(\.roles)).sorted().joined(separator: ", ")
            return WidgetLine(id: name, name: name,
                              note: detailed ? (up ? "Ready" : (nodes.first?.state.lowercased() ?? ""))
                                             : (up ? "Ready · \(count)" : (nodes.first?.state.lowercased() ?? "")),
                              detail: detailed ? ([count, roles.isEmpty ? nil : roles, nodes.first?.address]
                                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) : nil,
                              dot: up ? Theme.online : Color.secondary.opacity(0.45), dimmed: !up)
        }
        return tile(detail: "\(names.count) cluster\(names.count == 1 ? "" : "s")", link: .clusters(host: nil)) {
            listLayout(figure: WidgetFigure(value: ready.count, of: names.count, caption: "ready"),
                       lines: shown.map { line($0, detailed: false) }, large: shown.map { line($0, detailed: true) },
                       empty: names.isEmpty ? "No clusters yet." : "No cluster is ready.")
        }
    }

    // MARK: DNS

    private var dns: some View {
        let domains = model.dnsDomains
        // "For Containers" is the DNS section's own filter of the same name: not a host alias.
        let shown = show == .forContainers ? domains.filter { !$0.isHostAlias } : domains
        let resolving = domains.filter(\.resolverInstalled).count
        func line(_ domain: LocalDNSDomain, detailed: Bool) -> WidgetLine {
            let what = domain.hostAliasAddress.map { "Alias for \($0)" } ?? (domain.registersContainers ? "Names containers" : "")
            return WidgetLine(id: domain.id, name: domain.name,
                              note: detailed ? (domain.resolverInstalled ? "resolving" : "not resolving") : what,
                              detail: detailed ? (what.isEmpty ? "Local domain" : what) : nil,
                              dot: domain.resolverInstalled ? Theme.online : Theme.warning,
                              help: domain.resolverInstalled ? domain.name : "\(domain.name) — this Mac doesn't resolve it yet")
        }
        return tile(detail: "\(domains.count) domain\(domains.count == 1 ? "" : "s")",
                    link: .dns(filterID: show == .forContainers ? "containers" : "all", host: .local)) {
            listLayout(figure: WidgetFigure(value: shown.count, caption: "\(resolving) resolving on This Mac"),
                       lines: shown.map { line($0, detailed: false) }, large: shown.map { line($0, detailed: true) },
                       empty: domains.isEmpty ? "No local domains. Containers are reached by address." : "No domains name containers.")
        }
    }

    // MARK: Storage

    /// This Mac's startup disk, and what images and volumes account for — the figures the Images
    /// and Volumes sections already have. A volume's reported size is its capacity, not its use
    /// (measured 12 September), so volumes are counted and listed, never summed.
    private var storage: some View {
        let local = model.localHostFacts()
        let used = local.diskTotalBytes.flatMap { total in local.diskFreeBytes.map { total - $0 } }
        let fraction = used.flatMap { u in local.diskTotalBytes.map { $0 > 0 ? Double(u) / Double($0) : 0 } }
        let imageBytes = model.images.compactMap(\.displaySize).reduce(0, +)
        // One line at Small, where two would not leave room for the figure's two.
        let disk = VStack(alignment: .leading, spacing: 6) {
            WidgetMeter(fraction: fraction, label: "Startup disk used")
            Text(used.map { u in size == .small ? "\(Self.bytes(u)) of \(OverviewView.disk(local)) used"
                                              : "\(Self.bytes(u)) of \(OverviewView.disk(local)) used on the startup disk" }
                 ?? "Startup disk not read")
                .font(.caption).foregroundStyle(.secondary).lineLimit(size == .small ? 1 : 2)
        }
        let volumesFigure = WidgetFigure(value: model.volumes.count, caption: "volumes")
        let imagesFigure = WidgetFigure(value: model.images.count, caption: "images · \(Self.bytes(imageBytes))")
        let largest = model.images.sorted { ($0.displaySize ?? 0) > ($1.displaySize ?? 0) }.map { image in
            WidgetLine(id: image.reference, name: ContainerImage.shortReference(image.reference),
                       note: image.displaySize.map(Self.bytes) ?? "", dot: Theme.info, help: "Open \(image.reference)") {
                model.requestDetail(kind: .image, subject: image.reference)
            }
        }
        let volumeLines = model.volumes.map { volume in
            WidgetLine(id: volume.id, name: volume.configuration.name, note: volume.configuration.driver ?? "",
                       dot: Theme.info, help: "Open \(volume.configuration.name)") {
                model.requestDetail(kind: .volume, subject: volume.configuration.name)
            }
        }
        return tile(detail: "This Mac", link: .volumes(host: .local), help: "Open Volumes") {
            switch size {
            case .small:
                VStack(alignment: .leading, spacing: 8) {
                    WidgetFigure(value: model.volumes.count, caption: "volumes · images \(Self.bytes(imageBytes))")
                    disk
                }
            case .wide:
                WidgetSplit {
                    volumesFigure
                } right: {
                    VStack(alignment: .leading, spacing: 10) { imagesFigure; disk }
                }
            case .tall:
                VStack(alignment: .leading, spacing: 12) {
                    disk
                    HStack(alignment: .top, spacing: 16) { imagesFigure; volumesFigure }
                    Text("Largest images").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    WidgetLines(lines: largest, limit: 3)
                }
            case .large:
                VStack(alignment: .leading, spacing: 12) {
                    disk
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Largest images · \(Self.bytes(imageBytes))").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).lineLimit(1)
                            if largest.isEmpty { WidgetEmpty(text: "No images.") } else { WidgetLines(lines: largest, limit: 5) }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Volumes · \(model.volumes.count)").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).lineLimit(1)
                            if volumeLines.isEmpty { WidgetEmpty(text: "No volumes.") } else { WidgetLines(lines: volumeLines, limit: 5) }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    // MARK: Tasks

    private var tasks: some View {
        let all = model.tasks.board.entries.sorted { $0.startedAt > $1.startedAt }
        let running = all.filter { !$0.state.isFinished }.count
        let entries = show == .running ? all.filter { !$0.state.isFinished } : all
        let empty = all.isEmpty ? "No jobs. Pulls, builds and runs show here while they work." : "Nothing running."
        return tile(detail: running > 0 ? "\(running) running" : nil, link: .tasks, help: "Show Tasks") {
            if entries.isEmpty {
                switch size {
                case .small, .tall: WidgetEmpty(text: empty)
                case .wide, .large:
                    WidgetSplit { WidgetFigure(value: running, caption: "running") } right: { WidgetEmpty(text: empty) }
                }
            } else {
                switch size {
                case .small: taskList(entries, limit: 3, detailed: false)
                case .wide:
                    WidgetSplit {
                        WidgetFigure(value: running, caption: "running · \(all.count - running) finished")
                    } right: {
                        taskList(entries, limit: Self.wideRows, detailed: false)
                    }
                case .tall: taskList(entries, limit: Self.tallRows, detailed: false)
                case .large: taskList(entries, limit: Self.largeRows, detailed: true)
                }
            }
        }
    }

    private func taskList(_ entries: [TaskBoard.Entry], limit: Int, detailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.prefix(limit).enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().opacity(0.6) }
                HStack(spacing: 8) {
                    taskMark(entry.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.callout).lineLimit(1).truncationMode(.middle)
                        if detailed {
                            Text(entry.currentStep ?? entry.latestLine ?? entry.origin)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    if detailed {
                        Text(entry.startedAt, format: .dateTime.hour().minute())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, detailed ? 4 : 5)
                .help(entry.latestLine ?? entry.title)
            }
            if entries.count > limit {
                Text("\(entries.count - limit) more").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
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
        let all = model.images
        let total = all.compactMap(\.displaySize).reduce(0, +)
        let report = model.vulnerabilityReport
        let shown: [(image: ContainerImage, counts: VulnerabilityReport.Counts?)] = switch show {
        case .largest:
            all.sorted { ($0.displaySize ?? 0) > ($1.displaySize ?? 0) }.map { ($0, nil) }
        case .vulnerable:
            all.compactMap { image in
                report?.image(forAnyOf: image.reportDigests).flatMap { $0.counts.total > 0 ? (image, $0.counts) : nil }
            }
            .sorted { a, b in (a.counts!.critical, a.counts!.high) > (b.counts!.critical, b.counts!.high) }
        default:
            // Newest first: the creation date is an ISO-8601 string, which sorts as text.
            all.sorted { ($0.configuration.creationDate ?? "") > ($1.configuration.creationDate ?? "") }.map { ($0, nil) }
        }
        func line(_ item: (image: ContainerImage, counts: VulnerabilityReport.Counts?), detailed: Bool) -> WidgetLine {
            let image = item.image
            let size = image.displaySize.map(Self.bytes) ?? ""
            let note = item.counts.map { "\($0.critical) critical · \($0.high) high" } ?? size
            let created = image.configuration.creationDate.map { String($0.prefix(10)) }
            return WidgetLine(id: image.reference, name: ContainerImage.shortReference(image.reference), note: note,
                              detail: detailed ? ([item.counts == nil ? nil : size, created.map { "created \($0)" }]
                                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) : nil,
                              dot: item.counts.map { $0.critical > 0 ? Theme.danger : Theme.warning } ?? Theme.info,
                              help: "Open \(image.reference)") {
                model.requestDetail(kind: .image, subject: image.reference)
            }
        }
        let figure = show == .vulnerable
            ? WidgetFigure(value: shown.count, of: all.count, caption: report == nil ? "no report yet" : "with vulnerabilities",
                           tint: shown.isEmpty ? .primary : Theme.warning)
            : WidgetFigure(value: all.count, caption: "images · \(Self.bytes(total))")
        let empty = if all.isEmpty { "No images on This Mac." }
            else if report == nil { "No report yet. The daily vulnerability report arrives with the suggestions library." }
            else { "Nothing listed in \(all.count) images." }
        return tile(detail: "This Mac", link: .images(host: .local)) {
            listLayout(figure: figure, lines: shown.map { line($0, detailed: false) },
                       large: shown.map { line($0, detailed: true) }, empty: empty)
        }
    }

    // MARK: Networks

    private var networks: some View {
        let all = model.networks
        let shown = show == .userDefined ? all.filter { !$0.isBuiltin } : all
        // Who's on them: the containers on This Mac attached to each, from the list Containers reads.
        let members = Dictionary(grouping: model.containers.flatMap { c in
            (c.configuration.networks ?? []).map { ($0.network, c.name) }
        }, by: \.0).mapValues { $0.map(\.1) }
        func line(_ network: ContainerNetwork, detailed: Bool) -> WidgetLine {
            let on = members[network.name] ?? members[network.id] ?? []
            let count = "\(on.count) container\(on.count == 1 ? "" : "s")"
            return WidgetLine(id: network.id, name: network.name,
                              note: detailed ? count : (network.isBuiltin ? "built-in" : (network.subnet ?? "")),
                              detail: detailed ? ([network.isBuiltin ? "built-in" : nil, network.subnet,
                                                   on.isEmpty ? nil : on.sorted().joined(separator: ", ")]
                                                    .compactMap { $0 }.joined(separator: " · ")) : nil,
                              dot: Theme.info, dimmed: network.isBuiltin)
        }
        return tile(detail: "This Mac", link: .networks(filterID: show == .userDefined ? "user" : "all", host: .local)) {
            listLayout(figure: WidgetFigure(value: shown.count, caption: show == .userDefined
                                            ? "user-defined" : (all.count == 1 ? "network" : "networks")),
                       lines: shown.map { line($0, detailed: false) }, large: shown.map { line($0, detailed: true) },
                       empty: all.isEmpty ? "No networks." : "No user-defined networks.")
        }
    }

    // MARK: Suggestions

    /// A few picks from the signed library — the Suggestions section's own catalogue, unchanged.
    private var suggestions: some View {
        let tab: SuggestionTab = show == .apps ? .apps : .stacks
        let picks = SuggestionCatalogue(library: model.suggestionLibrary).matching("", tab: tab)
        let (limit, summaries): (Int, Bool) = switch size {
        case .small: (3, false)
        case .wide: (4, true)
        case .tall, .large: (6, true)
        }
        return tile(link: .suggestions(tab, host: .local), help: "Open Suggestions") {
            if picks.isEmpty {
                WidgetEmpty(text: "No suggestions in this library.")
            } else if size == .wide {
                // Two by two: three two-line rows are taller than a Wide tile.
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: min(picks.count, 4), by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(picks[start..<min(start + 2, picks.count)], id: \.id) { suggestionButton($0, summary: true) }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picks.prefix(limit).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.6) }
                        suggestionButton(item, summary: summaries)
                    }
                }
            }
        }
    }

    private func suggestionButton(_ item: SuggestionItem, summary: Bool) -> some View {
        Button { model.requestSuggestion(item.id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if summary {
                    Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, summary ? 4 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(item.title) in Suggestions")
    }
}

// MARK: - Hosts row

/// One Mac in the Hosts widget, in three shapes. Detailed (Large): the row Hosts draws, compact —
/// dot, name, its built-in and own tags, then model and macOS, with the load and the running count
/// and version at the end. Two-line (Tall): the name, and model or what is wrong under it. Compact
/// (Small, Wide): the name and how many are running, or what is wrong.
struct OverviewHostRow: View {
    enum Style { case compact, twoLine, detailed }

    let model: AppModel
    let row: HostRow
    let facts: HostFacts?
    let style: Style

    var body: some View {
        Button { model.requestDetail(kind: .host, subject: row.id) } label: {
            HStack(spacing: 10) {
                HostStatusDot(model: model, row: row)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        if style == .detailed {
                            ChipLine {
                                TagPillRow(tags: model.tags.tags(on: .host, row.id), compact: true, builtIns: builtIns)
                            }
                        }
                    }
                    if style != .compact {
                        Text(style == .twoLine && row.connected ? "\(OverviewView.chip(facts)) · \(running)" : secondLine)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                switch style {
                case .detailed:
                    VStack(alignment: .leading, spacing: 3) {
                        if row.connected {
                            WidgetMeter(fraction: facts?.cpuPercent.map { $0 / 100 }, label: "\(row.name) CPU load")
                        }
                        Text(trailing).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 130, alignment: .leading)
                case .compact:
                    Text(row.connected ? running : row.status).font(.caption)
                        .foregroundStyle(row.connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                        .lineLimit(1)
                case .twoLine:
                    EmptyView()
                }
            }
            .padding(.vertical, style == .compact ? 5 : 7)
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
        if style != .compact { parts.append(secondLine) }
        parts.append(row.connected ? running : trailing)
        return parts.joined(separator: ", ")
    }
}
