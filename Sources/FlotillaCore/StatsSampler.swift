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
    /// One retained history point for a container: the CPU percentage this sampler computed
    /// at that call (or `nil` when unknowable — see the type-level doc on why that happens)
    /// and the memory bytes reported at the same moment. Bundling both in one point means a
    /// caller drawing a CPU sparkline and a memory sparkline reads from one buffer instead of
    /// zipping two separately-trimmed arrays back together.
    ///
    /// Unknown CPU is stored as `nil`, not skipped: dropping the point would let a sparkline
    /// silently interpolate across a gap it never actually measured (a counter reset, a first
    /// sample) and claim continuity that did not exist. Storing the gap lets a renderer show
    /// one.
    public struct HistoryPoint: Sendable, Equatable {
        public let cpuPercent: Double?
        public let memoryUsageBytes: Int64?
    }

    /// Points retained per container. `pollIntervalSeconds` in `SettingsRegistry` defaults to
    /// 5s, so 40 points is ~3.3 minutes of trend — enough for a small sparkline to read as a
    /// shape rather than noise — while staying trivial in memory even for a fleet with many
    /// containers and a long-running app.
    private static let historyLimit = 40

    private struct Sample {
        var cpuUsageUsec: Int64
        var timestamp: Date
    }

    private let lock = NSLock()
    private var previous: [String: Sample] = [:]
    private var history: [String: [HistoryPoint]] = [:]

    public init() {}

    /// - Parameters:
    ///   - stats: the latest sample set, one entry per container currently reported by
    ///     `container stats`.
    ///   - now: wall-clock time this sample was taken.
    /// - Returns: CPU percent per container id, for ids where it could be computed. A
    ///   container missing from `stats` (stopped, removed) has its prior sample dropped so
    ///   it cannot leak state forever; if the same id reappears later it starts over as a
    ///   fresh first sample. Its retained `history(for:)` is dropped the same way.
    public func update(with stats: [ContainerStats], at now: Date) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }

        var result: [String: Double] = [:]
        var seen: Set<String> = []

        for stat in stats {
            seen.insert(stat.id)

            let cpuPercent = cpuPercent(for: stat, at: now)
            if let cpuPercent {
                result[stat.id] = cpuPercent
            }
            append(HistoryPoint(cpuPercent: cpuPercent, memoryUsageBytes: stat.memoryUsageBytes),
                   for: stat.id)
        }

        // Drop state for any id no longer present, so a removed container's previous
        // sample — and its history — cannot leak forever.
        previous = previous.filter { seen.contains($0.key) }
        history = history.filter { seen.contains($0.key) }

        return result
    }

    /// Retained history for `id`, oldest point first — the order a sparkline draws in, so the
    /// caller never has to reverse it. Empty if `id` has never been sampled or has since
    /// disappeared.
    public func history(for id: String) -> [HistoryPoint] {
        lock.lock()
        defer { lock.unlock() }
        return history[id] ?? []
    }

    private func cpuPercent(for stat: ContainerStats, at now: Date) -> Double? {
        guard let usec = stat.cpuUsageUsec else {
            previous.removeValue(forKey: stat.id)
            return nil
        }
        defer { previous[stat.id] = Sample(cpuUsageUsec: usec, timestamp: now) }

        guard let last = previous[stat.id] else { return nil }

        let elapsed = now.timeIntervalSince(last.timestamp)
        let delta = usec - last.cpuUsageUsec
        guard elapsed > 0, delta >= 0 else { return nil }

        return Double(delta) / (elapsed * 1_000_000) * 100
    }

    private func append(_ point: HistoryPoint, for id: String) {
        var points = history[id, default: []]
        points.append(point)
        if points.count > Self.historyLimit {
            points.removeFirst(points.count - Self.historyLimit)
        }
        history[id] = points
    }
}
