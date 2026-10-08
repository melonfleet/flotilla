import Foundation

// Names that resolve across Macs (PLAN.md Phase D, layer 2, Part C; DECISIONS Q37).
//
// `web.mini.fleet.internal` resolves on every Mac, not only the mini: to the mini's address, and
// only while `web` publishes a port there. A Mac's own zone stays the runtime's (it answers with the
// container's own address); every **other** Mac's zone is answered by Flotilla itself, on
// 127.0.0.1:7869, from a table the admin Mac builds and sends to each host.
//
// Pure, so it is tested without a network, a resolver or root.

/// The resolver files the Flotilla Helper keeps for other Macs' zones — and the rules it applies, as
/// root, before writing one (Q37). Fixed nameserver and port: a file can only ever send a private
/// fleet zone to Flotilla on this Mac.
public enum FleetResolvers {
    /// Flotilla's responder: loopback only, next to the wire's 7868.
    public static let port: UInt16 = 7869
    /// Set apart from the runtime's `containerization.` files, so neither touches the other's.
    public static let filenamePrefix = "flotilla."
    /// Suffixes reserved for private names (ICANN `.internal`; IETF `.test`, `.home.arpa`). A fleet
    /// domain outside them could redirect a real website on every Mac.
    public static let privateSuffixes = ["internal", "test", "home.arpa"]
    public static let maxZones = 256

    public static func filename(for zone: String) -> String { filenamePrefix + zone }

    /// The zone a resolver filename is for, or `nil` if the file is not Flotilla's.
    public static func zone(fromFilename name: String) -> String? {
        guard name.hasPrefix(filenamePrefix) else { return nil }
        let zone = String(name.dropFirst(filenamePrefix.count))
        return zone.isEmpty ? nil : zone
    }

    /// Always these four lines — nothing in them comes from a caller but the zone.
    public static func contents(for zone: String) -> String {
        "domain \(zone)\nsearch \(zone)\nnameserver 127.0.0.1\nport \(port)\n"
    }

    /// Why `fleetDomain` cannot have resolver files, or `nil`.
    public static func fleetDomainProblem(_ fleetDomain: String) -> String? {
        if let problem = FleetZones.fleetDomainProblem(fleetDomain) { return problem }
        guard privateSuffixes.contains(where: { fleetDomain.hasSuffix("." + $0) }) else {
            return "Names across Macs need a fleet domain under .internal, .test or .home.arpa, so it can "
                + "never take over a real website."
        }
        return nil
    }

    /// Why these zones cannot have resolver files, or `nil` — what the helper checks before writing.
    /// `runtimeZones` are domains this Mac's runtime has files for: one of those is this Mac's own.
    public static func problem(fleetDomain: String, zones: [String], runtimeZones: Set<String> = []) -> String? {
        if let problem = fleetDomainProblem(fleetDomain) { return problem }
        guard zones.count <= maxZones else { return "More than \(maxZones) zones." }
        for zone in zones {
            guard zone.hasSuffix("." + fleetDomain), zone.count > fleetDomain.count + 1 else {
                return "“\(zone)” isn't under \(fleetDomain)."
            }
            if let problem = FleetZones.fleetDomainProblem(zone) { return problem }
            if runtimeZones.contains(zone) { return "“\(zone)” is this Mac's own zone." }
        }
        return nil
    }
}

/// What the admin Mac sends each host, and what each Mac's responder answers from.
public struct FleetNameTable: Sendable, Equatable, Codable {
    public struct Zone: Sendable, Equatable, Codable {
        /// `mini.fleet.internal`.
        public var zone: String
        /// The Mac's IPv4 address, as the admin reaches it.
        public var address: String
        public var names: [Name]
        public init(zone: String, address: String, names: [Name]) {
            self.zone = zone; self.address = address; self.names = names
        }
    }

    public struct Name: Sendable, Equatable, Codable {
        /// The container's name — the first label.
        public var name: String
        /// Its published host ports. Empty: not reachable from another Mac, so no answer (Q37).
        public var ports: [Int]
        public init(name: String, ports: [Int]) { self.name = name; self.ports = ports }
        public var reachable: Bool { !ports.isEmpty }
    }

    public var fleetDomain: String
    public var zones: [Zone]

    public init(fleetDomain: String, zones: [Zone]) {
        self.fleetDomain = fleetDomain
        self.zones = zones
    }

    public static let maxNamesPerZone = 1024

    /// Why a host must refuse this table, or `nil`.
    public var problem: String? {
        if zones.isEmpty { return nil }
        if let problem = FleetResolvers.problem(fleetDomain: fleetDomain, zones: zones.map(\.zone)) { return problem }
        guard Set(zones.map(\.zone)).count == zones.count else { return "A zone appears twice." }
        for zone in zones {
            guard IPv4.bytes(zone.address) != nil else { return "“\(zone.address)” isn't an IPv4 address." }
            guard zone.names.count <= Self.maxNamesPerZone else { return "Too many names in \(zone.zone)." }
            for name in zone.names {
                guard FleetNameTable.isLabel(name.name) else { return "“\(name.name)” can't be a DNS name." }
                guard name.ports.allSatisfy({ (1...65535).contains($0) }) else { return "A port is out of range." }
            }
        }
        return nil
    }

    /// One DNS label: letters, digits and hyphens, 1–63, not starting or ending with a hyphen.
    /// Container names may carry `.` or `_`; those have no name here rather than a mangled one.
    public static func isLabel(_ text: String) -> Bool {
        guard (1...63).contains(text.count), !text.hasPrefix("-"), !text.hasSuffix("-") else { return false }
        return text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The same table without `zone` — what a Mac answers for, its own zone being the runtime's.
    public func excluding(zone own: String?) -> FleetNameTable {
        FleetNameTable(fleetDomain: fleetDomain, zones: zones.filter { $0.zone != own })
    }

    /// How the responder answers `name` for record `type`.
    public func answer(_ name: String, type: UInt16) -> FleetDNSAnswer {
        var query = name.lowercased()
        if query.hasSuffix(".") { query.removeLast() }
        guard let zone = zones.first(where: { query.hasSuffix("." + $0.zone) }) else {
            // Not ours: a resolver file only sends Flotilla its own zones, so this is a stray.
            return .refused
        }
        let label = String(query.dropLast(zone.zone.count + 1))
        guard !label.contains("."), let entry = zone.names.first(where: { $0.name == label }), entry.reachable else {
            return .nameError
        }
        switch type {
        case DNSRecordType.a:
            guard let bytes = IPv4.bytes(zone.address) else { return .nameError }
            return .address(bytes)
        default:
            // The name exists, with no record of this type: AAAA gets an empty answer quickly
            // rather than a timeout.
            return .noData
        }
    }
}

public enum FleetDNSAnswer: Sendable, Equatable {
    case address([UInt8])
    case noData
    case nameError
    case refused
}

public enum DNSRecordType {
    public static let a: UInt16 = 1
    public static let aaaa: UInt16 = 28
}

enum IPv4 {
    static func bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }
}

/// The DNS wire format, as much as the responder needs (RFC 1035): one question in, at most one
/// answer out. Anything it does not understand is answered with an error, never guessed at.
public enum FleetDNSMessage {
    public static let ttl: UInt32 = 30
    /// Bigger than any query a resolver sends for these names; anything larger is dropped.
    public static let maxQueryBytes = 512

    /// The reply to `query`, or `nil` when it is not a query worth answering at all.
    public static func respond(to query: Data, table: FleetNameTable) -> Data? {
        let bytes = [UInt8](query)
        guard bytes.count >= 12, bytes.count <= maxQueryBytes else { return nil }
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard flags & 0x8000 == 0 else { return nil }                 // a response, not a query
        let opcode = (flags >> 11) & 0x0F
        let questions = UInt16(bytes[4]) << 8 | UInt16(bytes[5])

        // The question, labels only — a query has no reason to compress its one name.
        var index = 12
        var labels: [String] = []
        var question: [UInt8]?
        if questions == 1 {
            while index < bytes.count {
                let length = Int(bytes[index])
                if length == 0 { index += 1; break }
                guard length < 64, index + 1 + length <= bytes.count else { labels = []; index = bytes.count + 1; break }
                labels.append(String(decoding: bytes[(index + 1)...(index + length)], as: UTF8.self))
                index += 1 + length
            }
            if index + 4 <= bytes.count, !labels.isEmpty {
                question = Array(bytes[12..<(index + 4)])
            }
        }

        func reply(rcode: UInt16, answer: [UInt8]? = nil) -> Data {
            // QR, the query's opcode and RD, AA (we are the authority for these zones), no RA.
            let responseFlags: UInt16 = 0x8000 | (opcode << 11) | 0x0400 | (flags & 0x0100) | rcode
            var out: [UInt8] = [bytes[0], bytes[1], UInt8(responseFlags >> 8), UInt8(responseFlags & 0xFF),
                                0, question == nil ? 0 : 1, 0, answer == nil ? 0 : 1, 0, 0, 0, 0]
            if let question { out += question }
            if let answer { out += answer }
            return Data(out)
        }

        guard opcode == 0 else { return reply(rcode: 4) }             // NOTIMP
        guard let question else { return reply(rcode: 1) }            // FORMERR
        let type = UInt16(question[question.count - 4]) << 8 | UInt16(question[question.count - 3])
        let qclass = UInt16(question[question.count - 2]) << 8 | UInt16(question[question.count - 1])
        guard qclass == 1 else { return reply(rcode: 5) }             // REFUSED: only IN

        switch table.answer(labels.joined(separator: "."), type: type) {
        case .refused: return reply(rcode: 5)
        case .nameError: return reply(rcode: 3)                       // NXDOMAIN
        case .noData: return reply(rcode: 0)
        case .address(let address):
            // A pointer to the question's name, A, IN, the TTL, and four bytes.
            let record: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1,
                                   UInt8(ttl >> 24), UInt8((ttl >> 16) & 0xFF), UInt8((ttl >> 8) & 0xFF), UInt8(ttl & 0xFF),
                                   0, 4] + address
            return reply(rcode: 0, answer: record)
        }
    }
}
