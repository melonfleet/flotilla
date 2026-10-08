import Foundation
import Testing
@testable import FlotillaCore

// These decode REAL `container` output captured in Fixtures/ by
// `Scripts/capture-fixtures.sh` — 1.4.1 as of 2026-09-12, recorded in `Fixtures/CAPTURED.md`.
// They pin the schema so model changes that break decoding fail loudly. No `container` install
// is needed to run `swift test`.
//
// **Subjects are named, not indexed.** These used to say `containers.first`, which meant a
// recapture against a different set of resources failed every assertion for no reason but
// ordering. Naming the container each expectation is about makes a recapture a two-line change
// and says what the test is actually claiming.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodeContainers() throws {
    let containers = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers"))
    #expect(containers.count == 6)
    let c = try #require(containers.first { $0.id == "cache" })
    #expect(c.name == "cache")
    #expect(c.imageReference == "docker.io/library/alpine:latest")
    #expect(c.isRunning)
    #expect(c.ipv4 == "192.168.67.4/24")
    #expect(c.configuration.resources?.cpus == 4)

    // A stopped container has no address, which is a different thing from an address we failed
    // to read — the fixture carries one of each so the distinction stays tested.
    let stopped = try #require(containers.first { $0.id == "test1" })
    #expect(!stopped.isRunning)
    #expect(stopped.ipv4 == nil)
}

@Test func decodeImages() throws {
    let images = try JSONDecoder.flotilla.decode([ContainerImage].self, from: fixture("images"))
    let img = try #require(images.first { $0.reference == "docker.io/library/alpine:3.22" })
    #expect(img.displaySize == 4122138) // arm64 variant
}

@Test func decodeStats() throws {
    let stats = try JSONDecoder.flotilla.decode([ContainerStats].self, from: fixture("stats"))
    let s = try #require(stats.first { $0.id == "busy" })
    #expect(s.numProcesses == 1)
    #expect(s.memoryUsageBytes == 1974272)
    #expect((s.memoryPercent ?? 0) > 0)
    // A stats sample covers containers *and* the machines' own containers, which is worth
    // pinning: the dashboard's table filters to the fleet and would otherwise list a VM.
    #expect(stats.contains { $0.id.hasPrefix("probe-alpine-") })
}

@Test func decodeSystemStatus() throws {
    let status = try JSONDecoder.flotilla.decode(SystemStatus.self, from: fixture("system-status"))
    #expect(status.isRunning)
    #expect(status.status == "running")
}

@Test func decodeVersions() throws {
    let versions = try JSONDecoder.flotilla.decode([VersionComponent].self, from: fixture("version"))
    // Both halves, and both the same build — the pair disagreeing is the upgrade state
    // `SystemStatus.hasVersionSkew` exists to catch.
    #expect(versions.contains { $0.appName == "container" && $0.version == "1.4.1" })
    #expect(versions.contains { $0.appName == "container-apiserver" && $0.version == "1.4.1" })
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
    // 1.4.1 always emits `publishedPorts`, empty when there are none, so "no ports" is now an
    // empty array rather than a missing key. Both must read as nothing published.
    let listed = try JSONDecoder.flotilla.decode([Container].self, from: fixture("containers"))
    #expect(try #require(listed.first { $0.id == "busy" }).portSummary == nil)
    #expect(try #require(listed.first { $0.id == "cache" }).portSummary == "6379:6379/tcp")
}

// MARK: - Reference shortening
//
// The containers table middle-truncated the full image reference, so every row read
// "docker.i…ne:latest" — identical for all of them and saying nothing about what was
// running. Shortening happens in the view, but the awkward cases are worth pinning:
// digest references (64 hex chars would swallow the whole cell) and bare names.

@Test func shortReferenceKeepsThePartThatDistinguishesOneImageFromAnother() throws {
    #expect(ContainerImage.shortReference("docker.io/library/alpine:latest") == "alpine:latest")
    #expect(ContainerImage.shortReference("ghcr.io/example/webapp:1.4.2") == "webapp:1.4.2")
    // No registry or namespace at all.
    #expect(ContainerImage.shortReference("alpine") == "alpine")
    #expect(ContainerImage.shortReference("alpine:3.24") == "alpine:3.24")
}

@Test func shortReferenceAbbreviatesADigestInsteadOfBeingSwallowedByIt() throws {
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let short = ContainerImage.shortReference("ghcr.io/example/webapp@\(digest)")

    // Recognisable, but not 71 characters of it.
    #expect(short.hasPrefix("webapp@sha256:"))
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
    #expect(c.id == "busy")
    #expect(c.isRunning)
    // The shape really is `ls`-identical, including the field the model only learned about
    // later — present, and empty, on a container with nothing published.
    #expect(c.portSummary == nil)
    #expect(c.configuration.publishedPorts?.isEmpty == true)
}

@Test func imageInspectDecodesAsTheImageModelToo() throws {
    let images = try JSONDecoder.flotilla.decode(
        [ContainerImage].self, from: fixture("inspect-image"))
    let img = try #require(images.first)
    #expect(img.reference == "docker.io/library/alpine:3.22")
}

@Test func systemDiskUsageDecodesTheRealPayload() throws {
    let df = try JSONDecoder.flotilla.decode(SystemDiskUsage.self, from: fixture("system-df"))

    // Keyed by resource, not an array — unlike every list command.
    #expect(df.containers.total == 7)
    #expect(df.containers.active == 5)
    #expect(df.images.total == 10)
    #expect(df.volumes.total == 3)

    // Row order matches the CLI's own table so the app and terminal agree.
    #expect(df.categories.map(\.id) == ["Images", "Containers", "Local Volumes"])
    #expect(df.totalReclaimableBytes == df.containers.reclaimable + df.images.reclaimable + df.volumes.reclaimable)
}

@Test func nothingStoredIsDistinctFromNothingReclaimable() throws {
    // **A deliberately older capture**, and the one fixture `Scripts/capture-fixtures.sh` does
    // not refresh: it is a real `system df` from a Mac with no volumes at all, which is the
    // state this test is about and not a state a recapture can be relied on to reproduce. The
    // payload shape was verified unchanged between 1.0.0 and 1.4.1, so it still decodes.
    let df = try JSONDecoder.flotilla.decode(
        SystemDiskUsage.self, from: fixture("system-df-nothing-stored"))

    // Volumes hold nothing at all, so "what fraction is reclaimable" has no answer —
    // reporting 0% would imply there is something here that cannot be freed. The CLI's own
    // table prints `0 B (0%)` for both cases and loses that distinction; we keep it.
    #expect(df.volumes.reclaimableFraction == nil)

    let images = try #require(df.categories.first { $0.id == "Images" })
    let fraction = try #require(images.reclaimableFraction)
    #expect(fraction > 0.7 && fraction < 0.8)   // CLI reported 74%
}

// MARK: - The upgrade state that looks healthy and is not

@Test func aSkewedRuntimeIsDetectedFromTheStatusPayload() throws {
    // Captured on this Mac on 2026-09-12, in the minutes after installing `container` 1.4.1
    // over 1.0.0 without restarting the service. `status` said `running`; every already-running
    // container kept running; and no new container or machine could start, failing with
    // `no available interface strategy for network default`. One restart fixed it.
    let skewed = try JSONDecoder.flotilla.decode(SystemStatus.self, from: fixture("system-status-version-skew"))
    #expect(skewed.status == "running")
    #expect(skewed.isRunning)
    #expect(skewed.hasVersionSkew)
    #expect(skewed.client?.version == "1.4.1")
    // The old daemon reported a whole sentence, which is exactly why the comparison is on
    // commits and why the display form is trimmed rather than the stored one rewritten.
    #expect(skewed.server?.version == "container-apiserver version 1.0.0 (build: release, commit: ee848e3)")
    #expect(skewed.skewDescription == "CLI 1.4.1, service 1.0.0")

    let healthy = try JSONDecoder.flotilla.decode(SystemStatus.self, from: fixture("system-status"))
    #expect(healthy.isRunning)
    #expect(!healthy.hasVersionSkew)
    #expect(healthy.skewDescription == nil)

    // Both payload shapes still answer the questions the app asks of them, which is what lets
    // one build drive either runtime.
    #expect(healthy.apiServerVersion == "1.4.1")
    #expect(healthy.installRoot == "/usr/local/")
    #expect(healthy.appRoot?.hasSuffix("com.apple.container/") == true)
}
