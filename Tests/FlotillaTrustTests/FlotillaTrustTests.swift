import Foundation
import Security
import Testing
import FlotillaCore
@testable import FlotillaTrust

/// Run against the real login Keychain, under labels of their own, and cleaned up after — so the
/// identity Flotilla actually uses is never touched.
@Suite("Device identity", .serialized)
struct DeviceIdentityTests {
    func store() -> DeviceIdentityStore { DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)") }

    @Test func anIdentityIsCreatedOnceAndThenLoaded() throws {
        let store = store()
        defer { store.reset() }
        #expect(try store.load() == nil)
        let created = try store.loadOrCreate()
        let loaded = try #require(try store.load())
        #expect(loaded.fingerprint == created.fingerprint)
        let again = try store.loadOrCreate()
        #expect(again.fingerprint == created.fingerprint)
        // What TLS will present, and what a peer will compute from it.
        #expect(created.secIdentity() != nil)
        #expect(try DeviceIdentity.fingerprint(of: created.certificate) == created.fingerprint)
    }

    @Test func aResetMeansANewFingerprint() throws {
        let store = store()
        defer { store.reset() }
        let first = try store.loadOrCreate()
        store.reset()
        #expect(try store.load() == nil)
        let second = try store.loadOrCreate()
        #expect(second.fingerprint != first.fingerprint)
    }

    @Test func twoMacsNeverShareAnIdentity() throws {
        let a = store(), b = store()
        defer { a.reset(); b.reset() }
        let first = try a.loadOrCreate(), second = try b.loadOrCreate()
        #expect(first.fingerprint != second.fingerprint)
    }
}

@Suite("System pairing crypto")
struct SystemCryptoTests {
    @Test func hmacMatchesRFC4231() {
        // RFC 4231, test case 2.
        let mac = PairingCrypto.system.mac(Array("Jefe".utf8), Array("what do ya want for nothing?".utf8))
        #expect(mac.map { String(format: "%02x", $0) }.joined()
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func sha256MatchesTheStandardVector() {
        let digest = PairingCrypto.system.digest(Array("abc".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func randomBytesAreFreshEachTime() {
        #expect(PairingCrypto.system.random(32) != PairingCrypto.system.random(32))
    }

    @Test func codePairingCompletesWithRealCryptoAndRealIdentities() throws {
        let adminStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        let hostStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        defer { adminStore.reset(); hostStore.reset() }
        let adminID = try adminStore.loadOrCreate(), hostID = try hostStore.loadOrCreate()

        let code = PairingCode()
        var admin = PairingAdminSession(own: adminID.fingerprint, host: hostID.fingerprint,
                                        details: PeerDetails(computerName: "admin"),
                                        method: .pairingCode(code.display), crypto: .system)
        var host = PairingHostSession(own: hostID.fingerprint, admin: adminID.fingerprint,
                                      details: PeerDetails(computerName: "host"),
                                      enrolmentKey: nil, code: code, crypto: .system)
        func sent<E>(_ events: [E], _ extract: (E) -> WireMessage?) -> [WireMessage] { events.compactMap(extract) }
        let hostSend: (PairingHostSession.Event) -> WireMessage? = { if case .send(let m) = $0 { m } else { nil } }
        let adminSend: (PairingAdminSession.Event) -> WireMessage? = { if case .send(let m) = $0 { m } else { nil } }

        let challenge = sent(try host.receive(admin.start()), hostSend)
        let proof = sent(try admin.receive(challenge[0]), adminSend)
        let hostEvents = try host.receive(proof[0])
        let adminEvents = try admin.receive(sent(hostEvents, hostSend)[0])
        guard case .confirmWords(let hostWords, _)? = hostEvents.last,
              case .confirmWords(let adminWords, _)? = adminEvents.last else { Issue.record("no words"); return }
        #expect(hostWords == adminWords)
    }
}

@Suite("Trust stores", .serialized)
struct TrustStoreTests {
    @Test func thePeerBookSurvivesARelaunch() throws {
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = PeerBook()
        let print = PeerFingerprint(bytes: Array(repeating: 9, count: 32))!
        _ = book.requestEnrolment(print, role: .host, details: PeerDetails(computerName: "mini"), at: Date())
        try PeerBookStore(defaults: defaults).save(book)
        #expect(PeerBookStore(defaults: defaults).load() == book)
    }

    @Test func anAdminKeyRotatesAndAHostKeyIsValidatedBeforeItIsKept() throws {
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = EnrolmentKeyStore(service: "dev.melonfleet.Flotilla.test-enrolment.\(UUID().uuidString)",
                                      defaults: defaults)
        defer { store.removeAll(); defaults.removePersistentDomain(forName: suite) }
        let admin = PeerFingerprint(bytes: Array(repeating: 3, count: 32))!

        #expect(store.adminKey() == nil)
        let first = try store.rotate(for: admin)
        #expect(store.adminKey() == first)
        let second = try store.rotate(for: admin)
        #expect(second != first && store.adminKey() == second && second.names(admin))

        #expect(throws: EnrolmentKey.ParseError.self) { try store.setPastedHostKey("FLT1-NOPE") }
        #expect(store.hostKey() == nil)
        try store.setPastedHostKey(second.text.lowercased())
        #expect(store.hostKey()?.key == second && store.hostKey()?.source == .pasted)
        #expect(store.managedKeyProblem() == nil)
    }
}
