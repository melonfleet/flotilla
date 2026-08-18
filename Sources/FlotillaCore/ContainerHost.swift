import Foundation

/// Result of running one `container` CLI invocation.
public struct CommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var ok: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
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
public struct LocalHost: ContainerHost {
    private let resolve: @Sendable () -> String?

    /// - Parameter resolve: how to find the binary. Resolved per call rather than cached at
    ///   init: `container` may be installed while Flotilla is already running, and a cache
    ///   would hold "missing" until the next launch. It is a handful of `stat` calls.
    public init(resolve: @escaping @Sendable () -> String? = { Preflight.locateBinary("container") }) {
        self.resolve = resolve
    }

    public func run(_ args: [String]) throws -> CommandResult {
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

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}
