import Foundation
import Testing
@testable import FlotillaCore

// `Fixtures/machines.json` and `Fixtures/machine-inspect.json` are real captures from a
// live `container 1.0.0` install (`machine list --format json` / `machine inspect`), not
// hand-written — see the fixture warning in `CLAUDE.md` and the doc comment on
// `ContainerMachine`. These tests decode against them and pin real values.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodeMachineList() throws {
    let machines = try JSONDecoder.flotilla.decode([ContainerMachine].self, from: fixture("machines"))
    let m = try #require(machines.first)

    #expect(m.id == "flotilla-probe")
    #expect(m.status == "running")
    #expect(m.cpus == 6)
    // Bytes, not the human-readable units `machine list --format table` shows.
    #expect(m.memory == 34_359_738_368)
    #expect(m.diskSize == 78_692_352)
    #expect(m.ipAddress == "192.168.64.10")
    #expect(m.createdDate == "2026-08-03T09:16:13Z")
    #expect(m.isDefault == true)
    #expect(m.isRunning)

    // `machine list` carries none of the inspect-only fields.
    #expect(m.containerId == nil)
    #expect(m.homeMount == nil)
    #expect(m.image == nil)
    #expect(m.platform == nil)
    #expect(m.startedDate == nil)
    #expect(m.userSetup == nil)
}

@Test func decodeMachineInspect() throws {
    let machines = try JSONDecoder.flotilla.decode([ContainerMachine].self, from: fixture("machine-inspect"))
    let m = try #require(machines.first)

    // The list-shared fields decode identically from either endpoint.
    #expect(m.id == "flotilla-probe")
    #expect(m.status == "running")
    #expect(m.cpus == 6)
    #expect(m.memory == 34_359_738_368)
    #expect(m.diskSize == 78_692_352)
    #expect(m.ipAddress == "192.168.64.10")
    #expect(m.createdDate == "2026-08-03T09:16:13Z")
    // `machine inspect` reports no `default` key at all — nil, not false.
    #expect(m.isDefault == nil)

    // The five inspect-only fields.
    #expect(m.containerId == "flotilla-probe-93936e")
    #expect(m.homeMount == "rw")
    #expect(m.startedDate == "2026-08-03T09:16:14Z")

    let image = try #require(m.image)
    #expect(image.reference == "docker.io/library/alpine:3.22")
    #expect(image.descriptor?.mediaType == "application/vnd.oci.image.index.v1+json")
    #expect(image.descriptor?.size == 9218)
    #expect(image.descriptor?.digest == "sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce")

    let platform = try #require(m.platform)
    #expect(platform.architecture == "arm64")
    #expect(platform.os == "linux")

    // `userSetup.username` is the host user's real name; the committed fixture is
    // anonymised to `example` on purpose (see `ContainerMachine.UserSetup`'s doc comment).
    let userSetup = try #require(m.userSetup)
    #expect(userSetup.uid == 501)
    #expect(userSetup.gid == 20)
    #expect(userSetup.username == "example")
}

// `Container` nests under `configuration`/`status`; `ContainerMachine` does not. Modelling
// this by analogy to `Container` is the exact mistake that made `ContainerVolume` throw on
// every real volume — this test fails the moment someone "corrects" `ContainerMachine` to
// look like `Container` by re-nesting it.
@Test func machineListFixtureIsFlatNotNested() throws {
    let raw = try JSONSerialization.jsonObject(with: fixture("machines")) as? [[String: Any]]
    let entry = try #require(raw?.first)

    #expect(entry["configuration"] == nil,
            "the machine payload is flat — nesting under configuration is the Container shape, not this one")
    #expect(entry["status"] is String,
            "status must be a top-level string, not a nested object the way it is on Container")
    #expect(entry["cpus"] != nil && entry["memory"] != nil && entry["diskSize"] != nil,
            "cpus/memory/diskSize must be readable straight off the top-level object")
}
