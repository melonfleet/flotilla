import SwiftUI
import AppKit
import Testing
import FlotillaCore
@testable import Flotilla

@Suite struct LogLevelTests {
    @Test func readsALevelThatTheLineStatesPlainly() {
        #expect(LogLevel.of("ERROR failed to bind :8080") == .error)
        #expect(LogLevel.of("2026-10-18T10:00:00Z WARN slow query") == .warning)
        #expect(LogLevel.of("[error] 12#12: *1 open() failed") == .error)
        #expect(LogLevel.of("[warn] upstream timed out") == .warning)
        #expect(LogLevel.of("time=2026-10-18 level=info msg=started") == .info)
        #expect(LogLevel.of(#"{"ts":1,"level":"debug","msg":"x"}"#) == .debug)
        #expect(LogLevel.of("FATAL: out of memory") == .error)
    }

    @Test func proseIsNotALevel() {
        #expect(LogLevel.of("Starting error handler") == nil)
        #expect(LogLevel.of("information about the build") == nil)
        #expect(LogLevel.of("GET /health 200") == nil)
        #expect(LogLevel.of("") == nil)
        // Past the first handful of words it is prose, however it is spelled.
        #expect(LogLevel.of("the request that was made at some point finally ended in an ERROR today") == nil)
        #expect(LogLevel.of(String(repeating: "x ", count: 100) + "ERROR") == nil)
    }
}

@Suite struct ActivityEventRowTests {
    private func event(_ kind: ActivityKind, _ subject: String, from: String = "", to: String = "",
                       action: String? = nil) -> ContainerEvent {
        ContainerEvent(date: Date(), from: from, to: to, kind: kind, subject: subject, action: action)
    }

    @Test func headlineNamesTheThingAndWhatHappenedToIt() {
        #expect(event(.container, "web", from: "stopped", to: "running").headline == "Started web")
        #expect(event(.container, "web", from: "running", to: "stopped").headline == "Stopped web")
        #expect(event(.volume, "data", from: "absent", to: "present").headline == "Added data")
        #expect(event(.network, "n", from: "present", to: "absent").headline == "Removed n")
        #expect(event(.container, "web", from: "running", to: "running", action: "Restarted").headline == "Restarted web")
    }

    @Test func anotherMacsEventsCarryTheirHost() {
        let remote = event(.container, "web on mac-mini", action: "Deleted")
        #expect(remote.subjectName == "web")
        #expect(remote.hostName == "mac-mini")
        #expect(remote.headline == "Deleted web")
        #expect(event(.container, "web").hostName == nil)
        // A host's own subject is its name, whatever it contains.
        #expect(event(.host, "Studio on the left").hostName == nil)
        #expect(event(.host, "Studio on the left").subjectName == "Studio on the left")
    }

    @Test func aPerformedActionHasNoTransition() {
        #expect(event(.container, "web", from: "running", to: "running", action: "Restarted").transition == nil)
        #expect(event(.volume, "v", from: "absent", to: "present").transition == nil)
        #expect(event(.container, "web", from: "running", to: "stopped").transition == "running \u{2192} stopped")
    }
}

/// Logs can hold thousands of lines. This hosts the real `LogsView` on 10,000 of them and scrolls it.
@MainActor
@Suite(.serialized) struct LogFeedScrollTests {
    static func fixture(sources: Int = 10, perSource: Int = 1000) -> [AggregatedLogChunk] {
        (0..<sources).map { s in
            let name = "service-\(s)"
            let lines = (0..<perSource).map { i in
                let text: String = switch i % 7 {
                case 0: "ERROR request \(i) failed: upstream connect error or disconnect/reset before headers"
                case 1: "2026-10-18T10:00:\(String(format: "%02d", i % 60))Z WARN slow query took \(i)ms"
                case 3: String(repeating: "stack frame \(i) ", count: 40)
                default: "GET /items/\(i) 200 \(i % 90)ms"
                }
                return AggregatedLogLine(source: name, kind: .container, index: i,
                                         stream: i % 11 == 0 ? .stderr : .stdout, text: text,
                                         receivedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(i)))
            }
            return AggregatedLogChunk(source: name, kind: .container, lines: lines, truncated: false, failure: nil)
        }
    }

    private func descendants<V: NSView>(of root: NSView, as type: V.Type) -> [V] {
        var found: [V] = []
        var queue = [root]
        while let view = queue.popLast() {
            if let match = view as? V { found.append(match) }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Gives the main actor, and so SwiftUI's layout and the view's `.task`s, the time to run.
    /// Alternates slices of run loop (layout, display) with sleeps (the tail's timer): either alone starves the other.
    private func pump(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A slice of run loop, so AppKit and Core Animation get their turn. Its own function because
    /// `RunLoop.run` may not be written in an async context.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }

    @Test func tenThousandLinesScrollWithoutBuildingThemAll() async throws {
        _ = NSApplication.shared
        let model = AppModel(settingsStore: SettingsStore())
        let ui = LogsUIState()
        let chunks = Self.fixture()
        #expect(chunks.reduce(0) { $0 + $1.lines.count } == 10_000)

        let view = LogsView(model: model, ui: ui, preloaded: chunks)
        let host = NSHostingView(rootView: view.frame(width: 1100, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        let started = Date()
        await pump(0.5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await pump(1.0)
        let firstLayout = Date().timeIntervalSince(started)

        let tables = descendants(of: host, as: NSTableView.self)
        let table = try #require(tables.first, "the feed is a lazy List (an NSTableView), not a stack")
        let scroll = try #require(table.enclosingScrollView)
        // The table knows every row exists, and has built views for only the ones on screen.
        #expect(table.numberOfRows >= 10_000)
        let realised = table.subviews.compactMap { $0 as? NSTableRowView }.count
        #expect(realised < 200, "built \(realised) row views for 10,000 lines")

        let maxY = table.frame.height - scroll.contentView.bounds.height
        func timed(_ y: Double) -> Double {
            let t0 = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return (CACurrentMediaTime() - t0) * 1000
        }
        func summary(_ times: [Double]) -> (p50: Double, p95: Double, worst: Double) {
            let sorted = times.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0)
        }
        // Smooth: a trackpad flick, 40pt a frame, from a third of the way down.
        let smoothStart = maxY / 3
        let smooth = summary((0..<300).map { timed(smoothStart + Double($0) * 40) })
        // Jumps: Page Down / dragging the scroller, where every row on screen is new each time.
        let jumps = summary((0...60).map { timed(maxY * Double($0) / 60) })
        // Back to the bottom: where Live's tail sits.
        _ = timed(maxY)
        let f = { (v: Double) in String(format: "%.1f", v) }
        print("LOGS-PERF lines=10000 rows=\(table.numberOfRows) realised=\(realised) "
              + "firstLayout=\(String(format: "%.2f", firstLayout))s "
              + "smooth p50=\(f(smooth.p50))ms p95=\(f(smooth.p95))ms worst=\(f(smooth.worst))ms "
              + "jump p50=\(f(jumps.p50))ms p95=\(f(jumps.p95))ms worst=\(f(jumps.worst))ms")
        // Generous: a frame is 16ms, and a test machine under load is not a Mac Studio. A debug build is
        // several times slower than the app, so the bound is loose enough for it and still catches a
        // list that builds every row (which takes seconds per frame).
        #expect(smooth.p95 < 100, "smooth scroll p95 \(smooth.p95)ms")
        #expect(jumps.p95 < 400, "page-jump p95 \(jumps.p95)ms")

        // Select-all is a count, and one selected line opens its page.
        ui.selection = Set(chunks.flatMap(\.lines).map(\.id))
        await pump(0.5)
        #expect(ui.selection.count == 10_000)
        ui.selection = [chunks[3].lines[5].id]
        await pump(0.5)
        window.orderOut(nil)
    }

    /// Live runs the real tail loop against two made-up sources, and the list follows the newest line.
    @Test func liveFollowsTheTailAsLinesArrive() async throws {
        _ = NSApplication.shared
        let model = AppModel(settingsStore: SettingsStore())
        let ui = LogsUIState()
        let view = LogsView(model: model, ui: ui, preloaded: Self.fixture(sources: 2, perSource: 50),
                            simulatedLines: 3200)
        let host = NSHostingView(rootView: view.frame(width: 1100, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        await pump(0.5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await pump(0.5)

        ui.live = true
        let started = Date()
        var longest = 0.0
        var last = Date()
        // The tail stays open and quiet once its 3,200 lines are in (as a container that has said what it
        // will for now), so the position can be read without Live switching itself off underneath it.
        while Date().timeIntervalSince(started) < 15 {
            await pump(0.01)
            longest = max(longest, Date().timeIntervalSince(last))
            last = Date()
            if let found = descendants(of: host, as: NSTableView.self).first, found.numberOfRows >= 3200 { break }
        }
        await pump(0.5)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await pump(0.3)
        let table = try #require(descendants(of: host, as: NSTableView.self).first, "the feed is on screen")
        let reached = Date().timeIntervalSince(started)
        let visible = table.rows(in: table.visibleRect)
        print("LOGS-LIVE rows=\(table.numberOfRows) in=\(String(format: "%.2f", reached))s "
              + "longestMainThreadGap=\(String(format: "%.0f", longest * 1000))ms visibleRows=\(visible)")
        #expect(table.numberOfRows == 3200)
        #expect(NSLocationInRange(table.numberOfRows - 1, visible), "the newest line is in view")
        ui.live = false
        window.orderOut(nil)
    }
}
