import Foundation

/// An IPv4 range in CIDR form: `10.240.16.0/20`.
public struct IPv4Block: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The first address, with the host bits cleared.
    public let base: UInt32
    public let prefix: Int

    public init?(base: UInt32, prefix: Int) {
        guard (0...32).contains(prefix) else { return nil }
        self.prefix = prefix
        self.base = base & Self.mask(prefix)
    }

    /// `10.240.16.0/20`, or a bare address as a `/32`. `nil` for anything else.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = Self.address(String(parts[0])) else { return nil }
        let prefix = parts.count == 2 ? Int(parts[1]) : 32
        guard let prefix else { return nil }
        self.init(base: address, prefix: prefix)
    }

    /// The netmask an interface reports, `255.255.240.0`, as a prefix length.
    public static func prefix(ofMask mask: String) -> Int? {
        guard let value = address(mask) else { return nil }
        let ones = value.nonzeroBitCount
        return Self.mask(ones) == value ? ones : nil
    }

    static func address(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet), String(byte) == octet else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix) }

    public var size: UInt64 { UInt64(1) << UInt64(32 - prefix) }
    public var last: UInt32 { base | ~Self.mask(prefix) }

    public func overlaps(_ other: IPv4Block) -> Bool { base <= other.last && other.base <= last }
    public func contains(_ other: IPv4Block) -> Bool { base <= other.base && other.last <= last }

    /// The `index`th block of length `prefix` inside this one, or `nil` past the end.
    public func subblock(_ index: Int, prefix sub: Int) -> IPv4Block? {
        guard sub >= prefix, index >= 0, UInt64(index) < (UInt64(1) << UInt64(sub - prefix)) else { return nil }
        return IPv4Block(base: base + UInt32(index) << UInt32(32 - sub), prefix: sub)
    }

    public var description: String {
        "\(base >> 24).\(base >> 16 & 0xFF).\(base >> 8 & 0xFF).\(base & 0xFF)/\(prefix)"
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let block = IPv4Block(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a CIDR block"))
        }
        self = block
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Each Mac's own address block, and a subnet from it for every network pushed there (PLAN.md
/// Phase D, layer 1; DECISIONS Q35).
///
/// One `/20` per Mac from `10.240.0.0/12` — room for 256 Macs with sixteen `/24` networks each.
/// Networks of the same name on two Macs are separate private networks; giving each Mac its own
/// range keeps them from ever overlapping, which a routed overlay (layer 3) would need, and which
/// letting each runtime choose cannot promise.
///
/// Pure: the app supplies what is already taken — every Mac's existing network subnets and this
/// Mac's interface ranges — and keeps the assignments.
public enum AddressPlan {
    public static let pool = IPv4Block("10.240.0.0/12")!
    public static let blockPrefix = 20
    public static let networkPrefix = 24

    /// Blocks for every Mac in `macs`, keeping each existing assignment and giving each new Mac the
    /// lowest free `/20` that overlaps nothing in `avoid`. A Mac with no free block is left out.
    public static func assign(_ macs: [String], existing: [String: IPv4Block],
                              avoid: [IPv4Block]) -> [String: IPv4Block] {
        var result = existing.filter { macs.contains($0.key) }
        var taken = Set(result.values)
        var next = 0
        for mac in macs where result[mac] == nil {
            while let candidate = pool.subblock(next, prefix: blockPrefix) {
                next += 1
                if taken.contains(candidate) || avoid.contains(where: { $0.overlaps(candidate) }) { continue }
                result[mac] = candidate
                taken.insert(candidate)
                break
            }
        }
        return result
    }

    /// The first `/24` in a Mac's block that none of its networks already uses, or `nil` when all
    /// sixteen are taken.
    public static func subnet(in block: IPv4Block, used: [IPv4Block]) -> IPv4Block? {
        var index = 0
        while let candidate = block.subblock(index, prefix: networkPrefix) {
            if !used.contains(where: { $0.overlaps(candidate) }) { return candidate }
            index += 1
        }
        return nil
    }
}
