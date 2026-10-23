import Foundation

/// A widget's footprint on the Overview's grid (DECISIONS Q67): Small 1×1, Wide 2×1, Tall 1×2
/// and Large 2×2. Four, and no free-form spans. Since round 3 (Kamal) **every widget offers all
/// four**, each drawing its own layout of the same data at each, not a crop of one.
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

/// What a widget shows (Q67, round 3): the subset or the view of its data the owner picked from
/// the widget's ⋯ menu. One flat set of words, each a storage value, so `defaults read` stays
/// legible; which of them a widget offers is `OverviewWidgetKind.shows`. Every choice is a filter
/// or an ordering of data the app already has — none adds a command or a poll.
public enum OverviewWidgetShow: String, CaseIterable, Sendable, Hashable {
    // Shared
    case all
    case running
    // Containers
    case stopped, byHost
    // Hosts
    case problems, thisSite
    // Images
    case newest, largest, vulnerable
    // Activity (also `problems`)
    case everything, thisMac
    // Vulnerabilities
    case totals, worst
    // Fleet at a glance
    case counts, load, both
    // Kubernetes
    case ready
    // DNS
    case forContainers
    // Networks
    case userDefined
    // Tasks: `all` and `running`. Suggestions:
    case stacks, apps

    /// The word in the ⋯ menu and after the widget's title — "Containers · Stopped".
    public var title: String {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .stopped: "Stopped"
        case .byHost: "By Host"
        case .problems: "Problems"
        case .thisSite: "This Mac's Site"
        case .newest: "Newest"
        case .largest: "Largest"
        case .vulnerable: "With Vulnerabilities"
        case .everything: "Everything"
        case .thisMac: "This Mac Only"
        case .totals: "Totals"
        case .worst: "Worst Images"
        case .counts: "Counts"
        case .load: "Load"
        case .both: "Counts and Load"
        case .ready: "Ready"
        case .forContainers: "For Containers"
        case .userDefined: "User-Defined"
        case .stacks: "Stacks"
        case .apps: "Apps"
        }
    }
}

/// Every widget the Overview can show. The notifications band is **not** one (Kamal, 23 October):
/// it is fixed above the grid and cannot be removed or moved, so it has no case here. Nor is Get
/// started (Kamal, round 2): it is the full-width card under the band again, closed with its own X.
/// A saved layout that still names `getStarted` decodes without it, as any unknown widget does.
///
/// Declaration order is the order the Add Widgets panel lists them in. A kind is a *kind*: since
/// round 3 the page may hold several of one (`OverviewWidget.id`).
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

    /// Every size, for every widget (Kamal, round 3) — smallest first, the order the size control
    /// and Change Size step through.
    public var sizes: [OverviewWidgetSize] { OverviewWidgetSize.allCases }

    /// The size it is added at, and the one the recommended layout uses — round 2's, unchanged, so
    /// the recommended page looks as it did.
    public var defaultSize: OverviewWidgetSize {
        switch self {
        case .fleet: .wide
        case .hosts: .large
        case .containers, .activity: .tall
        default: .small
        }
    }

    /// What the widget's ⋯ menu offers, in menu order; empty for a widget with no meaningful
    /// second choice (Storage), which then draws no Show menu at all.
    public var shows: [OverviewWidgetShow] {
        switch self {
        case .containers: [.running, .all, .stopped, .byHost]
        case .hosts: [.all, .problems, .thisSite]
        case .images: [.newest, .largest, .vulnerable]
        case .activity: [.everything, .problems, .thisMac]
        case .vulnerabilities: [.totals, .worst]
        case .fleet: [.counts, .load, .both]
        case .machines, .tasks: [.all, .running]
        case .kubernetes: [.all, .ready]
        case .dns: [.all, .forContainers]
        case .networks: [.all, .userDefined]
        case .suggestions: [.stacks, .apps]
        case .storage: []
        }
    }

    /// What a widget shows when nobody has chosen — what it showed in round 2, so a migrated page
    /// draws the same thing. Containers is All, as round 2's list was, though Running leads the menu.
    public var defaultShow: OverviewWidgetShow? {
        switch self {
        case .containers: .all
        case .fleet: .both
        case .suggestions: .stacks
        default: shows.first
        }
    }

    /// The size nearest a footprint of `columns` × `rows` — what the resize grip lands on. Ties go
    /// to the smaller size.
    public func nearestSize(columns: Int, rows: Int) -> OverviewWidgetSize {
        sizes.min { a, b in
            let da = abs(a.columns - columns) + abs(a.rows - rows)
            let db = abs(b.columns - columns) + abs(b.rows - rows)
            return da != db ? da < db : a.columns * a.rows < b.columns * b.rows
        } ?? defaultSize
    }
}

/// One widget on the page: which instance, of which kind, how big, and showing what.
///
/// **An instance, not a kind** (round 3): Containers · Running and Containers · Stopped are two
/// widgets. `id` is a short word, not a UUID — the kind's own name for the first of a kind and
/// `containers-2`, `containers-3` after it — so the plist stays readable, the recommended layout is
/// one fixed value (Reset to Recommended can tell it has nothing to do), and a round-2 layout, which
/// had one of each, migrates to the ids it would have been given.
public struct OverviewWidget: Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: OverviewWidgetKind
    public var size: OverviewWidgetSize
    /// Always one of `kind.shows`, or nil for a widget that offers none.
    public private(set) var show: OverviewWidgetShow?

    public init(_ kind: OverviewWidgetKind, _ size: OverviewWidgetSize? = nil,
                show: OverviewWidgetShow? = nil, id: String? = nil) {
        self.id = id ?? kind.rawValue
        self.kind = kind
        self.size = size ?? kind.defaultSize
        self.show = show.flatMap { kind.shows.contains($0) ? $0 : nil } ?? kind.defaultShow
    }

    /// Sets a choice the widget offers; anything else is ignored.
    public mutating func setShow(_ choice: OverviewWidgetShow) {
        if kind.shows.contains(choice) { show = choice }
    }

    /// "Containers", or "Containers · Stopped" once the owner has picked something other than the
    /// default — the header says what the widget is counting.
    public var title: String {
        guard let show, show != kind.defaultShow else { return kind.title }
        return "\(kind.title) · \(show.title)"
    }
}

/// Where a widget lands on a grid of a given width, in cells.
public struct OverviewPlacement: Hashable, Sendable {
    public let id: String
    public let kind: OverviewWidgetKind
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public func contains(column c: Int, row r: Int) -> Bool {
        (column..<column + columns).contains(c) && (row..<row + rows).contains(r)
    }
}

/// The Overview's widgets, in order, with their sizes and choices (DECISIONS Q67) — user content,
/// kept per Mac.
///
/// **An order, not coordinates.** The grid adds columns on a wider window, so a widget's cell on
/// one display is meaningless on another; what survives a resize, a second display and a relaunch
/// is the order, the sizes and the choices. `placements(columns:)` packs them for whatever width
/// there is, so nothing ever overlaps and a drag only ever changes the order.
///
/// Foundation-only and pure, like `TagBook`: every rule — add, remove, resize, show, move, reset,
/// reflow, and what a hand-edited or round-2 plist turns into — is here, where the tests can pin
/// it on Linux. `OverviewLayoutStore` in the app persists it.
public struct OverviewLayout: Equatable, Sendable {
    public private(set) var widgets: [OverviewWidget]

    /// Takes the widgets in order. An id already used is replaced with a fresh one, so two
    /// instances can never answer to one id.
    public init(_ widgets: [OverviewWidget] = []) {
        self.widgets = []
        for widget in widgets {
            self.widgets.append(contains(id: widget.id)
                ? OverviewWidget(widget.kind, widget.size, show: widget.show, id: nextID(for: widget.kind))
                : widget)
        }
    }

    /// For a new Mac: Fleet at a glance, Hosts, Containers, Vulnerabilities, Activity, Machines and
    /// Kubernetes (Kamal, 23 October), each at its default size and default choice. Get started is
    /// not in it: it is the card above the grid, not a widget (Kamal, round 2).
    public static let recommended = OverviewLayout(
        [.fleet, .hosts, .containers, .vulnerabilities, .activity, .machines, .kubernetes]
            .map { OverviewWidget($0) })

    public var kinds: [OverviewWidgetKind] { widgets.map(\.kind) }
    public var isEmpty: Bool { widgets.isEmpty }

    public func contains(_ kind: OverviewWidgetKind) -> Bool { widgets.contains { $0.kind == kind } }
    public func contains(id: String) -> Bool { widgets.contains { $0.id == id } }
    /// How many instances of `kind` are on the page — the Add Widgets row's "2 on the Overview".
    public func count(of kind: OverviewWidgetKind) -> Int { widgets.count { $0.kind == kind } }
    /// The kinds with at least one instance on the page, in `OverviewWidgetKind` order: the ticked
    /// rows of the Add Widgets panel (round 4).
    public var kindsPlaced: [OverviewWidgetKind] { OverviewWidgetKind.allCases.filter(contains) }
    public func index(of id: String) -> Int? { widgets.firstIndex { $0.id == id } }
    public func widget(_ id: String) -> OverviewWidget? { widgets.first { $0.id == id } }

    /// What the Add Widgets panel lists: every kind, always — a kind already on the page can be
    /// added again with another choice (round 3).
    public var addable: [OverviewWidgetKind] { OverviewWidgetKind.allCases }

    /// The id a new instance of `kind` gets: the kind's name if free, else the first free
    /// `kind-2`, `kind-3`…
    public func nextID(for kind: OverviewWidgetKind) -> String {
        if !contains(id: kind.rawValue) { return kind.rawValue }
        var n = 2
        while contains(id: "\(kind.rawValue)-\(n)") { n += 1 }
        return "\(kind.rawValue)-\(n)"
    }

    // MARK: Editing

    /// Adds a new instance of `kind` at `index` (the end when nil), at its default size and choice
    /// unless others are given. Always a new widget, even when the kind is already on the page.
    /// Returns its id.
    @discardableResult
    public mutating func add(_ kind: OverviewWidgetKind, at index: Int? = nil, size: OverviewWidgetSize? = nil,
                             show: OverviewWidgetShow? = nil) -> String {
        let widget = OverviewWidget(kind, size, show: show, id: nextID(for: kind))
        let at = min(max(index ?? widgets.count, 0), widgets.count)
        widgets.insert(widget, at: at)
        return widget.id
    }

    public mutating func remove(_ id: String) {
        widgets.removeAll { $0.id == id }
    }

    /// Removes every instance of `kind` — unticking its row in Add Widgets (round 4).
    public mutating func removeAll(_ kind: OverviewWidgetKind) {
        widgets.removeAll { $0.kind == kind }
    }

    public mutating func resize(_ id: String, to size: OverviewWidgetSize) {
        guard let i = index(of: id) else { return }
        widgets[i].size = size
    }

    /// The next size, wrapping — VoiceOver's Change Size.
    public mutating func cycleSize(_ id: String) {
        guard let widget = widget(id), let at = widget.kind.sizes.firstIndex(of: widget.size) else { return }
        resize(id, to: widget.kind.sizes[(at + 1) % widget.kind.sizes.count])
    }

    /// Sets what the widget shows; a choice its kind does not offer is ignored rather than coerced.
    public mutating func setShow(_ id: String, to choice: OverviewWidgetShow) {
        guard let i = index(of: id) else { return }
        widgets[i].setShow(choice)
    }

    /// The next choice it offers, wrapping — VoiceOver's Change What It Shows.
    public mutating func cycleShow(_ id: String) {
        guard let widget = widget(id), let show = widget.show,
              let at = widget.kind.shows.firstIndex(of: show) else { return }
        setShow(id, to: widget.kind.shows[(at + 1) % widget.kind.shows.count])
    }

    /// Moves the widget so it ends up at `index` in the order, clamped to the ends.
    public mutating func move(_ id: String, to index: Int) {
        guard let from = self.index(of: id) else { return }
        let widget = widgets.remove(at: from)
        widgets.insert(widget, at: min(max(index, 0), widgets.count))
    }

    /// One place earlier — VoiceOver's Move Earlier. A no-op at the start.
    public mutating func moveEarlier(_ id: String) {
        guard let i = index(of: id), i > 0 else { return }
        move(id, to: i - 1)
    }

    /// One place later — VoiceOver's Move Later. A no-op at the end.
    public mutating func moveLater(_ id: String) {
        guard let i = index(of: id), i < widgets.count - 1 else { return }
        move(id, to: i + 1)
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
                    result.append(OverviewPlacement(id: widget.id, kind: widget.kind, column: col, row: row,
                                                    columns: w, rows: h))
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
    public func insertionIndex(column: Int, row: Int, columns: Int, ignoring: String? = nil) -> Int {
        let hit = placements(columns: columns).first { $0.id != ignoring && $0.contains(column: column, row: row) }
        guard let hit, let index = index(of: hit.id) else {
            return widgets.count - (ignoring.map { contains(id: $0) } == true ? 1 : 0)
        }
        return index
    }

    // MARK: Storage

    /// Plist-native, for `defaults read`: an array of
    /// `["id": "containers-2", "widget": "containers", "size": "tall", "show": "stopped"]`, with no
    /// `show` for a widget that offers none.
    public var storage: [[String: String]] {
        widgets.map { widget in
            var entry = ["id": widget.id, "widget": widget.kind.rawValue, "size": widget.size.rawValue]
            if let show = widget.show { entry["show"] = show.rawValue }
            return entry
        }
    }

    /// Reads `storage` back. The plist is hand-editable, so this takes what it can: an unknown
    /// widget is dropped, a size or choice it does not know (or none) becomes the default, and a
    /// missing or repeated id gets a fresh one — a widget you asked for is better than a page that
    /// refused to load.
    ///
    /// **A round-2 layout** has no `id` and no `show` and held one of each kind; it loads in the
    /// same order at the same sizes, each with the default choice and its kind's name as its id.
    public init(storage: [[String: String]]) {
        var layout = OverviewLayout()
        for entry in storage {
            guard let kind = entry["widget"].flatMap(OverviewWidgetKind.init(rawValue:)) else { continue }
            let size = entry["size"].flatMap(OverviewWidgetSize.init(rawValue:))
            let show = entry["show"].flatMap(OverviewWidgetShow.init(rawValue:))
            let stored = entry["id"].map { $0.trimmingCharacters(in: .whitespaces) }
            let id = stored.flatMap { !$0.isEmpty && !layout.contains(id: $0) ? $0 : nil } ?? layout.nextID(for: kind)
            layout.widgets.append(OverviewWidget(kind, size, show: show, id: id))
        }
        self = layout
    }
}
