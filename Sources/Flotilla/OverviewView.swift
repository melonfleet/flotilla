import SwiftUI
import FlotillaCore

/// Overview — the fleet at a glance, made of widgets (DECISIONS Q67, Kamal, 23 October).
///
/// From the top: the notifications band, **fixed** — always first, never a widget, never removed
/// or moved (Kamal's change to the mockups: it does the job their "Needs attention" widget did) —
/// then Get started, the full-width card it always was (not a widget — Kamal, round 2), then a grid
/// of widgets the owner chooses, orders, sizes and points at something (round 3).
///
/// **The grid adds columns on a wider window** rather than stretching tiles, so a full-screen window
/// on a big display fills with more widgets. A widget is Small 1×1, Wide 2×1, Tall 1×2 or Large
/// 2×2 — every widget offers all four, each its own layout (Kamal, round 3) — and shows what its ⋯
/// menu's Show says. The same kind may be on the page more than once, so a widget is an instance
/// with its own id. `OverviewLayout` packs them in order so nothing overlaps, and it is what is
/// remembered — per Mac, across launches, in `OverviewLayoutStore`.
///
/// **Moving needs no mode** (Kamal, round 2): hovering a widget shows a dot grip at its top left,
/// and dragging by it reorders the layout, the grid reflowing round it; a click anywhere else still
/// opens the section. **Edit Widgets** is for the rest — an ×, a size control and a resize grip on
/// every tile, the whole card draggable, and the Add Widgets panel on the right. VoiceOver gets Move
/// Earlier, Move Later, Change Size, Change What It Shows and Remove on every widget, in or out of
/// edit mode, and the right-click menu and the widget's ⋯ offer the same.
///
/// **Nothing here may be wider than the pane it is given.** The detail column of the window's split
/// takes any width its content insists on from the sidebar, so content that overflows collapses the
/// navigation (round 2's broken sidebar). Every flexible frame on the way down says `minWidth: 0`.
struct OverviewView: View {
    let model: AppModel
    /// The sections a widget opens filtered — owned by `MainWindowView`, which outlives this view.
    let containersUI: ContainersUIState
    let machinesUI: MachinesUIState
    let hostsUI: ResourceUIState<HostRow>
    let dnsUI: ResourceUIState<HostedDNS>
    let networksUI: ResourceUIState<HostedNetwork>
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
                            getStarted
                            OverviewGrid(model: model, editing: editing, go: open)
                            if !editing, store.layout.isEmpty {
                                OverviewEmptyState(store: store)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .padding(.top, 2)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                }
                // `minWidth: 0`: this pane narrows when the panel opens, whatever its content
                // last measured — without it the frame keeps the widest child and pushes the split.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if editing {
                    Divider()
                    AddWidgetsPanel(store: store)
                }
            }
        }
        // Every branch bounded: the grid's height is computed, the panel scrolls inside itself, and
        // this fills the pane rather than sizing to its content (the activity-strip lesson).
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// A widget's click: its section, set to the filter matching what the widget shows — All when
    /// the widget shows everything, so a filter left on from an earlier visit does not hide rows the
    /// widget just listed.
    private func open(_ link: OverviewLink) {
        switch link {
        case .section(let section):
            go(section)
        case .containers(let filter):
            containersUI.search = ""
            containersUI.kindFilter = .all
            containersUI.hostFilter = nil
            containersUI.filter = filter
            go(.containers)
        case .machines(let filter):
            machinesUI.search = ""
            machinesUI.filter = filter
            go(.machines)
        case .hosts(let filterID):
            hostsUI.search = ""
            hostsUI.filterID = filterID
            go(.hosts)
        case .dns(let filterID):
            dnsUI.search = ""
            dnsUI.filterID = filterID
            go(.dns)
        case .networks(let filterID):
            networksUI.search = ""
            networksUI.filterID = filterID
            go(.networks)
        case .suggestions(let tab):
            model.requestSuggestionsTab(tab)
        case .tasks:
            model.tasks.showList()
        }
    }

    // MARK: Header

    /// The band every page has under the window bar (horizontal 12, vertical 8 — `SectionToolbar`),
    /// with the Overview's two actions on one glass cluster, as `ActionCluster` draws everywhere.
    private var header: some View {
        HStack(spacing: 12) {
            // The words give way first: the actions on the right are always whole (round 2).
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            if editing {
                ActionCluster {
                    Button {
                        store.update { $0.reset() }
                    } label: {
                        Label("Reset to Recommended", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isRecommended)
                    .help("Put back Fleet at a glance, Hosts, Containers, Vulnerabilities, Activity, "
                          + "Machines and Kubernetes, at their usual sizes")
                    Button("Done") { editing = false }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Finish arranging the Overview")
                }
            } else {
                ActionCluster {
                    // Every kind, always, ticked when it is on the page: ticking adds it, unticking
                    // removes it, and there is never more than one of a kind (Kamal, 23 October).
                    Menu {
                        ForEach(store.layout.addable) { kind in
                            Toggle(isOn: Binding(
                                get: { store.layout.contains(kind) },
                                set: { on in store.update { if on { $0.add(kind) } else { $0.removeAll(kind) } } })) {
                                Label(kind.title, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Widget", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose which widgets are on the Overview")
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
        // Only Edit mode's instructions: when the page was updated, and from how many Macs, is in the
        // window's status bar beside the version (`FreshnessStatusItem`, Kamal, 23 October).
        editing ? "Drag a widget to move it · pick its size · ⋯ chooses what it shows · × removes it" : ""
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
            HStack {
                Label("Nothing needs attention", systemImage: "checkmark.circle")
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

    // MARK: Get started

    /// The first things to do (Iris, 8 October; Add Host, the owner). Shown once `container` is
    /// usable — until then the top line is its setup — and **until the owner closes it** with the X
    /// (the owner, 9 October), which records `getStartedDismissed` in the preferences domain.
    /// Nothing else hides it: having containers already does not.
    @AppStorage("getStartedDismissed") private var getStartedDismissed = false

    @ViewBuilder
    private var getStarted: some View {
        if !getStartedDismissed, model.runtimeUsable, model.state == .loaded {
            // A card of its own, centred, with the first step in colour (the owner, beta 2's
            // test): left-aligned plain buttons under a small heading read as a footnote.
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.info)
                VStack(spacing: 4) {
                    Text("Get started").font(.title2.weight(.semibold))
                    Text("Run your first container, bring in an image, or add another Mac.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button { model.requestRunSheet() } label: {
                        Label("Run a Container\u{2026}", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.requestPullForm() } label: {
                        Label("Pull Image\u{2026}", systemImage: "arrow.down.circle")
                    }
                    if model.hostMode.isAdmin {
                        Button { model.requestAddHost() } label: {
                            Label("Add Host\u{2026}", systemImage: "desktopcomputer")
                        }
                    }
                    Button { model.requestSuggestions(.containers) } label: {
                        Label("Try a Suggested Stack\u{2026}", systemImage: "square.grid.2x2")
                    }
                }
                .controlSize(.large)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            // A flotilla in faint line work behind it (the owner, 12 October); the card's colour
            // is unchanged.
            .background { FlotillaSeascape().clipShape(RoundedRectangle(cornerRadius: 12)) }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            // Closed for good, like after the first container (the owner, 9 October).
            .overlay(alignment: .topTrailing) {
                Button { getStartedDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Close Get started")
                .accessibilityLabel("Close Get started")
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
    /// All keyed by the widget's instance id, not its kind: two Containers widgets drag apart.
    @State private var drag: (id: String, grab: CGSize, point: CGPoint, lastHit: String?)?
    /// The size a resize started from, so the grip's whole travel is measured from one place.
    @State private var resizing: (id: String, from: OverviewWidgetSize)?
    @State private var dropTargeted = false
    /// The tile under the pointer, which shows its grip outside edit mode.
    @State private var hovered: String?
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
            ForEach(placements, id: \.id) { placement in
                if let widget = layout.widget(placement.id) {
                    tile(widget, drawn: Self.drawnSize(widget.size, placement), at: frame(placement))
                }
            }
            if editing {
                dropBand
                    .frame(width: max(0, width), height: 64)
                    .offset(y: dropTop)
            }
        }
        // `minWidth: 0` is load-bearing (round 2). The tiles are sized from `width`, which is
        // measured here; with only `maxWidth`, this frame is never narrower than its widest tile,
        // so the width it measures could grow and never shrink. Opening the Add Widgets panel then
        // left the grid at its old width, overflowing the pane — which pushed the header's Done off
        // screen, the panel past the window's edge, and the sidebar down to a sliver.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
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
                Text("Drop a widget here, or tick it in Add Widgets")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    /// The layout a tile draws: its own size, or the narrower one the grid gave it — a Wide on a
    /// one-column grid is drawn Small and a Large is drawn Tall, so no layout meets a width it was
    /// not written for.
    static func drawnSize(_ size: OverviewWidgetSize, _ placement: OverviewPlacement) -> OverviewWidgetSize {
        guard placement.columns < size.columns else { return size }
        return size.rows == 2 ? .tall : .small
    }

    @ViewBuilder
    private func tile(_ widget: OverviewWidget, drawn: OverviewWidgetSize, at rect: CGRect) -> some View {
        let id = widget.id
        let dragged = drag?.id == id
        let origin = dragged ? CGPoint(x: drag!.point.x - drag!.grab.width, y: drag!.point.y - drag!.grab.height)
                             : rect.origin
        OverviewWidgetContent(model: model, widget: widget, size: drawn, editing: editing, go: go)
        .frame(width: rect.width, height: rect.height)
        .overlay(alignment: .topTrailing) {
            if editing {
                Button { store.update { $0.remove(id) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -7)
                .help("Remove \(widget.title)")
                .accessibilityLabel("Remove \(widget.title)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editing {
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
            if editing || dragged {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(dragged ? Theme.accent : Color.clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        // The grip, in the tile's top-left corner: always while editing, on hover otherwise. It
        // sits in the tile's 16pt leading margin, beside the header, so it covers nothing. It is
        // an overlay — a sibling of the card, not inside it — so a click on it never reaches the
        // card's open-the-section tap, and the drag is its own gesture, so it works in normal mode.
        .overlay(alignment: .topLeading) {
            if editing || hovered == id || dragged {
                WidgetGrip()
                    .frame(width: 16, height: 30)
                    .contentShape(Rectangle())
                    .padding(.top, 7)
                    .pointerStyle(dragged ? .grabActive : .grabIdle)
                    .help("Drag to move")
                    // Move Earlier and Move Later do this without a pointer.
                    .accessibilityHidden(true)
                    .gesture(moveGesture(id, rect: rect))
            }
        }
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .scaleEffect(dragged ? 1.02 : 1)
        .rotationEffect(.degrees(dragged && !reduceMotion ? 1.5 : 0))
        .shadow(color: .black.opacity(dragged ? 0.22 : 0), radius: 18, y: 10)
        .offset(x: origin.x, y: origin.y)
        .zIndex(dragged ? 1 : 0)
        // While editing the whole card drags; otherwise only the grip does, and a click on the
        // rest of the card opens its section as before.
        .gesture(moveGesture(id, rect: rect), including: editing ? .all : .subviews)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(widget.title) widget, \(widget.size.title)")
        .accessibilityActions { arrangeActions(widget) }
        .contextMenu { arrangeActions(widget) }
    }

    /// Move Earlier, Move Later, Change Size, Change What It Shows and Remove — for VoiceOver and the
    /// right-click alike, so changing a widget never needs a drag.
    @ViewBuilder
    private func arrangeActions(_ widget: OverviewWidget) -> some View {
        let id = widget.id
        let index = store.layout.index(of: id) ?? 0
        Button("Move Earlier") { store.update { $0.moveEarlier(id) } }
            .disabled(index == 0)
        Button("Move Later") { store.update { $0.moveLater(id) } }
            .disabled(index >= store.layout.widgets.count - 1)
        Button("Change Size") { store.update { $0.cycleSize(id) } }
        if widget.kind.shows.count > 1 {
            Button("Change What It Shows") { store.update { $0.cycleShow(id) } }
        }
        Divider()
        Button("Remove \(widget.title)") { store.update { $0.remove(id) } }
    }

    private func moveGesture(_ id: String, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag?.id != id {
                    drag = (id, CGSize(width: value.startLocation.x - rect.minX, height: value.startLocation.y - rect.minY),
                            value.location, nil)
                }
                drag?.point = value.location
                reorder(id, toward: value.location)
            }
            .onEnded { _ in
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { drag = nil }
            }
    }

    /// Takes the place of the tile under the pointer. The layout reflows round it on every swap, so
    /// tiles slide out of the way and nothing overlaps — the dragged one is drawn at the pointer
    /// until it is let go, then settles into its slot.
    private func reorder(_ id: String, toward point: CGPoint) {
        let target = cell(at: point)
        let hit = store.layout.placements(columns: columns)
            .first { $0.id != id && $0.contains(column: target.column, row: target.row) }?.id
        guard hit != drag?.lastHit else { return }
        drag?.lastHit = hit
        guard let hit, let index = store.layout.index(of: hit) else { return }
        store.update { $0.move(id, to: index) }
    }

    private func resizeGesture(_ widget: OverviewWidget) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if resizing?.id != widget.id { resizing = (widget.id, widget.size) }
                guard let from = resizing?.from else { return }
                let columns = from.columns + Int((value.translation.width / (cellWidth + Self.gap)).rounded())
                let rows = from.rows + Int((value.translation.height / (Self.rowHeight + Self.gap)).rounded())
                let size = widget.kind.nearestSize(columns: columns, rows: rows)
                store.update { $0.resize(widget.id, to: size) }
            }
            .onEnded { _ in resizing = nil }
    }
}

/// The size buttons in a tile's header while editing — all four, for every widget (round 3). One
/// letter each, so the four fit beside the title on a Small tile; the tooltip says the size.
struct OverviewSizeControl: View {
    let size: OverviewWidgetSize
    let choose: (OverviewWidgetSize) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(OverviewWidgetSize.allCases, id: \.self) { option in
                Button(Self.short(option)) { choose(option) }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(option == size ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                    .foregroundStyle(option == size ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .help("\(option.title), \(option.columns)×\(option.rows)")
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(option == size ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .fixedSize()
    }

    static func short(_ size: OverviewWidgetSize) -> String {
        switch size {
        case .small: "S"
        case .wide: "W"
        case .tall: "T"
        case .large: "L"
        }
    }
}

/// The move handle: a 2×3 grid of dots, the grip dashboards use (Kamal, round 2). Not ≡, which reads
/// as a menu that opens something. Drawn, because SF Symbols has no 2×3 dot grid —
/// `circle.grid.2x3` is not a symbol (checked with `NSImage(systemSymbolName:)`), and an unknown
/// name renders nothing.
struct WidgetGrip: View {
    var body: some View {
        Canvas { context, size in
            let dot: CGFloat = 2.5
            let step: CGFloat = 4.5
            let origin = CGPoint(x: (size.width - dot - step) / 2, y: (size.height - dot - 2 * step) / 2)
            for column in 0..<2 {
                for row in 0..<3 {
                    let rect = CGRect(x: origin.x + CGFloat(column) * step, y: origin.y + CGFloat(row) * step,
                                      width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .style(.secondary))
                }
            }
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

/// The panel on the right while editing: every kind of widget, always, in kind order — including
/// ones already on the page, which can be added again (round 3) — each draggable onto the grid.
///
/// Each row's checkbox is ticked while at least one instance of its kind is on the page (round 4):
/// ticking adds one at the end, as + does; unticking removes every instance. Both read and write
/// `store.layout`, so a tile's × or a drag-in moves the box with no state of the panel's own. The
/// Overview has no undo manager, so unticking is not undoable; there is no undo anywhere else on
/// the page to be consistent with.
struct AddWidgetsPanel: View {
    let store: OverviewLayoutStore

    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Widgets").font(.headline)
            Text("Tick a widget to put it on the Overview, or drag it there. Untick it to take it off.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.layout.addable) { kind in item(kind) }
                }
            }
        }
        .padding(16)
        // Fixed, and the grid's pane is the one that gives way (`minWidth: 0` there), so the panel
        // is always whole inside the window.
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func item(_ kind: OverviewWidgetKind) -> some View {
        let count = store.layout.count(of: kind)
        return HStack(spacing: 10) {
            Toggle("Show \(kind.title) on the Overview", isOn: Binding(
                get: { count > 0 },
                set: { on in
                    store.update { if on { $0.add(kind) } else { $0.removeAll(kind) } }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(count == 0 ? "Add \(kind.title) to the Overview" : "Remove \(kind.title) from the Overview")
                .accessibilityLabel("Show \(kind.title) on the Overview")
            Image(systemName: kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            // Takes the row's spare width, so a long summary wraps to its second line inside the
            // panel rather than pushing the + past it (round 2).
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                // More than one on the page: the subtitle says how many, because unticking takes
                // them all (round 4).
                Text(kind.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

/// No widgets: one-click adds and the recommended layout, as FirstRun draws it.
struct OverviewEmptyState: View {
    let store: OverviewLayoutStore

    private var picks: [OverviewWidgetKind] {
        OverviewLayout.recommended.kinds.filter { !store.layout.contains($0) }
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
                store.update { $0.reset() }
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
