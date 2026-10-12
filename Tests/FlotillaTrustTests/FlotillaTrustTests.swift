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
        defer { try? store.reset() }
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
        defer { try? store.reset() }
        let first = try store.loadOrCreate()
        #expect(try store.exists())
        try store.reset()
        #expect(try store.load() == nil)
        #expect(try !store.exists())
        // Nothing to delete is not a failure: a second reset succeeds too.
        try store.reset()
        let second = try store.loadOrCreate()
        #expect(second.fingerprint != first.fingerprint)
    }

    @Test func twoMacsNeverShareAnIdentity() throws {
        let a = store(), b = store()
        defer { try? a.reset(); try? b.reset() }
        let first = try a.loadOrCreate(), second = try b.loadOrCreate()
        #expect(first.fingerprint != second.fingerprint)
    }

    /// Why the reset button asks `exists` rather than `load`: a key whose certificate has gone
    /// loads as nothing, yet `loadOrCreate` gives it a new certificate and the *old* fingerprint is
    /// back. A button that read that as "no identity" would hide the one reset that removes it.
    @Test func aKeyWithoutItsCertificateStillCountsAsAnIdentity() throws {
        let store = store()
        defer { try? store.reset() }
        let original = try store.loadOrCreate()
        let certificates: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: store.label]
        try DeviceIdentityStore.deleteAll(certificates, "delete the test certificate")
        #expect(try store.load() == nil)
        #expect(try store.exists())
        #expect(try store.loadOrCreate().fingerprint == original.fingerprint)
        try store.reset()
        #expect(try !store.exists())
    }

    /// Kyle's review, 12 October: every delete's answer is read. Scripted, because a real Keychain
    /// cannot be made to refuse on cue.
    @Test func aDeleteIsDoneOnlyWhenTheKeychainSaysNothingIsLeft() throws {
        func script(_ statuses: [OSStatus]) -> (calls: () -> Int, delete: ([String: Any]) -> OSStatus) {
            var remaining = statuses[...], calls = 0
            return ({ calls }, { _ in calls += 1; return remaining.popFirst() ?? errSecItemNotFound })
        }
        // Gone at once, and one match per call until none is left: both are success.
        try DeviceIdentityStore.deleteAll([:], "delete it", delete: script([errSecItemNotFound]).delete)
        let several = script([errSecSuccess, errSecSuccess, errSecItemNotFound])
        try DeviceIdentityStore.deleteAll([:], "delete it", delete: several.delete)
        #expect(several.calls() == 3)
        // A refusal throws, and says which step and why.
        let refused = script([errSecSuccess, errSecInteractionNotAllowed])
        #expect(throws: DeviceIdentityStore.IdentityError.keychain(errSecInteractionNotAllowed, "delete it")) {
            try DeviceIdentityStore.deleteAll([:], "delete it", delete: refused.delete)
        }
        // So does a Keychain that keeps saying "deleted": the item may never go.
        #expect(throws: DeviceIdentityStore.IdentityError.stillThere("delete it")) {
            try DeviceIdentityStore.deleteAll([:], "delete it", delete: { _ in errSecSuccess })
        }
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
        defer { try? adminStore.reset(); try? hostStore.reset() }
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

    /// What *Forget all hosts and trust* leans on: the forgotten book is written rather than merely
    /// changed in memory, so the hosts are not back at the next launch — and neither is lost the
    /// block on a Mac the owner removed — and the fleet enrolment key goes on both sides, an
    /// admin's generated key and a host's pasted one.
    @Test func forgettingEverythingLeavesNothingToLoad() throws {
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = EnrolmentKeyStore(service: "dev.melonfleet.Flotilla.test-enrolment.\(UUID().uuidString)",
                                    defaults: defaults)
        defer { try? keys.removeAll(); defaults.removePersistentDomain(forName: suite) }

        var book = PeerBook()
        let mini = PeerFingerprint(bytes: Array(repeating: 7, count: 32))!
        let removed = PeerFingerprint(bytes: Array(repeating: 8, count: 32))!
        book.pairConfirmed(mini, role: .host, details: PeerDetails(computerName: "mini"), at: Date())
        book.pairConfirmed(removed, role: .host, details: PeerDetails(computerName: "old"), at: Date())
        book.revoke(removed, at: Date())
        let store = PeerBookStore(defaults: defaults)
        try store.save(book)
        let key = try keys.rotate(for: PeerFingerprint(bytes: Array(repeating: 4, count: 32))!)
        try keys.setPastedHostKey(key.text)

        book.forgetTrusted()
        try store.save(book)
        try keys.removeAll()

        #expect(store.load().peers.map(\.fingerprint) == [removed])
        #expect(store.load().isBlocked(removed))
        #expect(keys.adminKey() == nil && keys.hostKey() == nil)
        // Nothing left to remove is not a failure.
        try keys.removeAll()
        try keys.removePastedHostKey()
    }

    @Test func anAdminKeyRotatesAndAHostKeyIsValidatedBeforeItIsKept() throws {
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = EnrolmentKeyStore(service: "dev.melonfleet.Flotilla.test-enrolment.\(UUID().uuidString)",
                                      defaults: defaults)
        defer { try? store.removeAll(); defaults.removePersistentDomain(forName: suite) }
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
