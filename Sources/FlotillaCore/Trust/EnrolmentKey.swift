import Foundation

/// The fleet enrolment key — the CrowdStrike-CID idea (the owner, 7 October): one string the admin
/// Mac generates and a configuration profile hands to every host, so a managed Mac can ask to join
/// with nobody at its keyboard.
///
/// It carries two things:
///
/// - **who to trust** — the first 128 bits of the admin Mac's key fingerprint, so a host holding
///   the key accepts only that admin and no other Mac that happens to find it;
/// - **a 128-bit secret** — so the admin can tell a host that really holds the key from one that
///   merely says it does. A spoofed Bonjour advert cannot produce the proof.
///
/// A key is a bearer secret for **asking** to join, nothing more: every host it brings in still
/// waits in Hosts until the owner approves it, and rotating the key stops new requests without
/// touching hosts already enrolled. See PLAN.md Phase B.
///
/// Text form: `FLT1-` then Crockford base32 of version, fingerprint prefix, secret and a CRC-32,
/// in groups of six — 60 characters a person can paste, read or type, and mistype detectably.
public struct EnrolmentKey: Sendable, Equatable {
    public static let version: UInt8 = 1
    static let textPrefix = "FLT1-"
    static let fieldBytes = 16

    public let adminFingerprintPrefix: [UInt8]
    public let secret: [UInt8]

    public init(adminFingerprint: PeerFingerprint, secret: [UInt8]) {
        precondition(secret.count == Self.fieldBytes, "an enrolment secret is 16 bytes")
        adminFingerprintPrefix = adminFingerprint.prefix
        self.secret = secret
    }

    init(adminFingerprintPrefix: [UInt8], secret: [UInt8]) {
        self.adminFingerprintPrefix = adminFingerprintPrefix
        self.secret = secret
    }

    /// A new key for this admin, with a fresh secret from `generator`.
    public static func generate<G: RandomNumberGenerator>(for admin: PeerFingerprint,
                                                         using generator: inout G) -> EnrolmentKey {
        EnrolmentKey(adminFingerprint: admin,
                     secret: (0..<fieldBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func generate(for admin: PeerFingerprint) -> EnrolmentKey {
        var system = SystemRandomNumberGenerator()
        return generate(for: admin, using: &system)
    }

    public var text: String {
        var body = [Self.version] + adminFingerprintPrefix + secret
        let crc = CRC32.checksum(body)
        body += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
        return Self.textPrefix + Crockford32.grouped(Crockford32.encode(body), size: 6)
    }

    /// Whether the admin Mac with this fingerprint is the one the key names.
    public func names(_ admin: PeerFingerprint) -> Bool { admin.matches(prefix: adminFingerprintPrefix) }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case notAnEnrolmentKey
        case unsupportedVersion(UInt8)
        case wrongLength
        case checksumMismatch

        public var description: String {
            switch self {
            case .notAnEnrolmentKey: "That isn't a Flotilla enrolment key — they start with FLT1-."
            case .unsupportedVersion(let v): "This enrolment key is version \(v), which this Flotilla doesn't read. Update Flotilla."
            case .wrongLength: "The enrolment key is the wrong length — part of it may be missing."
            case .checksumMismatch: "The enrolment key has a typo in it. Copy it again from the admin Mac."
            }
        }
    }

    /// Reads a key a person pasted or typed, forgiving case, spacing and the usual look-alikes.
    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix(Self.textPrefix) else { throw ParseError.notAnEnrolmentKey }
        let encoded = String(trimmed.dropFirst(Self.textPrefix.count))
        // Length first, so a key cut short says so rather than "typo".
        let expectedCharacters = ((1 + 2 * Self.fieldBytes + 4) * 8 + 4) / 5
        guard Crockford32.normalised(encoded).count == expectedCharacters else { throw ParseError.wrongLength }
        guard let bytes = Crockford32.decode(encoded) else {
            throw ParseError.checksumMismatch
        }
        let expected = 1 + 2 * Self.fieldBytes + 4
        guard bytes.count == expected else { throw ParseError.wrongLength }
        let body = Array(bytes.prefix(expected - 4))
        let stored = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard CRC32.checksum(body) == stored else { throw ParseError.checksumMismatch }
        guard body[0] == Self.version else { throw ParseError.unsupportedVersion(body[0]) }
        self.init(adminFingerprintPrefix: Array(body[1...Self.fieldBytes]),
                  secret: Array(body[(1 + Self.fieldBytes)...]))
    }
}

/// The one-time code for pairing a single, unmanaged Mac: the host shows it, the owner types it on
/// the admin Mac. Eight characters of Crockford base32 — 40 bits — shown as `ABCD-EFGH`.
///
/// Short on purpose, and therefore **bounded** on purpose: it expires after ten minutes and dies
/// after five wrong tries, and pairing still ends with both screens showing the same fingerprint
/// words for the owner to compare. The words, not the code, are what defeat a machine in the
/// middle; the code keeps a stranger on the network from starting the conversation at all.
public struct PairingCode: Sendable, Equatable {
    public static let length = 8
    public static let lifetime: TimeInterval = 10 * 60
    public static let maxAttempts = 5

    /// Normalised: upper case, no dashes, look-alikes folded.
    public let value: String
    public let issuedAt: Date
    public private(set) var failedAttempts = 0

    public init<G: RandomNumberGenerator>(issuedAt: Date, using generator: inout G) {
        value = String((0..<Self.length).map { _ in Crockford32.alphabet[Int.random(in: 0..<32, using: &generator)] })
        self.issuedAt = issuedAt
    }

    public init(issuedAt: Date = Date()) {
        var system = SystemRandomNumberGenerator()
        self.init(issuedAt: issuedAt, using: &system)
    }

    public var display: String { Crockford32.grouped(value, size: 4) }

    /// What the admin side should use as the MAC key: the code exactly as the host holds it, from
    /// whatever the person typed.
    public static func normalise(_ typed: String) -> String { Crockford32.normalised(typed) }

    public func isUsable(at now: Date) -> Bool {
        failedAttempts < Self.maxAttempts && now.timeIntervalSince(issuedAt) < Self.lifetime
    }

    /// Records a wrong proof. Returns whether the code can still be used.
    public mutating func recordFailure(at now: Date) -> Bool {
        failedAttempts += 1
        return isUsable(at: now)
    }

    public var keyBytes: [UInt8] { Array(value.utf8) }
}

/// The words both screens show at the end of pairing, so the owner can see that the two Macs are
/// looking at the same pair of keys. Computed from a digest of both fingerprints (the trust layer
/// hashes them, sorted, so both sides get the same digest); four words carry 32 bits.
public enum FingerprintWords {
    public static func words(for digest: [UInt8], count: Int = 4) -> [String] {
        digest.prefix(count).map { list[Int($0)] }
    }

    /// 256 short, concrete, distinct words — one per byte.
    static let list: [String] = """
        acorn agent alarm album alley amber anchor angel ankle apple apron arch arrow aspen atlas \
        attic axle bacon badge bagel baker bamboo banjo barn basil basin beach beacon beard beaver \
        bell bench berry bison blade boat bonnet boot bottle bowl branch bread brick bridge broom \
        bubble bucket bugle bunny butter button cabin cactus camel camera candle canoe canvas canyon \
        carpet carrot castle cedar cello chain chalk cherry chess cider circus citrus cliff clock \
        cloud clover cobalt cocoa coffee comet copper coral cotton cowboy crane crayon crown cup \
        daisy dancer delta desert dingo domino donkey dragon drum eagle easel echo elbow ember engine \
        falcon fern ferry fiddle fig flag flame flute forest fossil fox garden garlic gecko geyser \
        ginger globe goblet goose grape gravel guitar hammer harbor harp hazel helmet heron honey \
        hornet igloo island ivory jacket jaguar jelly jigsaw jungle kayak kettle kitten koala ladder \
        lagoon lantern laurel lemon lily lion lizard locket lotus magnet mango maple marble meadow \
        melon mitten moose mosaic muffin napkin nectar nest noodle nutmeg oasis ocean olive onion \
        orange orchid otter owl paddle panda parrot peach peanut pebble pencil pepper piano pickle \
        pigeon pillow pine planet plum pocket pond poppy potato pumpkin puzzle quail quartz quilt \
        rabbit radish raven reef ribbon river robin rocket rose saddle salmon sandal saturn scarf \
        seal shadow shell silver sketch sled snail spider spoon squash star summit swan tablet tango \
        teapot thunder tiger timber toast tomato topaz trumpet tulip tunnel turtle valley velvet \
        violin volcano wagon walnut walrus wheat whistle willow window wizard yarn zebra zinc
        """.split(separator: " ").map(String.init)
}
