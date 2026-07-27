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
    return Preflight(cli: ContainerCLI(host: host), minimumVersion: minimum, locate: { _ in found })
}

@Test func missingWhenTheBinaryCannotBeLocated() {
    let host = ScriptedHost { _ in CommandResult(stdout: "", stderr: "unexpected", exitCode: 1) }
    let preflight = Preflight(cli: ContainerCLI(host: host), locate: { _ in nil })
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

@Test func unusableWhenTheServiceIsNotRunning() {
    let result = preflight(version: "1.0.0", running: false).run()
    guard case .unusable = result else {
        Issue.record("expected .unusable, got \(result)")
        return
    }
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
    let result = Preflight(cli: ContainerCLI(host: host), locate: { _ in "/usr/local/bin/container" }).run()
    guard case .unusable = result else {
        Issue.record("expected .unusable, got \(result)")
        return
    }
}

// MARK: - VersionTriple

@Test func versionTripleParsesAndComparesLeniently() {
    #expect(VersionTriple(parsing: "1.0.0") == VersionTriple(1, 0, 0))
    #expect(VersionTriple(parsing: "2.3.4-beta.1") == VersionTriple(2, 3, 4))
    #expect(VersionTriple(parsing: "1.2") == nil)
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
