import Foundation
import Testing
@testable import FlotillaCore

// `Preflight` composes `ContainerCLI.versions()`/`systemStatus()`, so these fake a host
// rather than needing a real `container` install — that's the point of the injectable
// `locate` closure too: it runs identically on the Linux CI toolchain, where there is no
// `container` binary and never will be.

private struct ScriptedHost: ContainerHost {
    let handler: @Sendable ([String]) throws -> CommandResult
    func run(_ args: [String]) throws -> CommandResult { try handler(args) }
}

private func versionJSON(_ version: String) -> String {
    """
    [{"appName":"container","version":"\(version)","buildType":"release"}]
    """
}

private func statusJSON(running: Bool) -> String {
    """
    {"status":"\(running ? "running" : "unregistered")"}
    """
}

/// Captured from the live CLI with the services stopped — `exit=1`, the status JSON on stdout,
/// empty stderr. Not hand-written: the first version of this test used a scripted host that
/// exited **zero**, which is not what the CLI does, so the code passed the test and misreported
/// the real machine.
private let stoppedServicePayload =
    #"{"apiServerAppName":"","apiServerBuild":"","apiServerCommit":"","apiServerVersion":"","appRoot":"","installRoot":"","status":"unregistered"}"#

private func preflight(
    found: String = "/usr/local/bin/container",
    version: String = "1.0.0",
    running: Bool = true,
    minimum: VersionTriple = VersionTriple(1, 0, 0)
) -> Preflight {
    let host = ScriptedHost { args in
        if args.first == "system", args.count > 1, args[1] == "version" {
            return CommandResult(stdout: versionJSON(version), stderr: "", exitCode: 0)
        }
        if args.first == "system", args.count > 1, args[1] == "status" {
            return CommandResult(stdout: statusJSON(running: running), stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "", stderr: "unexpected", exitCode: 1)
    }
    return Preflight(cli: ContainerCLI(host: host, wirePolicy: .localOwner), minimumVersion: minimum, locate: { _ in found })
}

@Test func missingWhenTheBinaryCannotBeLocated() {
    let host = ScriptedHost { _ in CommandResult(stdout: "", stderr: "unexpected", exitCode: 1) }
    let preflight = Preflight(cli: ContainerCLI(host: host, wirePolicy: .localOwner), locate: { _ in nil })
    #expect(preflight.run() == .missing)
}

@Test func okWhenVersionMeetsMinimumAndServiceIsRunning() {
    let result = preflight(version: "1.2.0", running: true).run()
    #expect(result == .ok(version: "1.2.0", path: "/usr/local/bin/container"))
    #expect(result.isOK)
}

@Test func tooOldWhenVersionIsBelowTheDeclaredMinimum() {
    let result = preflight(version: "0.9.5", minimum: VersionTriple(1, 0, 0)).run()
    #expect(result == .tooOld(found: "0.9.5", required: "1.0.0"))
}

@Test func semanticComparisonBeatsLexicographicComparison() {
    // "1.9.0" < "1.10.0" as versions, even though it sorts the other way as strings —
    // the whole reason `VersionTriple` exists instead of comparing `String`s.
    let result = preflight(version: "1.10.0", minimum: VersionTriple(1, 9, 0)).run()
    #expect(result.isOK)
}

@Test func exactReleaseVersionMeetsTheMinimumBoundary() {
    let result = preflight(version: "1.0.0", minimum: VersionTriple(1, 0, 0)).run()
    #expect(result == .ok(version: "1.0.0", path: "/usr/local/bin/container"))
}

@Test func prereleaseDoesNotMeetTheEquivalentReleaseMinimum() {
    let result = preflight(version: "1.0.0-beta.1", minimum: VersionTriple(1, 0, 0)).run()
    #expect(result == .tooOld(found: "1.0.0-beta.1", required: "1.0.0"))
}

@Test func aStoppedServiceIsRecognisedThroughItsNonZeroExit() {
    // The whole point: `system status` announces a stopped service *by failing*, and the answer
    // is in the output of the failed command.
    let host = ScriptedHost { args in
        if args.first == "system", args.count > 1, args[1] == "version" {
            return CommandResult(stdout: versionJSON("1.0.0"), stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: stoppedServicePayload, stderr: "", exitCode: 1)
    }
    let result = Preflight(cli: ContainerCLI(host: host, wirePolicy: .localOwner),
                           locate: { _ in "/usr/local/bin/container" }).run()
    #expect(result == .serviceStopped(version: "1.0.0",
                                     path: "/usr/local/bin/container",
                                     status: "unregistered"))
}

@Test func serviceStoppedIsItsOwnVerdictNotAGenericFailure() {
    let result = preflight(version: "1.0.0", running: false).run()
    // Deliberately NOT `.unusable`: the app starts the service for this one, and it cannot do
    // that if the verdict is a sentence it has to read.
    #expect(result == .serviceStopped(version: "1.0.0",
                                     path: "/usr/local/bin/container",
                                     status: "unregistered"))
}

// MARK: - Resolution
//
// The bug these cover shipped for weeks: a GUI-launched app's PATH is
// `/usr/bin:/bin:/usr/sbin:/sbin`, `container` lives in `/usr/local/bin`, and the app reported
// "isn't installed" on a machine where it was installed and running.

@Test func aBinaryOutsidePATHIsStillFoundInTheInstallDirectory() throws {
    // The install directory is a parameter here so the test is hermetic and runs on Linux CI,
    // but the PATH is the real one a bundled app is handed: `/usr/bin:/bin:/usr/sbin:/sbin`.
    let installDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("flotilla-locate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: installDirectory) }
    let binary = installDirectory.appendingPathComponent("container")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

    let guiPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    #expect(Preflight.locateOnPath("container", path: guiPath) == nil)
    #expect(Preflight.locateBinary("container", path: guiPath,
                                   directories: [installDirectory.path]) == binary.path)
}

@Test func theSearchedDirectoriesAlwaysIncludeTheInstallDirectory() {
    // The "not installed" message is built from this list, so it must name every place looked.
    #expect(Preflight.searchedDirectories(path: "/usr/bin:/bin").contains("/usr/local/bin"))
    #expect(Preflight.searchedDirectories(path: "").contains("/usr/local/bin"))
    // And never twice, when PATH already has it.
    #expect(Preflight.searchedDirectories(path: "/usr/local/bin:/usr/bin")
                .filter { $0 == "/usr/local/bin" }.count == 1)
}

@Test func unusableWhenTheVersionCannotBeParsed() {
    let result = preflight(version: "not-a-version").run()
    guard case .unusable = result else {
        Issue.record("expected .unusable, got \(result)")
        return
    }
}

@Test func unusableWhenNoContainerComponentIsReported() {
    let host = ScriptedHost { args in
        if args.first == "system", args.count > 1, args[1] == "version" {
            return CommandResult(stdout: #"[{"appName":"api-server","version":"1.0.0"}]"#, stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "", stderr: "", exitCode: 0)
    }
    let result = Preflight(cli: ContainerCLI(host: host, wirePolicy: .localOwner), locate: { _ in "/usr/local/bin/container" }).run()
    guard case .unusable = result else {
        Issue.record("expected .unusable, got \(result)")
        return
    }
}

// MARK: - VersionTriple

@Test func versionTripleParsesSupportedSuffixesAndRejectsMalformedCores() {
    #expect(VersionTriple(parsing: "1.0.0") == VersionTriple(1, 0, 0))
    #expect(VersionTriple(parsing: "2.3.4-beta.1") == VersionTriple(2, 3, 4))
    #expect(VersionTriple(parsing: "2.3.4+build.17") == VersionTriple(2, 3, 4))
    #expect(VersionTriple(parsing: "1.2") == nil)
    #expect(VersionTriple(parsing: "1.two.3") == nil)
    #expect(VersionTriple(parsing: "-1.2.3") == nil)
    #expect(VersionTriple(parsing: "1.2.3.4") == nil)
    #expect(VersionTriple(parsing: "not-a-version") == nil)
    #expect(VersionTriple(1, 9, 0) < VersionTriple(1, 10, 0))
    #expect(VersionTriple(1, 0, 0) < VersionTriple(1, 0, 1))
}

@Test func locateOnPathFindsARealExecutableAndRejectsAMissingOne() throws {
    // `sh` exists on every platform this runs on; use it as a stand-in for `container`
    // to test the real PATH search without needing `container` installed.
    let found = try #require(Preflight.locateOnPath("sh"))
    #expect(found.hasSuffix("/sh"))
    #expect(FileManager.default.isExecutableFile(atPath: found))
    #expect(Preflight.locateOnPath("definitely-not-a-real-binary-flotilla-test") == nil)
}
