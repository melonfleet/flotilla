import Foundation
import Testing
@testable import FlotillaCore

@Suite struct TaskBoardTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func startingAJobRaisesTheDrawerWithItsRowCollapsed() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Pull an image", at: t0)
        #expect(board.drawer == .list)
        #expect(board.expanded.isEmpty)
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
        #expect(up.drawer == .list)
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

    @Test func aFailureWithTheDrawerUpFlagsItsRowAndLeavesItCollapsed() {
        var board = TaskBoard()
        let failing = UUID(), other = UUID()
        board.start(failing, title: "Build", at: t0)
        board.start(other, title: "Pull", at: at(1))
        board.showList()
        board.fail(failing, reason: "exit 1", at: at(2))
        #expect(board.drawer == .list)
        #expect(board.expanded.isEmpty)
        #expect(board.row(board.entry(failing)!, at: at(3)).step == "exit 1")
        #expect(board.unseenFailures.isEmpty)
        #expect(board.entry(failing)?.state == .failed("exit 1"))
    }

    @Test func revealingAFailedTaskMarksItSeenAndOpensIt() {
        var board = TaskBoard()
        let id = UUID()
        board.start(id, title: "Build", at: t0)
        board.minimise()
        board.fail(id, reason: "x", at: at(1))
        board.reveal(id)
        #expect(board.unseenFailures.isEmpty)
        #expect(board.drawer == .list)
        #expect(board.expanded == [id])
        #expect(board.revealed == id)
        board.clearReveal()
        #expect(board.revealed == nil)
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
        board.minimise()
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
        let cleared = board.clearFinished()
        #expect(Set(cleared) == [failed])
        #expect(board.unseenFailures.isEmpty)
        #expect(board.ordered.map(\.id) == [running])
        #expect(!board.hasFinished)
    }

    @Test func clearingTasksLeavesTheListUpAndForgetsTheirRows() {
        var board = TaskBoard()
        let keep = UUID(), gone = UUID()
        board.start(keep, title: "k", at: t0)
        board.start(gone, title: "g", at: t0)
        board.toggleExpanded(gone)
        board.succeed(gone, at: at(1))
        #expect(board.drawer == .list)
        board.clear(gone)
        #expect(board.expanded.isEmpty)
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
        board.reveal(UUID())
        #expect(board.expanded.isEmpty)
    }

    // MARK: Round 2: kinds, Retry, Cancel, rows, notices

    /// The table Kamal asked for, in one place: a change to it is a change to this test.
    @Test func retryAndCancelEligibilityTable() {
        let table: [(TaskKind, retry: Bool, cancel: Bool)] = [
            (.pullImage, true, true), (.buildImage, true, true),
            (.pullImageToHosts, true, false), (.sendImage, true, false),
            (.createVolume, true, false), (.createNetwork, true, false),
            (.clusterAction, true, false), (.groupAction, true, false),
            (.runContainer, false, false), (.createStack, false, false),
            (.createCluster, false, false), (.recreateCluster, false, false),
            (.createMachine, false, false), (.importConfiguration, false, false),
            (.pushDefinition, false, false), (.dnsSetup, false, false),
            (.unclassified, false, false),
        ]
        #expect(Set(table.map(\.0)) == Set(TaskKind.allCases), "every kind is decided")
        for (kind, retry, cancel) in table {
            #expect(kind.canRetry == retry, "\(kind) retry")
            #expect(kind.canCancel == cancel, "\(kind) cancel")
        }
    }

    @Test func aCancellableKindIsAlwaysRetryable() {
        // A job we may stop part-way can be started again; the reverse need not hold.
        for kind in TaskKind.allCases where kind.canCancel { #expect(kind.canRetry) }
    }

    private func entryID(_ board: inout TaskBoard, kind: TaskKind, retry: Bool = true, cancel: Bool = true) -> UUID {
        let id = UUID()
        board.start(id, title: "Pull x", kind: kind, origin: "Images",
                    hasRetryAction: retry, hasCancelAction: cancel, at: t0)
        return id
    }

    @Test func cancelIsOfferedOnlyWhileRunningAndOnlyWhereTheKindAllowsIt() {
        var board = TaskBoard()
        let pull = entryID(&board, kind: .pullImage)
        let create = entryID(&board, kind: .createVolume)
        let noHandle = entryID(&board, kind: .buildImage, cancel: false)
        #expect(board.entry(pull)?.offersCancel == true)
        #expect(board.entry(create)?.offersCancel == false)
        #expect(board.entry(noHandle)?.offersCancel == false, "no process handed over, no button")
        let refused = board.requestCancel(create)
        let first = board.requestCancel(pull)
        let second = board.requestCancel(pull)
        #expect(!refused)
        #expect(first)
        #expect(!second, "not twice")
        #expect(board.row(board.entry(pull)!, at: at(1)).isCancelling)
        #expect(board.row(board.entry(pull)!, at: at(1)).stateText == "Cancelling")
    }

    @Test func cancelledIsItsOwnStateAndNeitherFailsNorFlags() {
        var board = TaskBoard()
        let id = entryID(&board, kind: .pullImage)
        board.minimise()
        board.requestCancel(id)
        board.cancel(id, at: at(2))
        #expect(board.entry(id)?.state == .cancelled)
        #expect(board.entry(id)?.state.isFailure == false)
        #expect(board.entry(id)?.state.isFinished == true)
        #expect(board.unseenFailures.isEmpty)
        #expect(board.failureNotices.isEmpty)
        #expect(board.headline(at: at(600)) == .quiet)
        #expect(board.entry(id)?.offersCancel == false)
    }

    @Test func retryIsOfferedOnFailedAndCancelledOnlyAndOnce() {
        var board = TaskBoard()
        let failed = entryID(&board, kind: .pullImage)
        let cancelled = entryID(&board, kind: .pullImage)
        let done = entryID(&board, kind: .pullImage)
        let running = entryID(&board, kind: .pullImage)
        let unsafe = entryID(&board, kind: .createCluster)
        let noAction = entryID(&board, kind: .pullImage, retry: false)
        board.fail(failed, reason: "x", at: at(1))
        board.cancel(cancelled, at: at(1))
        board.succeed(done, at: at(1))
        board.fail(unsafe, reason: "x", at: at(1))
        board.fail(noAction, reason: "x", at: at(1))
        #expect(board.entry(failed)?.offersRetry == true)
        #expect(board.entry(cancelled)?.offersRetry == true)
        #expect(board.entry(done)?.offersRetry == false)
        #expect(board.entry(running)?.offersRetry == false)
        #expect(board.entry(unsafe)?.offersRetry == false, "half-applied jobs say no")
        #expect(board.entry(noAction)?.offersRetry == false)
        let firstRetry = board.retry(failed)
        let secondRetry = board.retry(failed)
        let unsafeRetry = board.retry(unsafe)
        #expect(firstRetry)
        #expect(!secondRetry, "a double click starts one job")
        #expect(!unsafeRetry)
    }

    @Test func rowsStartCollapsedAndExpansionSurvivesNewLines() {
        var board = TaskBoard()
        let id = entryID(&board, kind: .pullImage)
        #expect(board.rows(at: at(1)).first?.isExpanded == false)
        board.toggleExpanded(id)
        board.setLine("[1/2] Fetching 10%", for: id)
        board.setStep("Pulling x — [1/2] Fetching 10%", for: id)
        board.setLine("[1/2] Fetching 20%", for: id)
        #expect(board.rows(at: at(2)).first?.isExpanded == true)
        board.toggleExpanded(id)
        #expect(board.rows(at: at(2)).first?.isExpanded == false)
    }

    @Test func aNewJobIsHighlightedBrieflyAndCollapsed() {
        var board = TaskBoard()
        let first = entryID(&board, kind: .pullImage)
        board.toggleExpanded(first)
        let second = UUID()
        board.start(second, title: "Pull y", at: at(5))
        #expect(board.drawer == .list)
        #expect(board.row(board.entry(second)!, at: at(5)).isHighlighted)
        #expect(board.row(board.entry(second)!, at: at(5)).isExpanded == false)
        board.clearHighlight(first)
        #expect(board.highlighted == second, "clearing another's highlight leaves this one")
        board.clearHighlight(second)
        #expect(board.highlighted == nil)
    }

    @Test func aRowShowsItsFractionWhileRunningOtherwiseElapsedTime() {
        var board = TaskBoard()
        let pull = entryID(&board, kind: .pullImage)
        let create = entryID(&board, kind: .createVolume)
        board.setFraction(0.42, for: pull)
        board.setFraction(nil, for: pull)
        #expect(board.row(board.entry(pull)!, at: at(75)).fraction == 0.42, "nil leaves the last figure")
        #expect(board.row(board.entry(create)!, at: at(75)).fraction == nil)
        #expect(board.row(board.entry(create)!, at: at(75)).elapsedText == "1m 15s")
        board.setFraction(7, for: pull)
        #expect(board.entry(pull)?.fraction == 1, "clamped")
        board.succeed(pull, at: at(80))
        #expect(board.row(board.entry(pull)!, at: at(90)).fraction == nil, "finished: no bar")
        #expect(board.row(board.entry(pull)!, at: at(90)).elapsedText == "1m 20s", "elapsed stops at the finish")
    }

    @Test func elapsedTextIsShortEnoughForARow() {
        #expect(TaskBoard.elapsedText(0) == "0s")
        #expect(TaskBoard.elapsedText(59.9) == "59s")
        #expect(TaskBoard.elapsedText(185) == "3m 05s")
        #expect(TaskBoard.elapsedText(3_725) == "1h 02m")
        #expect(TaskBoard.elapsedText(-4) == "0s")
    }

    @Test func aFailedRowCarriesTheReasonAsItsSecondaryLine() {
        var board = TaskBoard()
        let id = entryID(&board, kind: .pullImage)
        board.setStep("Pulling x", for: id)
        board.fail(id, reason: "\nnetwork unreachable\nmore detail", at: at(3))
        let row = board.row(board.entry(id)!, at: at(4))
        #expect(row.step == "network unreachable")
        #expect(row.stateText == "Failed")
        #expect(row.offersRetry)
    }

    @Test func failureNoticeKeyLevelAndLifetime() {
        var board = TaskBoard()
        let pull = entryID(&board, kind: .pullImage)
        let cluster = entryID(&board, kind: .createCluster)
        board.fail(pull, reason: "denied: requested access", at: at(1))
        board.fail(cluster, reason: "boom", at: at(1))
        let notices = board.failureNotices
        #expect(notices.count == 2)
        let forPull = notices.first { $0.task == pull }!
        let forCluster = notices.first { $0.task == cluster }!
        #expect(forPull.key == "task-failed:\(pull.uuidString)")
        #expect(TaskBoard.task(fromNoticeKey: forPull.key) == pull)
        #expect(TaskBoard.task(fromNoticeKey: "host-unreachable:abc") == nil)
        #expect(forPull.level == .warning, "Retry is the fix")
        #expect(forCluster.level == .error, "cannot be repeated: may have half-applied")
        #expect(forPull.text == "Pull x failed: denied: requested access")
        #expect(forPull.key != forCluster.key)
        // Retry or Clear ends the notice.
        board.retry(pull)
        #expect(board.failureNotices.map(\.task) == [cluster])
        board.clear(cluster)
        #expect(board.failureNotices.isEmpty)
    }

    @Test func successesAndRunningJobsRaiseNoNotice() {
        var board = TaskBoard()
        let ok = entryID(&board, kind: .pullImage)
        _ = entryID(&board, kind: .pullImage)
        board.succeed(ok, at: at(1))
        #expect(board.failureNotices.isEmpty)
    }

    @Test func noticeTextWithoutAReasonStillNamesTheJob() {
        #expect(TaskBoard.noticeText(title: "Pull grafana/grafana:13", reason: "  \n ") == "Pull grafana/grafana:13 failed")
    }

    @Test func aTaskNoticeIsAnnouncedUnderItsOwnCategory() {
        #expect(NotificationCategory.forNotice(key: TaskBoard.noticeKey(for: UUID())) == .taskFailed)
        #expect(NotificationCategory.taskFailed.defaultEnabled)
        var notices = NoticeBook()
        let id = UUID()
        notices.reconcile([.init(key: TaskBoard.noticeKey(for: id), level: .warning, text: "Pull x failed: no",
                                 host: nil, section: "images", dismissible: true)], at: t0)
        #expect(NoticeAlerts.due(notices, at: t0, enabled: { _ in true }).count == 1)
        #expect(NoticeAlerts.due(notices, at: t0, only: [.taskFailed], enabled: { _ in true }).count == 1)
        #expect(NoticeAlerts.due(notices, at: t0, only: [.hostOffline], enabled: { _ in true }).isEmpty)
        #expect(NoticeAlerts.due(notices, at: t0, enabled: { $0 != .taskFailed }).isEmpty, "the category switch is honoured")
    }

    @Test func drawerIsHalfTheContentAreaWithAFloorAndACeiling() {
        #expect(TaskBoard.drawerWidth(in: 1_200, minimum: 420) == 600)
        #expect(TaskBoard.drawerWidth(in: 700, minimum: 420) == 420, "a floor so rows stay readable")
        #expect(TaskBoard.drawerWidth(in: 380, minimum: 420) == 380, "a narrow window gets the full width")
        #expect(TaskBoard.drawerWidth(in: 0, minimum: 420) == 420)
    }
}
