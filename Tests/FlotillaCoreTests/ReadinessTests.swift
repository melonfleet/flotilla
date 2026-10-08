import Foundation
import Testing
@testable import FlotillaCore

@Suite("Readiness")
struct ReadinessTests {

    /// A clock the sleep moves, so a two-minute wait takes no time at all.
    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
        var probes = 0
    }

    @Test("ready as soon as the port answers")
    func readyAfterSomeProbes() async {
        let clock = FakeClock()
        let outcome = await Readiness.wait(timeout: 120, interval: 1, now: { clock.now },
                                           sleep: { clock.now += $0 },
                                           isRunning: { true },
                                           probe: { clock.probes += 1; return clock.probes >= 5 })
        #expect(outcome == .ready)
        #expect(clock.probes == 5)
        #expect(clock.now.timeIntervalSince1970 == 4)
    }

    @Test("gives up at the time limit and says so")
    func timesOut() async {
        let clock = FakeClock()
        let outcome = await Readiness.wait(timeout: 10, interval: 1, now: { clock.now },
                                           sleep: { clock.now += $0 },
                                           isRunning: { true },
                                           probe: { clock.probes += 1; return false })
        #expect(outcome == .timedOut)
        #expect(clock.now.timeIntervalSince1970 == 10)
        // One probe at each second, the deadline's own included.
        #expect(clock.probes == 11)
    }

    @Test("stops waiting when the container stops")
    func containerStopped() async {
        let clock = FakeClock()
        var checks = 0
        let outcome = await Readiness.wait(timeout: 120, interval: 1, now: { clock.now },
                                           sleep: { clock.now += $0 },
                                           isRunning: { checks += 1; return checks < 3 },
                                           probe: { false })
        #expect(outcome == .stopped)
        #expect(clock.now.timeIntervalSince1970 == 2)
    }

    @Test("the address drops the prefix length")
    func address() {
        #expect(Readiness.address(fromIPv4: "192.168.70.4/24") == "192.168.70.4")
        #expect(Readiness.address(fromIPv4: "10.0.0.2") == "10.0.0.2")
        #expect(Readiness.address(fromIPv4: nil) == nil)
        #expect(Readiness.address(fromIPv4: "") == nil)
    }

    @Test("a ready port must be a port")
    func readyPortValidated() throws {
        var book = GroupBook()
        let group = try book.createGroup(name: "shop")
        #expect(throws: GroupBook.GroupError.invalidReadyPort(70000)) {
            try book.addMember(GroupMember(name: "db", image: "postgres:18.6", readyPort: 70000),
                               to: group.id)
        }
        let added = try book.addMember(GroupMember(name: "db", image: "postgres:18.6",
                                                   readyPort: 5432), to: group.id)
        #expect(added.readyPort == 5432)
    }
}
