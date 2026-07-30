import Foundation

/// Turns `container stats`'s cumulative `cpuUsageUsec` counter into a CPU percentage by
/// diffing successive samples over wall-clock time — see the note on
/// `ContainerStats.cpuUsageUsec`: a single sample is not meaningful on its own.
///
/// The percentage is **per-core, not normalised across cores**: 100% means one core
/// saturated for the whole interval, matching what the counter's own units (CPU-seconds
/// consumed) imply, and a container spread across N cores can report up to N*100%.
/// `ContainerStats` carries no core-count for the container it describes, so normalising
/// against host or container core count — if a caller wants that view — is left to the UI.
///
/// A container's percentage is unknowable, not zero, when: it is the first sample seen for
/// that id, the elapsed time since the last sample is zero or negative, or the counter went
/// backwards (the container restarted, so the delta would be meaningless or a bogus wrap
/// guess). In every such case the container's id is simply **absent** from the returned
/// dictionary — a plain subscript already returns `nil` for a missing key, which is exactly
/// the "we don't know yet" signal a table needs to avoid painting a false 0% on first paint.
///
/// Call sites inject `now` rather than this type calling `Date()` itself, so behaviour is
/// deterministic under test.
public final class StatsSampler: @unchecked Sendable {
    private struct Sample {
        var cpuUsageUsec: Int64
        var timestamp: Date
    }

    private let lock = NSLock()
    private var previous: [String: Sample] = [:]

    public init() {}

    /// - Parameters:
    ///   - stats: the latest sample set, one entry per container currently reported by
    ///     `container stats`.
    ///   - now: wall-clock time this sample was taken.
    /// - Returns: CPU percent per container id, for ids where it could be computed. A
    ///   container missing from `stats` (stopped, removed) has its prior sample dropped so
    ///   it cannot leak state forever; if the same id reappears later it starts over as a
    ///   fresh first sample.
    public func update(with stats: [ContainerStats], at now: Date) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }

        var result: [String: Double] = [:]
        var seen: Set<String> = []

        for stat in stats {
            seen.insert(stat.id)

            guard let usec = stat.cpuUsageUsec else {
                previous.removeValue(forKey: stat.id)
                continue
            }
            defer { previous[stat.id] = Sample(cpuUsageUsec: usec, timestamp: now) }

            guard let last = previous[stat.id] else { continue }

            let elapsed = now.timeIntervalSince(last.timestamp)
            let delta = usec - last.cpuUsageUsec
            guard elapsed > 0, delta >= 0 else { continue }

            result[stat.id] = Double(delta) / (elapsed * 1_000_000) * 100
        }

        // Drop state for any id no longer present, so a removed container's previous
        // sample cannot leak forever.
        previous = previous.filter { seen.contains($0.key) }

        return result
    }
}
