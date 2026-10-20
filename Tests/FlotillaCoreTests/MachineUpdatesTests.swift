import Foundation
import Testing
@testable import FlotillaCore

// Command/policy tests only. No package output fixtures have been invented for the parser.
@Test func machinePackageChecksHaveExactLocalOwnerGrammar() throws {
    for operation in MachineUpdateCommand.allCases {
        let args = operation.arguments(machine: "dev")
        let validated = try Allowlist.validated(args, execPolicy: .interactiveShell)
        #expect(validated.arguments == ["machine", "run", "--name", "dev"]
                + (operation.runsAsRoot ? ["--root"] : []) + [operation.shellLine])
        #expect(validated.timeoutHint == 120)
        #expect(!validated.arguments.contains("--"))
        #expect(throws: AllowlistError.self) {
            try Allowlist.validated(args, execPolicy: .processListOnly)
        }
        #expect(throws: AllowlistError.self) {
            try Allowlist.validated(args, execPolicy: .interactiveShell, wirePolicy: .remotePeer)
        }
        let neighbours: [[String]] = [
            args + ["extra"],
            Array(args.dropLast()),
            ["machine", "run", "--", operation.shellLine],
            ["machine", "run", "--name", "dev", "--interactive", "--", operation.shellLine],
            ["machine", "run", "--name", "dev", "--tty", "--", operation.shellLine],
            ["machine", "run", "--name", "dev", "--", "sh", "-c", operation.command.joined(separator: " ")],
            ["machine", "run", "--name", "dev", "--", operation.shellLine, ";", "apk", "upgrade"],
            ["machine", "run", "--name", "dev", "--"] + operation.command,
            ["machine", "run", "--name", "dev", "--", operation.shellLine + "; id"],
        ]
        for neighbour in neighbours {
            #expect(throws: AllowlistError.self) {
                try Allowlist.validated(neighbour, execPolicy: .interactiveShell)
            }
        }
    }
    for command in [["apk", "upgrade"], ["apk", "update", "--allow-untrusted"],
                    ["apk", "version", "-l", ">"], ["dnf", "-q", "upgrade"],
                    ["dnf", "-y", "check-update"], ["rpm", "-qa"],
                    ["rpm", "-qa", "--queryformat", "%{NAME}"]] {
        #expect(throws: AllowlistError.self) {
            try Allowlist.validated(["machine", "run", "--name", "dev", "--"] + command,
                                    execPolicy: .interactiveShell)
        }
    }
}

@Test func packageSpecsKeepBootAndShellGrammar() throws {
    let boot = try Allowlist.validated(["machine", "run", "--name", "dev", "--", "/bin/true"],
                                       execPolicy: .interactiveShell)
    #expect(boot.arguments == ["machine", "run", "--name", "dev", "/bin/true"])
    let shell = try Allowlist.validated(["machine", "run", "--name", "dev", "-i", "-t"],
                                        execPolicy: .interactiveShell)
    #expect(shell.timeoutHint == 0)
}

private final class UpdateGuardHost: ContainerHost, @unchecked Sendable {
    var invocations: [[String]] = []
    let inspect: String
    let packageExit: Int32
    var timeouts: [TimeInterval] = []

    init(stopped: Bool = false, packageExit: Int32 = 1) throws {
        let url = try #require(Bundle.module.url(forResource: "machine-inspect", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        var text = try String(contentsOf: url, encoding: .utf8)
        // Mutate only the state of an existing captured machine, never package output.
        if stopped { text = text.replacingOccurrences(of: "running", with: "stopped") }
        inspect = text
        self.packageExit = packageExit
    }

    func run(_ args: [String]) throws -> CommandResult { try run(args, timeout: 0) }
    func run(_ args: [String], timeout: TimeInterval) throws -> CommandResult {
        invocations.append(args)
        timeouts.append(timeout)
        if args.starts(with: ["machine", "inspect"]) {
            return CommandResult(stdout: inspect, stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "", stderr: "", exitCode: packageExit)
    }
}

@Test func stoppedMachineNeverRunsPackageCommand() throws {
    let host = try UpdateGuardHost(stopped: true)
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    #expect(throws: ContainerCLIError.self) { try cli.checkMachineUpdates("probe-alpine") }
    #expect(host.invocations == [["machine", "inspect", "probe-alpine"]])
}

@Test func refreshFailureStopsBeforeVersionCheck() throws {
    let host = try UpdateGuardHost()
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    #expect(throws: ContainerCLIError.self) { try cli.checkMachineUpdates("probe-alpine") }
    #expect(host.invocations == [["machine", "inspect", "probe-alpine"],
                                 ["machine", "inspect", "probe-alpine"],
                                 ["machine", "run", "--name", "probe-alpine", "--root", "apk update"]])
    #expect(host.timeouts.allSatisfy { $0 > 0 && $0 <= 120 })
}

private final class DNFStatusHost: ContainerHost, @unchecked Sendable {
    var invocations: [[String]] = []
    let inspect: String

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "machine-inspect", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        // Only adapt the captured image reference to select AlmaLinux; this is not package output.
        inspect = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "alpine:3.22", with: "almalinux:9")
    }

    func run(_ args: [String]) throws -> CommandResult {
        invocations.append(args)
        if args.starts(with: ["machine", "inspect"]) {
            return .init(stdout: inspect, stderr: "", exitCode: 0)
        }
        // Stop at RPM so the parser is never tested using synthetic package output.
        return .init(stdout: "", stderr: "", exitCode: args.last?.hasPrefix("dnf ") == true ? 100 : 1)
    }
}

@Test func dnfExit100ContinuesToInstalledQuery() throws {
    let host = try DNFStatusHost()
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    #expect(throws: ContainerCLIError.self) { try cli.checkMachineUpdates("probe-alpine") }
    let commands = host.invocations.filter { $0.starts(with: ["machine", "run"]) }
    #expect(commands == [MachineUpdateCommand.dnfCheck, .rpmInstalled].map {
        ["machine", "run", "--name", "probe-alpine"] + [$0.shellLine]
    })
}

@Test func machinePackageChecksSurviveTheGuestShellsReparse() {
    // container 1.5.0 joins the trailing words and has the guest's login shell parse them again.
    #expect(MachineUpdateCommand.apkVersions.shellLine == "apk version -l '<'")
    #expect(MachineUpdateCommand.apkRefresh.shellLine == "apk update")
    #expect(MachineUpdateCommand.rpmInstalled.shellLine
            == #"rpm -qa --queryformat '%{NAME}.%{ARCH}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n'"#)
    #expect(MachineUpdateCommand.shellQuoted("it's $HOME") == #"'it'\''s $HOME'"#)
    for operation in MachineUpdateCommand.allCases {
        #expect(operation.arguments(machine: "dev").suffix(1) == [operation.shellLine])
    }
}

@Test func onlyTheAlpineRefreshRunsAsRootAndItMust() throws {
    let allowlist: (ExecPolicy, [String]) throws -> Void = { policy, args in
        _ = try Allowlist.validated(args, execPolicy: policy, wirePolicy: .localOwner)
    }
    // The refresh needs --root, and nothing else may have it.
    #expect(throws: (any Error).self) {
        try allowlist(.interactiveShell, ["machine", "run", "--name", "dev", "--", "apk update"])
    }
    try allowlist(.interactiveShell, ["machine", "run", "--name", "dev", "--root", "--", "apk update"])
    #expect(throws: (any Error).self) {
        try allowlist(.interactiveShell, ["machine", "run", "--name", "dev", "--root", "--", "apk version -l '<'"])
    }
    #expect(throws: (any Error).self) {
        try allowlist(.interactiveShell, ["machine", "run", "--name", "dev", "--root", "--", "apk upgrade"])
    }
}
