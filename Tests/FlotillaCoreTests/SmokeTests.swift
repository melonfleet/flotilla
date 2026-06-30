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
