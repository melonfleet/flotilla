import Foundation
import Testing
@testable import FlotillaCore

@Test func denyHostPathsRejectsHostPathsButNamedVolumesRemainValid() throws {
    #expect(!MountPolicy.denyHostPaths.allowsHostPath("/Users/shared"))

    #expect(
        Allowlist.validate(["run", "--volume", "/Users/shared:/data:ro", "alpine"])
            == .failure(.hostPathNotPermitted(context: "--volume", path: "/Users/shared"))
    )

    let namedVolume = try Allowlist.validated([
        "run", "--volume", "shared-data:/data:ro", "alpine",
    ])
    #expect(namedVolume.arguments.contains("shared-data:/data:ro"))
}

@Test func bothValidationEntryPointsDefaultToDeny() {
    let args = ["run", "--volume", "/tmp/data:/data:ro", "alpine"]
    let expected = AllowlistError.hostPathNotPermitted(context: "--volume", path: "/tmp/data")

    #expect(Allowlist.validate(args) == .failure(expected))
    #expect(throws: expected) {
        try Allowlist.validated(args)
    }
}

@Test func permittedRootsUsePathComponentBoundaries() {
    let policy = MountPolicy.roots(["/Users/shared"])

    #expect(policy.allowsHostPath("/Users/shared"))
    #expect(policy.allowsHostPath("/Users/shared/project"))
    #expect(!policy.allowsHostPath("/Users"))
    #expect(!policy.allowsHostPath("/Users/shared-secrets"))
    #expect(!policy.allowsHostPath("/Users/sharedness/project"))
}

@Test func trailingAndRepeatedSeparatorsAreNormalised() {
    let policy = MountPolicy.roots(["/Users//shared///"])

    #expect(policy.permittedRoots == ["/Users/shared"])
    #expect(policy.allowsHostPath("/Users/shared/"))
    #expect(policy.allowsHostPath("/Users///shared//project/"))
    #expect(!policy.allowsHostPath("/Users//shared-secrets/"))
    #expect(!policy.allowsHostPath("////"))
}

@Test func malformedRootsAreDiscarded() {
    let policy = MountPolicy.roots([
        "",
        "relative/path",
        ".",
        "..",
        "/",
        "///",
        "/safe/.",
        "/safe/..",
        "/safe/../outside",
        "/safe//..//outside",
    ])

    #expect(policy.permittedRoots.isEmpty)
    #expect(!policy.allowsHostPath("/etc/passwd"))
    #expect(
        Allowlist.validate(
            ["run", "--volume", "/etc/passwd:/data/passwd:ro", "alpine"],
            mountPolicy: policy
        )
            == .failure(.hostPathNotPermitted(context: "--volume", path: "/etc/passwd"))
    )
}

@Test func traversingCandidateIsNeverContained() {
    let policy = MountPolicy.roots(["/permitted"])

    // REGRESSION: `allowsHostPath` is public, so it must not turn a path outside the
    // root into an allowed path merely because Allowlist currently screens its caller.
    #expect(!policy.allowsHostPath("/permitted/../outside/secret"))
    #expect(!policy.allowsHostPath("/permitted/./child"))
}

@Test func containmentFollowsTheUnicodeSemanticsOfTheHostFilesystem() throws {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("FlotillaMountPolicy-\(UUID().uuidString)")
    let composedRoot = base.appendingPathComponent("Caf\u{00E9}")
    let decomposedRoot = base.appendingPathComponent("Cafe\u{301}")
    let composedChild = composedRoot.appendingPathComponent("project")
    let decomposedChild = decomposedRoot.appendingPathComponent("project")
    defer { try? fileManager.removeItem(at: base) }

    try fileManager.createDirectory(at: composedChild, withIntermediateDirectories: true)

    let filesystemTreatsNormalisationsAsEquivalent =
        fileManager.fileExists(atPath: decomposedChild.path)
    if !filesystemTreatsNormalisationsAsEquivalent {
        // On a normalisation-sensitive filesystem this is a second, distinct tree,
        // so accepting it would be a real outside-root admission rather than a check
        // involving a path that does not exist.
        try fileManager.createDirectory(at: decomposedChild, withIntermediateDirectories: true)
    }
    let policy = MountPolicy.roots([composedRoot.path])

    #expect(
        policy.allowsHostPath(decomposedChild.path)
            == filesystemTreatsNormalisationsAsEquivalent
    )
}

@Test func containmentFollowsTheCaseSemanticsOfTheHostFilesystem() throws {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("FlotillaMountPolicy-\(UUID().uuidString)")
    let root = base.appendingPathComponent("MixedCaseRoot")
    let child = root.appendingPathComponent("child")
    defer { try? fileManager.removeItem(at: base) }

    try fileManager.createDirectory(at: child, withIntermediateDirectories: true)

    let differentlyCasedRoot = base.appendingPathComponent("mixedcaseroot")
    let differentlyCasedChild = differentlyCasedRoot.appendingPathComponent("child")
    let filesystemTreatsCaseAsEquivalent = fileManager.fileExists(atPath: differentlyCasedChild.path)
    let policy = MountPolicy.roots([root.path])

    #expect(
        policy.allowsHostPath(differentlyCasedChild.path) == filesystemTreatsCaseAsEquivalent
    )
}

@Test func symlinkCannotEscapeAPermittedRoot() throws {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory
        .appendingPathComponent("FlotillaMountPolicy-\(UUID().uuidString)")
    let permitted = base.appendingPathComponent("permitted")
    let outside = base.appendingPathComponent("outside")
    let secret = outside.appendingPathComponent("secret")
    let escape = permitted.appendingPathComponent("escape")
    defer { try? fileManager.removeItem(at: base) }

    try fileManager.createDirectory(at: permitted, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secret, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: escape, withDestinationURL: outside)

    let escaped = escape.appendingPathComponent("secret")
    let escapedPath = escaped.path
    #expect(escapedPath.hasPrefix(permitted.path + "/"))
    #expect(escaped.resolvingSymlinksInPath().path == secret.path)

    // REGRESSION: this is lexically below `permitted`, but the runtime will mount the
    // directory outside it after following `escape`.
    #expect(!MountPolicy.roots([permitted.path]).allowsHostPath(escapedPath))
    #expect(
        Allowlist.validate(
            ["run", "--volume", "\(escapedPath):/data:ro", "alpine"],
            mountPolicy: .roots([permitted.path])
        )
            == .failure(.hostPathNotPermitted(context: "--volume", path: escapedPath))
    )
}

@Test func explicitPoliciesAreThreadedWithoutSharedMutableState() async {
    let args = ["run", "--volume", "/allowed/data:/data:ro", "alpine"]

    await withTaskGroup(of: Bool.self) { group in
        for index in 0..<100 {
            group.addTask {
                let shouldAllow = index.isMultiple(of: 2)
                let policy = shouldAllow
                    ? MountPolicy.roots(["/allowed"])
                    : MountPolicy.roots(["/different"])
                let accepted: Bool
                if case .success = Allowlist.validate(args, mountPolicy: policy) {
                    accepted = true
                } else {
                    accepted = false
                }
                return accepted == shouldAllow
            }
        }

        for await result in group {
            #expect(result)
        }
    }
}
