import Foundation

/// A way of grouping hosts that the owner names — Site, Rack, VLAN — with a value per host
/// (the owner, 9 October: "the user ultimately can decide what to group them by").
///
/// `id` is not the name, for the reason `Tag` gives: renaming Rack to Cabinet must keep every
/// host's value.
public struct HostCategory: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

/// The admin's categories and each host's value in them. Kept on the admin Mac only, like tags —
/// nothing here is sent to a host.
///
/// A host is keyed by its Hosts row id: a fingerprint in hex, or This Mac's fixed id.
public struct HostCategoryBook: Codable, Sendable, Equatable {
    public private(set) var categories: [HostCategory]
    /// Host id → category id → value. A host with no value in a category has no entry.
    public private(set) var values: [String: [String: String]]

    public init(categories: [HostCategory] = [], values: [String: [String: String]] = [:]) {
        self.categories = categories
        self.values = values
    }

    /// What a new install starts with: the three the owner named. Any can be renamed or removed.
    public static var starter: HostCategoryBook {
        HostCategoryBook(categories: ["Site", "Rack", "VLAN"].map { HostCategory(name: $0) })
    }

    /// Offered when adding a category, minus the ones already made.
    public static let suggestions = ["Site", "Building", "Room", "Rack", "VLAN", "Purpose", "Owner", "Department"]

    /// The grouping Flotilla works out itself; a category may not take its name.
    public static let subnetName = "Subnet"

    public static let maxNameLength = 40
    public static let maxValueLength = 60

    // MARK: Reading

    public func category(id: String) -> HostCategory? { categories.first { $0.id == id } }

    public func value(of categoryID: String, for host: String) -> String? { values[host]?[categoryID] }

    /// Every value in use in a category, sorted the way Finder sorts names.
    public func values(in categoryID: String) -> [String] {
        Array(Set(values.values.compactMap { $0[categoryID] }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public var unusedSuggestions: [String] {
        Self.suggestions.filter { name in !categories.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    /// Why a name cannot be used, or nil when it can.
    public func problem(withName raw: String, excluding excluded: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "A category needs a name." }
        if name.count > Self.maxNameLength { return "Keep it to \(Self.maxNameLength) characters." }
        if name.caseInsensitiveCompare(Self.subnetName) == .orderedSame {
            return "Subnet is filled in by Flotilla from each host's address — it's already in Group By."
        }
        if categories.contains(where: { $0.id != excluded && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "There is already a category called “\(name)”."
        }
        return nil
    }

    // MARK: Changing

    @discardableResult
    public mutating func addCategory(named raw: String) -> HostCategory? {
        guard problem(withName: raw) == nil else { return nil }
        let category = HostCategory(name: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        categories.append(category)
        return category
    }

    @discardableResult
    public mutating func rename(_ categoryID: String, to raw: String) -> Bool {
        guard problem(withName: raw, excluding: categoryID) == nil,
              let index = categories.firstIndex(where: { $0.id == categoryID }) else { return false }
        categories[index].name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    /// Removes the category and every host's value in it.
    public mutating func removeCategory(_ categoryID: String) {
        categories.removeAll { $0.id == categoryID }
        for host in Array(values.keys) { clear(categoryID, host) }
    }

    public mutating func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { categories[$0] }
        var rest = categories.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        categories = rest
    }

    /// Sets a host's value; nil or blank clears it. Values are trimmed and capped, so "R1" and
    /// "R1 " are one group.
    public mutating func setValue(_ raw: String?, of categoryID: String, for hosts: [String]) {
        guard categories.contains(where: { $0.id == categoryID }) else { return }
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxValueLength)
        for host in hosts {
            if let value, !value.isEmpty {
                values[host, default: [:]][categoryID] = String(value)
            } else {
                clear(categoryID, host)
            }
        }
    }

    /// Renames a value everywhere it is used — every host in "R1" moves to "Rack 1".
    public mutating func renameValue(_ old: String, to raw: String, in categoryID: String) {
        let hosts = values.compactMap { $0.value[categoryID] == old ? $0.key : nil }
        setValue(raw, of: categoryID, for: hosts)
    }

    /// A host forgotten by the admin takes its values with it.
    public mutating func forgetHost(_ host: String) { values[host] = nil }

    private mutating func clear(_ categoryID: String, _ host: String) {
        values[host]?[categoryID] = nil
        if values[host]?.isEmpty == true { values[host] = nil }
    }
}

/// How the Hosts list is grouped, and the grouping itself.
public enum HostGrouping: Equatable, Sendable, Hashable {
    case none
    /// Worked out from each host's address — read-only.
    case subnet
    case category(String)

    /// Stored as one string: "none", "subnet", or "category:<id>".
    public var storageKey: String {
        switch self {
        case .none: "none"
        case .subnet: "subnet"
        case .category(let id): "category:\(id)"
        }
    }

    public init(storageKey: String) {
        if storageKey == "subnet" { self = .subnet }
        else if storageKey.hasPrefix("category:") { self = .category(String(storageKey.dropFirst("category:".count))) }
        else { self = .none }
    }

    /// One group: its value, or nil for the hosts with none, and the hosts in it, in the order given.
    public struct Bucket: Equatable, Sendable {
        public let value: String?
        public let hosts: [String]
    }

    /// Hosts into groups by `value`: named groups sorted by name, then the hosts with no value.
    /// Hosts keep the order they came in, so a sort applied first holds inside each group.
    public static func buckets(_ hosts: [String], value: (String) -> String?) -> [Bucket] {
        var named: [String: [String]] = [:]
        var none: [String] = []
        for host in hosts {
            if let v = value(host), !v.isEmpty { named[v, default: []].append(host) } else { none.append(host) }
        }
        var result = named.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Bucket(value: $0, hosts: named[$0]!) }
        if !none.isEmpty { result.append(Bucket(value: nil, hosts: none)) }
        return result
    }

    /// The IPv4 network an address is on, as `10.20.4.0/24`. `prefix` comes from the host's
    /// interface when it reports one; without it, /24 — the usual size of a LAN segment.
    public static func subnet(of address: String, prefix: Int = 24) -> String? {
        guard let value = ipv4(address), (0...32).contains(prefix) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return "\(dotted(value & mask))/\(prefix)"
    }

    /// `10.20.4.17/23` → `10.20.4.0/23`; a bare address → its /24.
    public static func subnet(ofCIDR text: String) -> String? {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let prefix = parts.count == 2 ? Int(parts[1]) : 24
        return prefix.flatMap { subnet(of: String(first), prefix: $0) }
    }

    /// Whether `address` is inside `cidr`.
    public static func contains(_ cidr: String, _ address: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let prefix = Int(parts[1]),
              let network = subnet(of: String(parts[0]), prefix: prefix) else { return false }
        return subnet(of: address, prefix: prefix) == network
    }

    /// The prefix length of a dotted netmask, `255.255.254.0` → 23; nil if it is not contiguous.
    public static func prefixLength(ofMask mask: String) -> Int? {
        guard let value = ipv4(mask) else { return nil }
        let ones = value.nonzeroBitCount
        let expected: UInt32 = ones == 0 ? 0 : ~UInt32(0) << UInt32(32 - ones)
        return value == expected ? ones : nil
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    private static func dotted(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}
