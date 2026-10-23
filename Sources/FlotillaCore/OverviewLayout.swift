import Foundation

/// A widget's footprint on the Overview's grid (DECISIONS Q67): Small 1×1, Wide 2×1, Tall 1×2
/// and Large 2×2. Four, and no free-form spans: a size is a promise about what the widget can
/// show, and each widget offers only the sizes where it has more to show (`OverviewWidgetKind.sizes`).
///
/// The raw values are the storage format, read back by `defaults read dev.melonfleet.Flotilla
/// overviewLayout`, so they are words, not spans.
public enum OverviewWidgetSize: String, CaseIterable, Sendable, Hashable {
    case small, wide, tall, large

    public var columns: Int { self == .wide || self == .large ? 2 : 1 }
    public var rows: Int { self == .tall || self == .large ? 2 : 1 }

    public var title: String {
        switch self {
        case .small: "Small"
        case .wide: "Wide"
        case .tall: "Tall"
        case .large: "Large"
        }
    }
}

/// Every widget the Overview can show. The notifications band is **not** one (Kamal, 23 October):
/// it is fixed above the grid and cannot be removed or moved, so it has no case here. Nor is Get
/// started (Kamal, round 2): it is the full-width card under the band again, closed with its own X.
/// A saved layout that still names `getStarted` decodes without it, as any unknown widget does.
///
/// Declaration order is the order the Add Widgets panel lists them in.
public enum OverviewWidgetKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case fleet, hosts, containers, vulnerabilities, activity, machines, kubernetes
    case dns, storage, tasks, images, networks, suggestions

    public var id: Self { self }

    public var title: String {
        switch self {
        case .fleet: "Fleet at a glance"
        case .hosts: "Hosts"
        case .containers: "Containers"
        case .vulnerabilities: "Vulnerabilities"
        case .activity: "Activity"
        case .machines: "Machines"
        case .kubernetes: "Kubernetes"
        case .dns: "DNS"
        case .storage: "Storage"
        case .tasks: "Tasks"
        case .images: "Images"
        case .networks: "Networks"
        case .suggestions: "Suggestions"
        }
    }

    /// The Add Widgets panel's line under the title.
    public var summary: String {
        switch self {
        case .fleet: "Every count, plus CPU, memory and disk"
        case .hosts: "Each Mac, its state and its load"
        case .containers: "What's running"
        case .vulnerabilities: "What the daily report found in your images"
        case .activity: "What changed today"
        case .machines: "Machines and their state"
        case .kubernetes: "Clusters and whether they're ready"
        case .dns: "Domains and their names"
        case .storage: "Images and volumes on disk"
        case .tasks: "Jobs running and just finished"
        case .images: "Newest pulls and sizes"
        case .networks: "Networks and who's on them"
        case .suggestions: "A few picks for this Mac"
        }
    }

    /// The sizes this widget offers, smallest first — only those where it has more to show
    /// (`WidgetSizes` in the 23 October mockups). A widget with one size draws no size control.
    public var sizes: [OverviewWidgetSize] {
        switch self {
        case .fleet: [.small, .wide, .large]
        case .hosts: [.wide, .large]
        case .suggestions: [.small, .wide]
        case .dns, .storage: [.small]
        case .containers, .vulnerabilities, .activity, .machines, .kubernetes, .tasks, .images, .networks:
            [.small, .tall]
        }
    }

    /// The size it is added at, and the one the recommended layout uses.
    public var defaultSize: OverviewWidgetSize {
        switch self {
        case .fleet: .wide
        case .hosts: .large
        case .containers, .activity: .tall
        default: sizes[0]
        }
    }

    /// The allowed size nearest a footprint of `columns` × `rows` — what the resize grip lands on.
    /// Ties go to the smaller size, so a grip that has barely moved leaves the widget as it was
    /// only when it was already the smaller one.
    public func nearestSize(columns: Int, rows: Int) -> OverviewWidgetSize {
        sizes.min { a, b in
            let da = abs(a.columns - columns) + abs(a.rows - rows)
            let db = abs(b.columns - columns) + abs(b.rows - rows)
            return da != db ? da < db : a.columns * a.rows < b.columns * b.rows
        } ?? defaultSize
    }
}

/// One widget on the page: which, and how big.
public struct OverviewWidget: Hashable, Sendable, Identifiable {
    public let kind: OverviewWidgetKind
    public var size: OverviewWidgetSize

    public var id: OverviewWidgetKind { kind }

    public init(_ kind: OverviewWidgetKind, _ size: OverviewWidgetSize? = nil) {
        self.kind = kind
        let wanted = size ?? kind.defaultSize
        self.size = kind.sizes.contains(wanted) ? wanted : kind.defaultSize
    }
}

/// Where a widget lands on a grid of a given width, in cells.
public struct OverviewPlacement: Hashable, Sendable {
    public let kind: OverviewWidgetKind
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public func contains(column c: Int, row r: Int) -> Bool {
        (column..<column + columns).contains(c) && (row..<row + rows).contains(r)
    }
}

/// The Overview's widgets, in order, with their sizes (DECISIONS Q67) — user content, kept per Mac.
///
/// **An order, not coordinates.** The grid adds columns on a wider window, so a widget's cell on
/// one display is meaningless on another; what survives a resize, a second display and a relaunch
/// is the order and the sizes. `placements(columns:)` packs them for whatever width there is, so
/// nothing ever overlaps and a drag only ever changes the order.
///
/// Foundation-only and pure, like `TagBook`: every rule — add, remove, resize, move, reset, reflow,
/// and what a hand-edited plist turns into — is here, where the tests can pin it on Linux.
/// `OverviewLayoutStore` in the app persists it.
public struct OverviewLayout: Equatable, Sendable {
    public private(set) var widgets: [OverviewWidget]

    public init(_ widgets: [OverviewWidget] = []) {
        var seen = Set<OverviewWidgetKind>()
        // One of each: a second Hosts widget is the same widget twice.
        self.widgets = widgets.filter { seen.insert($0.kind).inserted }
    }

    /// For a new Mac: Fleet at a glance, Hosts, Containers, Vulnerabilities, Activity, Machines and
    /// Kubernetes (Kamal, 23 October), each at its default size. Get started is not in it: it is
    /// the card above the grid, not a widget (Kamal, round 2).
    public static let recommended = OverviewLayout(
        [.fleet, .hosts, .containers, .vulnerabilities, .activity, .machines, .kubernetes]
            .map { OverviewWidget($0) })

    public var kinds: [OverviewWidgetKind] { widgets.map(\.kind) }
    public var isEmpty: Bool { widgets.isEmpty }

    public func contains(_ kind: OverviewWidgetKind) -> Bool { widgets.contains { $0.kind == kind } }
    public func index(of kind: OverviewWidgetKind) -> Int? { widgets.firstIndex { $0.kind == kind } }
    public func size(of kind: OverviewWidgetKind) -> OverviewWidgetSize? { widgets.first { $0.kind == kind }?.size }

    /// What the Add Widgets panel lists: everything not on the page, in declaration order.
    public var missing: [OverviewWidgetKind] { OverviewWidgetKind.allCases.filter { !contains($0) } }

    // MARK: Editing

    /// Adds `kind` at `index` (the end when nil), at its default size unless `size` is one it
    /// offers. Adding a widget already on the page moves it there instead of duplicating it.
    public mutating func add(_ kind: OverviewWidgetKind, at index: Int? = nil, size: OverviewWidgetSize? = nil) {
        let existing = self.index(of: kind).map { widgets.remove(at: $0) }
        var widget = existing ?? OverviewWidget(kind, size)
        if let size, kind.sizes.contains(size) { widget.size = size }
        let at = min(max(index ?? widgets.count, 0), widgets.count)
        widgets.insert(widget, at: at)
    }

    public mutating func remove(_ kind: OverviewWidgetKind) {
        widgets.removeAll { $0.kind == kind }
    }

    /// Sets a size the widget offers; anything else is ignored rather than coerced, so a stale
    /// control can never give a widget a footprint it has nothing to fill.
    public mutating func resize(_ kind: OverviewWidgetKind, to size: OverviewWidgetSize) {
        guard kind.sizes.contains(size), let i = index(of: kind) else { return }
        widgets[i].size = size
    }

    /// The next size it offers, wrapping — VoiceOver's Change Size.
    public mutating func cycleSize(_ kind: OverviewWidgetKind) {
        guard let current = size(of: kind), let at = kind.sizes.firstIndex(of: current) else { return }
        resize(kind, to: kind.sizes[(at + 1) % kind.sizes.count])
    }

    /// Moves `kind` so it ends up at `index` in the order, clamped to the ends.
    public mutating func move(_ kind: OverviewWidgetKind, to index: Int) {
        guard let from = self.index(of: kind) else { return }
        let widget = widgets.remove(at: from)
        widgets.insert(widget, at: min(max(index, 0), widgets.count))
    }

    /// One place earlier — VoiceOver's Move Earlier. A no-op at the start.
    public mutating func moveEarlier(_ kind: OverviewWidgetKind) {
        guard let i = index(of: kind), i > 0 else { return }
        move(kind, to: i - 1)
    }

    /// One place later — VoiceOver's Move Later. A no-op at the end.
    public mutating func moveLater(_ kind: OverviewWidgetKind) {
        guard let i = index(of: kind), i < widgets.count - 1 else { return }
        move(kind, to: i + 1)
    }

    /// Reset to Recommended.
    public mutating func reset() { self = .recommended }

    // MARK: Reflow

    /// Packs the widgets onto a grid `columns` wide, in order, each into the first free spot that
    /// holds it — reading order, top to bottom — so nothing overlaps and a small widget fills a
    /// hole a large one left rather than leaving it empty. On a grid narrower than a widget, the
    /// widget is narrowed to the grid (a Large on one column is one column by two rows).
    public func placements(columns: Int) -> [OverviewPlacement] {
        let width = max(1, columns)
        var occupied: [[Bool]] = []
        func free(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            for row in r..<r + h where row < occupied.count {
                for col in c..<c + w where occupied[row][col] { return false }
            }
            return true
        }
        var result: [OverviewPlacement] = []
        for widget in widgets {
            let w = min(widget.size.columns, width)
            let h = widget.size.rows
            var row = 0
            search: while true {
                for col in 0...(width - w) where free(col, row, w, h) {
                    while occupied.count < row + h { occupied.append(Array(repeating: false, count: width)) }
                    for r in row..<row + h { for c in col..<col + w { occupied[r][c] = true } }
                    result.append(OverviewPlacement(kind: widget.kind, column: col, row: row, columns: w, rows: h))
                    break search
                }
                row += 1
            }
        }
        return result
    }

    /// How many rows `placements(columns:)` uses.
    public func rowCount(columns: Int) -> Int {
        placements(columns: columns).map { $0.row + $0.rows }.max() ?? 0
    }

    /// Where a widget dragged or dropped onto cell (`column`, `row`) goes in the order: the place
    /// of the widget under it, or the end when the cell is empty. `ignoring` is the one being
    /// dragged, which must not count as its own target.
    public func insertionIndex(column: Int, row: Int, columns: Int, ignoring: OverviewWidgetKind? = nil) -> Int {
        let hit = placements(columns: columns).first { $0.kind != ignoring && $0.contains(column: column, row: row) }
        guard let hit, let index = index(of: hit.kind) else {
            return widgets.count - (ignoring.map(contains) == true ? 1 : 0)
        }
        return index
    }

    // MARK: Storage

    /// Plist-native, for `defaults read`: an array of `["widget": "hosts", "size": "large"]`.
    public var storage: [[String: String]] {
        widgets.map { ["widget": $0.kind.rawValue, "size": $0.size.rawValue] }
    }

    /// Reads `storage` back. The plist is hand-editable, so this takes what it can: an unknown
    /// widget is dropped, a duplicate keeps its first place, and a size the widget does not offer
    /// (or none) becomes its default — a widget you asked for is better than a page that refused
    /// to load.
    public init(storage: [[String: String]]) {
        self.init(storage.compactMap { entry in
            guard let kind = entry["widget"].flatMap(OverviewWidgetKind.init(rawValue:)) else { return nil }
            return OverviewWidget(kind, entry["size"].flatMap(OverviewWidgetSize.init(rawValue:)))
        })
    }
}
