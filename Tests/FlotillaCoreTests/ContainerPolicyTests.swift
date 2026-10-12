import Foundation
import Testing
@testable import FlotillaCore

@Suite struct ContainerPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let always = ContainerPolicy(restart: .unlessStopped)

    @Test func anUnexpectedStopIsRestartedAtOnceThenWithBackoff() {
        var engine = PolicyEngine()
        _ = engine.observe("web", running: true, policy: always, at: t0)
        #expect(engine.observe("web", running: false, policy: always, at: t0 + 1) == [.restart("web")])
        // It stops again: the second restart waits 10 seconds.
        _ = engine.observe("web", running: true, policy: always, at: t0 + 2)
        #expect(engine.observe("web", running: false, policy: always, at: t0 + 3).isEmpty)
        #expect(engine.tick(policies: ["web": always], at: t0 + 12).isEmpty)
        #expect(engine.tick(policies: ["web": always], at: t0 + 13) == [.restart("web")])
    }

    @Test func aStopMadeInFlotillaIsLeftAlone() {
        var engine = PolicyEngine()
        _ = engine.observe("web", running: true, policy: always, at: t0)
        engine.noteDeliberateStop("web", at: t0 + 1)
        #expect(engine.observe("web", running: false, policy: always, at: t0 + 2).isEmpty)
        #expect(engine.tick(policies: ["web": always], at: t0 + 600).isEmpty)
        // Started again by hand, the next unexpected stop is restarted as usual.
        _ = engine.observe("web", running: true, policy: always, at: t0 + 700)
        #expect(engine.observe("web", running: false, policy: always, at: t0 + 701) == [.restart("web")])
    }

    @Test func neverMeansNever() {
        var engine = PolicyEngine()
        _ = engine.observe("web", running: true, policy: ContainerPolicy(), at: t0)
        #expect(engine.observe("web", running: false, policy: ContainerPolicy(), at: t0 + 1).isEmpty)
    }

    @Test func fiveRestartsInTenMinutesAndItGivesUp() {
        // A container that dies the moment it starts, ticked every second as the app does.
        var engine = PolicyEngine()
        var now = t0
        var restarts = 0
        _ = engine.observe("web", running: true, policy: always, at: now)
        var actions = engine.observe("web", running: false, policy: always, at: now + 1)
        now += 1
        while now < t0 + 600, engine.watches["web"]?.gaveUp != true {
            if actions.contains(.restart("web")) {
                restarts += 1
                _ = engine.observe("web", running: true, policy: always, at: now)
                actions = engine.observe("web", running: false, policy: always, at: now + 1)
            } else {
                actions = engine.tick(policies: ["web": always], at: now)
            }
            now += 1
        }
        #expect(restarts == PolicyEngine.maxRestarts)
        #expect(engine.watches["web"]?.gaveUp == true)
        #expect(engine.watches["web"]?.history.first?.kind == .gaveUp)
        // Started again by hand, it is watched again.
        engine.clearGaveUp("web")
        _ = engine.observe("web", running: true, policy: always, at: now + 1)
        #expect(engine.observe("web", running: false, policy: always, at: now + 2) == [.restart("web")])
    }

    @Test func healthWaitsForTheStartPeriodThenNeedsItsRetries() {
        let check = HealthCheck(probe: .port(8080), interval: 10, timeout: 2, retries: 2, startPeriod: 30)
        let policy = ContainerPolicy(health: check)
        var engine = PolicyEngine()
        _ = engine.observe("db", running: true, policy: policy, at: t0)
        #expect(engine.tick(policies: ["db": policy], at: t0 + 29).isEmpty)
        #expect(engine.tick(policies: ["db": policy], at: t0 + 30) == [.probe("db", .port(8080), timeout: 2)])
        // One failure isn't enough; the second makes it unhealthy, a notice and no restart.
        #expect(engine.probeFinished("db", ok: false, detail: "refused", policy: policy, at: t0 + 31).isEmpty)
        _ = engine.tick(policies: ["db": policy], at: t0 + 41)
        #expect(engine.probeFinished("db", ok: false, detail: "refused", policy: policy, at: t0 + 42) == [.changed("db")])
        #expect(engine.watches["db"]?.health == .unhealthy)
        // Recovery is a notice change too.
        _ = engine.tick(policies: ["db": policy], at: t0 + 52)
        #expect(engine.probeFinished("db", ok: true, detail: "ok", policy: policy, at: t0 + 53) == [.changed("db")])
        #expect(engine.watches["db"]?.health == .healthy)
    }

    @Test func restartingWhenUnhealthyIsAnOptIn() {
        let check = HealthCheck(probe: .http(port: 8080, path: "/health"), interval: 10, timeout: 2, retries: 1, startPeriod: 0)
        let optedIn = ContainerPolicy(health: check, restartWhenUnhealthy: true)
        var engine = PolicyEngine()
        _ = engine.observe("api", running: true, policy: optedIn, at: t0)
        _ = engine.tick(policies: ["api": optedIn], at: t0)
        #expect(engine.probeFinished("api", ok: false, detail: "503", policy: optedIn, at: t0 + 1) == [.changed("api"), .restart("api")])
    }

    @Test func aCheckIsBoundedAndNeverAURL() {
        #expect(HealthCheck(probe: .port(5432)).problem == nil)
        #expect(HealthCheck(probe: .http(port: 80, path: "/healthz")).problem == nil)
        #expect(HealthCheck(probe: .http(port: 80, path: "http://example.com/")).problem != nil)
        #expect(HealthCheck(probe: .http(port: 80, path: "//evil.example/x")).problem != nil)
        #expect(HealthCheck(probe: .http(port: 80, path: "/a b")).problem != nil)
        #expect(HealthCheck(probe: .port(0)).problem != nil)
        #expect(HealthCheck(probe: .port(80), interval: 1).problem != nil)          // a probe every second is load
        #expect(HealthCheck(probe: .port(80), interval: 10, timeout: 10).problem != nil)
        #expect(HealthCheck(probe: .command([])).problem != nil)
        #expect(HealthCheck(probe: .command(["pg_isready", "-U", "postgres"])).problem == nil)
    }

    @Test func aPolicySurvivesBeingSaved() throws {
        let policy = ContainerPolicy(restart: .unlessStopped,
                                     health: HealthCheck(probe: .command(["redis-cli", "ping"])),
                                     restartWhenUnhealthy: true)
        let data = try JSONEncoder().encode(["cache": policy])
        #expect(try JSONDecoder().decode([String: ContainerPolicy].self, from: data) == ["cache": policy])
    }
}
