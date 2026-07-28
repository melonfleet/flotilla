import Foundation
import Testing
@testable import FlotillaCore

// These decode REAL `container` 1.0.0 output captured in Fixtures/. They pin the
// schema so model changes that break decoding fail loudly. No `container` install
// is needed to run `swift test`.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodeContainers() throws {
    let containers = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers"))
    #expect(containers.count == 1)
    let c = try #require(containers.first)
    #expect(c.name == "flotilla-probe-test")
    #expect(c.imageReference == "docker.io/library/alpine:latest")
    #expect(c.isRunning)
    #expect(c.ipv4 == "192.168.64.2/24")
    #expect(c.configuration.resources?.cpus == 4)
}

@Test func decodeImages() throws {
    let images = try JSONDecoder.flotilla.decode([ContainerImage].self, from: fixture("images"))
    let img = try #require(images.first)
    #expect(img.reference == "docker.io/library/alpine:latest")
    #expect(img.displaySize == 4184689) // arm64 variant
}

@Test func decodeStats() throws {
    let stats = try JSONDecoder.flotilla.decode([ContainerStats].self, from: fixture("stats"))
    let s = try #require(stats.first)
    #expect(s.numProcesses == 1)
    #expect(s.memoryUsageBytes == 2002944)
    #expect((s.memoryPercent ?? 0) > 0)
}

@Test func decodeSystemStatus() throws {
    let status = try JSONDecoder.flotilla.decode(SystemStatus.self, from: fixture("system-status"))
    #expect(status.isRunning)
    #expect(status.status == "running")
}

@Test func decodeVersions() throws {
    let versions = try JSONDecoder.flotilla.decode([VersionComponent].self, from: fixture("version"))
    #expect(versions.contains { $0.appName == "container" && $0.version == "1.0.0" })
}

@Test func commandResultOK() {
    #expect(CommandResult(stdout: "", stderr: "", exitCode: 0).ok)
    #expect(!CommandResult(stdout: "", stderr: "boom", exitCode: 1).ok)
}

// MARK: - Published ports
//
// `publishedPorts` was present in `container ls --format json` from the start and the
// model simply dropped it, so the containers table had no ports column and the build
// contract asked for one that could not be written. The pre-existing `containers.json`
// fixture happens to publish nothing (`publishedPorts: []`), which is exactly why the
// gap went unnoticed — an always-empty field decodes identically whether you model it
// or not. `containers-ports.json` is captured from a real container started with
// `-p 18080:80`, plus a range and a no-ports case.

@Test func decodePublishedPorts() throws {
    let containers = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers-ports"))
    #expect(containers.count == 3)

    let published = try #require(containers.first { $0.id == "flotilla-portprobe" })
    let port = try #require(published.publishedPorts.first)
    #expect(port.hostPort == 18080)
    #expect(port.containerPort == 80)
    #expect(port.proto == "tcp")
    #expect(port.hostAddress == "0.0.0.0")
    #expect(published.portSummary == "18080:80/tcp")
}

@Test func aPublishedRangeReportsEveryPortItExposes() throws {
    let containers = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers-ports"))
    let ranged = try #require(containers.first { $0.id == "range-demo" })

    // `container` collapses a contiguous range into ONE entry with a count rather than
    // repeating it. Rendering only `hostPort` would tell the user 7000 is exposed while
    // 7001 and 7002 quietly are too — under-reporting an exposed port is a security
    // statement, not a formatting nicety.
    #expect(ranged.portSummary == "7000-7002:7000-7002/udp")
}

@Test func noPublishedPortsIsDistinctFromPortsWeFailedToRead() throws {
    let containers = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers-ports"))
    let bare = try #require(containers.first { $0.id == "no-ports" })
    #expect(bare.publishedPorts.isEmpty)
    // nil, not "" — the column shows a deliberate em dash rather than a blank cell that
    // reads as "we don't know".
    #expect(bare.portSummary == nil)

    // And a container whose JSON omits the key entirely must behave the same way, not trap.
    let legacy = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers"))
    #expect(try #require(legacy.first).portSummary == nil)
}
