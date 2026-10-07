import Foundation

/// Crockford's base32: the alphabet people can read aloud and type back. No I, L, O or U, and
/// decoding forgives the mistakes a person makes — lower case, O for 0, I or L for 1, and any
/// dashes or spaces they put in to keep their place.
enum Crockford32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ bytes: [UInt8]) -> String {
        var output: [Character] = []
        var buffer = 0, bits = 0
        for byte in bytes {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return String(output)
    }

    /// The bytes, or `nil` if anything is not a base32 character after normalising. Trailing bits
    /// that do not make a whole byte are dropped, as the encoder padded them.
    static func decode(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer = 0, bits = 0
        for character in normalised(text) {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5 | value) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return bytes
    }

    static func normalised(_ text: String) -> String {
        String(text.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ", "\t", "\n": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        })
    }

    /// `ABCDEFGH` → `ABCD-EFGH`, for display.
    static func grouped(_ text: String, size: Int) -> String {
        stride(from: 0, to: text.count, by: size).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: min(size, text.count - start))
            return String(text[from..<to])
        }.joined(separator: "-")
    }
}

/// CRC-32 (IEEE). A **typo check**, not security: it tells a person they mistyped a key before
/// anything is sent. The key's secret is what protects it.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A peer's identity on the wire: the SHA-256 of its TLS public key, computed by the trust layer
/// (B2b) and pinned here. Everything about trust keys on this — never on a name, which the owner
/// can change, or an address, which DHCP does.
public struct PeerFingerprint: Sendable, Hashable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        let digits = Array(hex.lowercased())
        guard digits.count == 64 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.bytes = bytes
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }

    /// The first 16 bytes. An enrolment key carries this much of the admin's fingerprint: 128
    /// bits is beyond any second-preimage search, and it halves the key's length.
    public var prefix: [UInt8] { Array(bytes.prefix(16)) }
    public func matches(prefix: [UInt8]) -> Bool { self.prefix == prefix }

    // Plist-native, like every other book: a hex string.
    public init(from decoder: Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let value = PeerFingerprint(hex: hex) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a fingerprint"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
