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

/// Kyle, 18 October: a reply that never comes, behind a `Deadline`. The wait must end when the
/// deadline cancels it — releasing the task — and `onCancel` (which invalidates the XPC
/// connection) must run. Without the cancellation handler the operation is still suspended when
/// this test ends, and `finished` stays false.
@Test func aCancelledReplyEndsTheWaitAndReleasesTheConnection() async {
    let invalidated = Flag()
    let finished = Flag()
    let value: Int? = await Deadline.value(within: .milliseconds(100)) {
        let answer: Int? = await CancellableReply.value(cancelled: nil, onCancel: { invalidated.set() }) { _ in
            // Never resumes: a helper that doesn't reply.
        }
        finished.set()
        return answer
    }
    #expect(value == nil)
    let started = Date()
    while !finished.value, Date().timeIntervalSince(started) < 10 { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value, "the probe's task ended after the deadline")
    #expect(invalidated.value)
}

/// The reply and the error handler both calling back resume once, with the first; a cancellation
/// before or after the request starts ends the wait with the cancelled value.
@Test func aCancellableReplyResumesOnceWithTheFirstAnswer() async {
    let first = await CancellableReply.value(cancelled: 0, onCancel: {}) { resume in
        resume(1); resume(2)
    }
    #expect(first == 1)
    let task = Task {
        await CancellableReply.value(cancelled: -1, onCancel: {}) { _ in }
    }
    task.cancel()
    #expect(await task.value == -1)
    let early = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let started = Flag()
        let answer = await CancellableReply.value(cancelled: -1, onCancel: {}) { _ in started.set() }
        return (answer, started.value)
    }
    let (answer, started) = await early.value
    #expect(answer == -1)
    #expect(!started, "a task already cancelled never sends the request")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}
