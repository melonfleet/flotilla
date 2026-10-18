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
