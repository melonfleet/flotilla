import Foundation
import Testing
@testable import FlotillaCore

/// Pins the modular Overview's layout (DECISIONS Q67): what is on the page, in what order and at
/// what size, how it packs onto a grid of any width, and what a hand-edited plist turns into.
@Suite("Overview layout")
struct OverviewLayoutTests {

    // MARK: Recommended

    @Test("the recommended layout is Kamal's list, in order, at default sizes")
    func recommendedOrder() {
        #expect(OverviewLayout.recommended.kinds == [.fleet, .hosts, .containers, .vulnerabilities,
                                                     .activity, .machines, .kubernetes])
        for widget in OverviewLayout.recommended.widgets {
            #expect(widget.size == widget.kind.defaultSize)
        }
    }

    @Test("Get started is the card above the grid, not a widget (round 2)")
    func getStartedIsNotAWidget() {
        #expect(OverviewWidgetKind(rawValue: "getStarted") == nil)
        #expect(OverviewLayout().missing.allSatisfy { $0.rawValue != "getStarted" })
    }

    @Test("a layout saved while Get started was a widget loads without it, keeping the rest")
    func savedGetStartedIsDropped() {
        let layout = OverviewLayout(storage: [
            ["widget": "getStarted", "size": "large"],
            ["widget": "fleet", "size": "large"],
            ["widget": "hosts", "size": "wide"],
        ])
        #expect(layout.kinds == [.fleet, .hosts])
        #expect(layout.size(of: .fleet) == .large)
        #expect(layout.size(of: .hosts) == .wide)
        // What the store writes back at load: the plist no longer names it.
        #expect(!layout.storage.contains { $0["widget"] == "getStarted" })
        #expect(OverviewLayout(storage: [["widget": "getStarted", "size": "wide"]]).isEmpty)
    }

    @Test("the notifications band is not a widget")
    func noAttentionWidget() {
        #expect(OverviewWidgetKind(rawValue: "attention") == nil)
        #expect(OverviewWidgetKind(rawValue: "needsAttention") == nil)
    }

    @Test("every widget's default size is one it offers, and each offers at least one")
    func sizesAreConsistent() {
        for kind in OverviewWidgetKind.allCases {
            #expect(!kind.sizes.isEmpty)
            #expect(kind.sizes.contains(kind.defaultSize), "\(kind)")
            #expect(Set(kind.sizes).count == kind.sizes.count, "\(kind)")
        }
    }

    // MARK: Editing

    @Test("add appends at the default size, and missing lists what is not on the page")
    func addAndMissing() {
        var layout = OverviewLayout()
        #expect(layout.missing == OverviewWidgetKind.allCases)
        layout.add(.dns)
        layout.add(.hosts)
        #expect(layout.kinds == [.dns, .hosts])
        #expect(layout.size(of: .hosts) == .large)
        #expect(!layout.missing.contains(.dns))
        #expect(layout.missing.count == OverviewWidgetKind.allCases.count - 2)
    }

    @Test("adding a widget already on the page moves it rather than duplicating it")
    func addIsUnique() {
        var layout = OverviewLayout.recommended
        layout.add(.kubernetes, at: 0)
        #expect(layout.kinds.first == .kubernetes)
        #expect(layout.kinds.filter { $0 == .kubernetes }.count == 1)
        #expect(layout.widgets.count == OverviewLayout.recommended.widgets.count)
    }

    @Test("add at an index clamps, and honours only a size the widget offers")
    func addAtIndexAndSize() {
        var layout = OverviewLayout([OverviewWidget(.fleet), OverviewWidget(.hosts)])
        layout.add(.tasks, at: 1, size: .tall)
        layout.add(.storage, at: 99, size: .large)
        layout.add(.images, at: -5)
        #expect(layout.kinds == [.images, .fleet, .tasks, .hosts, .storage])
        #expect(layout.size(of: .tasks) == .tall)
        #expect(layout.size(of: .storage) == .small)
    }

    @Test("remove takes the widget off and nothing else")
    func remove() {
        var layout = OverviewLayout.recommended
        layout.remove(.hosts)
        layout.remove(.dns)  // not on the page: a no-op
        #expect(!layout.contains(.hosts))
        #expect(layout.widgets.count == OverviewLayout.recommended.widgets.count - 1)
    }

    @Test("resize accepts only the sizes a widget offers")
    func resize() {
        var layout = OverviewLayout.recommended
        layout.resize(.containers, to: .small)
        #expect(layout.size(of: .containers) == .small)
        layout.resize(.containers, to: .large)
        #expect(layout.size(of: .containers) == .small)
        layout.resize(.dns, to: .small)  // not on the page
        #expect(!layout.contains(.dns))
    }

    @Test("cycleSize steps through the offered sizes and wraps")
    func cycleSize() {
        var layout = OverviewLayout([OverviewWidget(.fleet, .small), OverviewWidget(.storage)])
        layout.cycleSize(.fleet)
        #expect(layout.size(of: .fleet) == .wide)
        layout.cycleSize(.fleet)
        #expect(layout.size(of: .fleet) == .large)
        layout.cycleSize(.fleet)
        #expect(layout.size(of: .fleet) == .small)
        layout.cycleSize(.storage)
        #expect(layout.size(of: .storage) == .small)
    }

    @Test("move earlier and later step one place and stop at the ends")
    func moveSteps() {
        var layout = OverviewLayout([OverviewWidget(.fleet), OverviewWidget(.hosts), OverviewWidget(.dns)])
        layout.moveEarlier(.fleet)
        #expect(layout.kinds == [.fleet, .hosts, .dns])
        layout.moveLater(.fleet)
        #expect(layout.kinds == [.hosts, .fleet, .dns])
        layout.moveLater(.dns)
        #expect(layout.kinds == [.hosts, .fleet, .dns])
        layout.moveEarlier(.dns)
        #expect(layout.kinds == [.hosts, .dns, .fleet])
        layout.move(.hosts, to: 42)
        #expect(layout.kinds == [.dns, .fleet, .hosts])
    }

    @Test("reset restores the recommended layout")
    func reset() {
        var layout = OverviewLayout([OverviewWidget(.dns)])
        layout.reset()
        #expect(layout == .recommended)
    }

    @Test("the resize grip lands on the nearest offered size")
    func nearestSize() {
        #expect(OverviewWidgetKind.hosts.nearestSize(columns: 1, rows: 1) == .wide)
        #expect(OverviewWidgetKind.hosts.nearestSize(columns: 3, rows: 3) == .large)
        #expect(OverviewWidgetKind.containers.nearestSize(columns: 2, rows: 2) == .tall)
        #expect(OverviewWidgetKind.containers.nearestSize(columns: 2, rows: 1) == .small)
        #expect(OverviewWidgetKind.fleet.nearestSize(columns: 2, rows: 1) == .wide)
        #expect(OverviewWidgetKind.dns.nearestSize(columns: 2, rows: 2) == .small)
    }

    // MARK: Reflow

    /// Every cell is claimed at most once, on any width — the "no overlap" promise.
    private func assertNoOverlap(_ layout: OverviewLayout, columns: Int) {
        var cells = Set<[Int]>()
        for placement in layout.placements(columns: columns) {
            #expect(placement.column >= 0 && placement.column + placement.columns <= max(columns, 1))
            for r in placement.row..<placement.row + placement.rows {
                for c in placement.column..<placement.column + placement.columns {
                    #expect(cells.insert([c, r]).inserted, "overlap at \(c),\(r) on \(columns) columns")
                }
            }
        }
    }

    @Test("the recommended layout packs on four columns as the mockup draws it")
    func recommendedOnFour() {
        let placed = Dictionary(uniqueKeysWithValues: OverviewLayout.recommended.placements(columns: 4).map { ($0.kind, $0) })
        #expect(placed[.fleet].map { [$0.column, $0.row] } == [0, 0])
        #expect(placed[.hosts].map { [$0.column, $0.row, $0.columns, $0.rows] } == [2, 0, 2, 2])
        #expect(placed[.containers].map { [$0.column, $0.row, $0.rows] } == [0, 1, 2])
        #expect(placed[.vulnerabilities].map { [$0.column, $0.row] } == [1, 1])
        // Tall Containers holds column 0 through row 2, so Activity drops under Vulnerabilities and
        // the small ones fill the rest of row 2 under Hosts.
        #expect(placed[.activity].map { [$0.column, $0.row] } == [1, 2])
        #expect(placed[.machines].map { [$0.column, $0.row] } == [2, 2])
        #expect(placed[.kubernetes].map { [$0.column, $0.row] } == [3, 2])
        #expect(OverviewLayout.recommended.rowCount(columns: 4) == 4)
    }

    @Test("nothing overlaps on any width, and every widget is placed")
    func noOverlapAnyWidth() {
        let all = OverviewLayout(OverviewWidgetKind.allCases.map { OverviewWidget($0, $0.sizes.last) })
        for columns in 0...9 {
            assertNoOverlap(.recommended, columns: columns)
            assertNoOverlap(all, columns: columns)
            #expect(all.placements(columns: columns).count == OverviewWidgetKind.allCases.count)
        }
    }

    @Test("a wider window adds columns: the same layout takes fewer rows")
    func widerIsShorter() {
        let layout = OverviewLayout.recommended
        #expect(layout.rowCount(columns: 8) < layout.rowCount(columns: 4))
        #expect(layout.rowCount(columns: 4) < layout.rowCount(columns: 2))
    }

    @Test("on one column a two-wide widget is narrowed, keeping its height")
    func narrowedOnOneColumn() {
        let placed = OverviewLayout([OverviewWidget(.hosts, .large)]).placements(columns: 1)
        #expect(placed.first.map { [$0.columns, $0.rows] } == [1, 2])
    }

    @Test("a small widget fills the hole a wide one left")
    func fillsHoles() {
        // Three columns: Small at column 0, Large at columns 1–2 over rows 0–1. Wide cannot fit in
        // row 1's single free cell, so it goes to row 2 — and the Small after it takes that cell.
        let layout = OverviewLayout([OverviewWidget(.dns), OverviewWidget(.hosts, .large),
                                     OverviewWidget(.fleet, .wide), OverviewWidget(.storage)])
        let placed = Dictionary(uniqueKeysWithValues: layout.placements(columns: 3).map { ($0.kind, $0) })
        #expect(placed[.hosts].map { [$0.column, $0.row] } == [1, 0])
        #expect(placed[.fleet].map { [$0.column, $0.row] } == [0, 2])
        #expect(placed[.storage].map { [$0.column, $0.row] } == [0, 1])
    }

    @Test("a drop on a widget takes its place; on an empty cell, the end")
    func insertionIndex() {
        let layout = OverviewLayout.recommended
        #expect(layout.insertionIndex(column: 3, row: 1, columns: 4) == layout.index(of: .hosts))
        #expect(layout.insertionIndex(column: 3, row: 9, columns: 4) == layout.widgets.count)
        // Dragging Hosts over itself is not a target; over empty space it goes last.
        #expect(layout.insertionIndex(column: 3, row: 1, columns: 4, ignoring: .hosts) == layout.widgets.count - 1)
        #expect(layout.insertionIndex(column: 3, row: 9, columns: 4, ignoring: .hosts) == layout.widgets.count - 1)
        #expect(layout.insertionIndex(column: 0, row: 2, columns: 4, ignoring: .hosts) == layout.index(of: .containers))
    }

    // MARK: Storage

    @Test("the plist form round-trips")
    func roundTrip() {
        var layout = OverviewLayout.recommended
        layout.resize(.fleet, to: .large)
        layout.add(.suggestions, at: 2, size: .wide)
        #expect(OverviewLayout(storage: layout.storage) == layout)
        #expect(layout.storage.first == ["widget": "fleet", "size": "large"])
    }

    @Test("an empty plist is an empty page, not the recommended one")
    func emptyIsEmpty() {
        #expect(OverviewLayout(storage: []).isEmpty)
    }

    @Test("a hand-edited plist keeps what it can")
    func tolerantDecoding() {
        let layout = OverviewLayout(storage: [
            ["widget": "hosts", "size": "small"],      // not offered → default
            ["widget": "needsAttention", "size": "small"], // not a widget → dropped
            ["widget": "dns"],                           // no size → default
            ["widget": "hosts", "size": "wide"],         // duplicate → first kept
            ["size": "large"],                           // no widget → dropped
            ["widget": "containers", "size": "huge"],    // unknown size → default
        ])
        #expect(layout.kinds == [.hosts, .dns, .containers])
        #expect(layout.size(of: .hosts) == .large)
        #expect(layout.size(of: .dns) == .small)
        #expect(layout.size(of: .containers) == .tall)
    }
}
