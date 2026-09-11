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

// Fabricated fixture until 2026-07-30, same as networks below. The invented one claimed a
// volume named "flotilla-data" with a 1 GiB size and a project label — none of which the real
// CLI emits at the top level. Worse, `name` was non-optional, so against genuine output
// decoding THREW: the Volumes screen showed a runtime error the moment a volume existed.
@Test func decodeVolumes() throws {
    let volumes = try JSONDecoder.flotilla.decode([ContainerVolume].self, from: fixture("volumes"))
    let v = try #require(volumes.first)
    #expect(v.id == "audit-probe")
    #expect(v.name == "audit-probe")
    #expect(v.format == "ext4")
    #expect(v.driver == "local")
    // The real size is the ext4 image's provisioned size, not what is in use — 512 GiB for a
    // freshly created volume. Worth knowing before showing it to anyone as "disk used".
    #expect(v.sizeInBytes == 549_755_813_888)
    // `source` is an absolute path under the user's Library. It must never reach a support
    // bundle unredacted; `Redaction` handles that, and this asserts the field is populated so
    // the redactor has something to find.
    #expect(v.source?.hasSuffix("volumes/audit-probe/volume.img") == true)
}

// The fixture behind this was FABRICATED until 2026-07-30 — a flat shape written to match the
// model rather than captured from the CLI. It is now a real `container network list` capture,
// which is why the assertions changed: subnet and gateway live under `status`, and there is no
// `state` field at all.
@Test func decodeNetworks() throws {
    let networks = try JSONDecoder.flotilla.decode([ContainerNetwork].self, from: fixture("networks"))
    #expect(networks.count == 2)

    let builtin = try #require(networks.first { $0.id == "default" })
    #expect(builtin.name == "default")
    #expect(builtin.mode == "nat")
    #expect(builtin.plugin == "container-network-vmnet")
    #expect(builtin.subnet == "192.168.64.0/24")
    #expect(builtin.gateway == "192.168.64.1")
    #expect(builtin.isBuiltin, "Apple's own network carries the builtin role label")

    // A network the user made: same shape, but not builtin — which is what gates whether we
    // offer to delete it.
    let mine = try #require(networks.first { $0.id == "test" })
    #expect(mine.isBuiltin == false)
    #expect(mine.subnet == "192.168.65.0/24")
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

/// `machine restart` does not exist in the CLI either, so `restartMachine` synthesises it the
/// same way `restart` does for containers — and the boot half must carry a command, or it opens
/// an interactive shell, needs a PTY, and fails *after* booting. See the MACHINES-SPEC addendum.
@Test func machineRestartIsStopThenBoot() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.restartMachine("dev")

    #expect(host.invocations[0] == ["machine", "stop", "dev"])
    #expect(host.invocations[1] == ["machine", "run", "--name", "dev", "/bin/true"])
}

@Test func startStopRestartRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.remove("web")
    try cli.remove("web", force: true)

    #expect(host.invocations[0] == ["rm", "web"])
    // `Allowlist` canonicalises to the long spelling, so `-f` in ⇒ `--force` out.
    #expect(host.invocations[1] == ["rm", "--force", "web"])
}

@Test func killIsImmediateAndDefaultsToNoExplicitSignal() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.kill("web")
    try cli.kill("web", signal: "TERM")

    // Unlike `stop`, there is no `--time` grace period to pass.
    #expect(host.invocations[0] == ["kill", "web"])
    #expect(host.invocations[1] == ["kill", "--signal", "TERM", "web"])
}

@Test func pruneOperationsRouteThroughAllowlistWithNoOperands() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.tag("docker.io/library/alpine:latest", as: "alpine:mine")

    #expect(host.invocations[0] == ["image", "tag", "docker.io/library/alpine:latest", "alpine:mine"])
}

@Test func buildImageRoutesThroughAllowlistAndCarriesItsMountPolicy() throws {
    // Two things at once, because the second is the one a green suite has missed before: that
    // the argv is *accepted*, and that the host receives the allowlist's canonical form rather
    // than what this method assembled.
    //
    // **This call is not optional, and its absence was invisible for weeks.** `hostBuildPath`
    // requires the path to *exist* — the symlink-swap finding — so this test needs
    // `/tmp/flotilla/Dockerfile` on disk. It never created it; six tests in `AllowlistTests` and
    // one below do, and on a developer's Mac `/tmp/flotilla` then survives between runs forever,
    // so the dependency could not be observed locally. In a fresh CI container it became a pure
    // test-ordering coin flip, and the first CI run ever executed lost it:
    // "--file: host path '/tmp/flotilla/Dockerfile' is not permitted by the mount policy".
    //
    // The helper is idempotent, so every test that needs the fixtures should call it rather than
    // relying on a sibling having gone first.
    makeBuildFixtures()

    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .roots(["/tmp/flotilla"]), wirePolicy: .localOwner)

    try cli.buildImage(contextDirectory: "/tmp/flotilla/src", dockerfile: "/tmp/flotilla/Dockerfile",
                       tag: "app:latest", buildArgs: ["VERSION=1.2"], labels: ["team=infra"],
                       noCache: true, platform: "linux/arm64", target: "runtime")

    #expect(host.invocations[0] == ["build", "--file", "/tmp/flotilla/Dockerfile",
                                    "--tag", "app:latest", "--build-arg", "VERSION=1.2",
                                    "--label", "team=infra", "--no-cache",
                                    "--platform", "linux/arm64", "--target", "runtime",
                                    "/tmp/flotilla/src"])

    // A context outside the policy's roots never reaches the host at all.
    let denied = ContainerCLI(host: RecordingHost(), mountPolicy: .roots(["/tmp/flotilla"]), wirePolicy: .localOwner)
    #expect(throws: AllowlistError.self) {
        try denied.buildImage(contextDirectory: "/Users/someone/src", dockerfile: nil, tag: nil,
                              buildArgs: [], labels: [], noCache: false, platform: nil, target: nil)
    }
}

@Test func buildImageOmitsEveryOptionThatWasNotAskedFor() throws {
    makeBuildFixtures()
    // The context is required now — a nil one used to mean "let the CLI default it to `.`",
    // which quietly granted the process working directory. See `omittedBuildContextIsRefused`
    // in AllowlistTests.
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .roots(["/tmp/flotilla"]), wirePolicy: .localOwner)

    try cli.buildImage(contextDirectory: "/tmp/flotilla", dockerfile: nil, tag: "app:latest",
                       buildArgs: [], labels: [], noCache: false, platform: nil, target: nil)

    #expect(host.invocations[0] == ["build", "--tag", "app:latest", "/tmp/flotilla"])
}

@Test func inspectDecodesTheSameShapeAsListContainers() throws {
    let host = RecordingHost()
    // `inspect`'s stdout is keyed on args.first here since the id varies; this reuses
    // the real, live-captured `containers.json` fixture to prove the [Container] decode
    // path works — it does not by itself prove `container inspect` emits an array like
    // `ls` does, which is unverified (see the doc comment on `ContainerCLI.inspect`).
    host.stdoutByPath["inspect"] = String(decoding: try fixture("containers"), as: UTF8.self)
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let container = try cli.inspect("flotilla-probe-test")

    #expect(host.invocations[0] == ["inspect", "flotilla-probe-test"])
    #expect(container.name == "flotilla-probe-test")
}

@Test func inspectImageDecodesTheSameShapeAsListImages() throws {
    let host = RecordingHost()
    host.stdoutByPath["image inspect"] = String(decoding: try fixture("images"), as: UTF8.self)
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let image = try cli.inspectImage("docker.io/library/alpine:latest")

    #expect(host.invocations[0] == ["image", "inspect", "docker.io/library/alpine:latest"])
    #expect(image.reference == "docker.io/library/alpine:latest")
}

@Test func rawInspectJSONReturnsTheCLIsOwnOutputVerbatimAndRoutesThroughAllowlist() throws {
    let host = RecordingHost()
    let raw = String(decoding: try fixture("inspect-container"), as: UTF8.self)
    host.stdoutByPath["inspect"] = raw
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let result = try cli.rawInspectJSON("web-demo")

    #expect(host.invocations[0] == ["inspect", "web-demo"])
    #expect(result == raw)
}

@Test func rawInspectImageJSONReturnsTheCLIsOwnOutputVerbatimAndRoutesThroughAllowlist() throws {
    let host = RecordingHost()
    let raw = String(decoding: try fixture("images"), as: UTF8.self)
    host.stdoutByPath["image inspect"] = raw
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
        let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
        #expect(throws: AllowlistError.self, "\(name) accepted an invalid argument") {
            try attempt(cli)
        }
        #expect(host.invocations.isEmpty, "\(name) reached ContainerHost.run")
    }
}

@Test func inspectThrowsRatherThanCrashingOnAnEmptyResult() throws {
    let host = RecordingHost()
    host.stdoutByPath["inspect"] = "[]"
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    #expect(throws: ContainerCLIError.emptyInspectResult(id: "ghost")) {
        try cli.inspect("ghost")
    }
}

@Test func startRejectsAnAttemptedInjectionInTheIdentifier() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
        let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", command: [""])
    }
    #expect(host.invocations.isEmpty)
}

@Test func runRejectsContradictoryMountModes() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let options = ContainerCLI.RunOptions(volumes: ["/tmp/data:/data:ro,rw"])

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: options)
    }
    #expect(host.invocations.isEmpty)
}

@Test func runSeparatesAnInContainerCommandThatLooksLikeAFlag() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.run(image: "alpine", command: ["--version"])

    let argv = host.invocations[0]
    let separatorIndex = try #require(argv.firstIndex(of: "--"))
    #expect(Array(argv[(separatorIndex + 1)...]) == ["--version"])
}

@Test func pullAndRemoveImageRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
            try attempt(ContainerCLI(host: host, wirePolicy: .localOwner))
        }
        #expect(host.invocations.isEmpty)
    }
}

@Test func volumeAndNetworkMutationsRouteThroughAllowlist() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    #expect(throws: AllowlistError.self) { try cli.createVolume("../etc") }
}

@Test func logsFetchIsBoundedAndTaggedByStream() throws {
    let host = RecordingHost()
    // RecordingHost keys canned output on the first two argv tokens; `ContainerCLI.logs`
    // always sends "logs" "-n" first, so key on that pair rather than a literal id.
    host.stdoutByPath["logs -n"] = "booting\nready\n"
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let chunk = try cli.logs("web", lines: 50)

    #expect(host.invocations[0] == ["logs", "-n", "50", "web"])
    #expect(chunk.containerID == "web")
    #expect(chunk.requestedLines == 50)
    #expect(chunk.lines.map(\.text) == ["booting", "ready"])
    #expect(chunk.lines.allSatisfy { $0.stream == .stdout })
    #expect(!chunk.isBootLog)
}

@Test func followingLogsSendsTheBoundedFollowFormAndTagsEachStream() throws {
    // The live tail still sends `-n`: turning it on must not drag an entire log into the window
    // before the streaming part begins.
    let host = RecordingHost()
    host.stdoutByPath["logs --follow"] = "one\ntwo\n"
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let recorder = LineRecorder()
    let stream = try cli.followLogs("web", lines: 50,
                                    onLine: { recorder.line($0, $1) },
                                    onEnd: { _ in recorder.finish() })
    defer { stream.cancel() }

    #expect(host.invocations[0] == ["logs", "--follow", "-n", "50", "web"])
    #expect(recorder.texts == ["one", "two"])
    #expect(recorder.ended)
}

@Test func followingMachineLogsUsesTheMachineFormOfTheSameCommand() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    let recorder = LineRecorder()
    let stream = try cli.followMachineLogs("dev", lines: 200, boot: true,
                                           onLine: { recorder.line($0, $1) },
                                           onEnd: { _ in recorder.finish() })
    defer { stream.cancel() }

    #expect(host.invocations[0] == ["machine", "logs", "--follow", "-n", "200", "--boot", "dev"])
}

@Test func followingLogsRejectsALineCountOutsideTheAllowlistedRange() {
    // The tail goes through `Allowlist` exactly as the bounded fetch does; a follow is still an
    // argv, and nothing gets to skip the table because it happens to stream.
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    #expect(throws: AllowlistError.self) {
        _ = try cli.followLogs("web", lines: 10_000_000, onLine: { _, _ in }, onEnd: { _ in })
    }
}

/// Collects streamed lines. Plain and unlocked: the default `stream` implementation a scripted
/// host inherits replays synchronously on the calling thread.
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(LogLine.Stream, String)] = []
    private var done = false
    func line(_ stream: LogLine.Stream, _ text: String) {
        lock.lock(); lines.append((stream, text)); lock.unlock()
    }
    func finish() { lock.lock(); done = true; lock.unlock() }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.1) }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

@Test func logsRejectsALineCountOutsideTheAllowlistedRange() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
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
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner) // default mountPolicy: .unrestricted

    try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))

    #expect(host.invocations.count == 1)
}

@Test func aContainerCLIBuiltWithDenyHostPathsRejectsTheSameMount() {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: .localOwner)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))
    }
    #expect(host.invocations.isEmpty)
}

@Test func aContainerCLIBuiltWithARootsPolicyAcceptsOnlyPathsUnderIt() throws {
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, mountPolicy: .roots(["/tmp"]), wirePolicy: .localOwner)

    try cli.run(image: "alpine", options: .init(volumes: ["/tmp/data:/data"]))
    #expect(host.invocations.count == 1)

    #expect(throws: AllowlistError.self) {
        try cli.run(image: "alpine", options: .init(volumes: ["/etc/flotilla:/config:ro"]))
    }
    #expect(host.invocations.count == 1)
}

// MARK: - A failing CLI must fail loudly
//
// For a long time nothing read the exit code. `LocalHost.run` returned a `CommandResult`
// carrying `exitCode` and an `ok` property no call site touched, so every failure the CLI
// reported was thrown away and the operation looked successful. Creating a network that
// already exists was the clearest case: `container` exits 1 with `Error: network X already
// exists`, and the app said nothing whatsoever.

/// Answers a fixed non-zero result, so the exit-code path can be tested without a live CLI.
private final class FailingHost: ContainerHost, @unchecked Sendable {
    let stderr: String
    let code: Int32
    private(set) var invocations: [[String]] = []

    init(stderr: String, code: Int32 = 1) {
        self.stderr = stderr
        self.code = code
    }

    func run(_ args: [String]) throws -> CommandResult {
        invocations.append(args)
        return CommandResult(stdout: "", stderr: stderr, exitCode: code)
    }
}

@Test func aNonZeroExitBecomesAThrownError() throws {
    let host = FailingHost(stderr: "Error: network test2 already exists")
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    #expect(throws: (any Error).self) {
        try cli.createNetwork("test2")
    }
    // It really did attempt it — this is not the Allowlist refusing beforehand, which is the
    // only kind of failure that used to surface.
    #expect(host.invocations.count == 1)
}

@Test func theCLIsOwnWordsReachTheUser() throws {
    let host = FailingHost(stderr: "Error: network test2 already exists")
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    do {
        try cli.createNetwork("test2")
        Issue.record("expected a failure")
    } catch let error as ContainerCLIError {
        // "already exists" is the whole point: a generic "operation failed" would leave the
        // user guessing at exactly the moment the CLI already knew the answer.
        #expect(error.description.contains("already exists"))
        // And without the `Error:` prefix, which is noise once it is in an alert.
        #expect(error.description.hasPrefix("Error:") == false)
    }
}

@Test func aUsageDumpIsReducedToItsFirstLine() throws {
    // `container` follows a bad flag value with Help: and Usage: blocks. Useful in a support
    // bundle, unreadable in an alert.
    let host = FailingHost(
        stderr: """
        Error: The value '999.999.999.0/24' is invalid for '--subnet <subnet>': unableToParse
        Help:  --subnet <subnet>  Set subnet for a network
        Usage: container network create [--internal] [--label <label> ...] <name>
        """,
        code: 64
    )
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    do {
        try cli.createNetwork("net", options: .init(subnet: "10.0.0.0/24"))
        Issue.record("expected a failure")
    } catch let error as ContainerCLIError {
        #expect(error.description.contains("unableToParse"))
        #expect(error.description.contains("Usage:") == false)
        #expect(error.description.contains("Help:") == false)
    }
}

@Test func readsFailLoudlyToo() throws {
    // A failed `ls` used to return empty stdout, which then surfaced as a confusing JSON
    // decode error rather than the reason the CLI gave.
    let host = FailingHost(stderr: "Error: the container runtime is not running")
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    do {
        _ = try cli.listContainers()
        Issue.record("expected a failure")
    } catch let error as ContainerCLIError {
        #expect(error.description.contains("not running"))
    }
}

@Test func aZeroExitIsStillSuccess() throws {
    // The guard must not turn ordinary success into an error.
    let host = RecordingHost()
    #expect(throws: Never.self) {
        try ContainerCLI(host: host, wirePolicy: .localOwner).createNetwork("fine")
    }
}

// MARK: - Pull with progress

/// Emits scripted output lines through the observer, then returns a canned result. The one
/// thing `RecordingHost` cannot do: it implements only `run(_:)`, so it inherits the protocol
/// default that *drops* the observer — which is the right default for a double with nothing to
/// report, and useless for testing the observer itself.
private final class StreamingHost: ContainerHost, @unchecked Sendable {
    var lines: [String] = []
    var exitCode: Int32 = 0
    var stderr = ""
    private(set) var invocations: [[String]] = []

    func run(_ args: [String]) throws -> CommandResult {
        try run(args, timeout: 0, onLine: nil)
    }

    func run(_ args: [String], timeout: TimeInterval,
             onLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
        invocations.append(args)
        for line in lines { onLine?(line) }
        return CommandResult(stdout: "", stderr: stderr, exitCode: exitCode)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ImagePullProgress] = []
    func append(_ progress: ImagePullProgress) { lock.lock(); seen.append(progress); lock.unlock() }
    var all: [ImagePullProgress] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Test func pullReportsProgressAndDropsEverythingThatIsNotProgress() throws {
    let host = StreamingHost()
    // Real lines, from the transcript in Fixtures/pull-progress.txt, interleaved with the kinds
    // of output a CLI is entitled to emit alongside them. Anything unparseable is dropped rather
    // than guessed at — a half-understood line shown as progress would be worse than no line.
    host.lines = [
        "[1/2] Fetching image [0s]",
        "unexpected chatter from the runtime",
        "[1/2] Fetching image 20% (28 of 96 blobs, 9.2/45.0 MB, 1.1 MB/s) [11s]",
        "",
        "[2/2] Unpacking image for platform linux/arm64/v8 [33s]",
    ]
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let box = ProgressBox()

    try cli.pull("docker.io/library/alpine:latest") { box.append($0) }

    // Still the validated argv, not a second path around it.
    #expect(host.invocations == [["image", "pull", "docker.io/library/alpine:latest"]])

    let seen = box.all
    #expect(seen.count == 3)
    #expect(seen[0].fraction == nil)        // the CLI has no percentage yet on its first line
    #expect(seen[1].fraction == 0.2)
    #expect(seen[1].detail == "28 of 96 blobs, 9.2/45.0 MB, 1.1 MB/s")
    #expect(seen[2].phase == .unpacking)
    #expect(seen[2].platform == "linux/arm64/v8")
}

@Test func aRejectedReferenceReachesNeitherTheHostNorTheObserver() throws {
    // The observer is not a way round the allowlist: validation happens first, so a reference
    // the allowlist refuses produces no execution and no progress.
    let host = StreamingHost()
    host.lines = ["[1/2] Fetching image [0s]"]
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let box = ProgressBox()

    #expect(throws: (any Error).self) {
        try cli.pull("alpine latest") { box.append($0) }
    }
    #expect(host.invocations.isEmpty)
    #expect(box.all.isEmpty)
}

@Test func progressDeliveredBeforeAFailureIsNotUnsaid() throws {
    // A pull that gets 20% in and then fails did get 20% in. The throw reports the failure; it
    // does not retract what was already true.
    let host = StreamingHost()
    host.lines = ["[1/2] Fetching image 20% (28 of 96 blobs, 9.2/45.0 MB, 1.1 MB/s) [11s]"]
    host.exitCode = 1
    host.stderr = "unauthorized: authentication required"
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let box = ProgressBox()

    #expect(throws: ContainerCLIError.self) {
        try cli.pull("docker.io/library/private:latest") { box.append($0) }
    }
    #expect(box.all.count == 1)
    #expect(box.all[0].fraction == 0.2)
}

// MARK: - Stopping the runtime

@Test func stopSystemSendsTheBareSubcommand() throws {
    // No `--prefix`, no `--debug`. The CLI accepts both; nothing in the app has any business
    // naming a launchd service, and a spec that accepts a flag no caller sends is surface for
    // nothing.
    let host = RecordingHost()
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)

    try cli.stopSystem()

    #expect(host.invocations == [["system", "stop"]])
}

@Test func stoppingTheRuntimeIsRefusedOverTheWire() throws {
    // Stopping the services takes every running container down with them. `system start` is
    // already `.localOnly` for the weaker version of this reason; a remote peer must not be able
    // to do the stronger one.
    #expect(throws: (any Error).self) {
        _ = try Allowlist.validated(["system", "stop"], wirePolicy: .remotePeer)
    }
    #expect(throws: Never.self) {
        _ = try Allowlist.validated(["system", "stop"], wirePolicy: .localOwner)
    }
}
