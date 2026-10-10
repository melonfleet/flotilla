import Foundation
import Testing
@testable import FlotillaCore

/// D3: host calls on the wire, and per-host zones.
@Suite("Host calls and fleet zones")
struct HostCallTests {
    let admin = WirePeerInfo(name: "admin", appVersion: "0.0.0 (320)")
    let host = WirePeerInfo(name: "mini", appVersion: "0.0.0 (320)")

    func connected(versions: ClosedRange<UInt16> = WireProtocol.supportedVersions, trusted: Bool = true)
        throws -> (host: WireHostSession, client: WireClientSession) {
        var hostSession = WireHostSession(peer: host, versions: versions, trusted: trusted)
        var client = WireClientSession(peer: admin, versions: versions)
        guard case .send(let welcome)? = try hostSession.receive(client.hello()).first else { throw WireError.notConnected }
        _ = try client.receive(welcome)
        return (hostSession, client)
    }

    @Test func aHostCallSurvivesTheRoundTrip() throws {
        for call in [HostCall.dnsStatus, .dnsCreate(domain: "mini.fleet.internal", localhost: nil),
                     .dnsCreate(domain: "host.container.internal", localhost: "203.0.113.113"),
                     .dnsDelete(domains: ["a.test", "b.test"]), .setContainerDNSDomain(domain: nil),
                     .setContainerDNSDomain(domain: "mini.fleet.internal")] {
            let message = WireMessage.hostCall(.init(id: 7, call: call))
            var decoder = WireFrameDecoder()
            let frames = try decoder.append(try message.encoded(limits: .default))
            #expect(try WireMessage(frame: frames[0]) == message)
        }
    }

    @Test func keepAwakeIsBoundedAVersion9CallThatSurvivesTheWire() throws {
        #expect(HostCall.keepAwake(seconds: 3600).problem == nil)
        #expect(HostCall.keepAwake(seconds: 0).problem == nil)            // stop
        #expect(HostCall.keepAwake(seconds: HostCall.maxKeepAwakeSeconds + 1).problem != nil)
        #expect(HostCall.keepAwake(seconds: -1).problem != nil)
        #expect(HostCall.keepAwake(seconds: 60).minimumVersion == 9 && HostCall.keepAwake(seconds: 60).mutates)
        let message = WireMessage.hostCall(.init(id: 3, call: .keepAwake(seconds: 4 * 3600)))
        var decoder = WireFrameDecoder()
        let frames = try decoder.append(try message.encoded(limits: .default))
        #expect(try WireMessage(frame: frames[0]) == message)
        // A version-8 host is never sent it.
        var (_, client) = try connected(versions: 1...8)
        #expect(throws: WireError.self) { try client.call(.keepAwake(seconds: 60)) }
    }

    @Test func autoStartIsAVersion10CallThatSurvivesTheWire() throws {
        let call = HostCall.setAutoStartRuntime(.never)
        #expect(call.problem == nil && call.mutates && call.minimumVersion == 10)
        let message = WireMessage.hostCall(.init(id: 4, call: call))
        var decoder = WireFrameDecoder()
        let frames = try decoder.append(try message.encoded(limits: .default))
        #expect(try WireMessage(frame: frames[0]) == message)
        // A version-9 host is never sent it.
        var (_, client) = try connected(versions: 1...9)
        #expect(throws: WireError.self) { try client.call(.setAutoStartRuntime(.always)) }
    }

    @Test func runtimeControlIsAVersion11CallThatSurvivesTheWire() throws {
        for action in RuntimeControl.allCases {
            let call = HostCall.controlRuntime(action)
            #expect(call.problem == nil && call.mutates && call.minimumVersion == 11)
            let message = WireMessage.hostCall(.init(id: 5, call: call))
            var decoder = WireFrameDecoder()
            let frames = try decoder.append(try message.encoded(limits: .default))
            #expect(try WireMessage(frame: frames[0]) == message)
        }
        // A version-10 host is never sent it, and the raw commands stay closed to a peer.
        var (_, client) = try connected(versions: 1...10)
        #expect(throws: WireError.self) { try client.call(.controlRuntime(.stop)) }
    }

    @Test func aValidCallIsHandedToTheHostAndAnsweredLikeARequest() throws {
        var (hostSession, client) = try connected()
        let outgoing = try client.call(.dnsCreate(domain: "mini.fleet.internal", localhost: nil))
        let events = try hostSession.receive(outgoing.message)
        #expect(events == [.hostCall(id: outgoing.id, call: .dnsCreate(domain: "mini.fleet.internal", localhost: nil))])
        let completed = hostSession.complete(outgoing.id, with: CommandResult(stdout: "", stderr: "", exitCode: 0))
        let reply = try #require(completed)
        guard case .completed(let id, _)? = try client.receive(reply).first else { Issue.record("no result"); return }
        #expect(id == outgoing.id)
    }

    @Test func theHostRefusesWhatItsHelperWouldRefuse() throws {
        var (hostSession, _) = try connected()
        for (id, call) in [(1, HostCall.dnsCreate(domain: "printers.local", localhost: nil)),
                           (2, .dnsCreate(domain: "Bad Domain", localhost: nil)),
                           (3, .dnsCreate(domain: "x.test", localhost: "not-an-ip")),
                           (4, .dnsDelete(domains: [])),
                           (5, .dnsDelete(domains: Array(repeating: "a.test", count: 33))),
                           (6, .setContainerDNSDomain(domain: "a b"))] as [(UInt32, HostCall)] {
            guard case .send(.failure(let failure))? = try hostSession.receive(.hostCall(.init(id: id, call: call))).first else {
                Issue.record("accepted \(call)"); return
            }
            #expect(failure.code == .refused)
        }
    }

    @Test func anUntrustedCallerOrAnOlderConnectionGetsNothing() throws {
        var (stranger, _) = try connected(trusted: false)
        guard case .send(.failure(let failure))? = try stranger.receive(.hostCall(.init(id: 1, call: .dnsStatus))).first else {
            Issue.record("a stranger was answered"); return
        }
        #expect(failure.code == .refused)
        var (old, client) = try connected(versions: 1...2)
        #expect(throws: WireError.hostCallsUnsupported) { try client.call(.dnsStatus) }
        #expect(throws: WireError.self) { try old.receive(.hostCall(.init(id: 1, call: .dnsStatus))) }
    }

    @Test func dnsStatusSurvivesJSON() throws {
        let status = HostDNSStatus(domains: [LocalDNSDomain(name: "mini.fleet.internal", kind: .containers,
                                                            resolverInstalled: true, registersContainers: true),
                                             LocalDNSDomain(name: "host.container.internal", kind: .hostAlias("203.0.113.113"),
                                                            resolverInstalled: true, registersContainers: false)],
                                   containerDomain: "mini.fleet.internal", helper: .enabled)
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(HostDNSStatus.self, from: data) == status)
    }

    @Test func hostFactsNeedVersionFour() throws {
        var (_, old) = try connected(versions: 1...3)
        #expect(throws: WireError.hostCallsUnsupported) { try old.call(.hostFacts) }
        var (hostSession, client) = try connected()
        let outgoing = try client.call(.hostFacts)
        #expect(try hostSession.receive(outgoing.message) == [.hostCall(id: outgoing.id, call: .hostFacts)])
        let facts = HostFacts(chip: "Apple M1", cores: 8, model: "Macmini9,1", macOSVersion: "26.6.2",
                              memoryTotalBytes: 16 << 30, memoryUsedBytes: 6 << 30, cpuPercent: 12.5,
                              diskTotalBytes: 245_107_195_904, diskFreeBytes: 120_000_000_000)
        #expect(try JSONDecoder().decode(HostFacts.self, from: JSONEncoder().encode(facts)) == facts)
    }

    // MARK: Zones

    @Test func aMacsNameBecomesADNSLabel() {
        #expect(FleetZones.label(for: "test  Mac mini") == "test-mac-mini")
        #expect(FleetZones.label(for: "Golden-Gate-Test-VM") == "golden-gate-test-vm")
        #expect(FleetZones.label(for: "Kamal’s MacBook Pro (2)") == "kamal-s-macbook-pro-2")
        #expect(FleetZones.label(for: "—") == "mac")
        #expect(FleetZones.label(for: String(repeating: "a", count: 80)).count == 63)
    }

    @Test func noTwoMacsShareAZone() {
        let zones = FleetZones.zones(for: [("1", "Mini"), ("2", "mini"), ("3", "MINI"), ("4", "Studio")],
                                     fleetDomain: "fleet.internal")
        #expect(zones["1"] == "mini.fleet.internal")
        #expect(zones["2"] == "mini-2.fleet.internal")
        #expect(zones["3"] == "mini-3.fleet.internal")
        #expect(zones["4"] == "studio.fleet.internal")
        for zone in zones.values { #expect(HostCall.dnsCreate(domain: zone, localhost: nil).problem == nil) }
    }

    @Test func theFleetDomainFollowsTheDNSRules() {
        #expect(FleetZones.fleetDomainProblem("fleet.internal") == nil)
        #expect(FleetZones.fleetDomainProblem("fleet.local") != nil)
        #expect(FleetZones.fleetDomainProblem("Fleet Internal") != nil)
    }
}
