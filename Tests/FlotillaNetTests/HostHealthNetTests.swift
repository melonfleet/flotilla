import Foundation
import Network
import Testing
import FlotillaCore
import FlotillaTrust
@testable import FlotillaNet

/// How the admin tells a host that is busy from one it cannot hear (13 October: the mini "didn't
/// answer in time" for fourteen minutes while its Flotilla was up and listening).
///
/// The real failure shapes, on loopback TLS: a connection that stays open while a command runs
/// long, a refused connection, and a request stuck behind a full set of slots.
@Suite("Host health over loopback TLS", .serialized)
struct HostHealthNetTests {
    let loopback = LoopbackTests()

    @Test func aCommandThatIsLateOnALiveConnectionIsABusyHostNotADeadOne() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        // The admin's own deadline is the timeout plus the wire's 10-second grace (`WireLimits`),
        // so the command must outlast 1 + 10 seconds to be late.
        rig.host.delay = 14
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = loopback.remote(rig)
        defer { host.close() }
        // The connection is up (the welcome has been exchanged) and the command is simply slow.
        _ = try await host.call(.hostFacts)
        let started = Date()
        do {
            _ = try await host.run(["ls"], timeout: 1)
            Issue.record("a fourteen-second command finished inside an eleven-second deadline")
        } catch let error as RemoteHostError {
            #expect(error.isLate(connectionAlive: host.isAlive()), "\(error)")
        }
        #expect(Date().timeIntervalSince(started) < 13)
        #expect(host.isAlive(), "the connection itself must still be open")
    }

    @Test func aHostThatCannotBeReachedIsNotBusy() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        // Nothing listens on this port any more.
        let port = rig.port
        let stranger = RemoteHost(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                  fingerprint: rig.hostIdentity.fingerprint, identity: rig.adminIdentity,
                                  info: WirePeerInfo(name: "admin", appVersion: "test"), reachTimeout: 1)
        defer { stranger.close() }
        rig.tearDown()
        do {
            _ = try await stranger.run(["ls"], timeout: nil)
            Issue.record("a stopped listener answered")
        } catch let error as RemoteHostError {
            #expect(!error.isLate(connectionAlive: stranger.isAlive()), "\(error)")
        }
        #expect(!stranger.isAlive())
    }

    @Test func aLocalDeadlineOnADeadConnectionIsNotBusy() {
        #expect(RemoteHostError.timedOut.isLate(connectionAlive: true))
        #expect(!RemoteHostError.timedOut.isLate(connectionAlive: false))
        #expect(!RemoteHostError.closed("gone").isLate(connectionAlive: true))
        #expect(!RemoteHostError.unreachable("x").isLate(connectionAlive: true))
        // The host's own words count either way: it answered.
        #expect(RemoteHostError.failed(.init(id: 1, code: .timedOut, message: "late")).isLate(connectionAlive: false))
        #expect(RemoteHostError.failed(.init(id: 1, code: .busy, message: "full")).isLate(connectionAlive: false))
        #expect(!RemoteHostError.failed(.init(id: 1, code: .internalError, message: "no")).isLate(connectionAlive: true))
    }

    @Test func aRequestBehindFullSlotsIsOnItsDeadlineFromTheMomentItWasAsked() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        rig.host.delay = 4
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let admin = AdminConnection(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                                    identity: rig.adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"),
                                    limits: WireLimits(deadlineGrace: 1))
        defer { admin.close() }
        let limit = try await admin.connect().limits.maxConcurrentRequests
        // Every slot taken by a command that outlasts the test; the next one has to wait for one.
        let holders = (0..<limit).map { _ in Task { try await admin.run(["ls"], timeout: 30) } }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        do {
            _ = try await admin.run(["ls"], timeout: 0.5)
            Issue.record("a request with no slot was answered")
        } catch let error as RemoteHostError {
            #expect(error == .timedOut, "\(error)")
        }
        // 0.5s + 1s of grace — not the four seconds a slot takes to come free.
        #expect(Date().timeIntervalSince(started) < 3, "took \(Date().timeIntervalSince(started))s")
        #expect(admin.heard(within: 45))
        for holder in holders { _ = try? await holder.value }
    }

    @Test func aQueuedRequestKeepsItsOriginalDeadlineWhenAdmitted() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        // Every command takes 1.5s: a slot frees at ~1.5s and the waiter's own run would end at ~3s.
        rig.host.delay = 1.5
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let admin = AdminConnection(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                                    identity: rig.adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"),
                                    limits: WireLimits(deadlineGrace: 1))
        defer { admin.close() }
        let limit = try await admin.connect().limits.maxConcurrentRequests
        let holders = (0..<limit).map { _ in Task { try await admin.run(["ls"], timeout: 30) } }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        do {
            // Due 0.5s + 1s of grace after it was asked, i.e. at ~1.8s: admitted at ~1.5s, it has
            // ~0.3s left, not another 1.5s.
            _ = try await admin.run(["ls"], timeout: 0.5)
            Issue.record("a request past its original deadline was answered")
        } catch let error as RemoteHostError {
            #expect(error == .timedOut, "\(error)")
        }
        let took = Date().timeIntervalSince(started)
        #expect(took < 2.3, "took \(took)s; a restarted deadline would be ~3s")
        for holder in holders { _ = try? await holder.value }
    }

    @Test func aFailureTheHostSentCountsAsHeardFrom() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = loopback.remote(rig)
        defer { host.close() }
        _ = try await host.call(.hostFacts)
        let askedAt = Date()
        try await Task.sleep(for: .milliseconds(50))
        // Not on the allowlist: the host (or this Mac) refuses it. Whatever the outcome, bytes
        // arrived or the call never left — only the former may move the timestamp.
        _ = try? await host.run(["ls"], timeout: 5)
        let received = try #require(host.lastReceivedAt)
        #expect(received >= askedAt, "a reply that arrived during the ask must count, whatever its outcome")
    }

    @Test func aReplyFromBeforeTheAskDoesNotCount() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = loopback.remote(rig)
        defer { host.close() }
        _ = try await host.call(.hostFacts)
        try await Task.sleep(for: .milliseconds(100))
        let askedAt = Date()
        let received = try #require(host.lastReceivedAt)
        #expect(received < askedAt)
        // `isAlive` is true here — within 45 seconds — and is exactly what used to pass for hearing.
        #expect(host.isAlive())
    }

    @Test func aHalfOpenConnectionThatTimesOutDoesNotCount() async throws {
        let rig = try await loopback.rig()
        defer { rig.tearDown() }
        // Every reply is slower than the ask, so nothing arrives before the local deadline.
        rig.host.delay = 30
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let admin = AdminConnection(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                                    identity: rig.adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"),
                                    limits: WireLimits(deadlineGrace: 0.2))
        defer { admin.close() }
        _ = try await admin.connect()
        try await Task.sleep(for: .milliseconds(100))
        let askedAt = Date()
        do {
            _ = try await admin.run(["ls"], timeout: 0.3)
            Issue.record("a thirty-second command answered inside half a second")
        } catch let error as RemoteHostError {
            #expect(error == .timedOut, "\(error)")
        }
        let received = try #require(admin.lastReceivedAt)
        #expect(received < askedAt, "a local timeout is not the host's word")
    }
}
