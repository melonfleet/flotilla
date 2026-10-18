import Foundation
import Testing
@testable import FlotillaCore

/// Many blocking jobs at once must not starve Swift's cooperative pool: while 64 jobs each block a
/// thread, an ordinary async task still runs at once. With `Task.detached` in place of
/// `Blocking.run`, the pool (one thread per core) fills and the probe waits behind the jobs.
@Test func blockingWorkLeavesTheCooperativePoolFree() async {
    let jobs = 64
    let started = Date()
    async let blocked: [Int] = withTaskGroup(of: Int.self) { group in
        for index in 0..<jobs {
            group.addTask { await Blocking.run { Thread.sleep(forTimeInterval: 1.0); return index } }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    try? await Task.sleep(for: .milliseconds(100))
    let probe = await Task.detached { Date() }.value
    #expect(probe.timeIntervalSince(started) < 0.8)
    #expect(await blocked.count == jobs)
}
