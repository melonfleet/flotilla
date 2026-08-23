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

@Test func abandonedOutputIsReportedAsTruncatedRatherThanComplete() throws {
    // A grandchild that holds the pipe open past the drain grace: the child exits at once, but
    // its forked writer lingers. What we return is a prefix, and it must not claim otherwise.
    let host = runner(drainGrace: 0.4)
    let result = try host.run(["-c", "(printf 'kept'; sleep 8) & exit 0"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("kept"))
    #expect(result.stdoutTruncated)   // honest: the reader was cut loose, not finished
}

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
