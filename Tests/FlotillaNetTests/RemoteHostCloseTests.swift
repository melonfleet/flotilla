import Foundation
import Network
import Testing
import FlotillaCore
import FlotillaTrust
@testable import FlotillaNet

/// A closed `RemoteHost` stays closed (Kyle's review, 12 October): *Forget all hosts and trust*
/// closed only the stored connection, so one still being opened was stored when it finished and
/// went on serving with the identity just reset.
///
/// No listener, and no socket ever connects: the host is a Bonjour name nobody advertises, which
/// never resolves. Before the fix, each test waits out its attempts — three of five seconds — and
/// fails on the clock. The other half of the fix, a connection whose handshake *succeeds* after
/// `close`, needs a host to answer, so it is not reachable without a real listener; the check that
/// handles it is under the same lock as the store it guards (`RemoteHost.openConnection`).
@Suite("RemoteHost after close", .serialized)
struct RemoteHostCloseTests {
    func withHost(_ body: (RemoteHost) async throws -> Void) async throws {
        let store = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        defer { try? store.reset() }
        let identity = try store.loadOrCreate()
        let host = RemoteHost(endpoint: .service(name: "nobody-\(UUID().uuidString.prefix(8))",
                                                 type: WireTLS.serviceType, domain: "local.", interface: nil),
                              fingerprint: identity.fingerprint, identity: identity,
                              info: WirePeerInfo(name: "admin", appVersion: "test"), reachTimeout: 5)
        defer { host.close() }
        try await body(host)
    }

    @Test func aClosedHostRefusesEveryCallAtOnce() async throws {
        try await withHost { host in
            host.close()
            #expect(host.isClosed)
            let started = Date()
            await #expect(throws: RemoteHost.closedError) { try await host.run(["ls"], timeout: nil) }
            await #expect(throws: RemoteHost.closedError) { try await host.call(.dnsStatus) }
            let ended = LineBox()
            _ = try host.stream(["logs", "--follow", "web"], onLine: { _, _ in },
                                onEnd: { ended.add($0.reason ?? "") })
            #expect(ended.all.count == 1)
            #expect(Date().timeIntervalSince(started) < 1, "took \(Date().timeIntervalSince(started))s")
        }
    }

    @Test func closingWhileAConnectionIsBeingOpenedEndsItAndKeepsNothing() async throws {
        try await withHost { host in
            let started = Date()
            let waiting = Task { try await host.run(["ls"], timeout: nil) }
            // Under way: the name is being looked up, and the caller is waiting on the attempt.
            try await Task.sleep(for: .milliseconds(300))
            host.close()
            await #expect(throws: RemoteHost.closedError) { _ = try await waiting.value }
            // Told when it was closed, not when the attempt gave up, let alone three of them.
            #expect(Date().timeIntervalSince(started) < 2, "took \(Date().timeIntervalSince(started))s")
            // And nothing was kept to answer the next call.
            await #expect(throws: RemoteHost.closedError) { try await host.run(["ls"], timeout: nil) }
        }
    }
}
