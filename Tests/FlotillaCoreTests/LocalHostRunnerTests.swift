import Foundation
import Testing
@testable import FlotillaCore

/// Tests for the process boundary itself: concurrent drain, byte ceilings, deadline.
///
/// **These drive `/bin/sh` on purpose, and that is not a widening of the allowlist.** `LocalHost`
/// is constructed here directly with an injected resolver, so nothing goes near `Allowlist` or
/// `ContainerCLI`; the point is to control exactly how much a child writes, to which stream, and
/// how long it lives — which no `container` subcommand lets us do. Production still launches only
/// the resolved `container` binary.
///
/// Small limits so the suite stays fast: the ceilings are injected, not the defaults.
private func runner(limitBytes: Int = 64 * 1024,
                    grace: TimeInterval = 1,
                    drainGrace: TimeInterval = 1) -> LocalHost {
    LocalHost(resolve: { "/bin/sh" },
              limits: .init(maxBytesPerStream: limitBytes,
                            terminationGrace: grace,
                            drainGrace: drainGrace))
}

@Test func smallOutputSurvivesIntactOnBothStreams() throws {
    let result = try runner().run(["-c", "printf 'out'; printf 'err' 1>&2"])
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
    #expect(result.exitCode == 0)
    #expect(!result.stdoutTruncated)
    #expect(!result.stderrTruncated)
}

@Test func aFloodOnBothStreamsAtOnceDoesNotDeadlock() throws {
    // **The regression test for the bug that shipped.** Before the fix, stdout was drained to EOF
    // before stderr was read at all, so a child writing enough to fill the stderr pipe buffer
    // (64 KiB on Darwin) blocked on stderr while we blocked on stdout — forever. This test would
    // have hung rather than failed, which is exactly why the bug survived a green suite.
    //
    // Interleaved writes, and far more than one pipe buffer on each stream.
    let script = """
    i=0
    while [ $i -lt 400 ]; do
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 1>&2
      i=$((i+1))
    done
    """
    let result = try runner(limitBytes: 8 * 1024).run(["-c", script])
    #expect(result.exitCode == 0)
    // Both hit the ceiling, both say so, and neither exceeds it.
    #expect(result.stdoutTruncated)
    #expect(result.stderrTruncated)
    #expect(result.stdout.utf8.count <= 8 * 1024)
    #expect(result.stderr.utf8.count <= 8 * 1024)
    // And what was kept is the *start* of the stream, not a jumble of the two.
    #expect(result.stdout.allSatisfy { $0 == "a" })
    #expect(result.stderr.allSatisfy { $0 == "b" })
}

@Test func aLargeStreamIsCappedWhileTheOtherStaysWhole() throws {
    let script = "i=0; while [ $i -lt 300 ]; do printf '%0.sx' $(seq 1 100); i=$((i+1)); done; printf 'small' 1>&2"
    let result = try runner(limitBytes: 4 * 1024).run(["-c", script])
    #expect(result.stdoutTruncated)
    #expect(result.stdout.utf8.count <= 4 * 1024)
    // The small stream is unaffected — the ceiling is per stream, so a noisy stdout cannot cost
    // us the error text, which is usually the more useful half.
    #expect(result.stderr == "small")
    #expect(!result.stderrTruncated)
}

@Test func outputExactlyAtTheCeilingIsNotReportedAsTruncated() throws {
    // Boundary: at the limit is complete; one byte past it is not. Off-by-one here would either
    // cry truncation on every full read or hide a real cut.
    let limit = 1024
    let result = try runner(limitBytes: limit).run(["-c", "printf '%0.sy' $(seq 1 1024)"])
    #expect(result.stdout.utf8.count == limit)
    #expect(!result.stdoutTruncated)
}

@Test func aChildThatOutlivesItsDeadlineIsStoppedAndReported() throws {
    let start = Date()
    #expect(throws: ContainerCLIError.self) {
        try runner().run(["-c", "sleep 30"], timeout: 0.4)
    }
    // Returned promptly rather than after 30s, so the deadline actually fired.
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func theTimeoutErrorReportsTheLimitWithoutEchoingFlagValues() throws {
    // The message reaches an alert, so it must name the command and **not** its arguments.
    // `--env TOKEN=…` in a timeout dialog is the audit's SEC-03 leak on a more exposed surface.
    do {
        _ = try runner().run(["-c", "sleep 30", "--env", "TOKEN=hunter2"], timeout: 0.3)
        Issue.record("expected a timeout")
    } catch let error as ContainerCLIError {
        guard case .timedOut(let command, let seconds) = error else {
            Issue.record("expected .timedOut, got \(error)")
            return
        }
        #expect(seconds == 0.3)
        #expect(!error.description.contains("hunter2"))
        #expect(!command.contains("hunter2"))
        // An honest sentence, not a raw enum.
        #expect(error.description.contains("stopped"))
    }
}

@Test func aSummarisedCommandKeepsTheSubcommandChainAndDropsTheRest() {
    // Unit-level, because the redaction rule is the security-relevant part and driving it
    // through a real timeout only ever exercises one shape of argv.
    #expect(LocalHost.summarise(["logs", "-n", "500", "web"]) == "logs")
    #expect(LocalHost.summarise(["machine", "run", "-n", "park"]) == "machine run")
    #expect(LocalHost.summarise(["run", "--env", "TOKEN=hunter2", "alpine"]) == "run")
    #expect(LocalHost.summarise([]) == "command")
    // Flags first: nothing safe to name, so nothing is named.
    #expect(LocalHost.summarise(["--env", "TOKEN=hunter2"]) == "--env")
}

@Test func aChildIgnoringSIGTERMIsStillKilledAndDoesNotHoldUsViaAGrandchild() throws {
    // `trap '' TERM` makes terminate() a no-op — the case that used to leave a process holding
    // its pipes for the lifetime of the app.
    //
    // It also caught a second bug in the fix itself. `sh` with a trap installed cannot exec, so
    // it forks `sleep` and waits; SIGKILL reaps `sh`, `sleep` inherits the pipe, and the readers
    // saw no EOF for the full 30 seconds. The first version of this test failed at 30.36s against
    // a 0.3s deadline, with a comment in the source confidently asserting that waiting on the
    // readers "cannot outlive the process". Hence `drainGrace` and `Sink.abandon()`.
    let start = Date()
    #expect(throws: ContainerCLIError.self) {
        try runner(grace: 0.5, drainGrace: 0.5).run(["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
    }
    #expect(Date().timeIntervalSince(start) < 6)
}

/// **macOS only, and the reason is a measured platform difference rather than a shrug.**
///
/// This case needs the child to exit while a grandchild still holds the pipe open. On Linux that
/// is unobservable: `Process` does not report the child's termination until the pipe's last writer
/// closes, so `exited.wait` sat for the grandchild's full 8 seconds and the drain grace was never
/// reached — the run took 8.03s and returned complete, untruncated output. The pipes themselves are
/// fine there (a standalone probe read them correctly), and `/bin/sh` being dash rather than bash
/// turned out not to be the cause.
///
/// Gated rather than rewritten because `LocalHost` spawns exactly one binary — `container`, which
/// is macOS-only — so Darwin is the only platform where its process semantics are load-bearing.
/// `LocalHost`'s own docs now carry the same caveat for anyone who ports it.
#if os(macOS)
@Test func abandonedOutputIsReportedAsTruncatedRatherThanComplete() throws {
    // A grandchild that holds the pipe open past the drain grace: the child exits at once, but
    // its forked writer lingers. What we return is a prefix, and it must not claim otherwise.
    let host = runner(drainGrace: 0.4)
    let result = try host.run(["-c", "(printf 'kept'; sleep 8) & exit 0"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("kept"))
    #expect(result.stdoutTruncated)   // honest: the reader was cut loose, not finished
}
#endif

@Test func aNonZeroExitStillReturnsRatherThanThrowing() throws {
    // The runner reports; deciding what a failure *means* belongs to ContainerCLI, which has one
    // path that tolerates non-zero (`system status` announces a stopped service that way).
    let result = try runner().run(["-c", "printf 'boom' 1>&2; exit 3"])
    #expect(result.exitCode == 3)
    #expect(result.stderr == "boom")
    #expect(!result.ok)
}

@Test func aMissingRuntimeIsNamedRatherThanCrashing() throws {
    let host = LocalHost(resolve: { nil })
    #expect(throws: ContainerCLIError.self) { try host.run(["ls"]) }
}

// MARK: - The line observer
//
// `run(_:timeout:onLine:)` exists so a bounded-but-slow command can report progress while it
// runs. The observer is called from the drain threads, so the collector below is locked: a test
// that read an unsynchronised array here would be testing the same race it is meant to catch.

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

@Test func everyLineArrivesOnceAndInOrder() throws {
    let box = LineBox()
    let result = try runner().run(["-c", "printf 'one\\ntwo\\nthree\\n'"], timeout: 0) {
        box.append($0)
    }
    #expect(result.exitCode == 0)
    #expect(box.all == ["one", "two", "three"])
}

@Test func aLineSplitAcrossTwoReadsIsDeliveredWhole() throws {
    // The reason `pending` exists. `availableData` returns whatever has arrived, which has no
    // relationship to where the newlines are: a progress line written in two writes must not
    // reach the observer as two lines, and half a UTF-8 sequence must not be decoded early.
    let box = LineBox()
    _ = try runner().run(["-c", "printf 'first ha'; sleep 0.3; printf 'lf\\nsecond\\n'"],
                         timeout: 0) { box.append($0) }
    #expect(box.all == ["first half", "second"])
}

@Test func aFinalLineWithNoTrailingNewlineIsStillDelivered() throws {
    // `container image pull` does terminate its last line, but a command that does not must not
    // have its final — and most interesting — line silently dropped at EOF.
    let box = LineBox()
    _ = try runner().run(["-c", "printf 'done\\nno newline here'"], timeout: 0) { box.append($0) }
    #expect(box.all == ["done", "no newline here"])
}

@Test func carriageReturnsAreNotLeftOnTheEndOfEveryLine() throws {
    let box = LineBox()
    _ = try runner().run(["-c", "printf 'crlf\\r\\nplain\\n'"], timeout: 0) { box.append($0) }
    #expect(box.all == ["crlf", "plain"])
}

@Test func progressOnStderrReachesTheObserver() throws {
    // Not an arbitrary choice of stream: `container image pull` writes **every** progress line
    // to stderr and leaves stdout empty. Measured, not assumed — a pull with stdout discarded
    // still prints all of it, and with stderr discarded prints none. An observer wired only to
    // stdout would have reported nothing for the one command this was built for.
    let box = LineBox()
    let result = try runner().run(["-c", "printf '[1/2] Fetching image [0s]\\n' 1>&2"],
                                  timeout: 0) { box.append($0) }
    #expect(result.stdout.isEmpty)
    #expect(box.all == ["[1/2] Fetching image [0s]"])
}

@Test func theObserverKeepsSeeingLinesPastTheByteCeiling() throws {
    // A deliberate asymmetry, pinned here so it is not "fixed" later. The ceiling bounds what
    // the runner *retains*; a line handed to an observer is not retained. Progress whose value
    // is entirely in its tail must not stop arriving because the head filled a buffer.
    let box = LineBox()
    let script = "i=0; while [ $i -lt 200 ]; do printf 'line %d\\n' $i; i=$((i+1)); done"
    let result = try runner(limitBytes: 128).run(["-c", script], timeout: 0) { box.append($0) }
    #expect(result.stdoutTruncated)
    #expect(result.stdout.utf8.count <= 128)
    #expect(box.all.count == 200)
    #expect(box.all.first == "line 0")
    #expect(box.all.last == "line 199")
}

@Test func linesDeliveredBeforeADeadlineSurviveTheTimeoutError() throws {
    // The failure path that matters for a pull: the command is killed at its deadline and throws,
    // but the progress already reported is not unsaid. A UI that showed 40% and then a timeout
    // is telling the truth about both.
    let box = LineBox()
    #expect(throws: ContainerCLIError.self) {
        _ = try runner().run(["-c", "printf 'before\\n'; sleep 5"], timeout: 0.4) {
            box.append($0)
        }
    }
    #expect(box.all == ["before"])
}

// MARK: - Streaming (`logs --follow`)

/// Collects what a stream delivered, from whichever thread delivers it.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(String, OutputChannel)] = []
    private var end: CommandStreamEnd?

    func line(_ text: String, _ channel: OutputChannel) {
        lock.lock(); lines.append((text, channel)); lock.unlock()
    }
    func finish(_ end: CommandStreamEnd) {
        lock.lock(); self.end = end; lock.unlock()
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.0) }
    var channels: [OutputChannel] { lock.lock(); defer { lock.unlock() }; return lines.map(\.1) }
    var ending: CommandStreamEnd? { lock.lock(); defer { lock.unlock() }; return end }

    /// Wait until `predicate` holds, or give up. Polling, because the whole point of a stream is
    /// that it delivers before the child is finished — there is nothing to await.
    func wait(upTo seconds: TimeInterval = 5, for predicate: @Sendable () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            usleep(20_000)
        }
        return predicate()
    }
}

@Test func aStreamDeliversLinesWhileTheChildIsStillRunning() throws {
    // The property the old three-second poll could not have: output is visible *before* the
    // command ends. This child writes three lines and then sleeps, so if the reader waited for
    // exit — as `run` does — nothing would arrive for five seconds.
    let recorder = StreamRecorder()
    let stream = try runner().stream(
        ["-c", "printf 'one\\ntwo\\n'; printf 'bad\\n' 1>&2; sleep 5"],
        onLine: { recorder.line($0, $1) },
        onEnd: { recorder.finish($0) }
    )
    defer { stream.cancel() }

    #expect(recorder.wait { recorder.texts.count >= 3 })
    #expect(recorder.texts.sorted() == ["bad", "one", "two"])
    // Which pipe each line came from survives, which is what colours stderr red in the viewer.
    #expect(recorder.channels.filter { $0 == .stderr }.count == 1)
    // Still running: no end has been reported.
    #expect(recorder.ending == nil)
}

@Test func cancellingAStreamStopsTheChildAndSaysItWasCancelled() throws {
    let recorder = StreamRecorder()
    let stream = try runner().stream(
        ["-c", "printf 'up\\n'; sleep 30"],
        onLine: { recorder.line($0, $1) },
        onEnd: { recorder.finish($0) }
    )
    #expect(recorder.wait { !recorder.texts.isEmpty })

    stream.cancel()
    #expect(recorder.wait { recorder.ending != nil })
    // A child killed by SIGTERM reports a non-zero status, and reporting that as a failure is
    // exactly the lie this flag exists to prevent — every time the user turns Live off.
    let end = try #require(recorder.ending)
    #expect(end.cancelled)
    #expect(end.ok)
}

@Test func aStreamThatEndsOnItsOwnReportsTheExitCode() throws {
    let recorder = StreamRecorder()
    let stream = try runner().stream(
        ["-c", "printf 'gone\\n' 1>&2; exit 3"],
        onLine: { recorder.line($0, $1) },
        onEnd: { recorder.finish($0) }
    )
    defer { stream.cancel() }

    #expect(recorder.wait { recorder.ending != nil })
    let end = try #require(recorder.ending)
    #expect(!end.cancelled)
    #expect(end.exitCode == 3)
    #expect(!end.ok)
    // The explanation arrives as a stderr line, because a stream retains nothing to explain it
    // with afterwards.
    #expect(recorder.texts == ["gone"])
}

@Test func aStreamRetainsNothingHoweverMuchItCarries() throws {
    // The ceiling that bounds `run`'s buffers is zero here: lines flow, memory does not grow.
    // A tail of a chatty container must not become a way to exhaust the app's memory by leaving
    // a tab open, and the viewer's own cap cannot help with what the host holds.
    let recorder = StreamRecorder()
    let stream = try runner(limitBytes: 8 * 1024).stream(
        ["-c", "i=0; while [ $i -lt 2000 ]; do printf 'line %d\\n' $i; i=$((i+1)); done"],
        onLine: { recorder.line($0, $1) },
        onEnd: { recorder.finish($0) }
    )
    defer { stream.cancel() }

    #expect(recorder.wait { recorder.ending != nil })
    // Every line was delivered even though the sink's ceiling is far smaller than the output.
    #expect(recorder.texts.count == 2000)
    #expect(recorder.texts.first == "line 0")
    #expect(recorder.texts.last == "line 1999")
}
