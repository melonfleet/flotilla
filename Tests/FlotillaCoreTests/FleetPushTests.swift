import Foundation
import Testing
@testable import FlotillaCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Against captured `network list` / `volume list` output, never hand-written shapes (CLAUDE.md).
@Suite("Fleet push")
struct FleetPushTests {
    let networks: [ContainerNetwork]
    let volumes: [ContainerVolume]

    init() throws {
        networks = try JSONDecoder().decode([ContainerNetwork].self, from: fixture("networks"))
        volumes = try JSONDecoder().decode([ContainerVolume].self, from: fixture("volumes"))
    }

    @Test func aNetworkIsCreatedMatchedOrReportedNeverReplaced() throws {
        #expect(FleetPush.status(of: NetworkSpec(name: "test"), on: nil) == .unavailable)
        #expect(FleetPush.status(of: NetworkSpec(name: "absent"), on: networks) == .create)
        #expect(FleetPush.status(of: NetworkSpec(name: "test"), on: networks) == .matches)
        // The runtime's own `com.apple.` labels are not part of anyone's definition.
        #expect(FleetPush.status(of: NetworkSpec(name: "default"), on: networks) == .matches)
        #expect(FleetPush.status(of: NetworkSpec(name: "test", hostOnly: true, labels: ["team=shop"]), on: networks)
                == .differs(["host-only here, not there", "labels differ"]))
    }

    @Test func theDefinitionOfANetworkLeavesItsSubnetOut() throws {
        let test = try #require(networks.first { $0.id == "test" })
        #expect(FleetPush.definition(of: test) == NetworkSpec(name: "test", hostOnly: false, subnet: nil, labels: []))
    }

    @Test func aVolumeComparesCapacityAndLabels() throws {
        // `web` was created with no size, so it reports the 512 GiB default.
        #expect(FleetPush.status(of: VolumeSpec(name: "web", size: "512G"), on: volumes) == .matches)
        #expect(FleetPush.status(of: VolumeSpec(name: "web", size: "1G"), on: volumes)
                == .differs(["capacity 1G here, 512G there"]))
        let probe = try #require(volumes.first { $0.name == "probe-shortform" })
        #expect(FleetPush.definition(of: probe).size == "64M")
    }

    @Test func theSpreadCountsOnlyHostsThatAnswered() {
        var spread = FleetPush.Spread()
        for status: FleetPush.Status in [.matches, .differs(["x"]), .create, .unavailable] { spread.add(status) }
        #expect(spread.present == 2 && spread.differing == 1 && spread.asked == 3)
    }
}
