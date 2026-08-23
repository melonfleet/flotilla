import Foundation

/// Result of running one `container` CLI invocation.
public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    /// True when the stream hit its byte ceiling and the rest was read and discarded.
    ///
    /// Surfaced rather than silent: a caller decoding JSON from a truncated stream would
    /// otherwise report a parse error and blame the CLI, and "the output was too big" is a
    /// different fact from "the output was malformed".
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public var ok: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32,
                stdoutTruncated: Bool = false, stderrTruncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

/// A place that can run `container` subcommands. `LocalHost` runs them via Process;
/// `RemoteHost` (Phase 2) ships the args to a host-mode peer over mTLS and streams
/// the result back. The UI talks only to this protocol.
///
/// NOTE: `run` is synchronous for the Phase 1 scaffold. Phase 2 adds an async
/// variant plus a streaming API (`stream`) for `logs -f` / `stats`.
public protocol ContainerHost: Sendable {
    func run(_ args: [String]) throws -> CommandResult
    /// Run with a hard deadline. `timeout <= 0` means no deadline.
    ///
    /// A separate requirement with a default implementation, so the many test doubles that
    /// implement only `run(_:)` keep working and inherit "no deadline" — which is what a
    /// scripted host that returns instantly wants anyway.
    func run(_ args: [String], timeout: TimeInterval) throws -> CommandResult
}

public extension ContainerHost {
    func run(_ args: [String], timeout: TimeInterval) throws -> CommandResult {
        try run(args)
    }
}

/// Runs the `container` CLI on this machine.
///
/// Resolves the binary with `Preflight.locateBinary` — `PATH`, then the known install
/// directory — and launches it **by absolute path**. This used to be
/// `/usr/bin/env container`, which is the same PATH lookup by another route, and a
/// GUI-launched app's `PATH` is only `/usr/bin:/bin:/usr/sbin:/sbin`: no `/usr/local/bin`, so
/// every command failed after a restart. Detection and execution had to change together, or
/// preflight would have said "ready" while nothing could run.
///
/// Launching an absolute path from a known directory is also the stricter choice: there is no
/// `PATH` entry an attacker can prepend to have something else answer to the name `container`.
///
/// ## The runner contract (2026-08-23)
///
/// Three things were wrong at this boundary, all found by an independent audit and all confirmed
/// in the tree before changing anything:
///
/// 1. **Sequential drain.** `readDataToEndOfFile()` on stdout ran to completion *before* stderr
///    was read at all. A child that fills the stderr pipe buffer while stdout is still open
///    blocks writing stderr; we block reading stdout; neither side moves. A deadlock, not a
///    slowdown — and the `logs` screen asking five sources for a thousand lines each is exactly
///    the shape that reaches it. Both streams are now drained **concurrently**.
/// 2. **Unbounded buffers.** Whatever the CLI produced was held whole in memory. There is now a
///    per-stream ceiling; past it, output is read and **discarded** rather than stopping the
///    read, because stopping the read is what re-creates the deadlock.
/// 3. **No deadline.** `waitUntilExit()` waited forever, and cancelling the Swift `Task` that
///    called it did nothing to the child — the process stayed, holding its pipes. There is now a
///    hard deadline with terminate, grace, then `SIGKILL`.
public struct LocalHost: ContainerHost {
    /// What the runner refuses to exceed.
    public struct Limits: Sendable {
        /// Per stream, not combined: a huge stdout must not make a small stderr unreadable, and
        /// the CLI's error text is usually the more valuable of the two.
        public var maxBytesPerStream: Int
        /// How long `SIGTERM` gets before `SIGKILL`. `container` cleans up on TERM; this is the
        /// allowance for that, not a guess at how long the work takes.
        public var terminationGrace: TimeInterval
        /// How long the readers get to finish *after* the child is gone, before we take what we
        /// have and stop waiting. See `run` — a grandchild can outlive the child and hold the
        /// pipe, and waiting on that is an unbounded wait wearing a bounded one's clothes.
        public var drainGrace: TimeInterval

        public init(maxBytesPerStream: Int = 4 * 1024 * 1024,
                    terminationGrace: TimeInterval = 2,
                    drainGrace: TimeInterval = 2) {
            self.maxBytesPerStream = maxBytesPerStream
            self.terminationGrace = terminationGrace
            self.drainGrace = drainGrace
        }

        public static let `default` = Limits()
    }

    private let resolve: @Sendable () -> String?
    private let limits: Limits

    /// - Parameter resolve: how to find the binary. Resolved per call rather than cached at
    ///   init: `container` may be installed while Flotilla is already running, and a cache
    ///   would hold "missing" until the next launch. It is a handful of `stat` calls.
    public init(resolve: @escaping @Sendable () -> String? = { Preflight.locateBinary("container") },
                limits: Limits = .default) {
        self.resolve = resolve
        self.limits = limits
    }

    public func run(_ args: [String]) throws -> CommandResult {
        try run(args, timeout: 0)
    }

    /// Names a command for a message a human will read, **without echoing any flag value**.
    ///
    /// Only the leading non-flag tokens — the subcommand chain, `container logs`, `container
    /// machine run`. The moment a `-` appears, everything after it is dropped, because argv is
    /// where the secrets are: `--env TOKEN=…`, `--registry-password`, a mount path naming
    /// someone's home directory. The audit's SEC-03 is exactly this fault in
    /// `ValidatedCommand.auditDescription`, and a timeout alert is a *more* exposed surface than
    /// a log line, so this one is not going to repeat it.
    static func summarise(_ args: [String]) -> String {
        let subcommand = args.prefix { !$0.hasPrefix("-") }
        if !subcommand.isEmpty { return subcommand.joined(separator: " ") }
        // Everything was a flag: name nothing rather than guess. The seconds still identify it.
        return args.first.map { $0.hasPrefix("-") ? $0 : "command" } ?? "command"
    }

    public func run(_ args: [String], timeout: TimeInterval) throws -> CommandResult {
        guard let executable = resolve() else {
            throw ContainerCLIError.runtimeNotFound(searched: Preflight.searchedDirectories())
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = Sink(limit: limits.maxBytesPerStream)
        let err = Sink(limit: limits.maxBytesPerStream)
        let draining = DispatchGroup()
        // Signalled by `terminationHandler` rather than by `waitUntilExit()`, so the deadline can
        // be a *wait with a timeout* instead of an unbounded block.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        DispatchQueue.global(qos: .userInitiated).async(group: draining) {
            out.drain(outPipe.fileHandleForReading)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: draining) {
            err.drain(errPipe.fileHandleForReading)
        }

        var timedOut = false
        let deadline: DispatchTime = timeout > 0 ? .now() + timeout : .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + limits.terminationGrace) == .timedOut {
                // TERM was ignored or the child is wedged. Reap it rather than leaving a process
                // holding pipes for the lifetime of the app.
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + limits.terminationGrace)
            }
        }
        // The readers end at EOF on the pipe — which the child's exit does **not** guarantee.
        // A child that forks holds no monopoly on the write end: kill `sh -c 'trap "" TERM; sleep
        // 30'` and `sh` dies while `sleep` inherits the pipe and keeps it open for the full 30s.
        // An unbounded wait here would have turned a 0.3s deadline into a 30s block — the timeout
        // fires, and then we sit anyway. So the readers get a grace period, after which we take
        // what arrived and let them finish into a sink nobody reads.
        if draining.wait(timeout: .now() + limits.drainGrace) == .timedOut {
            out.abandon()
            err.abandon()
        }

        if timedOut {
            throw ContainerCLIError.timedOut(command: Self.summarise(args), seconds: timeout)
        }

        let (stdout, stdoutCut) = out.snapshot()
        let (stderr, stderrCut) = err.snapshot()
        return CommandResult(
            stdout: stdout, stderr: stderr,
            exitCode: process.terminationStatus,
            stdoutTruncated: stdoutCut, stderrTruncated: stderrCut
        )
    }
}

/// One stream's accumulator: keeps up to `limit` bytes, then keeps reading and throwing away.
///
/// Locked, not barrier-protected. The obvious cheaper design — one writer, read only after the
/// `DispatchGroup` completes — needs the reader to always outlive the writer, and `abandon()`
/// exists precisely because sometimes it does not. Contention is one lock per pipe read.
private final class Sink: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private var abandoned = false

    init(limit: Int) { self.limit = limit }

    /// What arrived, and whether anything was dropped — from the ceiling or from being abandoned.
    func snapshot() -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    /// Stop collecting: nobody is going to read what comes next.
    ///
    /// Reports as truncated, because it is — claiming complete output when a reader was cut loose
    /// mid-stream is the kind of quiet lie this file is being rewritten to remove.
    func abandon() {
        lock.lock()
        abandoned = true
        truncated = true
        lock.unlock()
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }          // EOF
            lock.lock()
            if abandoned {
                lock.unlock()
                // **Read on regardless**, here and at the ceiling below. Stopping the read fills
                // the pipe and blocks the writer — the deadlock this whole change exists to
                // remove. Bounded memory is the goal, not a bounded number of syscalls.
                continue
            }
            if data.count >= limit {
                truncated = true
                lock.unlock()
                continue
            }
            let room = limit - data.count
            if chunk.count > room {
                data.append(chunk.prefix(room))
                truncated = true
            } else {
                data.append(chunk)
            }
            lock.unlock()
        }
    }
}
