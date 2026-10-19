import Foundation
import Testing
@testable import FlotillaCore

@Suite struct TaskBoardTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func startingAJobRaisesTheDrawerOnIt() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Pull an image", at: t0)
        #expect(board.drawer == .task(id))
        #expect(board.headline(at: t0) == .running(count: 1, line: "Pull an image"))
    }

    @Test func minimisingKeepsTheJobAndItsLines() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Pull an image", at: t0)
        board.minimise()
        board.setLine("  layer 3 of 5  ", for: id)
        #expect(board.drawer == .hidden)
        #expect(board.headline(at: at(1)) == .running(count: 1, line: "layer 3 of 5"))
        board.setLine("   ", for: id)
        #expect(board.headline(at: at(1)).text == "Pull an image")
    }

    @Test func headlineFollowsTheNewestRunningTask() {
        var board = TaskBoard()
        let first = UUID(), second = UUID()
        board.start(first, title: "Build", at: t0)
        board.setLine("step 4", for: first)
        board.start(second, title: "Pull", at: at(2))
        board.setLine("layer 1", for: second)
        #expect(board.headline(at: at(3)) == .running(count: 2, line: "layer 1"))
        board.succeed(second, at: at(4))
        #expect(board.headline(at: at(4)) == .running(count: 1, line: "step 4"))
    }

    @Test func orderIsRunningNewestFirstThenFinishedNewestFirst() {
        var board = TaskBoard()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        board.start(a, title: "a", at: at(0))
        board.start(b, title: "b", at: at(1))
        board.start(c, title: "c", at: at(2))
        board.start(d, title: "d", at: at(3))
        board.succeed(a, at: at(10))
        board.fail(c, reason: "no", at: at(5))
        #expect(board.ordered.map(\.id) == [d, b, a, c])
    }

    @Test func successFlashesThenGoesQuietAndLeavesTheDrawerAlone() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Pull an image", at: t0)
        board.minimise()
        board.succeed(id, at: at(10))
        #expect(board.drawer == .hidden)
        #expect(board.headline(at: at(11)) == .finished(title: "Pull an image"))
        #expect(board.headline(at: at(11)).text == "Pull an image finished")
        #expect(board.flashEnds(at: at(11)) == at(10 + TaskBoard.finishedFlash))
        #expect(board.headline(at: at(10 + TaskBoard.finishedFlash)) == .quiet)
        #expect(board.flashEnds(at: at(20)) == nil)

        var up = TaskBoard()
        up.start(id, title: "x", at: t0)
        up.succeed(id, at: at(1))
        #expect(up.drawer == .task(id))
    }

    @Test func aFailureWithTheDrawerDownStaysFlaggedUntilItIsOpened() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Build", at: t0)
        board.minimise()
        board.fail(id, reason: "exit 1", at: at(1))
        #expect(board.drawer == .hidden)
        // Long after any flash would have ended.
        #expect(board.headline(at: at(600)) == .failed(title: "Build"))
        #expect(board.headline(at: at(600)).text == "Build failed")
        board.toggleList()
        #expect(board.drawer == .list)
        #expect(board.unseenFailures.isEmpty)
        #expect(board.headline(at: at(601)) == .quiet)
    }

    @Test func aFailureWithTheDrawerUpTurnsItToTheReason() {
        var board = TaskBoard()
        let failing = UUID(), other = UUID()
        board.start(failing, title: "Build", at: t0)
        board.start(other, title: "Pull", at: at(1))
        board.showList()
        board.fail(failing, reason: "exit 1", at: at(2))
        #expect(board.drawer == .task(failing))
        #expect(board.unseenFailures.isEmpty)
        #expect(board.entry(failing)?.state == .failed("exit 1"))
    }

    @Test func showingAFailedTaskMarksItSeen() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Build", at: t0)
        board.minimise()
        board.fail(id, reason: "x", at: at(1))
        board.show(id)
        #expect(board.unseenFailures.isEmpty)
        #expect(board.drawer == .task(id))
    }

    @Test func aRunningTaskOutranksAFailure() {
        var board = TaskBoard()
        let failed = UUID(), running = UUID()
        board.start(failed, title: "Build", at: t0)
        board.minimise()
        board.fail(failed, reason: "x", at: at(1))
        board.start(running, title: "Pull", at: at(2))
        board.minimise()
        #expect(board.headline(at: at(3)) == .running(count: 1, line: "Pull"))
        board.succeed(running, at: at(4))
        // The finished flash does not hide a failure nobody has seen.
        #expect(board.headline(at: at(5)) == .failed(title: "Build"))
    }

    @Test func toggleListOpensAndClosesTheList() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "x", at: t0)
        board.toggleList()
        #expect(board.drawer == .list)
        board.toggleList()
        #expect(board.drawer == .hidden)
    }

    @Test func onlyFinishedTasksClear() {
        var board = TaskBoard()
        let running = UUID(), done = UUID(), failed = UUID()
        board.start(running, title: "r", at: t0)
        board.start(done, title: "d", at: t0)
        board.start(failed, title: "f", at: t0)
        board.succeed(done, at: at(1))
        board.minimise()
        board.fail(failed, reason: "x", at: at(2))
        let clearedRunning = board.clear(running)
        let clearedDone = board.clear(done)
        #expect(!clearedRunning)
        #expect(clearedDone)
        #expect(board.entry(done) == nil)
        board.show(running)
        let cleared = board.clearFinished()
        #expect(Set(cleared) == [failed])
        #expect(board.unseenFailures.isEmpty)
        #expect(board.ordered.map(\.id) == [running])
        #expect(!board.hasFinished)
    }

    @Test func clearingTheShownTaskFallsBackToTheList() {
        var board = TaskBoard()
        let keep = UUID(), gone = UUID()
        board.start(keep, title: "k", at: t0)
        board.start(gone, title: "g", at: t0)
        board.succeed(gone, at: at(1))
        #expect(board.drawer == .task(gone))
        board.clear(gone)
        #expect(board.drawer == .list)
        board.succeed(keep, at: at(2))
        board.clearFinished()
        // An empty list stays open and says so; only the user puts it away.
        #expect(board.drawer == .list)
        #expect(board.entries.isEmpty)
    }

    @Test func finishedTasksAreCappedAndRunningOnesNeverAre() {
        var board = TaskBoard()
        let running = UUID()
        board.start(running, title: "long", at: t0)
        var finished: [UUID] = []
        var dropped: [UUID] = []
        for index in 0..<(TaskBoard.finishedLimit + 3) {
            let id = UUID()
            finished.append(id)
            board.start(id, title: "\(index)", at: at(Double(index)))
            dropped += board.succeed(id, at: at(Double(index) + 0.5))
        }
        #expect(dropped == Array(finished.prefix(3)))
        #expect(board.entries.count == TaskBoard.finishedLimit + 1)
        #expect(board.entry(running) != nil)
        #expect(board.ordered.first?.id == running)
    }

    @Test func anUnknownOrFinishedTaskIgnoresUpdates() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "x", at: t0)
        board.succeed(id, at: at(1))
        board.fail(id, reason: "late", at: at(2))
        #expect(board.entry(id)?.state == .succeeded)
        board.start(id, title: "again", at: at(3))
        #expect(board.entries.count == 1)
        board.show(UUID())
        #expect(board.drawer == .task(id))
    }
}
