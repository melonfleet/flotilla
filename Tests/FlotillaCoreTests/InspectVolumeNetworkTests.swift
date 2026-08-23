import Foundation
import Testing
@testable import FlotillaCore

/// GAP-06: `volume inspect` and `network inspect` were in the allowlist from the beginning and had
/// no `ContainerCLI` method, so the grammar permitted a command nothing could issue.
///
/// Fixtures are captured from the real CLI on this Mac. The volume record contains the on-disk
/// image path, so the **account name** is replaced with `example` — matching the existing
/// `volumes.json`. That substitution is worth a note: the CLI escapes forward slashes in JSON
/// (`\/Users\/name\/`), so the obvious `s|/Users/name/|…|` pass matches nothing and silently leaves
/// the real name in a tracked file. It did exactly that on the first attempt here.

/// Answers one canned payload per argv, keyed on the joined arguments. Local to this file — the
/// suite has several of these shaped slightly differently, and sharing one would mean a change for
/// one test's needs silently altering another's fixture semantics.
private struct FixtureHost: ContainerHost {
    let responses: [String: String]
    func run(_ args: [String]) throws -> CommandResult {
        guard let stdout = responses[args.joined(separator: " ")] else {
            // The real CLI's shape for an unknown request: non-zero with a message, not a throw.
            return CommandResult(stdout: "", stderr: "unexpected argv: \(args.joined(separator: " "))",
                                 exitCode: 64)
        }
        return CommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}

private func fixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
    let data = try Data(contentsOf: try #require(url))
    return String(decoding: data, as: UTF8.self)
}

@Test func volumeInspectDecodesTheRealRecord() throws {
    let host = FixtureHost(responses: ["volume inspect probe-shortform": try fixture("inspect-volume")])
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let volume = try cli.inspectVolume("probe-shortform")

    #expect(volume.id == "probe-shortform")
    #expect(volume.configuration.name == "probe-shortform")
    #expect(volume.configuration.driver == "local")
    #expect(volume.configuration.format == "ext4")
    #expect(volume.configuration.sizeInBytes == 67_108_864)
    // `options` carries the `-s 64M` the volume was created with — the one field that explains
    // a size that does not match the default.
    #expect(volume.configuration.options?["size"] == "64M")
    #expect(volume.configuration.source?.hasSuffix("volume.img") == true)
}

@Test func networkInspectDecodesTheStatusBlock() throws {
    let host = FixtureHost(responses: ["network inspect default": try fixture("inspect-network")])
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    let network = try cli.inspectNetwork("default")

    #expect(network.id == "default")
    #expect(network.configuration.mode == "nat")
    // The reason inspect is worth having for networks at all: the assigned addressing.
    #expect(network.status?.ipv4Gateway == "192.168.66.1")
    #expect(network.status?.ipv4Subnet == "192.168.66.0/24")
    #expect(network.status?.ipv6Subnet?.hasSuffix("::/64") == true)
    // The builtin marker, which is why `default` cannot be deleted.
    #expect(network.configuration.labels?["com.apple.container.resource.role"] == "builtin")
}

@Test func anEmptyInspectResultIsNamedRatherThanCrashing() throws {
    // `[]` is what the CLI returns for a name that does not exist but is well-formed. Decoding it
    // succeeds and yields nothing, so `first` would be nil — the crash this guard exists for.
    let host = FixtureHost(responses: ["volume inspect ghost": "[]", "network inspect ghost": "[]"])
    let cli = ContainerCLI(host: host, wirePolicy: .localOwner)
    #expect(throws: ContainerCLIError.self) { try cli.inspectVolume("ghost") }
    #expect(throws: ContainerCLIError.self) { try cli.inspectNetwork("ghost") }
}
