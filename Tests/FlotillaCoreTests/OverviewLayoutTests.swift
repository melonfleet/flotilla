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
        #expect(OverviewLayout().addable.allSatisfy { $0.rawValue != "getStarted" })
    }

    @Test("a layout saved while Get started was a widget loads without it, keeping the rest")
    func savedGetStartedIsDropped() {
        let layout = OverviewLayout(storage: [
            ["widget": "getStarted", "size": "large"],
            ["widget": "fleet", "size": "large"],
            ["widget": "hosts", "size": "wide"],
        ])
        #expect(layout.kinds == [.fleet, .hosts])
        #expect(layout.widget("fleet")?.size == .large)
        #expect(layout.widget("hosts")?.size == .wide)
        // What the store writes back at load: the plist no longer names it.
        #expect(!layout.storage.contains { $0["widget"] == "getStarted" })
        #expect(OverviewLayout(storage: [["widget": "getStarted", "size": "wide"]]).isEmpty)
    }

    @Test("the notifications band is not a widget")
    func noAttentionWidget() {
        #expect(OverviewWidgetKind(rawValue: "attention") == nil)
        #expect(OverviewWidgetKind(rawValue: "needsAttention") == nil)
    }

    @Test("every widget offers all four sizes, and its defaults are ones it offers (round 3)")
    func sizesAreConsistent() {
        for kind in OverviewWidgetKind.allCases {
            #expect(kind.sizes == [.small, .wide, .tall, .large], "\(kind)")
            #expect(kind.sizes.contains(kind.defaultSize), "\(kind)")
        }
    }

    @Test("default sizes are round 2's, so the recommended page looks as it did")
    func defaultSizesUnchanged() {
        #expect(OverviewWidgetKind.fleet.defaultSize == .wide)
        #expect(OverviewWidgetKind.hosts.defaultSize == .large)
        #expect(OverviewWidgetKind.containers.defaultSize == .tall)
        #expect(OverviewWidgetKind.activity.defaultSize == .tall)
        #expect(OverviewWidgetKind.machines.defaultSize == .small)
        #expect(OverviewWidgetKind.dns.defaultSize == .small)
    }

    // MARK: Show

    @Test("the Show choices are Kamal's, in his order")
    func showChoices() {
        #expect(OverviewWidgetKind.containers.shows == [.running, .all, .stopped, .byHost])
        #expect(OverviewWidgetKind.hosts.shows == [.all, .problems, .thisSite])
        #expect(OverviewWidgetKind.images.shows == [.newest, .largest, .vulnerable])
        #expect(OverviewWidgetKind.activity.shows == [.everything, .problems, .thisMac])
        #expect(OverviewWidgetKind.vulnerabilities.shows == [.totals, .worst])
        #expect(OverviewWidgetKind.fleet.shows == [.counts, .load, .both])
        #expect(OverviewWidgetKind.machines.shows == [.all, .running])
        #expect(OverviewWidgetKind.kubernetes.shows == [.all, .ready])
        #expect(OverviewWidgetKind.dns.shows == [.all, .forContainers])
        #expect(OverviewWidgetKind.networks.shows == [.all, .userDefined])
        #expect(OverviewWidgetKind.tasks.shows == [.all, .running])
        #expect(OverviewWidgetKind.suggestions.shows == [.stacks, .apps])
        // No meaningful second choice: no menu at all, rather than a menu of one.
        #expect(OverviewWidgetKind.storage.shows.isEmpty)
        #expect(OverviewWidgetKind.storage.defaultShow == nil)
    }

    @Test("every default choice is one the widget offers, and no widget offers a single choice")
    func showDefaultsConsistent() {
        for kind in OverviewWidgetKind.allCases {
            #expect(kind.shows.count != 1, "\(kind)")
            #expect(Set(kind.shows).count == kind.shows.count, "\(kind)")
            if let show = kind.defaultShow { #expect(kind.shows.contains(show), "\(kind)") }
            #expect((kind.defaultShow == nil) == kind.shows.isEmpty, "\(kind)")
        }
        // What round 2 drew: every container, counts with load, stacks.
        #expect(OverviewWidgetKind.containers.defaultShow == .all)
        #expect(OverviewWidgetKind.fleet.defaultShow == .both)
        #expect(OverviewWidgetKind.suggestions.defaultShow == .stacks)
    }

    @Test("every choice is offered by some widget")
    func everyChoiceIsUsed() {
        let offered = Set(OverviewWidgetKind.allCases.flatMap(\.shows))
        #expect(offered == Set(OverviewWidgetShow.allCases))
    }

    @Test("setShow takes only a choice the widget offers")
    func setShow() {
        var layout = OverviewLayout.recommended
        layout.setShow("containers", to: .stopped)
        #expect(layout.widget("containers")?.show == .stopped)
        layout.setShow("containers", to: .largest)
        #expect(layout.widget("containers")?.show == .stopped)
        layout.setShow("nothing", to: .stopped)  // no such widget: a no-op
        #expect(layout.widgets.count == OverviewLayout.recommended.widgets.count)
        var storage = OverviewLayout([OverviewWidget(.storage)])
        storage.setShow("storage", to: .all)
        #expect(storage.widget("storage")?.show == nil)
    }

    @Test("cycleShow steps through the choices and wraps; a widget with none is left alone")
    func cycleShow() {
        var layout = OverviewLayout([OverviewWidget(.images), OverviewWidget(.storage)])
        var seen: [OverviewWidgetShow?] = []
        for _ in 0..<3 {
            layout.cycleShow("images")
            seen.append(layout.widget("images")?.show)
        }
        #expect(seen == [.largest, .vulnerable, .newest])
        layout.cycleShow("storage")
        #expect(layout.widget("storage")?.show == nil)
    }

    @Test("the title names the choice only when it isn't the default")
    func titles() {
        #expect(OverviewWidget(.containers).title == "Containers")
        #expect(OverviewWidget(.containers, show: .stopped).title == "Containers · Stopped")
        #expect(OverviewWidget(.containers, show: .running).title == "Containers · Running")
        #expect(OverviewWidget(.hosts, show: .problems).title == "Hosts · Problems")
        #expect(OverviewWidget(.storage).title == "Storage")
        #expect(OverviewWidget(.images, show: .apps).title == "Images")  // not offered → default
    }

    // MARK: Editing

    @Test("add appends at the default size and choice, and every kind stays addable")
    func addAndAddable() {
        var layout = OverviewLayout()
        #expect(layout.addable == OverviewWidgetKind.allCases)
        layout.add(.dns)
        let hosts = layout.add(.hosts)
        #expect(layout.kinds == [.dns, .hosts])
        #expect(layout.widget(hosts)?.size == .large)
        #expect(layout.widget(hosts)?.show == .all)
        #expect(layout.addable == OverviewWidgetKind.allCases)
    }

    @Test("kindsPlaced and count follow every add and remove; removeAll takes the kind off the page")
    func kindsPlacedAndRemoveAll() {
        var layout = OverviewLayout()
        #expect(layout.kindsPlaced.isEmpty)
        layout.add(.dns)
        layout.add(.containers)
        layout.add(.containers, show: .stopped)
        layout.add(.fleet)
        // Kind order, not page order.
        #expect(layout.kindsPlaced == OverviewWidgetKind.allCases.filter { [.dns, .containers, .fleet].contains($0) })
        #expect(layout.count(of: .containers) == 1)
        #expect(layout.count(of: .hosts) == 0)
        layout.removeAll(.containers)
        #expect(layout.count(of: .containers) == 0)
        #expect(!layout.kindsPlaced.contains(.containers))
        #expect(layout.kinds == [.dns, .fleet])
        // Every kind stays listed, placed or not.
        #expect(layout.addable == OverviewWidgetKind.allCases)
    }

    @Test("removing a kind and adding it again gives back its own id")
    func idAfterReadd() {
        var layout = OverviewLayout()
        #expect(layout.add(.images) == "images")
        #expect(layout.add(.images) == "images")
        layout.remove("images")
        #expect(layout.isEmpty)
        #expect(layout.add(.images) == "images")
        #expect(layout.count(of: .images) == 1)
    }

    @Test("init renames a repeated id rather than keeping two widgets under it")
    func initDedupesIDs() {
        let layout = OverviewLayout([OverviewWidget(.hosts), OverviewWidget(.hosts, .small, show: .problems)])
        #expect(layout.widgets.map(\.id) == ["hosts", "hosts-2"])
        #expect(layout.widgets[1].size == .small)
        #expect(layout.widgets[1].show == .problems)
    }

    @Test("add at an index clamps, and honours a size and a choice")
    func addAtIndexAndSize() {
        var layout = OverviewLayout([OverviewWidget(.fleet), OverviewWidget(.hosts)])
        layout.add(.tasks, at: 1, size: .tall)
        layout.add(.storage, at: 99, size: .large)
        layout.add(.images, at: -5, show: .largest)
        #expect(layout.kinds == [.images, .fleet, .tasks, .hosts, .storage])
        #expect(layout.widget("tasks")?.size == .tall)
        #expect(layout.widget("storage")?.size == .large)
        #expect(layout.widget("images")?.show == .largest)
    }

    @Test("remove takes that widget off and nothing else")
    func remove() {
        var layout = OverviewLayout.recommended
        layout.remove("hosts")
        layout.remove("dns")  // not on the page: a no-op
        #expect(!layout.contains(.hosts))
        #expect(layout.widgets.count == OverviewLayout.recommended.widgets.count - 1)
    }

    @Test("resize takes every size for every kind")
    func resize() {
        var layout = OverviewLayout(OverviewWidgetKind.allCases.map { OverviewWidget($0) })
        for kind in OverviewWidgetKind.allCases {
            for size in OverviewWidgetSize.allCases {
                layout.resize(kind.rawValue, to: size)
                #expect(layout.widget(kind.rawValue)?.size == size, "\(kind) \(size)")
            }
        }
        layout.resize("nothing", to: .small)
        #expect(layout.widgets.count == OverviewWidgetKind.allCases.count)
    }

    @Test("cycleSize steps through all four sizes and wraps")
    func cycleSize() {
        var layout = OverviewLayout([OverviewWidget(.storage)])
        var seen: [OverviewWidgetSize] = []
        for _ in 0..<4 {
            layout.cycleSize("storage")
            seen.append(layout.widget("storage")!.size)
        }
        #expect(seen == [.wide, .tall, .large, .small])
    }

    @Test("move earlier and later step one place and stop at the ends")
    func moveSteps() {
        var layout = OverviewLayout([OverviewWidget(.fleet), OverviewWidget(.hosts), OverviewWidget(.dns)])
        layout.moveEarlier("fleet")
        #expect(layout.kinds == [.fleet, .hosts, .dns])
        layout.moveLater("fleet")
        #expect(layout.kinds == [.hosts, .fleet, .dns])
        layout.moveLater("dns")
        #expect(layout.kinds == [.hosts, .fleet, .dns])
        layout.moveEarlier("dns")
        #expect(layout.kinds == [.hosts, .dns, .fleet])
        layout.move("hosts", to: 42)
        #expect(layout.kinds == [.dns, .fleet, .hosts])
    }

    @Test("one widget per kind: adding a kind already on the page adds nothing (Kamal, 23 October)")
    func onePerKind() {
        var layout = OverviewLayout([OverviewWidget(.containers), OverviewWidget(.dns)])
        let again = layout.add(.containers, show: .stopped)
        #expect(again == "containers")
        #expect(layout.widgets.map(\.id) == ["containers", "dns"])
        #expect(layout.widget("containers")?.show != .stopped)
        // A round-3 layout with two of a kind keeps the first.
        let stored = [["id": "containers", "widget": "containers", "size": "tall"],
                      ["id": "containers-2", "widget": "containers", "size": "small", "show": "stopped"]]
        #expect(OverviewLayout(storage: stored).widgets.map(\.id) == ["containers"])
    }

    @Test("reset restores the recommended layout, which then counts as recommended")
    func reset() {
        var layout = OverviewLayout([OverviewWidget(.dns)])
        layout.add(.containers, show: .stopped)
        layout.reset()
        #expect(layout == .recommended)
    }

    @Test("the resize grip lands on the nearest size")
    func nearestSize() {
        #expect(OverviewWidgetKind.hosts.nearestSize(columns: 1, rows: 1) == .small)
        #expect(OverviewWidgetKind.hosts.nearestSize(columns: 3, rows: 3) == .large)
        #expect(OverviewWidgetKind.containers.nearestSize(columns: 2, rows: 2) == .large)
        #expect(OverviewWidgetKind.containers.nearestSize(columns: 2, rows: 1) == .wide)
        #expect(OverviewWidgetKind.dns.nearestSize(columns: 1, rows: 2) == .tall)
        #expect(OverviewWidgetKind.dns.nearestSize(columns: 0, rows: 0) == .small)
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
        // Every kind at every size; the second pass adds nothing, one per kind.
        var mixed = OverviewLayout()
        for (i, kind) in (OverviewWidgetKind.allCases + OverviewWidgetKind.allCases).enumerated() {
            mixed.add(kind, size: OverviewWidgetSize.allCases[i % 4])
        }
        for columns in 0...9 {
            assertNoOverlap(.recommended, columns: columns)
            assertNoOverlap(all, columns: columns)
            assertNoOverlap(mixed, columns: columns)
            #expect(all.placements(columns: columns).count == OverviewWidgetKind.allCases.count)
            #expect(Set(mixed.placements(columns: columns).map(\.id)).count == mixed.widgets.count)
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
        #expect(layout.insertionIndex(column: 3, row: 1, columns: 4) == layout.index(of: "hosts"))
        #expect(layout.insertionIndex(column: 3, row: 9, columns: 4) == layout.widgets.count)
        // Dragging Hosts over itself is not a target; over empty space it goes last.
        #expect(layout.insertionIndex(column: 3, row: 1, columns: 4, ignoring: "hosts") == layout.widgets.count - 1)
        #expect(layout.insertionIndex(column: 3, row: 9, columns: 4, ignoring: "hosts") == layout.widgets.count - 1)
        #expect(layout.insertionIndex(column: 0, row: 2, columns: 4, ignoring: "hosts") == layout.index(of: "containers"))
    }

    // MARK: Storage

    @Test("the plist form round-trips, instances and choices included")
    func roundTrip() {
        var layout = OverviewLayout.recommended
        layout.resize("fleet", to: .large)
        layout.setShow("fleet", to: .load)
        layout.add(.suggestions, at: 2, size: .wide, show: .apps)
        layout.add(.storage, size: .tall)
        #expect(OverviewLayout(storage: layout.storage) == layout)
        #expect(layout.storage.first == ["id": "fleet", "widget": "fleet", "size": "large", "show": "load"])
        #expect(layout.storage.last == ["id": "storage", "widget": "storage", "size": "tall"])
    }

    @Test("a round-2 layout migrates: same order, same sizes, default choices, kind names as ids")
    func migratesRoundTwo() {
        let saved: [[String: String]] = [
            ["widget": "fleet", "size": "large"],
            ["widget": "hosts", "size": "wide"],
            ["widget": "containers", "size": "small"],
            ["widget": "activity", "size": "tall"],
            ["widget": "storage", "size": "small"],
            ["widget": "suggestions", "size": "wide"],
        ]
        let layout = OverviewLayout(storage: saved)
        #expect(layout.kinds == [.fleet, .hosts, .containers, .activity, .storage, .suggestions])
        #expect(layout.widgets.map(\.size) == [.large, .wide, .small, .tall, .small, .wide])
        #expect(layout.widgets.map(\.id) == ["fleet", "hosts", "containers", "activity", "storage", "suggestions"])
        #expect(layout.widgets.map(\.show) == [.both, .all, .all, .everything, nil, .stacks])
        // The store writes the migration back at load: the new form differs from what was read.
        #expect(layout.storage != saved)
        #expect(OverviewLayout(storage: layout.storage) == layout)
    }

    @Test("a round-2 recommended layout migrates to exactly today's recommended one")
    func migratesRecommended() {
        let roundTwo = OverviewLayout.recommended.widgets.map { ["widget": $0.kind.rawValue, "size": $0.size.rawValue] }
        #expect(OverviewLayout(storage: roundTwo) == .recommended)
    }

    @Test("an empty plist is an empty page, not the recommended one")
    func emptyIsEmpty() {
        #expect(OverviewLayout(storage: []).isEmpty)
    }

    @Test("a hand-edited plist keeps what it can")
    func tolerantDecoding() {
        let layout = OverviewLayout(storage: [
            ["widget": "hosts", "size": "small", "show": "problems"],
            ["widget": "needsAttention", "size": "small"],          // not a widget → dropped
            ["widget": "dns"],                                       // no size → default
            ["widget": "hosts", "size": "wide"],                     // a second Hosts → dropped, one per kind
            ["size": "large"],                                       // no widget → dropped
            ["widget": "containers", "size": "huge", "show": "x"],   // unknown size, choice → defaults
            ["id": "hosts", "widget": "images", "show": "largest"],  // id taken → fresh id
            ["id": " ", "widget": "tasks", "show": "stopped"],       // blank id, choice not offered
        ])
        #expect(layout.kinds == [.hosts, .dns, .containers, .images, .tasks])
        #expect(layout.widgets.map(\.id) == ["hosts", "dns", "containers", "images", "tasks"])
        #expect(layout.widgets[0].size == .small)
        #expect(layout.widgets[0].show == .problems)
        #expect(layout.widgets[1].size == .small)
        #expect(layout.widgets[2].size == .tall)
        #expect(layout.widgets[2].show == .all)
        #expect(layout.widgets[3].show == .largest)
        #expect(layout.widgets[4].show == .all)
    }
}
