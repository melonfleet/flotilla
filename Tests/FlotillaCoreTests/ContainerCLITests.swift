import Foundation
import Testing
@testable import FlotillaCore

// Volumes and networks don't have a captured live fixture yet (see the ⚠️ note on
// `ContainerVolume`/`ContainerNetwork` in Models.swift) — these are synthetic, shaped from
// `reference/container-cli.md`. Replace with real captures the first time this runs
// against a live install.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodeVolumes() throws {
    let volumes = try JSONDecoder.flotilla.decode([ContainerVolume].self, from: fixture("volumes"))
    let v = try #require(volumes.first)
    #expect(v.name == "flotilla-data")
    #expect(v.sizeInBytes == 1_073_741_824)
    #expect(v.labels?["project"] == "flotilla")
}

@Test func decodeNetworks() throws {
    let networks = try JSONDecoder.flotilla.decode([ContainerNetwork].self, from: fixture("networks"))
    let n = try #require(networks.first)
    #expect(n.id == "default")
    #expect(n.isDefault)
    #expect(n.subnet == "192.168.64.0/24")
}

// MARK: - ContainerCLI: every mutation is allowlisted

/// Records every argv `ContainerHost.run` was actually asked to execute, and answers
/// canned results keyed by the subcommand path — enough to test both "does `ContainerCLI`
/// build a request `Allowlist` accepts" and "does it hand `Allowlist`'s *canonical* argv
/// (not the caller's original one) to the host".
private final class RecordingHost: ContainerHost, @unchecked Sendable {
    private(set) var invocations: [[String]] = []
    var stdoutByPath: [String: String] = [:]

    func run(_ args: [String]) throws -> CommandResult {
        invocations.append(args)
        let key = args.prefix(2).joined(separator: " ")
        let stdout = stdoutByPath[key] ?? stdoutByPath[args.first ?? ""] ?? ""
        return CommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}

@Test func startStopRestartRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.start("web")
    try cli.stop("web", timeout: 5)
    try cli.restart("web", timeout: 5)

    #expect(host.invocations[0] == ["start", "web"])
    #expect(host.invocations[1] == ["stop", "--time", "5", "web"])
    // restart = stop then start, in that order.
    #expect(host.invocations[2] == ["stop", "--time", "5", "web"])
    #expect(host.invocations[3] == ["start", "web"])
}

@Test func removeUsesForceFlagOnlyWhenAsked() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.remove("web")
    try cli.remove("web", force: true)

    #expect(host.invocations[0] == ["rm", "web"])
    // `Allowlist` canonicalises to the long spelling, so `-f` in ⇒ `--force` out.
    #expect(host.invocations[1] == ["rm", "--force", "web"])
}

@Test func startRejectsAnAttemptedInjectionInTheIdentifier() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    #expect(throws: AllowlistError.self) {
        try cli.start("web; rm -rf /")
    }
    #expect(host.invocations.isEmpty)
}

@Test func everyMutatingEntryPointRejectsBeforeReachingTheHost() {
    let attempts: [(String, (ContainerCLI) throws -> Void)] = [
        ("start", { try $0.start("") }),
        ("stop", { try $0.stop("web", timeout: -1) }),
        ("restart", { try $0.restart("../web") }),
        ("remove", { try $0.remove("web;id", force: true) }),
        ("run", { try $0.run(image: "") }),
        ("pull", { try $0.pull("../alpine") }),
        ("removeImage", { try $0.removeImage("alpine;id", force: true) }),
        ("createVolume", { try $0.createVolume("../data") }),
        ("removeVolume", { try $0.removeVolume("") }),
        ("createNetwork", { try $0.createNetwork("private network") }),
        ("removeNetwork", { try $0.removeNetwork("../private") }),
    ]

    for (name, attempt) in attempts {
        let host = RecordingHost()
        let cli = ContainerCLI(host: host)
        do {
            try attempt(cli)
            Issue.record("\(name) accepted an invalid argument")
        } catch is AllowlistError {
            // Expected: validation rejected the request before the host boundary.
        } catch {
            Issue.record("\(name) threw the wrong error: \(error)")
        }
        #expect(host.invocations.isEmpty, "\(name) reached ContainerHost.run")
    }
}

@Test func runBuildsTheCanonicalArgvAndAcceptsAnyHostPathLocally() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    let options = ContainerCLI.RunOptions(
        name: "web",
        ports: ["8080:80"],
        env: ["FOO=bar"],
        volumes: ["/etc/flotilla:/config:ro"],
        detach: true
    )
    try cli.run(image: "docker.io/library/alpine:latest", options: options)

    #expect(host.invocations.count == 1)
    let argv = host.invocations[0]
    // `Allowlist` canonicalises every flag to its long spelling, regardless of which
    // spelling `ContainerCLI` sent in.
    #expect(argv.contains("--detach"))
    #expect(argv.contains("--name"))
    #expect(argv.contains("web"))
    #expect(argv.contains("--env"))
    #expect(argv.contains("FOO=bar"))
    #expect(argv.contains("--publish"))
    #expect(argv.contains("8080:80"))
    #expect(argv.contains("--volume"))
    #expect(argv.contains("/etc/flotilla:/config:ro"))
    #expect(argv.last == "docker.io/library/alpine:latest")

    // The same bind mount is exactly what `MountPolicy.denyHostPaths` (the wire default)
    // exists to reject — proving `ContainerCLI` really does pass `.unrestricted` here,
    // and only here, on purpose.
    #expect(Allowlist.validate(["run", "-v", "/etc/flotilla:/config:ro", "alpine"]).isFailure)
}

@Test func runRejectsAnEmptyInContainerCommandToken() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", command: [""])
    }
    #expect(host.invocations.isEmpty)
}

@Test func runRejectsContradictoryMountModes() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)
    let options = ContainerCLI.RunOptions(volumes: ["/tmp/data:/data:ro,rw"])

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: options)
    }
    #expect(host.invocations.isEmpty)
}

@Test func runSeparatesAnInContainerCommandThatLooksLikeAFlag() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.run(image: "alpine", command: ["--version"])

    let argv = host.invocations[0]
    let separatorIndex = try #require(argv.firstIndex(of: "--"))
    #expect(Array(argv[(separatorIndex + 1)...]) == ["--version"])
}

@Test func pullAndRemoveImageRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.pull("docker.io/library/alpine:latest")
    try cli.removeImage("docker.io/library/alpine:latest", force: true)

    #expect(host.invocations[0] == ["image", "pull", "docker.io/library/alpine:latest"])
    #expect(host.invocations[1] == ["image", "rm", "--force", "docker.io/library/alpine:latest"])
}

@Test func imageOperationsRejectReferencesWithAnEmptyTag() {
    let attempts: [(ContainerCLI) throws -> Void] = [
        { try $0.pull("alpine:") },
        { try $0.removeImage("alpine:", force: true) },
    ]

    for attempt in attempts {
        let host = RecordingHost()
        #expect(throws: AllowlistError.self) {
            try attempt(ContainerCLI(host: host))
        }
        #expect(host.invocations.isEmpty)
    }
}

@Test func volumeAndNetworkMutationsRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.createVolume("data")
    try cli.removeVolume("data")
    try cli.createNetwork("islet")
    try cli.removeNetwork("islet")

    #expect(host.invocations[0] == ["volume", "create", "data"])
    #expect(host.invocations[1] == ["volume", "rm", "data"])
    #expect(host.invocations[2] == ["network", "create", "islet"])
    #expect(host.invocations[3] == ["network", "rm", "islet"])
}

@Test func volumeCreateRejectsAPathTraversalName() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)
    #expect(throws: AllowlistError.self) { try cli.createVolume("../etc") }
}

@Test func logsFetchIsBoundedAndTaggedByStream() throws {
    let host = RecordingHost()
    // RecordingHost keys canned output on the first two argv tokens; `ContainerCLI.logs`
    // always sends "logs" "-n" first, so key on that pair rather than a literal id.
    host.stdoutByPath["logs -n"] = "booting\nready\n"
    let cli = ContainerCLI(host: host)

    let chunk = try cli.logs("web", lines: 50)

    #expect(host.invocations[0] == ["logs", "-n", "50", "web"])
    #expect(chunk.containerID == "web")
    #expect(chunk.requestedLines == 50)
    #expect(chunk.lines.map(\.text) == ["booting", "ready"])
    #expect(chunk.lines.allSatisfy { $0.stream == .stdout })
    #expect(!chunk.isBootLog)
}

@Test func logsRejectsALineCountOutsideTheAllowlistedRange() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)
    #expect(throws: AllowlistError.self) { try cli.logs("web", lines: 0) }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
