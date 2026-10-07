import Foundation
import FlotillaCore

/// One event from a live log tail.
enum LiveLogEvent: Sendable {
    case line(LogLine.Stream, String)
    /// The tail stopped on its own — the container exited, the machine stopped, or the CLI
    /// refused. Cancelling does not produce this: the stream simply ends.
    case ended(CommandStreamEnd)
    /// The tail could not be started at all. Carries the reason, because there are no stderr
    /// lines to explain it — nothing ran.
    case failed(String)
}

/// The live tail, bridged from a background process to a view.
///
/// `AsyncStream` rather than a callback the view registers, because a view's lifetime is the
/// thing that has to stop the child and `for await` in a `Task` already models that exactly:
/// cancel the task, the stream terminates, `onTermination` cancels the child. Every other shape
/// needed the view to remember to clean up in `onDisappear`, and a `container logs --follow` that
/// outlives the window it was feeding is a process leak per tab visit.
extension AppModel {
    /// A container's live tail — on This Mac, or on a paired host through its follow (PLAN.md
    /// Phase D, D2), which arrives through the same `ContainerCLI` call.
    func liveContainerLogs(_ id: String, lines: Int, bootLog: Bool,
                           host: HostRef = .local) -> AsyncStream<LiveLogEvent> {
        let cli: ContainerCLI
        do { cli = try self.cli(for: host) } catch {
            return AsyncStream { $0.yield(.failed(String(describing: error))); $0.finish() }
        }
        return Self.liveLogs(cli: cli) { cli, onLine, onEnd in
            try cli.followLogs(id, lines: lines, bootLog: bootLog, onLine: onLine, onEnd: onEnd)
        }
    }

    nonisolated func liveMachineLogs(_ id: String, lines: Int,
                                     boot: Bool) -> AsyncStream<LiveLogEvent> {
        Self.liveLogs(cli: cli) { cli, onLine, onEnd in
            try cli.followMachineLogs(id, lines: lines, boot: boot, onLine: onLine, onEnd: onEnd)
        }
    }

    /// Lines a tail may hold for a reader that has fallen behind. Past it the oldest go, are
    /// counted, and the count is said in a notice — so a host writing faster than the window can
    /// draw costs this Mac a fixed amount, however long it goes on (Iris's review, High 1).
    nonisolated static let liveBufferLines = 5_000

    private nonisolated static func liveLogs(
        cli: ContainerCLI,
        start: @escaping @Sendable (ContainerCLI,
                                    @escaping @Sendable (LogLine.Stream, String) -> Void,
                                    @escaping @Sendable (CommandStreamEnd) -> Void) throws -> CommandStream
    ) -> AsyncStream<LiveLogEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(liveBufferLines)) { continuation in
            // Spawning is a `Process.run` and a pair of threads; off the main actor with the
            // rest of the CLI work, so turning the tail on never stutters the window.
            let pending = PendingStream()
            let dropped = DropCount()
            continuation.onTermination = { _ in pending.cancel() }
            Task.detached {
                do {
                    let handle = try start(
                        cli,
                        { stream, text in
                            if case .dropped = continuation.yield(.line(stream, text)) {
                                dropped.add()
                            } else if let count = dropped.take() {
                                continuation.yield(.line(.notice, "\(count) lines dropped: the window fell behind"))
                            }
                        },
                        { end in
                            continuation.yield(.ended(end))
                            continuation.finish()
                        }
                    )
                    pending.adopt(handle)
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                    continuation.finish()
                }
            }
        }
    }
}

/// Lines a bounded tail has had to drop since it last said so.
private final class DropCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    /// The count, reset — or `nil` when nothing was dropped.
    func take() -> Int? {
        lock.withLock {
            defer { count = 0 }
            return count > 0 ? count : nil
        }
    }
}

/// Holds the child between "the consumer went away" and "the child finished starting".
///
/// Those two orders are both real: a tab closed in the moment after the toggle is flipped
/// terminates the stream before `Process.run` has returned, and without this the handle would
/// arrive afterwards with nobody left to cancel it. Cancelling late is the same as cancelling
/// early here — which is why `adopt` on an already-cancelled box stops the child immediately
/// rather than storing it.
private final class PendingStream: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: CommandStream?
    private var token: UUID?
    private var cancelled = false

    func adopt(_ handle: CommandStream) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled {
            self.handle = handle
            // Registered so quitting the app can end it. Nothing in the view layer runs on
            // termination — see `LiveStreamRegistry`, which was written after a clean quit left
            // five `--follow` children reparented to launchd.
            token = LiveStreamRegistry.shared.register(handle)
        }
        lock.unlock()
        if alreadyCancelled { handle.cancel() }
    }

    func cancel() {
        lock.lock()
        let handle = self.handle
        let token = self.token
        self.handle = nil
        self.token = nil
        cancelled = true
        lock.unlock()
        if let token { LiveStreamRegistry.shared.remove(token) }
        handle?.cancel()
    }
}
