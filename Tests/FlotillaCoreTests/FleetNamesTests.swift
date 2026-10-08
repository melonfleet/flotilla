import Foundation
import Testing
@testable import FlotillaCore

/// D3 Part C: names across Macs (DECISIONS Q37).
@Suite("Fleet names")
struct FleetNamesTests {
    let table = FleetNameTable(fleetDomain: "fleet.internal", zones: [
        .init(zone: "mini.fleet.internal", address: "192.168.1.20",
              names: [.init(name: "web", ports: [8080]), .init(name: "db", ports: [])]),
        .init(zone: "studio.fleet.internal", address: "192.168.1.21", names: [.init(name: "api", ports: [443])]),
    ])

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Answers

    @Test func aPublishedContainerResolvesToItsMac() {
        #expect(table.answer("web.mini.fleet.internal", type: DNSRecordType.a) == .address([192, 168, 1, 20]))
        #expect(table.answer("WEB.Mini.Fleet.Internal.", type: DNSRecordType.a) == .address([192, 168, 1, 20]))
    }

    @Test func aContainerWithoutAPublishedPortHasNoName() {
        #expect(table.answer("db.mini.fleet.internal", type: DNSRecordType.a) == .nameError)
        #expect(table.answer("nothing.mini.fleet.internal", type: DNSRecordType.a) == .nameError)
        #expect(table.answer("a.web.mini.fleet.internal", type: DNSRecordType.a) == .nameError)
    }

    @Test func aaaaIsAnsweredEmptyAndStraysAreRefused() {
        #expect(table.answer("web.mini.fleet.internal", type: DNSRecordType.aaaa) == .noData)
        #expect(table.answer("apple.com", type: DNSRecordType.a) == .refused)
        #expect(table.answer("mini.fleet.internal", type: DNSRecordType.a) == .refused)
    }

    @Test func aMacsOwnZoneIsLeftToItsRuntime() {
        let mine = table.excluding(zone: "mini.fleet.internal")
        #expect(mine.answer("web.mini.fleet.internal", type: DNSRecordType.a) == .refused)
        #expect(mine.answer("api.studio.fleet.internal", type: DNSRecordType.a) == .address([192, 168, 1, 21]))
    }

    // MARK: The wire format, on queries dig really sent

    @Test func aRealAQueryGetsOneAddress() throws {
        let query = try fixture("dns-query-a")
        let reply = try #require(FleetDNSMessage.respond(to: query, table: table))
        let bytes = [UInt8](reply)
        #expect(bytes[0] == query[0] && bytes[1] == query[1])            // same id
        #expect(bytes[2] & 0x80 != 0)                                     // a response
        #expect(bytes[3] & 0x0F == 0)                                     // NOERROR
        #expect(bytes[7] == 1)                                            // one answer
        #expect(Array(bytes.suffix(4)) == [192, 168, 1, 20])
    }

    @Test func aRealAAAAQueryGetsAnEmptyAnswer() throws {
        let reply = try #require(FleetDNSMessage.respond(to: try fixture("dns-query-aaaa"), table: table))
        let bytes = [UInt8](reply)
        #expect(bytes[3] & 0x0F == 0 && bytes[7] == 0)
    }

    @Test func anUnknownNameIsNXDOMAINAndGarbageIsDropped() throws {
        let empty = FleetNameTable(fleetDomain: "fleet.internal", zones: [
            .init(zone: "mini.fleet.internal", address: "192.168.1.20", names: []),
        ])
        let reply = try #require(FleetDNSMessage.respond(to: try fixture("dns-query-a"), table: empty))
        #expect([UInt8](reply)[3] & 0x0F == 3)
        #expect(FleetDNSMessage.respond(to: Data([1, 2, 3]), table: table) == nil)
        #expect(FleetDNSMessage.respond(to: Data(count: 600), table: table) == nil)
        // A response sent back at us is not answered.
        var response = [UInt8](try fixture("dns-query-a"))
        response[2] |= 0x80
        #expect(FleetDNSMessage.respond(to: Data(response), table: table) == nil)
    }

    // MARK: What the helper will and won't write

    @Test func resolverFilesOnlyForPrivateFleetDomains() {
        #expect(FleetResolvers.problem(fleetDomain: "fleet.internal", zones: ["mini.fleet.internal"]) == nil)
        #expect(FleetResolvers.problem(fleetDomain: "lab.test", zones: ["mini.lab.test"]) == nil)
        #expect(FleetResolvers.problem(fleetDomain: "home.home.arpa", zones: ["mini.home.home.arpa"]) == nil)
        #expect(FleetResolvers.problem(fleetDomain: "apple.com", zones: ["www.apple.com"]) != nil)
        #expect(FleetResolvers.problem(fleetDomain: "internal", zones: ["mini.internal"]) != nil)
        #expect(FleetResolvers.problem(fleetDomain: "fleet.internal", zones: ["mini.other.internal"]) != nil)
        #expect(FleetResolvers.problem(fleetDomain: "fleet.internal", zones: ["fleet.internal"]) != nil)
        #expect(FleetResolvers.problem(fleetDomain: "fleet.internal", zones: ["mini.fleet.internal"],
                                       runtimeZones: ["mini.fleet.internal"]) != nil)
        let many = (0...FleetResolvers.maxZones).map { "m\($0).fleet.internal" }
        #expect(FleetResolvers.problem(fleetDomain: "fleet.internal", zones: many) != nil)
    }

    @Test func aResolverFileIsAlwaysTheSameFourLines() {
        #expect(FleetResolvers.contents(for: "mini.fleet.internal")
                == "domain mini.fleet.internal\nsearch mini.fleet.internal\nnameserver 127.0.0.1\nport 7869\n")
        #expect(FleetResolvers.filename(for: "mini.fleet.internal") == "flotilla.mini.fleet.internal")
        #expect(FleetResolvers.zone(fromFilename: "flotilla.mini.fleet.internal") == "mini.fleet.internal")
        #expect(FleetResolvers.zone(fromFilename: "containerization.flotilla") == nil)
    }

    @Test func aTableAHostWouldRefuse() {
        var bad = table
        bad.zones[0].address = "not-an-address"
        #expect(bad.problem != nil)
        var name = table
        name.zones[0].names.append(.init(name: "Bad_Name", ports: [80]))
        #expect(name.problem != nil)
        #expect(table.problem == nil)
        #expect(FleetNameTable(fleetDomain: "fleet.internal", zones: []).problem == nil)
    }

    @Test func setFleetNamesNeedsVersionFive() {
        #expect(HostCall.setFleetNames(table).minimumVersion == 5)
        #expect(HostCall.setFleetNames(table).problem == nil)
    }
}
