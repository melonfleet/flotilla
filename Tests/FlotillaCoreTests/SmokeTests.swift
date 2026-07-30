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

// MARK: - Reference shortening
//
// The containers table middle-truncated the full image reference, so every row read
// "docker.i…ne:latest" — identical for all of them and saying nothing about what was
// running. Shortening happens in the view, but the awkward cases are worth pinning:
// digest references (64 hex chars would swallow the whole cell) and bare names.

@Test func shortReferenceKeepsThePartThatDistinguishesOneImageFromAnother() throws {
    #expect(ContainerImage.shortReference("docker.io/library/alpine:latest") == "alpine:latest")
    #expect(ContainerImage.shortReference("ghcr.io/melonfleet/inkwarden:1.4.2") == "inkwarden:1.4.2")
    // No registry or namespace at all.
    #expect(ContainerImage.shortReference("alpine") == "alpine")
    #expect(ContainerImage.shortReference("alpine:3.24") == "alpine:3.24")
}

@Test func shortReferenceAbbreviatesADigestInsteadOfBeingSwallowedByIt() throws {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let short = ContainerImage.shortReference("ghcr.io/melonfleet/inkwarden@\(digest)")

    // Recognisable, but not 71 characters of it.
    #expect(short.hasPrefix("inkwarden@sha256:"))
    #expect(short.count < 32)
    // A registry port must not be mistaken for a tag, and the digest must not be dropped
    // silently — showing a bare name for a digest-pinned image would hide the pinning.
    #expect(short.contains("sha256:"))
}

@Test func shortReferenceDoesNotMistakeARegistryPortForATag() throws {
    // `host:5000/name:tag` — the FIRST colon belongs to the port, not the tag.
    #expect(ContainerImage.shortReference("registry.example:5000/team/tool:2.1") == "tool:2.1")
}

// MARK: - inspect and system df, against real captures
//
// Both were added without a live `container` to capture from, so `inspect` was only known
// to decode `ls` output and `system df` was left as a raw passthrough rather than a
// fabricated schema. These fixtures are real captures from `container 1.0.0` taken on the
// Mac afterwards, which is what lets both be pinned properly.

@Test func containerInspectReallyEmitsAnArrayLikeListDoes() throws {
    // The unverified assumption: `inspect` returns a single object, not a one-element
    // array. It is an array — so decoding it as `[Container]` and taking `.first` is right,
    // and this fixture is what stops that being a guess.
    let containers = try JSONDecoder.flotilla.decode(
        [Container].self, from: fixture("inspect-container"))
    #expect(containers.count == 1)

    let c = try #require(containers.first)
    #expect(c.id == "web-demo")
    #expect(c.isRunning)
    // The shape really is `ls`-identical, including the field the model only learned about
    // later.
    #expect(c.portSummary == "18080:80/tcp")
}

@Test func imageInspectDecodesAsTheImageModelToo() throws {
    let images = try JSONDecoder.flotilla.decode(
        [ContainerImage].self, from: fixture("inspect-image"))
    let img = try #require(images.first)
    #expect(img.reference == "docker.io/library/alpine:latest")
}

@Test func systemDiskUsageDecodesTheRealPayload() throws {
    let df = try JSONDecoder.flotilla.decode(SystemDiskUsage.self, from: fixture("system-df"))

    // Keyed by resource, not an array — unlike every list command.
    #expect(df.containers.total == 3)
    #expect(df.containers.active == 1)
    #expect(df.images.total == 2)
    #expect(df.volumes.total == 0)

    // Row order matches the CLI's own table so the app and terminal agree.
    #expect(df.categories.map(\.id) == ["Images", "Containers", "Local Volumes"])
    #expect(df.totalReclaimableBytes == df.containers.reclaimable + df.images.reclaimable + df.volumes.reclaimable)
}

@Test func nothingStoredIsDistinctFromNothingReclaimable() throws {
    let df = try JSONDecoder.flotilla.decode(SystemDiskUsage.self, from: fixture("system-df"))

    // Volumes hold nothing at all, so "what fraction is reclaimable" has no answer —
    // reporting 0% would imply there is something here that cannot be freed. The CLI's own
    // table prints `0 B (0%)` for both cases and loses that distinction; we keep it.
    #expect(df.volumes.reclaimableFraction == nil)

    let images = try #require(df.categories.first { $0.id == "Images" })
    let fraction = try #require(images.reclaimableFraction)
    #expect(fraction > 0.7 && fraction < 0.8)   // CLI reported 74%
}
