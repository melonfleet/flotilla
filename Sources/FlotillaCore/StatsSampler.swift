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
        /// Wall clock, so a chart can plot against real time rather than sample index — the
        /// two diverge whenever a poll is late or the interval setting changes.
        public let date: Date
        public let cpuPercent: Double?
        public let memoryUsageBytes: Int64?
        public let memoryLimitBytes: Int64?
        /// Bytes per second, from the delta of the cumulative counters. `nil` on the first
        /// sample or after a counter reset, for the same reason CPU is.
        public let networkRxBytesPerSecond: Double?
        public let networkTxBytesPerSecond: Double?
        public let blockReadBytesPerSecond: Double?
        public let blockWriteBytesPerSecond: Double?
        public let processCount: Int?

        public init(date: Date, cpuPercent: Double?, memoryUsageBytes: Int64?,
                    memoryLimitBytes: Int64? = nil,
                    networkRxBytesPerSecond: Double? = nil,
                    networkTxBytesPerSecond: Double? = nil,
                    blockReadBytesPerSecond: Double? = nil,
                    blockWriteBytesPerSecond: Double? = nil,
                    processCount: Int? = nil) {
            self.date = date
            self.cpuPercent = cpuPercent
            self.memoryUsageBytes = memoryUsageBytes
            self.memoryLimitBytes = memoryLimitBytes
            self.networkRxBytesPerSecond = networkRxBytesPerSecond
            self.networkTxBytesPerSecond = networkTxBytesPerSecond
            self.blockReadBytesPerSecond = blockReadBytesPerSecond
            self.blockWriteBytesPerSecond = blockWriteBytesPerSecond
            self.processCount = processCount
        }
    }

    /// Points retained per container. At the default 5s poll this is **one hour** of trend,
    /// which is what the dashboard's longest range needs.
    ///
    /// Raised from 40 (~3.3 minutes) when the dashboard grew real charts. The cost is bounded
    /// and small: a `HistoryPoint` is a handful of optional numbers, so 720 of them is tens of
    /// kilobytes per container. A 24-hour range is deliberately NOT supported by simply raising
    /// this further — 17,280 points per container would be a different design (downsampling to
    /// per-minute averages beyond the recent window), and pretending otherwise would give a
    /// 24h button that silently showed an hour.
    /// Public so tests assert against the real value instead of duplicating the number.
    /// A test that hardcodes a constant it does not own breaks on every legitimate change —
    /// and worse, can encode a stale value as the expected one, which is exactly how the
    /// `volume create --size` bug got written into the suite as correct.
    public static let historyLimit = 720

    private struct Sample {
        var cpuUsageUsec: Int64
        var networkRxBytes: Int64?
        var networkTxBytes: Int64?
        var blockReadBytes: Int64?
        var blockWriteBytes: Int64?
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

            // Rates are computed BEFORE `cpuPercent` updates `previous`, since both read the
            // same prior sample. Reversing these two lines would silently compare a counter
            // against itself and report every rate as zero.
            let rates = rates(for: stat, at: now)
            let cpuPercent = cpuPercent(for: stat, at: now)
            if let cpuPercent {
                result[stat.id] = cpuPercent
            }
            append(HistoryPoint(date: now,
                                cpuPercent: cpuPercent,
                                memoryUsageBytes: stat.memoryUsageBytes,
                                memoryLimitBytes: stat.memoryLimitBytes,
                                networkRxBytesPerSecond: rates.rx,
                                networkTxBytesPerSecond: rates.tx,
                                blockReadBytesPerSecond: rates.read,
                                blockWriteBytesPerSecond: rates.write,
                                processCount: stat.numProcesses),
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

    /// Bytes per second for the four cumulative byte counters.
    ///
    /// Same rules as CPU, and for the same reason: a single sample of a cumulative counter says
    /// how much has happened since the container started, not how fast anything is happening
    /// now. `nil` on a first sample, a non-positive interval, or a counter that went backwards
    /// (a restart), because each of those makes the delta meaningless rather than zero.
    private func rates(for stat: ContainerStats, at now: Date)
    -> (rx: Double?, tx: Double?, read: Double?, write: Double?) {
        guard let last = previous[stat.id] else { return (nil, nil, nil, nil) }
        let elapsed = now.timeIntervalSince(last.timestamp)
        guard elapsed > 0 else { return (nil, nil, nil, nil) }

        func rate(_ current: Int64?, _ earlier: Int64?) -> Double? {
            guard let current, let earlier, current >= earlier else { return nil }
            return Double(current - earlier) / elapsed
        }
        return (rate(stat.networkRxBytes, last.networkRxBytes),
                rate(stat.networkTxBytes, last.networkTxBytes),
                rate(stat.blockReadBytes, last.blockReadBytes),
                rate(stat.blockWriteBytes, last.blockWriteBytes))
    }

    private func cpuPercent(for stat: ContainerStats, at now: Date) -> Double? {
        guard let usec = stat.cpuUsageUsec else {
            previous.removeValue(forKey: stat.id)
            return nil
        }
        defer {
            previous[stat.id] = Sample(cpuUsageUsec: usec,
                                       networkRxBytes: stat.networkRxBytes,
                                       networkTxBytes: stat.networkTxBytes,
                                       blockReadBytes: stat.blockReadBytes,
                                       blockWriteBytes: stat.blockWriteBytes,
                                       timestamp: now)
        }

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
