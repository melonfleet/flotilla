import SwiftUI
import FlotillaCore

/// Overview — the fleet at a glance, made of widgets (DECISIONS Q67, Kamal, 23 October).
///
/// From the top: the notifications band, **fixed** — always first, never a widget, never removed
/// or moved (Kamal's change to the mockups: it does the job their "Needs attention" widget did) —
/// then a grid of widgets the owner chooses, orders and sizes. Get started is one of them: first on
/// a new Mac, removable, and in Add Widgets to bring back.
///
/// **The grid adds columns on a wider window** rather than stretching tiles, so a full-screen window
/// on a big display fills with more widgets. A widget is Small 1×1, Wide 2×1, Tall 1×2 or Large
/// 2×2; `OverviewLayout` packs them in order so nothing overlaps, and it is what is remembered — per
/// Mac, across launches, in `OverviewLayoutStore`.
///
/// **Edit Widgets** puts a handle, an ×, a size control and a resize grip on every tile, and the
/// Add Widgets panel on the right. Dragging a tile reorders the layout and the grid reflows round
/// it. VoiceOver gets Move Earlier, Move Later, Change Size and Remove on every widget, in or out
/// of edit mode, and the right-click menu offers the same.
struct OverviewView: View {
    let model: AppModel
    /// The sections a widget opens filtered — owned by `MainWindowView`, which outlives this view.
    let containersUI: ContainersUIState
    let machinesUI: MachinesUIState
    let hostsUI: ResourceUIState<HostRow>
    let go: (Section) -> Void

    @State private var editing = false

    private var store: OverviewLayoutStore { model.overviewLayout }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    band
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            OverviewGrid(model: model, editing: editing, go: open)
                            if !editing, store.layout.kinds.allSatisfy({ $0 == .getStarted }) {
                                OverviewEmptyState(store: store)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if editing {
                    Divider()
                    AddWidgetsPanel(store: store)
                }
            }
        }
        // Every branch bounded: the grid's height is computed, the panel scrolls inside itself, and
        // this fills the pane rather than sizing to its content (the activity-strip lesson).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The lists the widgets read are refreshed by the poll only every sixth tick or on a
        // section's visit, so Overview loads them itself rather than showing zeros on a fresh
        // launch. Paired hosts are asked alongside, not first: a host that is slow to answer must
        // not hold This Mac's numbers at zero.
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

    /// A widget's click: its section, filtered to what the widget counted where it counted a subset.
    private func open(_ link: OverviewLink) {
        switch link {
        case .section(let section):
            go(section)
        case .runningContainers:
            containersUI.search = ""
            containersUI.kindFilter = .all
            containersUI.hostFilter = nil
            containersUI.filter = .running
            go(.containers)
        case .runningMachines:
            machinesUI.search = ""
            machinesUI.filter = .running
            go(.machines)
        case .hostsNeedingAttention:
            hostsUI.search = ""
            hostsUI.filterID = "attention"
            go(.hosts)
        case .tasks:
            model.tasks.showList()
        }
    }

    // MARK: Header

    /// The band every page has under the window bar (horizontal 12, vertical 8 — `SectionToolbar`),
    /// with the Overview's two actions on one glass cluster, as `ActionCluster` draws everywhere.
    private var header: some View {
        HStack(spacing: 12) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if editing {
                ActionCluster {
                    Button {
                        store.update { $0.reset() }
                    } label: {
                        Label("Reset to Recommended", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isRecommended)
                    .help("Put back Get started, Fleet at a glance, Hosts, Containers, Vulnerabilities, "
                          + "Activity, Machines and Kubernetes, at their usual sizes")
                    Button("Done") { editing = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Finish arranging the Overview")
                }
            } else {
                ActionCluster {
                    Menu {
                        ForEach(store.layout.missing) { kind in
                            Button { store.update { $0.add(kind) } } label: {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Widget", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(store.layout.missing.isEmpty)
                    .help(store.layout.missing.isEmpty ? "Every widget is on the Overview" : "Add a widget to the end of the Overview")
                    Button {
                        editing = true
                    } label: {
                        Label("Edit Widgets", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Arrange, resize and remove widgets")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        if editing { return "Drag a widget to move it · pick its size · × removes it" }
        let macs = 1 + model.hostMode.trustedHosts.count
        let updated = model.lastRefresh.map { "Updated \(OverviewView.checkIn($0))" } ?? "Not refreshed yet"
        return macs > 1 ? "\(updated) · \(macs) Macs" : "\(updated) · This Mac"
    }

    // MARK: The fixed band

    /// Setting up `container` comes first and says what is happening (beta 2's test), then what
    /// needs attention. Not a widget (Q67): it cannot be removed or moved.
    @ViewBuilder
    private var band: some View {
        let setupBanner = model.runtimeSetup != nil || model.needsContainerInstall
        VStack(alignment: .leading, spacing: 10) {
            if setupBanner { RuntimeBanner(model: model) }
            // "Nothing needs attention" under a banner saying container isn't installed contradicts
            // it (the owner, on Tahoe, 10 October): with the banner up, the box shows only when
            // something else needs attention too.
            if !(setupBanner && model.notices.attention.isEmpty) { attention }
        }
    }

    /// What needs the owner, first, in a box like the others (the owner, 9 October) — a quiet
    /// grey line on the page background read as a footnote. When nothing does, one line that says so.
    private var attention: some View {
        attentionContent
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    /// One notice at a time (the owner, 10 October): a long list made Overview unusable. The
    /// heading and its detail on the left; on the right the fix, Dismiss where allowed, the
    /// ‹ 2 of 12 › arrows and All Notifications. Errors come first, then the newest. A fixed
    /// height, so stepping through or a notice resolving never moves the page under it.
    @State private var noticeIndex = 0

    @ViewBuilder
    private var attentionContent: some View {
        let notices = model.notices.attention
        if notices.isEmpty {
            let hosts = model.hostMode.trustedHosts.count
            HStack {
                Label(hosts == 0 ? "Nothing needs attention" : "Nothing needs attention on \(hosts + 1) Macs",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.online)
                Spacer()
                Button("All Notifications") { go(.notifications) }.buttonStyle(.link).font(.caption)
            }
        } else {
            let index = min(noticeIndex, notices.count - 1)
            let notice = notices[index]
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: notice.level.symbol).font(.title3).foregroundStyle(notice.level.colour)
                    .accessibilityLabel(notice.level.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.body.weight(.medium)).lineLimit(1)
                    if let detail = notice.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { go(.notifications) }
                .help(notice.text)
                if let fix = model.fix(for: notice) {
                    Button(fix.title) { fix.run() }.controlSize(.small).disabled(model.startingRuntime)
                }
                if notice.dismissible {
                    Button("Dismiss") { model.notices.dismiss([notice.id]) }.controlSize(.small)
                        .help("Hide until it changes")
                }
                if notices.count > 1 {
                    HStack(spacing: 2) {
                        Button { noticeIndex = (index - 1 + notices.count) % notices.count } label: {
                            Image(systemName: "chevron.left").frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless).help("Previous notification").accessibilityLabel("Previous notification")
                        Text("\(index + 1) of \(notices.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { noticeIndex = (index + 1) % notices.count } label: {
                            Image(systemName: "chevron.right").frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless).help("Next notification").accessibilityLabel("Next notification")
                    }
                }
                Button("All") { go(.notifications) }.buttonStyle(.link).font(.caption)
                    .help("All notifications").accessibilityLabel("All notifications")
            }
        }
    }

    // MARK: Formatting, shared with Hosts

    /// `just now`, `40 sec ago`, `12 min ago` — re-read on each poll, which redraws Overview.
    static func checkIn(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 5 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// `M1 · 8 cores`, `M3 Max · 4 vCores`. No "Apple" — every Mac's is — and a virtual Mac says
    /// so in its cores rather than a "(Virtual)" in the name: shorter, so the row has room (the
    /// owner, 8 October).
    static func chip(_ facts: HostFacts?) -> String {
        guard let facts else { return "—" }
        var name = facts.chip?.trimmingCharacters(in: .whitespaces)
        if let current = name, current.hasPrefix("Apple ") { name = String(current.dropFirst("Apple ".count)) }
        let virtual = name?.localizedCaseInsensitiveContains("(Virtual)") ?? false
        if virtual {
            name = name?.replacingOccurrences(of: "(Virtual)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }
        let cores = facts.cores.map { "\($0) \(virtual ? "vCores" : "cores")" }
        let text = [name, cores].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
}

// MARK: - The grid

/// The widgets, packed by `OverviewLayout.placements(columns:)` at the pane's width.
///
/// **Columns, not stretch.** A column is at least `minColumn` wide; a wider pane gets another
/// column as soon as one fits, so a tile never grows past about two columns' worth of width and a
/// big display shows more widgets rather than bigger ones. Rows are a fixed height, so every tile's
/// height is known before it draws and the grid's own height is computed — nothing here sizes to its
/// content, which is what keeps it from scrolling the window (the activity-strip lesson).
struct OverviewGrid: View {
    let model: AppModel
    let editing: Bool
    let go: (OverviewLink) -> Void

    static let minColumn: CGFloat = 250
    static let rowHeight: CGFloat = 170
    static let gap: CGFloat = 16
    private static let space = "overviewGrid"

    @State private var width: CGFloat = 0
    /// The tile being dragged, where it was grabbed, where the pointer is, and the last tile it
    /// swapped with — so hovering over a tile that has just slid away does not swap it straight back.
    @State private var drag: (kind: OverviewWidgetKind, grab: CGSize, point: CGPoint, lastHit: OverviewWidgetKind?)?
    /// The size a resize started from, so the grip's whole travel is measured from one place.
    @State private var resizing: (kind: OverviewWidgetKind, from: OverviewWidgetSize)?
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: OverviewLayoutStore { model.overviewLayout }

    private var columns: Int { max(1, Int((width + Self.gap) / (Self.minColumn + Self.gap))) }
    private var cellWidth: CGFloat { max(0, (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)) }

    private func frame(_ placement: OverviewPlacement) -> CGRect {
        CGRect(x: CGFloat(placement.column) * (cellWidth + Self.gap),
               y: CGFloat(placement.row) * (Self.rowHeight + Self.gap),
               width: CGFloat(placement.columns) * cellWidth + CGFloat(placement.columns - 1) * Self.gap,
               height: CGFloat(placement.rows) * Self.rowHeight + CGFloat(placement.rows - 1) * Self.gap)
    }

    /// The cell under a point in the grid's own coordinates.
    private func cell(at point: CGPoint) -> (column: Int, row: Int) {
        (min(columns - 1, max(0, Int(point.x / (cellWidth + Self.gap)))),
         max(0, Int(point.y / (Self.rowHeight + Self.gap))))
    }

    var body: some View {
        let layout = store.layout
        let placements = layout.placements(columns: columns)
        let rows = layout.rowCount(columns: columns)
        let height = rows > 0 ? CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.gap : 0
        let dropTop = height + (rows > 0 ? Self.gap : 0)
        ZStack(alignment: .topLeading) {
            ForEach(placements, id: \.kind) { placement in
                if let widget = layout.widgets.first(where: { $0.kind == placement.kind }) {
                    tile(widget, at: frame(placement))
                }
            }
            if editing {
                dropBand
                    .frame(width: max(0, width), height: 64)
                    .offset(y: dropTop)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: editing ? dropTop + 64 : height, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .coordinateSpace(.named(Self.space))
        // From the Add Widgets panel: dropped on a tile, it takes that tile's place; anywhere else,
        // it goes last.
        .dropDestination(for: String.self) { items, location in
            guard editing, let kind = items.compactMap(OverviewWidgetKind.init(rawValue:)).first else { return false }
            let target = cell(at: location)
            let index = store.layout.insertionIndex(column: target.column, row: target.row, columns: columns)
            store.update { $0.add(kind, at: index) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: layout)
    }

    private var dropBand: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(dropTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            .overlay {
                Text("Drop a widget here, or click + in Add Widgets")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func tile(_ widget: OverviewWidget, at rect: CGRect) -> some View {
        let kind = widget.kind
        let dragged = drag?.kind == kind
        let origin = dragged ? CGPoint(x: drag!.point.x - drag!.grab.width, y: drag!.point.y - drag!.grab.height)
                             : rect.origin
        OverviewWidgetContent(model: model, widget: widget, editing: editing, go: go,
                              onClose: { store.update { $0.remove(kind) } }) {
            OverviewSizeControl(widget: widget) { size in store.update { $0.resize(kind, to: size) } }
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(alignment: .topTrailing) {
            if editing {
                Button { store.update { $0.remove(kind) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
                .help("Remove \(kind.title)")
                .accessibilityLabel("Remove \(kind.title)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editing, kind.sizes.count > 1 {
                ResizeGrip()
                    .frame(width: 14, height: 14)
                    .padding(6)
                    .contentShape(Rectangle())
                    .help("Drag to resize")
                    // The size control and VoiceOver's Change Size do this without a pointer.
                    .accessibilityHidden(true)
                    .gesture(resizeGesture(widget))
            }
        }
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dragged ? Theme.accent : Color.clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(dragged ? 1.02 : 1)
        .rotationEffect(.degrees(dragged && !reduceMotion ? 1.5 : 0))
        .shadow(color: .black.opacity(dragged ? 0.22 : 0), radius: 18, y: 10)
        .offset(x: origin.x, y: origin.y)
        .zIndex(dragged ? 1 : 0)
        .gesture(moveGesture(kind, rect: rect), including: editing ? .all : .subviews)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.title) widget, \(widget.size.title)")
        .accessibilityActions { arrangeActions(widget) }
        .contextMenu { arrangeActions(widget) }
    }

    /// Move Earlier, Move Later, Change Size and Remove — for VoiceOver and the right-click alike,
    /// so moving a widget never needs a drag.
    @ViewBuilder
    private func arrangeActions(_ widget: OverviewWidget) -> some View {
        let kind = widget.kind
        let index = store.layout.index(of: kind) ?? 0
        Button("Move Earlier") { store.update { $0.moveEarlier(kind) } }
            .disabled(index == 0)
        Button("Move Later") { store.update { $0.moveLater(kind) } }
            .disabled(index >= store.layout.widgets.count - 1)
        if kind.sizes.count > 1 {
            Button("Change Size") { store.update { $0.cycleSize(kind) } }
        }
        Divider()
        Button("Remove \(kind.title)") { store.update { $0.remove(kind) } }
    }

    private func moveGesture(_ kind: OverviewWidgetKind, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag?.kind != kind {
                    drag = (kind, CGSize(width: value.startLocation.x - rect.minX, height: value.startLocation.y - rect.minY),
                            value.location, nil)
                }
                drag?.point = value.location
                reorder(kind, toward: value.location)
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { drag = nil }
            }
    }

    /// Takes the place of the tile under the pointer. The layout reflows round it on every swap, so
    /// tiles slide out of the way and nothing overlaps — the dragged one is drawn at the pointer
    /// until it is let go, then settles into its slot.
    private func reorder(_ kind: OverviewWidgetKind, toward point: CGPoint) {
        let target = cell(at: point)
        let hit = store.layout.placements(columns: columns)
            .first { $0.kind != kind && $0.contains(column: target.column, row: target.row) }?.kind
        guard hit != drag?.lastHit else { return }
        drag?.lastHit = hit
        guard let hit, let index = store.layout.index(of: hit) else { return }
        store.update { $0.move(kind, to: index) }
    }

    private func resizeGesture(_ widget: OverviewWidget) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if resizing?.kind != widget.kind { resizing = (widget.kind, widget.size) }
                guard let from = resizing?.from else { return }
                let columns = from.columns + Int((value.translation.width / (cellWidth + Self.gap)).rounded())
                let rows = from.rows + Int((value.translation.height / (Self.rowHeight + Self.gap)).rounded())
                let size = widget.kind.nearestSize(columns: columns, rows: rows)
                store.update { $0.resize(widget.kind, to: size) }
            }
            .onEnded { _ in resizing = nil }
    }
}

/// The size buttons in a tile's header while editing: S, Wide, Tall, L — only the ones it offers.
struct OverviewSizeControl: View {
    let widget: OverviewWidget
    let choose: (OverviewWidgetSize) -> Void

    var body: some View {
        if widget.kind.sizes.count > 1 {
            HStack(spacing: 2) {
                ForEach(widget.kind.sizes, id: \.self) { size in
                    Button(Self.short(size)) { choose(size) }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(size == widget.size ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                        .foregroundStyle(size == widget.size ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .help("\(size.title), \(size.columns)×\(size.rows)")
                        .accessibilityLabel(size.title)
                        .accessibilityAddTraits(size == widget.size ? .isSelected : [])
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }

    static func short(_ size: OverviewWidgetSize) -> String {
        switch size {
        case .small: "S"
        case .wide: "Wide"
        case .tall: "Tall"
        case .large: "L"
        }
    }
}

/// Three diagonal strokes in the corner, the way a resizable window's corner reads.
struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            for step in 1...3 {
                let inset = size.width * CGFloat(step) / 3.5
                var path = Path()
                path.move(to: CGPoint(x: size.width, y: size.height - inset))
                path.addLine(to: CGPoint(x: size.width - inset, y: size.height))
                context.stroke(path, with: .style(.secondary), lineWidth: 1.2)
            }
        }
    }
}

// MARK: - Add Widgets

/// The panel on the right while editing: every widget not on the page, each with + and draggable
/// onto the grid.
struct AddWidgetsPanel: View {
    let store: OverviewLayoutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Widgets").font(.headline)
            Text("Click + or drag one onto the Overview.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.layout.missing) { kind in item(kind) }
                    if store.layout.missing.isEmpty {
                        Text("Every widget is on the Overview.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func item(_ kind: OverviewWidgetKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(kind.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            IconActionButton(systemImage: "plus", label: "Add \(kind.title)",
                             help: "Add \(kind.title) to the Overview") {
                store.update { $0.add(kind) }
            }
        }
        .padding(8)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
        .draggable(kind.rawValue) {
            Label(kind.title, systemImage: kind.systemImage)
                .padding(8)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Empty

/// No widgets (Get started aside): one-click adds and the recommended layout, as FirstRun draws it.
struct OverviewEmptyState: View {
    let store: OverviewLayoutStore

    private var picks: [OverviewWidgetKind] {
        OverviewLayout.recommended.kinds.filter { $0 != .getStarted && !store.layout.contains($0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Make the Overview yours").font(.title3.weight(.semibold))
            Text("Add the widgets you want to see first. Drag them to arrange them; Flotilla keeps the layout for next time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 440)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(picks) { kind in
                    Button { store.update { $0.add(kind) } } label: {
                        Label(kind.title, systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .help("Add \(kind.title)")
                }
            }
            .frame(maxWidth: 620)
            Button("Use the recommended layout") {
                store.update { layout in
                    // Keeps Get started where it is: this is about the widgets, not the welcome.
                    let keepsGetStarted = layout.contains(.getStarted)
                    layout = .recommended(includingGetStarted: keepsGetStarted)
                }
            }
            .buttonStyle(.link)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("No widgets")
    }
}
