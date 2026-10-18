import Testing
@testable import FlotillaCore

/// Each operation stays suspended until the test releases it. Admission is synchronous at
/// `request`, and start notifications let tests advance without sleeps or scheduler guesses.
private actor ControlledChecks {
    private(set) var starts: [String] = []
    private(set) var maximumActive = 0
    private(set) var sawCancellation = false
    private var active = 0
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(_ key: String) async {
        let index = starts.count
        starts.append(key)
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { continuation in
            releases[index] = continuation
            let ready = observers.filter { $0.0 <= starts.count }
            observers.removeAll { $0.0 <= starts.count }
            for (_, observer) in ready { observer.resume() }
        }
        sawCancellation = sawCancellation || Task.isCancelled
        active -= 1
    }

    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finish(_ index: Int) {
        releases.removeValue(forKey: index)!.resume()
    }
}

@Test(.timeLimit(.minutes(1))) func coalescerJoinsRequestsForOneKey() async {
    let checks = ControlledChecks()
    let coalescer = KeyedCoalescer<String>(maxConcurrent: 4)
    let first = await coalescer.request("a") { await checks.run("a") }
    await checks.waitForStarts(1)
    let second = await coalescer.request("a") { await checks.run("duplicate") }
    await checks.finish(0)
    await first.wait()
    await second.wait()
    #expect(await checks.starts == ["a"])
}

@Test(.timeLimit(.minutes(1))) func coalescerForceWaitsForOneSubsequentRun() async {
    let checks = ControlledChecks()
    let coalescer = KeyedCoalescer<String>(maxConcurrent: 4)
    let first = await coalescer.request("a") { await checks.run("original") }
    await checks.waitForStarts(1)
    let forced = await coalescer.request("a", force: true) { await checks.run("forced") }
    let alsoForced = await coalescer.request("a", force: true) { await checks.run("duplicate") }
    let joined = await coalescer.request("a") { await checks.run("duplicate") }
    #expect(await checks.starts == ["original"])
    await checks.finish(0)
    await first.wait()
    await checks.waitForStarts(2)
    #expect(await checks.starts == ["original", "forced"])
    #expect(await checks.maximumActive == 1)
    await checks.finish(1)
    await forced.wait()
    await alsoForced.wait()
    await joined.wait()
    #expect(await checks.starts.count == 2)
}

@Test(.timeLimit(.minutes(1))) func coalescerBoundsConcurrencyAndDrainsQueue() async {
    let checks = ControlledChecks()
    let coalescer = KeyedCoalescer<String>(maxConcurrent: 4)
    var completions: [KeyedCoalescer<String>.Completion] = []
    for key in ["a", "b", "c", "d", "e", "f"] {
        completions.append(await coalescer.request(key) { await checks.run(key) })
    }
    await checks.waitForStarts(4)
    #expect(Set(await checks.starts) == Set(["a", "b", "c", "d"]))
    await checks.finish(0)
    await checks.waitForStarts(5)
    #expect(await checks.starts.last == "e")
    await checks.finish(1)
    await checks.waitForStarts(6)
    #expect(await checks.starts.last == "f")
    for index in 2..<6 { await checks.finish(index) }
    for completion in completions { await completion.wait() }
    #expect(await checks.maximumActive == 4)
}

@Test(.timeLimit(.minutes(1))) func coalescerForceWhileQueuedJoinsTheUnstartedRun() async {
    let checks = ControlledChecks()
    let coalescer = KeyedCoalescer<String>(maxConcurrent: 1)
    let first = await coalescer.request("a") { await checks.run("a") }
    await checks.waitForStarts(1)
    let queued = await coalescer.request("b") { await checks.run("b") }
    let forced = await coalescer.request("b", force: true) { await checks.run("duplicate") }
    await checks.finish(0)
    await first.wait()
    await checks.waitForStarts(2)
    await checks.finish(1)
    await queued.wait()
    await forced.wait()
    #expect(await checks.starts == ["a", "b"])
}

@Test(.timeLimit(.minutes(1))) func coalescerWaiterCancellationLeavesSharedRunAlive() async {
    let checks = ControlledChecks()
    let coalescer = KeyedCoalescer<String>(maxConcurrent: 4)
    let shared = await coalescer.request("a") { await checks.run("a") }
    await checks.waitForStarts(1)
    let waiter = Task { await shared.wait() }
    waiter.cancel()
    let joined = await coalescer.request("a") { await checks.run("duplicate") }
    await checks.finish(0)
    await waiter.value
    await joined.wait()
    #expect(await checks.starts == ["a"])
    #expect(await !checks.sawCancellation)
}
