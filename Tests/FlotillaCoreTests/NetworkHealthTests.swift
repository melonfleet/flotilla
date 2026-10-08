import Foundation
import Testing
@testable import FlotillaCore

@Suite("Network health")
struct NetworkHealthTests {

    @Test("a network with running containers but no gateway on this Mac is disconnected")
    func disconnected() {
        // This Mac on 6 October: default's 192.168.64.1 was missing, shop-net's was present.
        let networks = [NetworkHealth.Network(name: "default", gateway: "192.168.64.1"),
                        NetworkHealth.Network(name: "shop-net", gateway: "192.168.70.1"),
                        NetworkHealth.Network(name: "idle-net", gateway: "192.168.71.1")]
        let result = NetworkHealth.disconnected(networks: networks,
                                                withRunningContainers: ["default", "shop-net"],
                                                hostAddresses: ["192.168.70.1", "10.0.0.5"])
        #expect(result == ["default"])
    }

    @Test("a network with nothing running has no bridge by design, and is not a fault")
    func idleIsFine() {
        let networks = [NetworkHealth.Network(name: "idle-net", gateway: "192.168.71.1")]
        #expect(NetworkHealth.disconnected(networks: networks, withRunningContainers: [],
                                           hostAddresses: []).isEmpty)
    }

    @Test("a free subnet avoids every existing network and interface")
    func freeSubnet() {
        #expect(StackPlanner.freeSubnet(used: []) == "192.168.100.0/24")
        #expect(StackPlanner.freeSubnet(used: ["192.168.100.0/24", "192.168.101.1", "10.0.0.0/8"])
                == "192.168.102.0/24")
        let all = (100...250).map { "192.168.\($0).0/24" }
        #expect(StackPlanner.freeSubnet(used: all) == nil)
    }

    @Test("the chosen subnet is one the network create grammar accepts")
    func subnetAccepted() throws {
        let subnet = try #require(StackPlanner.freeSubnet(used: []))
        let args = ContainerCLI.createNetworkArguments("blog-net", options: .init(subnet: subnet))
        guard case .success = Allowlist.validate(args) else { Issue.record("refused: \(args)"); return }
    }
}
