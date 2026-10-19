import Foundation
import Testing
@testable import FlotillaCore

@Suite("Host health")
struct HostHealthTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Backoff

    @Test func theRetryWaitIsCappedAtTwoMinutes() {
        var backoff = HostBackoff()
        for _ in 0..<20 { backoff.failed(at: t0) }
        #expect(backoff.interval == 120)
        #expect(!backoff.isDue(at: at(119)) && backoff.isDue(at: at(120)))
    }

    @Test func aNetworkChangeForgetsTheFailuresAsWellAsTheWait() {
        var backoff = HostBackoff()
        for _ in 0..<5 { backoff.failed(at: t0) }
        backoff.reset()
        #expect(backoff.isDue(at: t0) && backoff.failures == 0)
        // The next failure starts from the bottom again, not from the ceiling.
        backoff.failed(at: t0)
        #expect(backoff.interval == 60)
    }

    // MARK: Network path

    @Test func theFirstPathReportIsABaselineNotAChange() {
        var filter = NetworkChangeFilter()
        let result1 = filter.observe(satisfied: true, signature: ["en0"])
        #expect(!result1)
        let result2 = filter.observe(satisfied: true, signature: ["en0"])
        #expect(!result2)
    }

    @Test func tailscaleComingUpIsAChange() {
        var filter = NetworkChangeFilter()
        _ = filter.observe(satisfied: true, signature: ["en0", "192.168.1.1"])
        let result3 = filter.observe(satisfied: true, signature: ["en0", "utun4", "192.168.1.1"])
        #expect(result3)
        // Repeats of the same path are not.
        let result4 = filter.observe(satisfied: true, signature: ["utun4", "en0", "192.168.1.1"])
        #expect(!result4)
    }

    @Test func losingTheNetworkWaitsAndGettingItBackReconnects() {
        var filter = NetworkChangeFilter()
        _ = filter.observe(satisfied: true, signature: ["en0"])
        let result5 = filter.observe(satisfied: false, signature: [])
        #expect(!result5)
        // Same interface as before the drop, but it was gone in between.
        let result6 = filter.observe(satisfied: true, signature: ["en0"])
        #expect(result6)
    }

    @Test func anotherWiFiNetworkOnTheSameInterfaceAndGatewayIsAChange() {
        func signature(_ address: [UInt8]) -> [String] {
            ["en0", "192.168.1.1", NetworkChangeFilter.addressToken(interface: "en0", bytes: address)!]
        }
        var filter = NetworkChangeFilter()
        _ = filter.observe(satisfied: true, signature: signature([192, 168, 1, 20]))
        // A lease renewal repeats the path: no storm.
        let renewed = filter.observe(satisfied: true, signature: signature([192, 168, 1, 20]))
        #expect(!renewed)
        // A different network, same interface name, same gateway address.
        let moved = filter.observe(satisfied: true, signature: signature([192, 168, 1, 77]))
        #expect(moved)
    }

    @Test func addressTokensIgnoreWhatSaysNothingAboutTheNetwork() {
        #expect(NetworkChangeFilter.addressToken(interface: "lo0", bytes: [127, 0, 0, 1]) == nil)
        #expect(NetworkChangeFilter.addressToken(interface: "en0", bytes: [169, 254, 3, 4]) == nil)
        var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xfe; linkLocal[1] = 0x80; linkLocal[15] = 1
        #expect(NetworkChangeFilter.addressToken(interface: "en0", bytes: linkLocal) == nil)
        // A privacy address that rotates within one network keeps its token.
        var a = [UInt8](repeating: 0, count: 16); a[0] = 0x20; a[1] = 0x01; a[7] = 5; a[15] = 1
        var b = a; b[15] = 9; b[12] = 0xaa
        #expect(NetworkChangeFilter.addressToken(interface: "en0", bytes: a) == NetworkChangeFilter.addressToken(interface: "en0", bytes: b))
        var c = a; c[7] = 6
        #expect(NetworkChangeFilter.addressToken(interface: "en0", bytes: a) != NetworkChangeFilter.addressToken(interface: "en0", bytes: c))
    }

    // MARK: Update confirmation

    @Test func silenceWhileTheHostRelaunchesIsNotAFailure() {
        // 13 October: the host was on build 452 at 09:07; the admin called it failed at four minutes.
        var watch = UpdateWatch(target: 452, startedAt: t0)
        let result7 = watch.observe(answered: false, build: nil, at: at(240))
        #expect(result7 == .waiting(.silent))
        let result8 = watch.observe(answered: false, build: nil, at: at(1200))
        #expect(result8 == .waiting(.silent))
    }

    @Test func theHostsOwnBuildConfirmsItWhenItAnswers() {
        var watch = UpdateWatch(target: 452, startedAt: t0)
        _ = watch.observe(answered: false, build: nil, at: at(600))
        let result9 = watch.observe(answered: true, build: 452, at: at(1000))
        #expect(result9 == .confirmed)
        var newer = UpdateWatch(target: 452, startedAt: t0)
        let result10 = newer.observe(answered: true, build: 453, at: at(30))
        #expect(result10 == .confirmed)
    }

    @Test func theOldBuildMayAnswerForAWhileThenItIsAFailure() {
        var watch = UpdateWatch(target: 452, startedAt: t0)
        let result11 = watch.observe(answered: true, build: 451, at: at(5))
        #expect(result11 == .waiting(.stillOldBuild))
        guard case .failed(let why) = watch.observe(answered: true, build: 451, at: at(300)) else {
            Issue.record("an old build still answering five minutes on was not a failure")
            return
        }
        #expect(why.contains("451") && why.contains("452"))
    }

    @Test func aHostSilentForHalfAnHourIsFinallyCalledLost() {
        var watch = UpdateWatch(target: 452, startedAt: t0)
        let result12 = watch.observe(answered: false, build: nil, at: at(1799))
        #expect(result12 == .waiting(.silent))
        guard case .failed = watch.observe(answered: false, build: nil, at: at(1801)) else {
            Issue.record("thirty minutes of silence was not a failure")
            return
        }
    }

    @Test func silenceIsMeasuredFromTheLastAnswer() {
        var watch = UpdateWatch(target: 452, startedAt: t0)
        // Answers on the old build early on, then goes quiet for the relaunch.
        _ = watch.observe(answered: true, build: 451, at: at(60))
        let result13 = watch.observe(answered: false, build: nil, at: at(60 + 1700))
        #expect(result13 == .waiting(.silent))
        let result14 = watch.observe(answered: false, build: nil, at: at(60 + 1801))
        #expect(result14 != .waiting(.silent))
    }

    @Test func anAnswerWithNoBuildYetIsNotAVerdict() {
        var watch = UpdateWatch(target: 452, startedAt: t0)
        let result15 = watch.observe(answered: true, build: nil, at: at(600))
        #expect(result15 == .waiting(.stillOldBuild))
    }
}
