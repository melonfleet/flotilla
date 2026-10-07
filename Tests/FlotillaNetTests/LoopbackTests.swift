import Foundation
import Network
import Testing
import FlotillaCore
import FlotillaTrust
@testable import FlotillaNet

/// Host mode end to end on this Mac's loopback: two real Keychain identities, real TLS 1.3 with
/// client certificates, the real wire protocol and both pairing methods. Nothing here launches
/// `container` — the host side runs a scripted `ContainerHost`.
@Suite("Host mode over loopback TLS", .serialized)
struct LoopbackTests {

    final class ScriptedHost: ContainerHost, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ran: [[String]] = []
        func run(_ args: [String]) throws -> CommandResult {
            lock.lock(); ran.append(args); lock.unlock()
            return CommandResult(stdout: "[]\n", stderr: "", exitCode: 0)
        }
    }

    final class Delegate: HostServerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        var trusted: [PeerFingerprint: Peer.Method] = [:]
        var code: PairingCode?
        var key: EnrolmentKey?
        var codeFailures = 0
        var answers: [WireMessage.PairOutcome] = []
        var hostSaysWordsMatch = true

        func isTrusted(_ fingerprint: PeerFingerprint) -> Bool { locked { trusted[fingerprint] != nil } }
        func currentPairingCode() -> PairingCode? { locked { code } }
        func pairingCodeFailed() { locked { codeFailures += 1 } }
        func enrolmentKey() -> EnrolmentKey? { locked { key } }
        func trust(admin: PeerFingerprint, details: PeerDetails, method: Peer.Method) { locked { trusted[admin] = method } }
        func confirmWords(_ words: [String], admin: PeerDetails, reply: @escaping @Sendable (Bool) -> Void) {
            reply(locked { hostSaysWordsMatch })
        }
        func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String) { locked { answers.append(outcome) } }

        func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    }

    /// A listening host and an identity for the admin, torn down afterwards.
    struct Rig {
        let server: HostServer
        let delegate: Delegate
        let host: ScriptedHost
        let hostIdentity: DeviceIdentity
        let adminIdentity: DeviceIdentity
        let port: UInt16
        let stores: [DeviceIdentityStore]

        func admin() -> AdminConnection {
            AdminConnection(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                            identity: adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"))
        }

        func tearDown() {
            server.stop()
            stores.forEach { $0.reset() }
        }
    }

    func rig() async throws -> Rig {
        let hostStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        let adminStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        let hostIdentity = try hostStore.loadOrCreate(), adminIdentity = try adminStore.loadOrCreate()
        let delegate = Delegate(), host = ScriptedHost()
        let server = HostServer(configuration: .init(identity: hostIdentity, port: 0,
                                                     info: WirePeerInfo(name: "mini-test", appVersion: "test"),
                                                     details: PeerDetails(computerName: "mini-test", serialNumber: "TEST")),
                                host: host, delegate: delegate)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            server.onStateChange = { state in
                switch state {
                case .listening(let port): once.run { continuation.resume(returning: port) }
                case .failed(let why): once.run { continuation.resume(throwing: RemoteHostError.unreachable(why)) }
                default: break
                }
            }
            do { try server.start() } catch { once.run { continuation.resume(throwing: error) } }
        }
        return Rig(server: server, delegate: delegate, host: host, hostIdentity: hostIdentity,
                   adminIdentity: adminIdentity, port: port, stores: [hostStore, adminStore])
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    // MARK: Tests

    @Test func aStrangerConnectsButCannotRunAnything() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let admin = rig.admin()
        defer { admin.close() }
        let welcome = try await admin.connect()
        #expect(!welcome.trusted)
        #expect(welcome.peer.name == "mini-test")
        #expect(admin.hostFingerprint == rig.hostIdentity.fingerprint)
        await #expect(throws: RemoteHostError.self) { try await admin.run(["ls", "--format", "json"]) }
        #expect(rig.host.ran.isEmpty)
    }

    @Test func pairingByCodeThenRunningACommand() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let code = PairingCode()
        rig.delegate.locked { rig.delegate.code = code }

        let first = rig.admin()
        _ = try await first.connect()
        let outcome = try await first.pair(details: PeerDetails(computerName: "admin-laptop"),
                                           method: .pairingCode(code.display.lowercased()),
                                           confirmWords: { words, _ in words.count == 4 },
                                           recordEnrolment: { _, _ in .blocked })
        #expect(outcome == .paired(rig.hostIdentity.fingerprint,
                                   PeerDetails(computerName: "mini-test", serialNumber: "TEST")))
        #expect(rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] } == .pairingCode)
        first.close()

        // A new connection from the same key is now trusted, and commands run.
        let second = rig.admin()
        defer { second.close() }
        let welcome = try await second.connect()
        #expect(welcome.trusted)
        let result = try await second.run(["ls", "--format", "json"])
        #expect(result.stdout == "[]\n" && result.exitCode == 0)
        #expect(rig.host.ran == [["ls", "--format", "json"]])
        // Refused before it leaves this Mac.
        await #expect(throws: AllowlistError.self) { try await second.run(["system", "stop"]) }
    }

    @Test func aWrongCodeIsRefusedAndCounted() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.code = PairingCode() }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        await #expect(throws: RemoteHostError.self) {
            try await admin.pair(details: PeerDetails(computerName: "admin"), method: .pairingCode("0000-0000"),
                                 confirmWords: { _, _ in true }, recordEnrolment: { _, _ in .blocked })
        }
        #expect(rig.delegate.locked { rig.delegate.codeFailures } == 1)
        #expect(rig.delegate.locked { rig.delegate.trusted.isEmpty })
    }

    @Test func theHostOwnerCanSayTheWordsDoNotMatch() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let code = PairingCode()
        rig.delegate.locked { rig.delegate.code = code; rig.delegate.hostSaysWordsMatch = false }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        await #expect(throws: RemoteHostError.self) {
            try await admin.pair(details: PeerDetails(computerName: "admin"), method: .pairingCode(code.value),
                                 confirmWords: { _, _ in true }, recordEnrolment: { _, _ in .blocked })
        }
        #expect(rig.delegate.locked { rig.delegate.trusted.isEmpty })
    }

    @Test func enrolmentPutsTheHostInTheApprovalList() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let key = EnrolmentKey.generate(for: rig.adminIdentity.fingerprint)
        rig.delegate.locked { rig.delegate.key = key }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        let outcome = try await admin.pair(details: PeerDetails(computerName: "admin"), method: .enrolmentKey(key),
                                           confirmWords: { _, _ in false },
                                           recordEnrolment: { _, _ in .addedPending })
        guard case .enrolment(let fingerprint, let details, .addedPending) = outcome else {
            Issue.record("unexpected \(outcome)"); return
        }
        #expect(fingerprint == rig.hostIdentity.fingerprint && details.serialNumber == "TEST")
        // The host trusts the admin its key names; the admin still has to approve the host.
        #expect(rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] } == .enrolmentKey)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.delegate.locked { rig.delegate.answers } == [.pending])
    }

    @Test func revokingClosesTheLiveConnection() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let admin = rig.admin()
        defer { admin.close() }
        #expect(try await admin.connect().trusted)
        rig.delegate.locked { rig.delegate.trusted = [:] }
        rig.server.disconnect(rig.adminIdentity.fingerprint)
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: RemoteHostError.self) { try await admin.run(["ls"]) }
    }
}
