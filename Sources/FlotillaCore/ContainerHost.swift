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

/// Runs the `container` CLI on this machine. Resolves the binary via PATH (`env`)
/// so it works regardless of the exact install location.
public struct LocalHost: ContainerHost {
    public init() {}

    public func run(_ args: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["container"] + args

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
