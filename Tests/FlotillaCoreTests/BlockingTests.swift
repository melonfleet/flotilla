import Foundation
import Testing
@testable import FlotillaCore

/// Many blocking jobs at once must not starve Swift's cooperative pool: while 64 jobs each block a
/// thread, an ordinary async task still runs at once. With `Task.detached` in place of
/// `Blocking.run`, the pool (one thread per core) fills and the probe waits behind the jobs — at
/// least one whole job, 4 s. The 3.5 s bound is that long because the rest of the suite runs in
/// parallel in this process and holds pool threads of its own: measured on 18 October, the probe
/// waited up to 2.3 s in a full run whatever the jobs' length, so at 0.8 s against 1 s jobs this
/// failed about one full run in three with `Blocking` working.
///
/// **macOS only.** On Linux, libdispatch serves the Swift executor and every queue from one global
/// pool with a hard thread cap, so 64 parked jobs can delay any other task there. That is a
/// property of the platform, not of `Blocking`, and the app — the only thing relying on this — is
/// macOS-only. The Linux CI runner failed it on most pushes on 18 October.
#if os(macOS)
@Test func blockingWorkLeavesTheCooperativePoolFree() async {
    let jobs = 64
    let started = Date()
    async let blocked: [Int] = withTaskGroup(of: Int.self) { group in
        for index in 0..<jobs {
            group.addTask { await Blocking.run { Thread.sleep(forTimeInterval: 4.0); return index } }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    try? await Task.sleep(for: .milliseconds(100))
    let probe = await Task.detached { Date() }.value
    #expect(probe.timeIntervalSince(started) < 3.5)
    #expect(await blocked.count == jobs)
}
#endif

/// The sweep moved ~100 `try await Task.detached { try … }.value` onto `Blocking.run`: what the work
/// throws must reach the caller as itself, and a value must come back unchanged.
@Test func blockingRunPassesThrownErrorsThrough() async {
    struct Refused: Error, Equatable {}
    await #expect(throws: Refused.self) { try await Blocking.run { () throws -> Int in throw Refused() } }
    let value = try? await Blocking.run { () throws -> String in "answered" }
    #expect(value == "answered")
}
