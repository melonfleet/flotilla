import Foundation
import Testing
@testable import FlotillaCore

private func stat(_ id: String, usec: Int64, memory: Int64? = nil) -> ContainerStats {
    ContainerStats(id: id, cpuUsageUsec: usec, memoryUsageBytes: memory, memoryLimitBytes: nil,
                   networkRxBytes: nil, networkTxBytes: nil, blockReadBytes: nil,
                   blockWriteBytes: nil, numProcesses: nil)
}

@Test func firstSampleReturnsNilRatherThanZero() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    let result = sampler.update(with: [stat("web", usec: 1_000_000)], at: t0)

    #expect(result["web"] == nil)
}

@Test func twoSamplesAKnownIntervalApartGiveAKnownPercentage() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0)], at: t0)
    // 500_000 usec of CPU time over 1 second of wall clock = 50% of one core.
    let result = sampler.update(with: [stat("web", usec: 500_000)], at: t1)

    #expect(result["web"] == 50.0)
}

@Test func aCounterThatGoesBackwardsIsUnknownNotHuge() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 1_000_000)], at: t0)
    // A restarted container's counter starts over near zero — a smaller value than last time.
    let result = sampler.update(with: [stat("web", usec: 100)], at: t1)

    #expect(result["web"] == nil)
}

@Test func aRemovedContainersPriorSampleDoesNotLeakIntoAReappearance() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)
    let t2 = t1.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0)], at: t0)
    // "web" disappears from this sample (container removed).
    _ = sampler.update(with: [], at: t1)
    // It reappears — this must be treated as a fresh first sample, not resume the old delta.
    let result = sampler.update(with: [stat("web", usec: 999_999_999)], at: t2)

    #expect(result["web"] == nil)
}

@Test func zeroElapsedTimeIsHandledWithoutDividingByZero() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    _ = sampler.update(with: [stat("web", usec: 0)], at: t0)
    // Same timestamp as the previous sample.
    let result = sampler.update(with: [stat("web", usec: 500_000)], at: t0)

    #expect(result["web"] == nil)
}

@Test func negativeElapsedTimeIsHandledWithoutDividingByZero() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let earlier = t0.addingTimeInterval(-1)

    _ = sampler.update(with: [stat("web", usec: 0)], at: t0)
    let result = sampler.update(with: [stat("web", usec: 500_000)], at: earlier)

    #expect(result["web"] == nil)
}

@Test func aContainerWithNoCpuFieldIsUnknownAndClearsAnyPriorSample() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)
    let t2 = t1.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0)], at: t0)
    let missingField = ContainerStats(id: "web", cpuUsageUsec: nil, memoryUsageBytes: nil,
                                       memoryLimitBytes: nil, networkRxBytes: nil,
                                       networkTxBytes: nil, blockReadBytes: nil,
                                       blockWriteBytes: nil, numProcesses: nil)
    _ = sampler.update(with: [missingField], at: t1)
    // The prior sample was dropped when the field went missing, so this resumes as fresh.
    let result = sampler.update(with: [stat("web", usec: 999_999_999)], at: t2)

    #expect(result["web"] == nil)
}

@Test func multipleContainersAreTrackedIndependently() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(2)

    _ = sampler.update(with: [stat("web", usec: 0), stat("db", usec: 0)], at: t0)
    let result = sampler.update(with: [stat("web", usec: 2_000_000), stat("db", usec: 200_000)], at: t1)

    // 2_000_000 usec over 2s = 100%; 200_000 usec over 2s = 10%.
    #expect(result["web"] == 100.0)
    #expect(result["db"] == 10.0)
}

@Test func firstSampleStillRecordsAHistoryPointWithANilCPUGap() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    _ = sampler.update(with: [stat("web", usec: 1_000_000, memory: 4_096)], at: t0)

    let history = sampler.history(for: "web")
    #expect(history.count == 1)
    #expect(history[0].cpuPercent == nil)
    #expect(history[0].memoryUsageBytes == 4_096)
}

@Test func aCounterResetRecordsAHistoryPointWithANilCPUGapNotAHugeSpike() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 1_000_000, memory: 1_024)], at: t0)
    _ = sampler.update(with: [stat("web", usec: 100, memory: 2_048)], at: t1)

    let history = sampler.history(for: "web")
    #expect(history.count == 2)
    #expect(history[1].cpuPercent == nil)
    #expect(history[1].memoryUsageBytes == 2_048)
}

@Test func cpuPercentAndMemoryStayAlignedInTheSamePoint() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0, memory: 1_000)], at: t0)
    // 500_000 usec over 1s = 50%.
    _ = sampler.update(with: [stat("web", usec: 500_000, memory: 2_000)], at: t1)

    let history = sampler.history(for: "web")
    #expect(history.count == 2)
    #expect(history[1].cpuPercent == 50.0)
    #expect(history[1].memoryUsageBytes == 2_000)
}

@Test func historyIsReturnedOldestToNewest() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    for i in 0..<5 {
        _ = sampler.update(with: [stat("web", usec: Int64(i) * 1_000_000, memory: Int64(i))],
                            at: t0.addingTimeInterval(Double(i)))
    }

    let history = sampler.history(for: "web")
    #expect(history.map { $0.memoryUsageBytes } == [0, 1, 2, 3, 4])
}

@Test func historyBufferCapsAtTheLimitAndDropsOldestFirst() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    // Read from the sampler, never duplicated here — see the note on `historyLimit`.
    let limit = StatsSampler.historyLimit
    let overflow = 10

    for i in 0..<(limit + overflow) {
        _ = sampler.update(with: [stat("web", usec: Int64(i) * 1_000_000, memory: Int64(i))],
                            at: t0.addingTimeInterval(Double(i)))
    }

    let history = sampler.history(for: "web")
    #expect(history.count == limit)
    // The oldest surviving point is the one from iteration `overflow`, not 0.
    #expect(history.first?.memoryUsageBytes == Int64(overflow))
    #expect(history.last?.memoryUsageBytes == Int64(limit + overflow - 1))
}

@Test func aVanishedContainersHistoryIsReleased() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0, memory: 1_024)], at: t0)
    #expect(sampler.history(for: "web").count == 1)

    // "web" disappears from this sample (container removed).
    _ = sampler.update(with: [], at: t1)

    #expect(sampler.history(for: "web").isEmpty)
}

@Test func aReappearingContainerStartsHistoryOverFromEmpty() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)
    let t2 = t1.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0, memory: 1_024)], at: t0)
    _ = sampler.update(with: [], at: t1)
    _ = sampler.update(with: [stat("web", usec: 999_999_999, memory: 2_048)], at: t2)

    let history = sampler.history(for: "web")
    #expect(history.count == 1)
    #expect(history[0].cpuPercent == nil)
    #expect(history[0].memoryUsageBytes == 2_048)
}

@Test func historyForAnUnknownIdIsEmpty() {
    let sampler = StatsSampler()

    #expect(sampler.history(for: "never-seen").isEmpty)
}

@Test func multipleContainersHaveIndependentHistories() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    let t1 = t0.addingTimeInterval(1)

    _ = sampler.update(with: [stat("web", usec: 0, memory: 10), stat("db", usec: 0, memory: 20)],
                        at: t0)
    _ = sampler.update(with: [stat("web", usec: 500_000, memory: 11), stat("db", usec: 0, memory: 20)],
                        at: t1)

    #expect(sampler.history(for: "web").count == 2)
    #expect(sampler.history(for: "db").count == 2)
}

// MARK: - Byte-counter rates
//
// The four byte counters are cumulative exactly as `cpuUsageUsec` is, so they inherit its
// traps: a first sample says nothing about rate, and a counter that goes backwards means a
// restart rather than negative throughput. These pin that the answer is nil in both cases and
// never a misleading zero.

private func ioStat(_ id: String, usec: Int64 = 0,
                    rx: Int64? = nil, tx: Int64? = nil,
                    read: Int64? = nil, write: Int64? = nil,
                    processes: Int? = nil) -> ContainerStats {
    ContainerStats(id: id, cpuUsageUsec: usec, memoryUsageBytes: nil, memoryLimitBytes: nil,
                   networkRxBytes: rx, networkTxBytes: tx, blockReadBytes: read,
                   blockWriteBytes: write, numProcesses: processes)
}

@Test func firstSampleHasNoRatesRatherThanZeroRates() {
    let sampler = StatsSampler()
    _ = sampler.update(with: [ioStat("web", rx: 1_000, tx: 500)],
                       at: Date(timeIntervalSince1970: 1000))

    let point = sampler.history(for: "web").last
    // A zero here would read as "no traffic" when the truth is "not measurable yet".
    #expect(point?.networkRxBytesPerSecond == nil)
    #expect(point?.networkTxBytesPerSecond == nil)
    #expect(point?.blockReadBytesPerSecond == nil)
    #expect(point?.blockWriteBytesPerSecond == nil)
}

@Test func ratesAreBytesPerSecondFromTheCounterDelta() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    _ = sampler.update(with: [ioStat("web", rx: 1_000, tx: 200, read: 4_096, write: 0)], at: t0)
    _ = sampler.update(with: [ioStat("web", rx: 11_000, tx: 700, read: 4_096, write: 2_048)],
                       at: t0.addingTimeInterval(5))

    let point = sampler.history(for: "web").last
    #expect(point?.networkRxBytesPerSecond == 2_000)   // 10_000 bytes over 5s
    #expect(point?.networkTxBytesPerSecond == 100)     //    500 bytes over 5s
    // Unchanged counter is a real zero — nothing was read — and must not become nil.
    #expect(point?.blockReadBytesPerSecond == 0)
    #expect(point?.blockWriteBytesPerSecond == 409.6)
}

@Test func aCounterGoingBackwardsYieldsNilNotNegativeThroughput() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)

    _ = sampler.update(with: [ioStat("web", rx: 50_000)], at: t0)
    // The container restarted, so its counters reset.
    _ = sampler.update(with: [ioStat("web", rx: 12)], at: t0.addingTimeInterval(5))

    #expect(sampler.history(for: "web").last?.networkRxBytesPerSecond == nil)
}

@Test func memoryLimitAndProcessCountAreRetainedForTheDashboard() {
    let sampler = StatsSampler()
    let stats = ContainerStats(id: "web", cpuUsageUsec: 0, memoryUsageBytes: 100,
                               memoryLimitBytes: 1_000, networkRxBytes: nil, networkTxBytes: nil,
                               blockReadBytes: nil, blockWriteBytes: nil, numProcesses: 17)
    _ = sampler.update(with: [stats], at: Date(timeIntervalSince1970: 1000))

    let point = sampler.history(for: "web").last
    // Both were decoded by ContainerStats all along and discarded by the sampler.
    #expect(point?.memoryLimitBytes == 1_000)
    #expect(point?.processCount == 17)
}

@Test func everyPointCarriesTheWallClockItWasSampledAt() {
    let sampler = StatsSampler()
    let t0 = Date(timeIntervalSince1970: 1000)
    _ = sampler.update(with: [ioStat("web")], at: t0)
    // Charts plot against real time, and a late poll must not be drawn as if it were on time.
    #expect(sampler.history(for: "web").last?.date == t0)
}
