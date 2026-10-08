import Foundation
import Testing
@testable import FlotillaCore

// `container` 1.5.0's payloads, captured on 5 October (to-do item 3) into
// `Fixtures/container-1.5.0/` by `Scripts/capture-fixtures.sh --out`.
//
// **Decode-only, on purpose.** The value-pinned tests (`SmokeTests` and friends) stay on the 1.4.1
// set in `Fixtures/`: their numbers — six containers, a 4122138-byte image — describe the resources
// that existed when it was captured, and overwriting it with 1.5.0 failed them for that reason
// alone (tried, 5 October). What a version bump has to prove is that every payload Flotilla reads
// still *decodes*, so this set answers exactly that, and a later bump adds a folder beside it.
//
// The core CLI's help is identical between the two versions (`reference/cli-help/`); these are
// the other half of that claim.
//
// Fourteen JSON files, not the pinned set's nineteen. The five missing each need a state made for
// them — a version skew, an empty Mac, an administrator's DNS domain, a registry login, three
// purpose-made port containers — and were captured by hand once, against 1.4.1. Copying those in
// to fill the gap would have labelled 1.4.1 output as 1.5.0's, which is the one thing a capture
// must not do (it happened in the first draft of this set, and a byte comparison caught it).

private let version = "container-1.5.0"

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures/\(version)"))
    return try Data(contentsOf: url)
}

private func decodes<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder.flotilla.decode(type, from: fixture(name))
}

@Suite("container 1.5.0 payloads")
struct Container150DecodeTests {

    @Test func theSetRecordsTheCLIItCameFrom() throws {
        let url = try #require(Bundle.module.url(forResource: "CAPTURED", withExtension: "md",
                                                 subdirectory: "Fixtures/\(version)"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("container CLI version 1.5.0"))
    }

    @Test func containersDecode() throws {
        let containers = try decodes([Container].self, "containers")
        // One has a published port and one has none, so both shapes of the field are read.
        #expect(containers.contains { !$0.publishedPorts.isEmpty })
        #expect(containers.contains { $0.publishedPorts.isEmpty })
        // The same shape, read through `container inspect`.
        #expect(!(try decodes([Container].self, "inspect-container")).isEmpty)
    }

    @Test func imagesDecode() throws {
        #expect(!(try decodes([ContainerImage].self, "images")).isEmpty)
        #expect(!(try decodes([ContainerImage].self, "inspect-image")).isEmpty)
    }

    @Test func statsDecode() throws {
        #expect(!(try decodes([ContainerStats].self, "stats")).isEmpty)
    }

    @Test func volumesAndNetworksDecode() throws {
        #expect(!(try decodes([ContainerVolume].self, "volumes")).isEmpty)
        #expect(!(try decodes([ContainerVolume].self, "inspect-volume")).isEmpty)
        #expect(!(try decodes([ContainerNetwork].self, "networks")).isEmpty)
        #expect(!(try decodes([ContainerNetwork].self, "inspect-network")).isEmpty)
    }

    @Test func machinesDecode() throws {
        #expect(!(try decodes([ContainerMachine].self, "machines")).isEmpty)
        #expect(!(try decodes([ContainerMachine].self, "machine-inspect")).isEmpty)
    }

    @Test func systemPayloadsDecode() throws {
        let status = try decodes(SystemStatus.self, "system-status")
        #expect(status.isRunning)
        #expect(!status.hasVersionSkew)
        _ = try decodes(SystemDiskUsage.self, "system-df")
    }

    @Test func theVersionPayloadNamesTheNewCLI() throws {
        let components = try decodes([VersionComponent].self, "version")
        #expect(components.contains { $0.version.hasPrefix("1.5.0") })
    }
}
