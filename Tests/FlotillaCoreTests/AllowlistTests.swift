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
        ["system", "start"],
    ]

    for args in rejected {
        requireRejected(args)
    }

    #expect(Allowlist.validate([]) == .failure(.emptyCommand))
    #expect(Allowlist.validate(["image", "push", "alpine"]) == .failure(.unknownSubcommand("image push")))
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
        "start", "stop", "delete", "rm", "run",
        "image pull", "image delete", "image rm",
        "volume create", "volume delete", "volume rm",
        "network create", "network delete", "network rm",
    ]
    let actualMutating = Set(Allowlist.commands.filter(\.mutates).map(\.name))
    #expect(actualMutating == expectedMutating)

    let expectedReadOnly: Set<String> = [
        "ls", "list", "inspect", "stats", "logs",
        "image list",
        "volume list", "volume inspect",
        "network list", "network inspect",
        "system status", "system version", "system df",
    ]
    let actualReadOnly = Set(Allowlist.commands.filter { !$0.mutates }.map(\.name))
    #expect(actualReadOnly == expectedReadOnly)
    #expect(expectedMutating.isDisjoint(with: expectedReadOnly))
    #expect(expectedMutating.union(expectedReadOnly).count == Allowlist.commands.count)
}

@Test func everyAllowlistedCommandShapeProducesItsCanonicalCommand() throws {
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
        AllowedCase(["image", "pull", "--platform=linux/arm64", "alpine@sha256:\(digest)"],
                    canonical: ["image", "pull", "--platform", "linux/arm64",
                                "alpine@sha256:\(digest)"],
                    mutates: true, timeout: 1800),
        AllowedCase(["image", "delete", "-a"], canonical: ["image", "delete", "--all"],
                    mutates: true),
        AllowedCase(["image", "rm", "-f", "alpine"], canonical: ["image", "rm", "--force", "alpine"],
                    mutates: true),

        AllowedCase(["volume", "list", "--format", "toml"], mutates: false),
        AllowedCase(["volume", "inspect", "data"], mutates: false),
        AllowedCase(["volume", "create", "-s", "2GB", "--opt", "type=fast",
                     "--label=team=infra", "data"],
                    canonical: ["volume", "create", "--size", "2GB", "--opt", "type=fast",
                                "--label", "team=infra", "data"], mutates: true),
        AllowedCase(["volume", "delete", "--all"], mutates: true),
        AllowedCase(["volume", "rm", "data"], mutates: true),

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

        AllowedCase(["system", "status", "--format=json"],
                    canonical: ["system", "status", "--format", "json"], mutates: false),
        AllowedCase(["system", "version"], mutates: false),
        AllowedCase(["system", "df", "--format", "table"], mutates: false),
    ]

    #expect(cases.count == Allowlist.commands.count)
    for testCase in cases {
        let command = try Allowlist.validated(testCase.input)
        let pathLength = command.subcommand.count
        #expect(command.subcommand == Array(testCase.canonical.prefix(pathLength)))
        #expect(command.arguments == testCase.canonical)
        #expect(command.mutates == testCase.mutates)
        #expect(command.timeoutHint == testCase.timeout)
        #expect(command.auditDescription == (["container"] + testCase.canonical).joined(separator: " "))
    }
}
