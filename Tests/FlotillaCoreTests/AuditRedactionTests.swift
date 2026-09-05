import Foundation
import Testing
@testable import FlotillaCore

/// SEC-03: `auditDescription` used to join the whole canonical argv, so an audit record of
/// `container run --env DATABASE_PASSWORD=… ` carried the password to whatever read it.
///
/// These tests pin the *partition* — which shapes survive and which do not — rather than a set of
/// example strings, because the risk is a new `ValueShape` slipping into the wrong half.

private func audit(_ argv: [String],
                   mount: MountPolicy = .roots(["/tmp"]),
                   exec: ExecPolicy = .processListOnly) throws -> String {
    try Allowlist.validated(argv, mountPolicy: mount, execPolicy: exec).auditDescription
}

@Test func environmentValuesNeverReachTheAuditRecord() throws {
    let line = try audit(["run", "--env", "DATABASE_PASSWORD=hunter2", "--name", "web", "alpine"])
    #expect(!line.contains("hunter2"))
    #expect(!line.contains("DATABASE_PASSWORD"))   // the key names the secret too
    #expect(line.contains("--env <envAssignment>"))
    // The parts an auditor needs are all still there.
    #expect(line.contains("container run"))
    #expect(line.contains("alpine"))
    #expect(line.contains("web"))
}

@Test func labelAndOptionValuesAreShapedAway() throws {
    let line = try audit(["volume", "create", "--label", "team=infra", "--opt", "type=fast", "data"])
    #expect(!line.contains("infra"))
    #expect(!line.contains("fast"))
    #expect(line.contains("--label <keyValue>"))
    #expect(line.contains("--opt <keyValue>"))
    #expect(line.contains("data"))                 // the volume's name survives
}

@Test func hostPathsAreShapedAwayOnEveryShapeThatCarriesOne() throws {
    // Four separate shapes reach the filesystem, and missing one is the whole risk. `/tmp` is the
    // permitted root here, but a real one is `/Users/<someone>/…` — the account name is the point.
    let copy = try audit(["copy", "web:/etc/hostname", "/tmp/out"])
    #expect(!copy.contains("/tmp/out"))
    #expect(copy.contains("<copyEndpoint>"))

    let mount = try audit(["run", "--volume", "/tmp/data:/data", "alpine"])
    #expect(!mount.contains("/tmp/data"))
    #expect(mount.contains("--volume <mountSpec>"))

    // `hostBuildPath` requires the path to **exist** — the symlink-swap finding — so this one
    // needs real files rather than a plausible string, and a root that is already symlink-resolved
    // (on macOS `/tmp` is a link to `/private/tmp`, and the check compares both forms).
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.temporaryDirectory.resolvingSymlinksInPath().path)
    let dir = root.appendingPathComponent("flotilla-audit-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let dockerfile = dir.appendingPathComponent("Dockerfile")
    try Data("FROM alpine\n".utf8).write(to: dockerfile)

    let build = try audit(["build", "--file", dockerfile.path, "--tag", "app:1", dir.path],
                          mount: .roots([root.path]))
    #expect(!build.contains(dockerfile.path))
    #expect(!build.contains(dir.path))
    #expect(build.contains("--file <hostBuildPath>"))
    #expect(build.contains("app:1"))               // the tag is a name, and survives
}

@Test func theInContainerCommandIsCountedNotQuoted() throws {
    // Free text, and a plausible place for a credential (`sh -c 'curl -H "Authorization: …"'`).
    // The count is the part worth keeping.
    // The separator is required on *input* even though `exec` runs without one — the grammar
    // stays unambiguous, and the argv we execute drops it.
    let line = try audit(["exec", "web", "--", "ps", "-o", "pid,comm,args"])
    #expect(!line.contains("pid,comm,args"))
    #expect(line.contains("<command: 3 tokens>"))
    #expect(line.contains("container exec web"))
}

@Test func namesAndClosedSetsSurviveBecauseTheAuditIsWorthlessWithoutThem() throws {
    // The security interest of `machine set` is *which* setting changed. Hiding it would record
    // that something happened and withhold the only thing worth recording.
    // The machine is named by `-n`; the operands are the settings themselves.
    let set = try audit(["machine", "set", "-n", "prod", "home-mount=rw"])
    #expect(set.contains("home-mount=rw"))
    #expect(set.contains("prod"))

    let delete = try audit(["delete", "web"])
    #expect(delete == "container delete web")      // nothing shaped: nothing free-form present

    let pull = try audit(["image", "pull", "docker.io/library/nginx:latest"])
    #expect(pull.contains("docker.io/library/nginx:latest"))

    let net = try audit(["network", "create", "--subnet", "10.0.0.0/24", "private"])
    #expect(net.contains("10.0.0.0/24"))           // configuration, and an auditor wants it
}

@Test func everyValueShapeIsClassifiedOneWayOrTheOther() {
    // The classification is an exhaustive switch, so this cannot fail at runtime — it is here to
    // state the requirement, and to fail loudly if someone reintroduces a `default:`.
    for shape in ValueShape.allCases {
        _ = shape.carriesFreeFormData
    }
    // Spot-check both halves so a wholesale flip (everything true, or everything false) is caught.
    #expect(ValueShape.envAssignment.carriesFreeFormData)
    #expect(ValueShape.mountSpec.carriesFreeFormData)
    #expect(!ValueShape.identifier.carriesFreeFormData)
    #expect(!ValueShape.machineSetting.carriesFreeFormData)
}

@Test func aDirectlyConstructedCommandRedactsEverythingRatherThanNothing() {
    // No spec means no way to tell a value from a name, so the fallback fails closed. The old
    // behaviour — join it all — is what SEC-03 was.
    let command = ValidatedCommand(subcommand: ["run"],
                                   arguments: ["run", "--env", "TOKEN=hunter2", "alpine"],
                                   mutates: true, timeoutHint: 600)
    #expect(!command.auditDescription.contains("hunter2"))
    #expect(command.auditDescription.contains("--env"))
    // And the preview still shows the person their own command.
    #expect(command.localPreview.contains("TOKEN=hunter2"))
}
