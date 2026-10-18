import Foundation

/// Shares asynchronous work for a key and bounds the number of keys running at once.
/// Operations must finish their work before returning. Cancelling a waiter does not cancel work.
public actor KeyedCoalescer<Key: Hashable & Sendable> {
    /// A completion can be awaited independently by many callers, without exposing cancellation
    /// of the shared task. A cancelled caller still waits for the operation it requested.
    public struct Completion: Sendable {
        fileprivate let task: Task<Void, Never>

        public func wait() async { await task.value }
    }

    private struct Run {
        let completion: Completion
        let start: AsyncStream<Void>.Continuation
    }

    private struct Entry {
        var current: Run
        var running = false
        var next: Run?
    }

    private let limit: Int
    private var active = 0
    private var entries: [Key: Entry] = [:]
    private var queue: [Key] = []

    public init(maxConcurrent: Int) {
        precondition(maxConcurrent > 0)
        limit = maxConcurrent
    }

    /// Returns the shared completion to await. A force during a running operation joins one
    /// follow-up operation; a force while queued joins that operation, which has yet to start.
    /// Multiple forces before the follow-up starts collapse into that same follow-up.
    public func request(_ key: Key, force: Bool = false,
                        operation: @escaping @Sendable () async -> Void) -> Completion {
        if var entry = entries[key] {
            if force && entry.running {
                let next = entry.next ?? makeRun(key, operation: operation)
                entry.next = next
                entries[key] = entry
                return next.completion
            }
            return (entry.next ?? entry.current).completion
        }
        let run = makeRun(key, operation: operation)
        entries[key] = Entry(current: run)
        queue.append(key)
        drain()
        return run.completion
    }

    private func makeRun(_ key: Key, operation: @escaping @Sendable () async -> Void) -> Run {
        let (stream, start) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { await operation() }
            finished(key)
        }
        return Run(completion: Completion(task: task), start: start)
    }

    private func finished(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        active -= 1
        if let next = entry.next {
            entries[key] = Entry(current: next)
            queue.append(key)
        }
        drain()
    }

    private func drain() {
        while active < limit, !queue.isEmpty {
            let key = queue.removeFirst()
            guard var entry = entries[key] else { continue }
            entry.running = true
            entries[key] = entry
            active += 1
            entry.current.start.yield(())
            entry.current.start.finish()
        }
    }
}
