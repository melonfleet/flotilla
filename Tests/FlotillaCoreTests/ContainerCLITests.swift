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

@Test func killIsImmediateAndDefaultsToNoExplicitSignal() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.kill("web")
    try cli.kill("web", signal: "TERM")

    // Unlike `stop`, there is no `--time` grace period to pass.
    #expect(host.invocations[0] == ["kill", "web"])
    #expect(host.invocations[1] == ["kill", "--signal", "TERM", "web"])
}

@Test func pruneOperationsRouteThroughAllowlistWithNoOperands() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.pruneContainers()
    try cli.pruneImages()
    try cli.pruneImages(all: true)
    try cli.pruneVolumes()
    try cli.pruneNetworks()

    #expect(host.invocations[0] == ["prune"])
    #expect(host.invocations[1] == ["image", "prune"])
    #expect(host.invocations[2] == ["image", "prune", "--all"])
    #expect(host.invocations[3] == ["volume", "prune"])
    #expect(host.invocations[4] == ["network", "prune"])
}

@Test func tagRoutesThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host)

    try cli.tag("docker.io/library/alpine:latest", as: "alpine:mine")

    #expect(host.invocations[0] == ["image", "tag", "docker.io/library/alpine:latest", "alpine:mine"])
}

@Test func inspectDecodesTheSameShapeAsListContainers() throws {
    let host = RecordingHost()
    // `inspect`'s stdout is keyed on args.first here since the id varies; this reuses
    // the real, live-captured `containers.json` fixture to prove the [Container] decode
    // path works — it does not by itself prove `container inspect` emits an array like
    // `ls` does, which is unverified (see the doc comment on `ContainerCLI.inspect`).
    host.stdoutByPath["inspect"] = String(decoding: try fixture("containers"), as: UTF8.self)
    let cli = ContainerCLI(host: host)

    let container = try cli.inspect("flotilla-probe-test")

    #expect(host.invocations[0] == ["inspect", "flotilla-probe-test"])
    #expect(container.name == "flotilla-probe-test")
}

@Test func inspectImageDecodesTheSameShapeAsListImages() throws {
    let host = RecordingHost()
    host.stdoutByPath["image inspect"] = String(decoding: try fixture("images"), as: UTF8.self)
    let cli = ContainerCLI(host: host)

    let image = try cli.inspectImage("docker.io/library/alpine:latest")

    #expect(host.invocations[0] == ["image", "inspect", "docker.io/library/alpine:latest"])
    #expect(image.reference == "docker.io/library/alpine:latest")
}

@Test func rawInspectJSONReturnsTheCLIsOwnOutputVerbatimAndRoutesThroughAllowlist() throws {
    let host = RecordingHost()
    let raw = String(decoding: try fixture("inspect-container"), as: UTF8.self)
    host.stdoutByPath["inspect"] = raw
    let cli = ContainerCLI(host: host)

    let result = try cli.rawInspectJSON("web-demo")

    #expect(host.invocations[0] == ["inspect", "web-demo"])
    #expect(result == raw)
}

@Test func rawInspectImageJSONReturnsTheCLIsOwnOutputVerbatimAndRoutesThroughAllowlist() throws {
    let host = RecordingHost()
    let raw = String(decoding: try fixture("images"), as: UTF8.self)
    host.stdoutByPath["image inspect"] = raw
    let cli = ContainerCLI(host: host)

    let result = try cli.rawInspectImageJSON("docker.io/library/alpine:latest")

    #expect(host.invocations[0] == ["image", "inspect", "docker.io/library/alpine:latest"])
    #expect(result == raw)
}

@Test func rawInspectAccessorsRejectAnInvalidIdentifierBeforeReachingTheHost() {
    let attempts: [(String, (ContainerCLI) throws -> Void)] = [
        ("rawInspectJSON", { try $0.rawInspectJSON("web; rm -rf /") }),
        ("rawInspectImageJSON", { try $0.rawInspectImageJSON("alpine:") }),
    ]

    for (name, attempt) in attempts {
        let host = RecordingHost()
        let cli = ContainerCLI(host: host)
        #expect(throws: AllowlistError.self, "\(name) accepted an invalid argument") {
            try attempt(cli)
        }
        #expect(host.invocations.isEmpty, "\(name) reached ContainerHost.run")
    }
}

@Test func inspectThrowsRatherThanCrashingOnAnEmptyResult() throws {
    let host = RecordingHost()
    host.stdoutByPath["inspect"] = "[]"
    let cli = ContainerCLI(host: host)

    #expect(throws: ContainerCLIError.emptyInspectResult(id: "ghost")) {
        try cli.inspect("ghost")
    }
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
        ("kill", { try $0.kill("web; rm -rf /") }),
        ("run", { try $0.run(image: "") }),
        ("pull", { try $0.pull("../alpine") }),
        ("removeImage", { try $0.removeImage("alpine;id", force: true) }),
        ("tag", { try $0.tag("../alpine", as: "alpine:mine") }),
        ("inspectImage", { try $0.inspectImage("alpine:") }),
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

// MARK: - Run argument construction (the run sheet's preview seam)

// The run sheet shows a live command preview. If it assembled its own argv the preview
// would drift from what actually executes — a preview that lies is worse than none — so
// `runArguments` is the single construction both use. These pin it.

@Test func runArgumentsAreWhatRunActuallyExecutes() throws {
    let args = ContainerCLI.runArguments(
        image: "docker.io/library/alpine:latest",
        options: .init(name: "web", ports: ["8080:80"], env: ["TZ=UTC"], volumes: ["data:/data"], detach: true),
        command: []
    )
    #expect(args == ["run", "-d", "--name", "web", "-e", "TZ=UTC", "-p", "8080:80",
                     "-v", "data:/data", "docker.io/library/alpine:latest"])

    // And the preview must be something the Allowlist accepts, not merely plausible.
    let validated = try Allowlist.validated(args, mountPolicy: .unrestricted)
    #expect(validated.arguments.first == "run")
}

@Test func aTrailingCommandIsSeparatedSoItCannotBeReadAsAFlag() throws {
    let args = ContainerCLI.runArguments(
        image: "alpine", options: .init(detach: false), command: ["--version"]
    )
    // Without the `--`, `--version` would be parsed as a flag of `container run` itself.
    let separator = try #require(args.firstIndex(of: "--"))
    let versionToken = try #require(args.firstIndex(of: "--version"))
    #expect(separator < versionToken)
    #expect(!args.contains("-d"))
}

@Test func anInvalidMountIsRejectedAtPreviewTimeNotRunTime() throws {
    // The sheet should be able to tell the user *before* they press Run. A named volume
    // is fine; a traversal is not.
    let ok = ContainerCLI.runArguments(image: "alpine", options: .init(volumes: ["data:/data"]))
    #expect(throws: Never.self) { try Allowlist.validated(ok, mountPolicy: .denyHostPaths) }

    let bad = ContainerCLI.runArguments(image: "alpine", options: .init(volumes: ["/Users:/host:ro"]))
    #expect(throws: (any Error).self) { try Allowlist.validated(bad, mountPolicy: .denyHostPaths) }
}

@Test func runArgumentsAppendsTheNewFlagsAfterExistingOnesWithoutReordering() throws {
    let args = ContainerCLI.runArguments(
        image: "alpine",
        options: .init(name: "web", ports: ["8080:80"], env: ["TZ=UTC"], volumes: ["data:/data"],
                       detach: true, rm: true, cpus: 2, memory: "512M", network: "islet", platform: "linux/arm64")
    )
    // The pinned prefix from `runArgumentsAreWhatRunActuallyExecutes` is untouched; the
    // five new flags are appended after volumes and before the image operand.
    #expect(args == ["run", "-d", "--name", "web", "-e", "TZ=UTC", "-p", "8080:80", "-v", "data:/data",
                     "--rm", "--cpus", "2", "--memory", "512M", "--network", "islet",
                     "--platform", "linux/arm64", "alpine"])

    let validated = try Allowlist.validated(args, mountPolicy: .unrestricted)
    #expect(validated.arguments.first == "run")
}

@Test func runArgumentsOmitsTheNewFlagsWhenUnset() throws {
    // Every new `RunOptions` field is optional, so a caller that never touches them
    // (like the three pre-existing pinned tests above) must see byte-identical output.
    let args = ContainerCLI.runArguments(image: "alpine")
    #expect(args == ["run", "-d", "alpine"])
}

// MARK: - Mount policy is injectable, and only ever narrows

@Test func aContainerCLIBuiltWithTheDefaultAcceptsAHostBindMount() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host) // default mountPolicy: .unrestricted

    try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))

    #expect(host.invocations.count == 1)
}

@Test func aContainerCLIBuiltWithDenyHostPathsRejectsTheSameMount() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .denyHostPaths)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))
    }
    #expect(host.invocations.isEmpty)
}

@Test func aContainerCLIBuiltWithARootsPolicyAcceptsOnlyPathsUnderIt() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .roots(["/tmp"]))

    try cli.run(image: "alpine", options: .init(volumes: ["/tmp/data:/data"]))
    #expect(host.invocations.count == 1)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))
    }
    #expect(host.invocations.count == 1)
}
