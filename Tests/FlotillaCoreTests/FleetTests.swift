import Foundation
import Testing
@testable import FlotillaCore

@Suite("Fleet")
struct FleetTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let mini = PeerFingerprint(bytes: Array(repeating: 0xAB, count: 32))!

    @Test func thisMacKeepsBareRowIDsAndHostsArePrefixed() {
        #expect(HostRef.local.rowID("web") == "web")
        #expect(HostRef.peer(mini).rowID("web") == "abababababababab/web")
        #expect(HostRef.peer(mini).rowID("web") != HostRef.local.rowID("web"))
    }

    @Test func aFailedAskKeepsTheLastAnswerAndMarksItStale() {
        var snapshot = FleetSnapshot<String>()
        #expect(!snapshot.isStale(at: now, freshFor: 60))
        snapshot.succeeded(["web", "db"], at: now)
        #expect(!snapshot.isStale(at: now.addingTimeInterval(10), freshFor: 60))
        snapshot.failed("unreachable", at: now.addingTimeInterval(30))
        #expect(snapshot.items == ["web", "db"])
        #expect(snapshot.isStale(at: now.addingTimeInterval(31), freshFor: 60))
        #expect(snapshot.age(at: now.addingTimeInterval(45)) == 45)
        snapshot.succeeded(["web"], at: now.addingTimeInterval(60))
        #expect(snapshot.lastError == nil && snapshot.items == ["web"])
    }

    @Test func anOldAnswerIsStaleEvenWithoutAFailure() {
        var snapshot = FleetSnapshot<Int>()
        snapshot.succeeded([1], at: now)
        #expect(snapshot.isStale(at: now.addingTimeInterval(120), freshFor: 60))
    }

    @Test func anUnreachableHostIsAskedLessOftenUntilItAnswers() {
        var backoff = HostBackoff(base: 30, ceiling: 300)
        #expect(backoff.isDue(at: now))
        backoff.failed(at: now)
        #expect(backoff.interval == 60 && !backoff.isDue(at: now.addingTimeInterval(59)))
        backoff.failed(at: now)
        backoff.failed(at: now)
        #expect(backoff.interval == 240)
        for _ in 0..<10 { backoff.failed(at: now) }
        #expect(backoff.interval == 300)
        backoff.succeeded(at: now)
        #expect(backoff.interval == 30 && backoff.failures == 0)
        backoff.forceDue()
        #expect(backoff.isDue(at: now))
    }
}
