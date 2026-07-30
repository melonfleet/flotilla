import Foundation
import Testing
@testable import FlotillaCore

private func stat(_ id: String, usec: Int64) -> ContainerStats {
    ContainerStats(id: id, cpuUsageUsec: usec, memoryUsageBytes: nil, memoryLimitBytes: nil,
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
