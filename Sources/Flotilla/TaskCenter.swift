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
    @ObservationIgnored private var flashEnd: Task<Void, Never>?

    var headline: TaskBoard.Headline { board.headline(at: now) }

    func progress(_ id: UUID) -> OperationProgress? { live[id] }

    /// Starts showing a job. The drawer rises on it; the window stays usable.
    func start(_ progress: OperationProgress) {
        live[progress.id] = progress
        now = Date()
        board.start(progress.id, title: progress.title, at: now)
        progress.onChange = { [weak self, weak progress] in
            guard let self, let progress else { return }
            self.changed(progress)
        }
        changed(progress)
    }

    func minimise() { board.minimise() }
    func toggleList() { board.toggleList() }
    func showList() { board.showList() }
    func show(_ id: UUID) { board.show(id) }

    func clear(_ id: UUID) {
        if board.clear(id) { release([id]) }
    }

    func clearFinished() { release(board.clearFinished()) }

    private func changed(_ progress: OperationProgress) {
        let id = progress.id
        board.setLine(progress.latestLine, for: id)
        guard board.entry(id)?.state == .running, let outcome = progress.outcome else { return }
        now = Date()
        switch outcome {
        case .succeeded:
            release(board.succeed(id, at: now))
            // Finish and fail are read out; every line would be noise.
            AccessibilityNotification.Announcement("\(progress.title) finished").post()
            scheduleFlashEnd()
        case .failed(let reason):
            release(board.fail(id, reason: reason, at: now))
            AccessibilityNotification.Announcement("\(progress.title) failed").post()
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
