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
    nonisolated func liveContainerLogs(_ id: String, lines: Int,
                                       bootLog: Bool) -> AsyncStream<LiveLogEvent> {
        liveLogs { cli, onLine, onEnd in
            try cli.followLogs(id, lines: lines, bootLog: bootLog, onLine: onLine, onEnd: onEnd)
        }
    }

    nonisolated func liveMachineLogs(_ id: String, lines: Int,
                                     boot: Bool) -> AsyncStream<LiveLogEvent> {
        liveLogs { cli, onLine, onEnd in
            try cli.followMachineLogs(id, lines: lines, boot: boot, onLine: onLine, onEnd: onEnd)
        }
    }

    private nonisolated func liveLogs(
        start: @escaping @Sendable (ContainerCLI,
                                    @escaping @Sendable (LogLine.Stream, String) -> Void,
                                    @escaping @Sendable (CommandStreamEnd) -> Void) throws -> CommandStream
    ) -> AsyncStream<LiveLogEvent> {
        AsyncStream { continuation in
            // Spawning is a `Process.run` and a pair of threads; off the main actor with the
            // rest of the CLI work, so turning the tail on never stutters the window.
            let pending = PendingStream()
            continuation.onTermination = { _ in pending.cancel() }
            let cli = self.cli
            Task.detached {
                do {
                    let handle = try start(
                        cli,
                        { stream, text in continuation.yield(.line(stream, text)) },
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
