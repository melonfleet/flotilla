import Foundation

/// Spotting a network that has lost its bridge — apple/container#2051, still present in 1.5.0
/// (research/CONTAINER-UPGRADE-1.5.0.md; DECISIONS Q30).
///
/// Two networks can be handed the same kernel bridge; when one's last container stops, the bridge
/// goes and the other network is left with **no gateway on this Mac**. Its containers still reach
/// each other, so it looks alive, but nothing reaches it from the Mac and its published ports are
/// dead. The tell is simple and cheap: a network with running containers whose gateway address is
/// not on any of this Mac's interfaces. Only restarting the runtime recovers it.
public enum NetworkHealth {
    public struct Network: Sendable, Equatable {
        public let name: String
        /// `192.168.70.1`, without a prefix length.
        public let gateway: String?
        public init(name: String, gateway: String?) { self.name = name; self.gateway = gateway }
    }

    /// The networks that have running containers but whose gateway is missing from this Mac,
    /// sorted. A network with nothing running has no bridge **by design** — that is not a fault.
    public static func disconnected(networks: [Network], withRunningContainers running: Set<String>,
                                    hostAddresses: Set<String>) -> [String] {
        networks.filter { network in
            guard running.contains(network.name), let gateway = network.gateway else { return false }
            return !hostAddresses.contains(gateway)
        }
        .map(\.name).sorted()
    }
}

extension StackPlanner {
    /// A `/24` for a gateway-wired stack's new network that no existing network uses, so its
    /// gateway cannot move on a restart (6 October: `default` and a network made without
    /// `--subnet` swapped subnets across a restart, and gateway wiring writes the address down).
    ///
    /// From `192.168.100.0/24` upward — clear of the runtime's own allocations, which start at
    /// `.64` — skipping any `/24` an existing network or this Mac's interfaces already use.
    public static func freeSubnet(used: [String]) -> String? {
        let taken = Set(used.compactMap { thirdOctet(of: $0) })
        for octet in 100...250 where !taken.contains(octet) {
            return "192.168.\(octet).0/24"
        }
        return nil
    }

    /// `192.168.70.0/24` or `192.168.70.1` → 70, for addresses in `192.168.0.0/16`.
    static func thirdOctet(of address: String) -> Int? {
        let host = address.split(separator: "/").first.map(String.init) ?? address
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts[0] == "192", parts[1] == "168" else { return nil }
        return Int(parts[2])
    }
}
