import Foundation

/// Per-host DNS zones (PLAN.md Phase D, layer 2; DECISIONS Q36): each Mac names its containers in
/// its own zone, `<its label>.<fleet domain>` — `web.mini.fleet.internal` — so two Macs' `web`
/// never share a name.
public enum FleetZones {
    /// `.internal` is reserved for private use, so it can never be someone's real domain.
    public static let defaultFleetDomain = "fleet.internal"

    /// A DNS label from a Mac's name: lowercase letters and digits, anything else a hyphen, runs of
    /// hyphens collapsed and none at either end, at most 63 characters. `Test  Mac mini` → `test-mac-mini`.
    public static func label(for name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 63 { out = String(out.prefix(63)); while out.hasSuffix("-") { out.removeLast() } }
        return out.isEmpty ? "mac" : out
    }

    /// Each Mac's zone, by id, in the order given: a second Mac whose name makes the same label gets
    /// `-2`, a third `-3`, so no two Macs share a zone.
    public static func zones(for macs: [(id: String, name: String)], fleetDomain: String) -> [String: String] {
        var taken: Set<String> = []
        var zones: [String: String] = [:]
        for mac in macs {
            let base = label(for: mac.name)
            var candidate = base
            var n = 2
            while taken.contains(candidate) {
                let suffix = "-\(n)"
                candidate = String(base.prefix(63 - suffix.count)) + suffix
                n += 1
            }
            taken.insert(candidate)
            zones[mac.id] = "\(candidate).\(fleetDomain)"
        }
        return zones
    }

    /// Why `domain` cannot be the fleet domain, or `nil`. The same grammar a DNS domain has here,
    /// not `.local`, and short enough that a 63-character label still fits in front of it.
    public static func fleetDomainProblem(_ domain: String) -> String? {
        if let reserved = LocalDNS.reservedProblem(domain) { return reserved }
        if case .failure(let error) = ContainerCLI.dnsDeleteCommand(domain: domain) { return String(describing: error) }
        guard domain.count <= 253 - 64 else { return "That domain is too long to have a Mac's name in front of it." }
        return nil
    }
}
