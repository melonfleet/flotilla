import Foundation

/// Which of several overlapping refreshes may still write its answer.
///
/// **Why this exists (Kyle's review, 18 October):** the main actor stops two refreshes touching
/// state at the same instant, not one overtaking another across a suspension. Refresh A asked the
/// Flotilla Helper its version; refresh B, started after the helper was switched off, cleared the
/// version; then A's reply arrived and wrote the stale version back. Each refresh takes a ticket
/// when it starts, and a reply is applied only while its ticket is still the latest.
public struct RefreshGeneration: Sendable {
    public struct Ticket: Sendable, Equatable {
        fileprivate let value: UInt64
    }

    private var latest: UInt64 = 0

    public init() {}

    /// A new refresh starting; every earlier ticket stops being current.
    public mutating func begin() -> Ticket {
        latest &+= 1
        return Ticket(value: latest)
    }

    /// Whether a refresh holding `ticket` may still apply what it read.
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.value == latest }
}

/// An answer that must arrive within a bound, or not at all.
public enum Deadline {
    /// `operation`'s result, or `nil` once `limit` has passed. Returns at the limit even when the
    /// operation ignores cancellation — an XPC reply that never comes, say — so a caller's loop is
    /// never held by it; the operation is cancelled and its late result discarded.
    ///
    /// Not a task group: a group waits for every child before it returns, so a child that ignores
    /// cancellation would hold the group exactly as long as having no deadline.
    public static func value<T: Sendable>(within limit: Duration,
                                          _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            let work = Task { once.resume(await operation()) }
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
                work.cancel()
            }
            once.onResume { timer.cancel() }
        }
    }
}

/// A continuation resumed by whichever side answers first; later answers are dropped.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var resumed = false
    private var cleanup: (@Sendable () -> Void)?

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Runs `action` once resumed — at once if that has already happened.
    func onResume(_ action: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            if resumed { return true }
            cleanup = action
            return false
        }
        if now { action() }
    }

    func resume(_ value: T) {
        let (continuation, cleanup): (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?) = lock.withLock {
            guard !resumed else { return (nil, nil) }
            resumed = true
            defer { self.continuation = nil; self.cleanup = nil }
            return (self.continuation, self.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup?()
    }
}

/// One reply from a callback API — XPC, say — that the caller may stop waiting for.
///
/// **Why this exists (Kyle, 18 October):** `Deadline.value` cancels the operation at its limit
/// and returns, but a `withCheckedContinuation` that waits on an XPC reply does not notice the
/// cancellation. With a helper that never answers, every timed-out probe left its task suspended
/// and its connection open, and each refresh added another. Here cancellation resumes the wait
/// with `cancelled` and runs `onCancel` — which invalidates the connection — so the task ends and
/// whatever it holds is released. Resumed exactly once, whichever of the reply, an error and the
/// cancellation comes first.
public enum CancellableReply {
    /// `start` is given a `resume` it or its callbacks call with the answer; any call after the
    /// first is dropped. A task already cancelled does not call `start` at all.
    /// `start` runs in the caller's isolation, so a main-actor caller may hand it main-actor state.
    public static func value<T: Sendable>(isolation: isolated (any Actor)? = #isolation,
                                          cancelled: T,
                                          onCancel: @escaping @Sendable () -> Void,
                                          _ start: (_ resume: @escaping @Sendable (T) -> Void) -> Void) async -> T {
        let once = ReplyOnce<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation(isolation: isolation) { (continuation: CheckedContinuation<T, Never>) in
                guard once.arm(continuation) else { return }
                if Task.isCancelled {
                    once.resume(cancelled)
                    return
                }
                start { once.resume($0) }
            }
        } onCancel: {
            onCancel()
            once.resume(cancelled)
        }
    }
}

/// `ResumeOnce` for a wait whose cancellation may arrive before the continuation exists: the
/// first value is kept until `arm` hands it one.
private final class ReplyOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    /// An answer that came before `arm`: at most one. An array, not an optional, since `T` may
    /// itself be optional.
    private var early: [T] = []
    private var done = false

    /// Stores the continuation; false (having resumed it) if an answer already came.
    func arm(_ continuation: CheckedContinuation<T, Never>) -> Bool {
        let answer: [T] = lock.withLock {
            guard !early.isEmpty else {
                self.continuation = continuation
                return []
            }
            done = true
            defer { early = [] }
            return early
        }
        guard let value = answer.first else { return true }
        continuation.resume(returning: value)
        return false
    }

    func resume(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            guard let continuation else {
                if early.isEmpty { early = [value] }
                return nil
            }
            done = true
            self.continuation = nil
            return continuation
        }
        pending?.resume(returning: value)
    }
}
