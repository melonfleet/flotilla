import SwiftUI
import FlotillaCore

/// Every long-running job the window has started this session, and where the Tasks drawer is
/// (Q63, Kamal, 19 October).
///
/// **It wraps `OperationProgress` rather than replacing it.** The callers — pulls, builds, sends,
/// fleet pushes, group starts — already write steps and output to that object, and nothing about
/// what they write changed; what changed is who holds it. One "active" slot became a list keyed
/// by identity, so hiding the drawer no longer drops a job's updates and a second job no longer
/// takes the first one's place. The ordering, the cap, the headline and the drawer's state are
/// `TaskBoard`'s, in `FlotillaCore`, with the tests.
@MainActor
@Observable
final class TaskCenter {
    private(set) var board = TaskBoard()
    /// The clock the headline is read at; moved on when a "finished" flash ends.
    private(set) var now = Date()
    @ObservationIgnored private var live: [UUID: OperationProgress] = [:]
    /// The task whose Retry has been launched and has not yet started its replacement. Retry is
    /// claimed when the new task starts, not when the button is pressed: a retried call can return
    /// at a guard without starting anything, and that must leave the failure, its notice and its
    /// Retry exactly as they were. Observed, so the drawer hides every Retry while one is in flight.
    private var retrying: UUID?
    @ObservationIgnored private var flashEnd: Task<Void, Never>?
    @ObservationIgnored private var highlightEnd: Task<Void, Never>?
    @ObservationIgnored private var autoMinimise: Task<Void, Never>?

    var headline: TaskBoard.Headline { board.headline(at: now) }

    func progress(_ id: UUID) -> OperationProgress? { live[id] }

    /// Whether Retry may be offered on this row now: the board allows it and the original call has
    /// let go of its guards. Read by the drawer, so it follows the busy state.
    func canRetry(_ id: UUID) -> Bool {
        guard retrying == nil, board.entry(id)?.offersRetry == true, let progress = live[id] else { return false }
        return progress.retryReady?() ?? true
    }

    /// Starts showing a job. The drawer rises on it; the window stays usable.
    func start(_ progress: OperationProgress) {
        autoMinimise?.cancel()   // a new job keeps the drawer up
        live[progress.id] = progress
        now = Date()
        // Claimed by the job it relaunched, which carries the same title — not by whatever else
        // happens to start while the retried call is on its way to `start`.
        if let original = retrying, board.entry(original)?.title == progress.title {
            retrying = nil
            board.retry(original)
        }
        board.start(progress.id, title: progress.title, kind: progress.kind, origin: progress.origin,
                    hasRetryAction: progress.retryAction != nil, hasCancelAction: progress.cancellation != nil,
                    at: now)
        progress.onChange = { [weak self, weak progress] in
            guard let self, let progress else { return }
            self.changed(progress)
        }
        changed(progress)
        lightNewRow(progress.id)
    }

    /// The new job's row is lit for a moment, so the eye finds it in a list that may be long.
    private func lightNewRow(_ id: UUID) {
        highlightEnd?.cancel()
        highlightEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.board.clearHighlight(id)
        }
    }

    /// Opens the list on one task, expanded — where a failure notice's button goes.
    func reveal(_ id: UUID) { board.reveal(id) }

    /// Stops a job, if its kind can be stopped: the process is ended and the call site, seeing the
    /// cancellation, records the task as cancelled. Nothing happens for a job that cannot be.
    func cancel(_ id: UUID) {
        guard board.requestCancel(id) else { return }
        live[id]?.cancellation?.cancel()
    }

    /// Runs the same job again as a new task. The old row stays, marked as retried once the new task
    /// has actually started, so there is one running job and one record of the failure — never two
    /// attempts claiming one row, and no retry spent on a call that did nothing.
    func retry(_ id: UUID) {
        guard canRetry(id), let action = live[id]?.retryAction else { return }
        retrying = id
        Task {
            await action()
            // It returned at a guard without starting a task: nothing was consumed.
            if retrying == id { retrying = nil }
        }
    }

    func minimise() { board.minimise() }
    func toggleList() { board.toggleList() }
    func showList() { board.showList() }
    func toggleExpanded(_ id: UUID) { board.toggleExpanded(id) }
    func toggleFinished() { board.toggleFinished() }
    func clearReveal() { board.clearReveal() }

    func clear(_ id: UUID) {
        if board.clear(id) { release([id]) }
    }

    func clearFinished() { release(board.clearFinished()) }

    private func changed(_ progress: OperationProgress) {
        let id = progress.id
        board.setLine(progress.latestLine, for: id)
        board.setStep(progress.currentStep, for: id)
        board.setFraction(progress.fraction, for: id)
        board.setContainer(progress.container, for: id)
        guard board.entry(id)?.state == .running, let outcome = progress.outcome else { return }
        now = Date()
        switch outcome {
        case .succeeded:
            release(board.succeed(id, at: now))
            // Finish and fail are read out; every line would be noise.
            AccessibilityNotification.Announcement("\(progress.title) finished").post()
            scheduleFlashEnd()
            scheduleAutoMinimise(after: id)
        case .failed(let reason):
            release(board.fail(id, reason: reason, at: now))
            AccessibilityNotification.Announcement("\(progress.title) failed").post()
        case .cancelled:
            release(board.cancel(id, at: now))
            AccessibilityNotification.Announcement("\(progress.title) cancelled").post()
            scheduleAutoMinimise(after: id)
        }
    }

    /// The last running job has ended and nothing needs looking at: the drawer sinks into the status
    /// item after a moment (Kamal, 19 October). Re-checked when the moment is up, so a job that
    /// started, a failure, or a row opened meanwhile keeps it where it is.
    private func scheduleAutoMinimise(after id: UUID) {
        autoMinimise?.cancel()
        guard board.shouldAutoMinimise(after: id) else { return }
        autoMinimise = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TaskBoard.autoMinimiseDelay))
            guard !Task.isCancelled, let self, self.board.shouldAutoMinimise(after: id) else { return }
            self.board.minimise()
        }
    }

    /// Moves the clock on once the "finished" flash is over, so the item goes quiet by itself.
    private func scheduleFlashEnd() {
        flashEnd?.cancel()
        guard let end = board.flashEnds(at: now) else { return }
        flashEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.now = Date()
            self.scheduleFlashEnd()
        }
    }

    private func release(_ ids: [UUID]) {
        for id in ids {
            live[id]?.onChange = nil
            live[id] = nil
        }
    }
}
