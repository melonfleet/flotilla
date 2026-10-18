import Foundation
import Testing
@testable import FlotillaCore

/// Kyle's interleaving: refresh A starts, refresh B starts (the helper was switched off) and
/// finishes, then A's reply arrives. A must not apply; B, the latest, still may.
@Test func anOlderRefreshCannotApplyAfterANewerOneStarts() {
    var generation = RefreshGeneration()
    let a = generation.begin()
    #expect(generation.isCurrent(a))
    let b = generation.begin()
    #expect(!generation.isCurrent(a))
    #expect(generation.isCurrent(b))
    // B having finished changes nothing: only a newer start retires it.
    #expect(generation.isCurrent(b))
    _ = generation.begin()
    #expect(!generation.isCurrent(b))
}

/// An answer inside the limit comes back as itself.
@Test func aDeadlinePassesAPromptAnswerThrough() async {
    let value = await Deadline.value(within: .seconds(5)) { 7 }
    #expect(value == 7)
}

/// An operation that never answers and ignores cancellation — an XPC reply that never comes —
/// still lets the caller go at the limit. With a task group in place of the race this waits the
/// operation's whole 30 s, so the wall-clock bound is what makes the failure legible. The bound is
/// 10 s rather than near the 0.2 s limit because the rest of the suite runs in parallel and holds
/// pool threads the timer needs (see `blockingWorkLeavesTheCooperativePoolFree`): measured at 4.5 s
/// in a full run on 18 October against 0.22 s alone.
@Test func aDeadlineReturnsAtTheLimitWhenTheAnswerNeverComes() async {
    let started = Date()
    let value: Int? = await Deadline.value(within: .milliseconds(200)) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { continuation.resume(returning: 1) }
        }
    }
    #expect(value == nil)
    #expect(Date().timeIntervalSince(started) < 10)
}
