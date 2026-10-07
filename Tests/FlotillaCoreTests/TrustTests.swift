import Foundation
import Testing
@testable import FlotillaCore

/// A stand-in for CryptoKit, so the protocol's rules are tested on Linux too. Not secure — it only
/// has to be deterministic and to change completely when any input byte changes. The real HMAC and
/// SHA-256 are the app's (B2b) and are tested there.
enum FakeCrypto {
    static func digest(_ bytes: [UInt8]) -> [UInt8] {
        (0..<32).map { lane in
            var h: UInt64 = 0xcbf2_9ce4_8422_2325 &+ UInt64(lane)
            for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return UInt8(truncatingIfNeeded: h >> 24)
        }
    }

    static func make(seed: UInt8 = 1) -> PairingCrypto {
        let counter = Counter(seed)
        return PairingCrypto(mac: { key, message in digest(key + [0x5c] + message) },
                             digest: digest,
                             random: { count in counter.next(count) })
    }

    final class Counter: @unchecked Sendable {
        private var value: UInt8
        private let lock = NSLock()
        init(_ seed: UInt8) { value = seed }
        func next(_ count: Int) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return digest([value, UInt8(count)]) + Array(repeating: value, count: max(0, count - 32))
        }
    }
}

func fingerprint(_ seed: UInt8) -> PeerFingerprint { PeerFingerprint(bytes: FakeCrypto.digest([seed, 0xAA]))! }

/// A deterministic generator, so a key or a code can be pinned in a test.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Trust encodings")
struct TrustEncodingTests {
    @Test func crockfordRoundTripsAndForgivesPeople() {
        let bytes: [UInt8] = (0..<37).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let text = Crockford32.encode(bytes)
        #expect(Crockford32.decode(text) == bytes)
        let sloppy = Crockford32.grouped(text, size: 4).lowercased()
        #expect(Crockford32.decode(sloppy) == bytes)
        #expect(Crockford32.decode("O1L") == Crockford32.decode("011"))
        #expect(Crockford32.decode("U") == nil)
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func fingerprintsRoundTripThroughHex() throws {
        let print = fingerprint(1)
        #expect(PeerFingerprint(hex: print.hex) == print)
        #expect(PeerFingerprint(hex: "zz") == nil)
        #expect(PeerFingerprint(bytes: [1, 2]) == nil)
        let decoded = try JSONDecoder().decode(PeerFingerprint.self, from: JSONEncoder().encode(print))
        #expect(decoded == print)
    }

    @Test func theWordListIsOneWordPerByte() {
        #expect(FingerprintWords.list.count == 256)
        #expect(Set(FingerprintWords.list).count == 256)
        #expect(FingerprintWords.words(for: [0, 255, 1, 2]) == ["acorn", "zinc", "agent", "alarm"])
    }
}

@Suite("Enrolment keys and pairing codes")
struct EnrolmentKeyTests {
    let admin = fingerprint(1)

    @Test func aKeyRoundTripsThroughItsText() throws {
        var generator = SeededGenerator(state: 7)
        let key = EnrolmentKey.generate(for: admin, using: &generator)
        #expect(key.text.hasPrefix("FLT1-"))
        #expect(key.text.count == 5 + 60 + 9)   // prefix, 60 characters, nine dashes
        #expect(try EnrolmentKey(text: key.text) == key)
        // Pasted badly: lower case, spaces, a trailing newline.
        let sloppy = "  " + key.text.lowercased().replacingOccurrences(of: "-", with: " ") + "\n"
        #expect(try EnrolmentKey(text: "FLT1-" + sloppy.dropFirst(7)) == key)
        #expect(key.names(admin))
        #expect(!key.names(fingerprint(2)))
    }

    @Test func aTypoIsCaughtBeforeAnythingIsSent() {
        var generator = SeededGenerator(state: 7)
        let text = EnrolmentKey.generate(for: admin, using: &generator).text
        var characters = Array(text)
        characters[10] = characters[10] == "A" ? "B" : "A"
        #expect(throws: EnrolmentKey.ParseError.checksumMismatch) { try EnrolmentKey(text: String(characters)) }
        #expect(throws: EnrolmentKey.ParseError.wrongLength) { try EnrolmentKey(text: String(text.dropLast(7))) }
        #expect(throws: EnrolmentKey.ParseError.notAnEnrolmentKey) { try EnrolmentKey(text: "CID-1234") }
    }

    @Test func aTypoInTheLastCharacterIsCaught() {
        // Iris's review: the last character carries one meaningful bit; the other four were ignored,
        // so several different last characters decoded to the same key.
        var generator = SeededGenerator(state: 7)
        let text = EnrolmentKey.generate(for: admin, using: &generator).text
        let last = text.last!
        let others = Crockford32.alphabet.filter { $0 != last }
        let accepted = others.filter { (try? EnrolmentKey(text: String(text.dropLast()) + String($0))) != nil }
        #expect(accepted.isEmpty, "also accepted: \(accepted)")
    }

    @Test func aPairingCodeExpiresAndRunsOutOfTries() {
        var generator = SeededGenerator(state: 3)
        let start = Date(timeIntervalSince1970: 1_000)
        var code = PairingCode(issuedAt: start, using: &generator)
        #expect(code.value.count == 8)
        #expect(code.display.count == 9 && code.display.contains("-"))
        #expect(PairingCode.normalise(code.display.lowercased()) == code.value)
        #expect(code.isUsable(at: start.addingTimeInterval(599)))
        #expect(!code.isUsable(at: start.addingTimeInterval(600)))
        for _ in 0..<4 {
            let usable = code.recordFailure(at: start)
            #expect(usable)
        }
        let last = code.recordFailure(at: start)
        #expect(!last)
    }
}

@Suite("Peer book")
struct PeerBookTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let mini = fingerprint(5)
    let details = PeerDetails(computerName: "mini-1", model: "Mac14,3", serialNumber: "SERIAL", macOSVersion: "27.0")

    @Test func anEnrolmentWaitsForTheOwner() {
        var book = PeerBook()
        let first = book.requestEnrolment(mini, role: .host, details: details, at: now)
        #expect(first == .addedPending)
        #expect(!book.isTrusted(mini))
        let again = book.requestEnrolment(mini, role: .host, details: details, at: now)
        #expect(again == .stillPending)
        let approved = book.approve(mini, at: now)
        #expect(approved && book.isTrusted(mini))
        let later = book.requestEnrolment(mini, role: .host, details: details, at: now)
        #expect(later == .alreadyApproved)
    }

    @Test func aRejectedMacStaysOutUntilTheOwnerRelents() {
        var book = PeerBook()
        _ = book.requestEnrolment(mini, role: .host, details: details, at: now)
        let rejected = book.reject(mini, at: now)
        let retry = book.requestEnrolment(mini, role: .host, details: details, at: now)
        #expect(rejected && retry == .blocked)
        let readmitted = book.approve(mini, at: now)
        #expect(readmitted && book.isTrusted(mini))
    }

    @Test func aRemovedAdminIsNotLetBackByItsKey() {
        var book = PeerBook()
        let admin = fingerprint(9)
        let admitted = book.admitByEnrolmentKey(admin, details: details, at: now)
        #expect(admitted)
        book.revoke(admin, at: now)
        let again = book.admitByEnrolmentKey(admin, details: details, at: now)
        #expect(!again && !book.isTrusted(admin) && book.isBlocked(admin))
        // A code pairing the owner confirms — or the owner's own approval — does let it back.
        book.pairConfirmed(admin, role: .admin, details: details, at: now)
        #expect(book.isTrusted(admin))
    }

    @Test func onlyAnApprovedMacCanBeRevoked() {
        var book = PeerBook()
        _ = book.requestEnrolment(mini, role: .host, details: details, at: now)
        let early = book.revoke(mini, at: now)
        #expect(!early)
        book.approve(mini, at: now)
        let revoked = book.revoke(mini, at: now)
        #expect(revoked && !book.isTrusted(mini))
        let retry = book.requestEnrolment(mini, role: .host, details: details, at: now)
        #expect(retry == .blocked)
    }

    @Test func unansweredRequestsLapseAfterSevenDays() {
        var book = PeerBook()
        _ = book.requestEnrolment(mini, role: .host, details: details, at: now)
        _ = book.requestEnrolment(fingerprint(6), role: .host, details: details, at: now.addingTimeInterval(86_400))
        let lapsed = book.expirePending(at: now.addingTimeInterval(PeerBook.pendingLifetime))
        #expect(lapsed.map(\.fingerprint) == [mini])
        #expect(book.peers.count == 1)
    }

    @Test func aRenamedMacUpdatesItsRecordButNotTheOwnersNickname() {
        var book = PeerBook()
        _ = book.requestEnrolment(mini, role: .host, details: details, at: now)
        let changed = book.refresh(mini, computerName: "rack-2-mini", macOSVersion: "27.1")
        #expect(changed)
        #expect(book[mini]?.details.computerName == "rack-2-mini")
        #expect(book[mini]?.details.serialNumber == "SERIAL")
        let again = book.refresh(mini, computerName: "rack-2-mini", macOSVersion: "27.1")
        #expect(!again)
        book.rename(mini, to: "Build box")
        book.refresh(mini, computerName: "renamed-again", macOSVersion: nil)
        #expect(book[mini]?.displayName == "Build box")
    }

    @Test func theBookIsPlistNative() throws {
        var book = PeerBook()
        _ = book.requestEnrolment(mini, role: .host, details: details, at: now)
        book.rename(mini, to: "  Rack 2  ")
        let data = try PropertyListEncoder().encode(book)
        let back = try PropertyListDecoder().decode(PeerBook.self, from: data)
        #expect(back == book)
        #expect(back[mini]?.displayName == "Rack 2")
    }
}

@Suite("Pairing")
struct PairingTests {
    let adminPrint = fingerprint(1)
    let hostPrint = fingerprint(2)
    let adminDetails = PeerDetails(computerName: "admin-laptop")
    let hostDetails = PeerDetails(computerName: "mini-1", serialNumber: "SERIAL")

    /// Sends each `.send` from one side to the other, through real frames, until both are quiet.
    func run(admin: inout PairingAdminSession, host: inout PairingHostSession,
             first: WireMessage) throws -> (admin: [PairingAdminSession.Event], host: [PairingHostSession.Event]) {
        var adminEvents: [PairingAdminSession.Event] = []
        var hostEvents: [PairingHostSession.Event] = []
        var toHost = [first], toAdmin: [WireMessage] = []
        func wire(_ m: WireMessage) throws -> WireMessage { try WireMessage(frame: try m.frame()) }
        while !toHost.isEmpty || !toAdmin.isEmpty {
            for message in toHost {
                let events = try host.receive(try wire(message))
                hostEvents += events
                toAdmin += events.compactMap { if case .send(let m) = $0 { m } else { nil } }
            }
            toHost = []
            for message in toAdmin {
                let events = try admin.receive(try wire(message))
                adminEvents += events
                toHost += events.compactMap { if case .send(let m) = $0 { m } else { nil } }
            }
            toAdmin = []
        }
        return (adminEvents, hostEvents)
    }

    // MARK: Enrolment key

    @Test func aHostWithTheKeyAsksToJoinAndWaitsForApproval() throws {
        let key = EnrolmentKey.generate(for: adminPrint)
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .enrolmentKey(key), crypto: FakeCrypto.make(seed: 1))
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails,
                                      enrolmentKey: key, code: nil, crypto: FakeCrypto.make(seed: 50))
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(adminEvents == [.enrolmentRequested(hostPrint, hostDetails)])
        #expect(hostEvents.contains(.adminTrusted(adminPrint, adminDetails)))

        var book = PeerBook()
        let outcome = book.requestEnrolment(hostPrint, role: .host, details: hostDetails, at: Date())
        let answer = admin.finishEnrolment(outcome)
        let answered = try host.receive(answer)
        #expect(answered == [.enrolmentAnswered(.pending, "Waiting for the owner to approve this Mac.")])
        #expect(!book.isTrusted(hostPrint))
    }

    @Test func aHostRefusesAnAdminItsKeyDoesNotName() throws {
        let key = EnrolmentKey.generate(for: fingerprint(9))
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .enrolmentKey(EnrolmentKey.generate(for: adminPrint)),
                                        crypto: FakeCrypto.make())
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails,
                                      enrolmentKey: key, code: nil, crypto: FakeCrypto.make(seed: 50))
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(hostEvents.contains { if case .close = $0 { true } else { false } })
        #expect(!hostEvents.contains { if case .adminTrusted = $0 { true } else { false } })
        #expect(adminEvents.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aHostWithoutTheSecretCannotJoin() throws {
        let realKey = EnrolmentKey.generate(for: adminPrint)
        // Same admin named, different secret — a forged key.
        let forged = EnrolmentKey(adminFingerprint: adminPrint, secret: Array(repeating: 7, count: 16))
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .enrolmentKey(realKey), crypto: FakeCrypto.make())
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails,
                                      enrolmentKey: forged, code: nil, crypto: FakeCrypto.make(seed: 50))
        let (adminEvents, _) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(!adminEvents.contains { if case .enrolmentRequested = $0 { true } else { false } })
        #expect(adminEvents.contains { if case .failed = $0 { true } else { false } })
    }

    // MARK: Pairing code

    func codeSessions(typed: String, hostSees: PeerFingerprint? = nil, adminSees: PeerFingerprint? = nil)
        -> (PairingAdminSession, PairingHostSession, PairingCode) {
        var generator = SeededGenerator(state: 11)
        let code = PairingCode(issuedAt: Date(), using: &generator)
        let admin = PairingAdminSession(own: adminPrint, host: adminSees ?? hostPrint, details: adminDetails,
                                        method: .pairingCode(typed.isEmpty ? code.display.lowercased() : typed),
                                        crypto: FakeCrypto.make(seed: 1))
        let host = PairingHostSession(own: hostPrint, admin: hostSees ?? adminPrint, details: hostDetails,
                                      enrolmentKey: nil, code: code, crypto: FakeCrypto.make(seed: 50))
        return (admin, host, code)
    }

    @Test func theRightCodeShowsTheSameWordsOnBothMacs() throws {
        var (admin, host, _) = codeSessions(typed: "")
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        guard case .confirmWords(let adminWords, let seen)? = adminEvents.last,
              case .confirmWords(let hostWords, _)? = hostEvents.last else { Issue.record("no words"); return }
        #expect(adminWords == hostWords && adminWords.count == 4)
        #expect(seen == hostDetails)

        // Both owners say yes, in either order; only the second completes it.
        let hostSays = host.confirm(true)
        #expect(!hostSays.contains { if case .paired = $0 { true } else { false } })
        guard case .send(let hostYes) = hostSays.first else { Issue.record(); return }
        let quiet = try admin.receive(hostYes)
        #expect(quiet.isEmpty)
        let adminSays = admin.confirm(true)
        // Not yet: the admin waits for the host to say it has recorded the trust.
        #expect(!adminSays.contains { if case .paired = $0 { true } else { false } })
        guard case .send(let adminYes) = adminSays.first else { Issue.record(); return }
        let done = try host.receive(adminYes)
        #expect(done.first == .paired(adminPrint, adminDetails))
        guard case .send(let acknowledgement)? = done.last else { Issue.record("no acknowledgement"); return }
        let finished = try admin.receive(acknowledgement)
        #expect(finished == [.paired(hostPrint, hostDetails)])
    }

    @Test func aWrongCodeIsRefusedAndCounted() throws {
        var (admin, host, _) = codeSessions(typed: "0000-0000")
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(hostEvents.contains(.codeFailed))
        #expect(adminEvents.contains { if case .failed = $0 { true } else { false } })
        #expect(!adminEvents.contains { if case .confirmWords = $0 { true } else { false } })
    }

    @Test func aMachineInTheMiddleBreaksTheProofs() throws {
        // Each side sees the attacker's key where the other's should be, and the attacker relays
        // every message unchanged — knowing the code is not enough to make the proofs agree.
        var (admin, host, _) = codeSessions(typed: "", hostSees: fingerprint(66), adminSees: fingerprint(77))
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(hostEvents.contains(.codeFailed))
        #expect(!adminEvents.contains { if case .confirmWords = $0 { true } else { false } })
    }

    @Test func eitherOwnerCanSayTheWordsDoNotMatch() throws {
        var (admin, host, _) = codeSessions(typed: "")
        _ = try run(admin: &admin, host: &host, first: admin.start())
        let no = admin.confirm(false)
        guard case .send(let message) = no.first else { Issue.record(); return }
        let hostEvents = try host.receive(message)
        #expect(hostEvents.contains { if case .failed = $0 { true } else { false } })
        #expect(host.state == .failed)
    }

    @Test func aRemovedAdminCannotReEnrolWithTheKey() throws {
        let key = EnrolmentKey.generate(for: adminPrint)
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .enrolmentKey(key), crypto: FakeCrypto.make())
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails,
                                      enrolmentKey: key, code: nil, adminBlocked: true, crypto: FakeCrypto.make(seed: 50))
        let (adminEvents, hostEvents) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(!hostEvents.contains { if case .adminTrusted = $0 { true } else { false } })
        #expect(adminEvents.contains { if case .failed(let why) = $0 { why.contains("removed") } else { false } })
    }

    @Test func theCodeIsCheckedAgainWhenTheProofArrives() throws {
        // Withdrawn between the start and the proof: the held-open session gets nothing.
        var generator = SeededGenerator(state: 11)
        let code = PairingCode(issuedAt: Date(), using: &generator)
        let showing = Showing(code)
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .pairingCode(code.value), crypto: FakeCrypto.make())
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails, enrolmentKey: nil,
                                      currentCode: { showing.code }, crypto: FakeCrypto.make(seed: 50))
        let challenge = try host.receive(admin.start())
        guard case .send(let message)? = challenge.first else { Issue.record(); return }
        let proof = try admin.receive(message)
        showing.code = nil
        guard case .send(let proofMessage)? = proof.first else { Issue.record(); return }
        let answer = try host.receive(proofMessage)
        #expect(!answer.contains { if case .confirmWords = $0 { true } else { false } })
        #expect(answer.contains { if case .close = $0 { true } else { false } })
    }

    @Test func nothingIdentifyingIsSentBeforeAProof() {
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint,
                                        details: PeerDetails(computerName: "admin", model: "Mac15,9", serialNumber: "SECRET",
                                                             macOSVersion: "27.0.1"),
                                        method: .pairingCode("ABCD-EFGH"), crypto: FakeCrypto.make())
        guard case .pairStart(let start) = admin.start() else { Issue.record(); return }
        #expect(start.details.serialNumber == nil && start.details.model == nil)
        #expect(start.details.computerName == "admin")
    }

    final class Showing: @unchecked Sendable {
        var code: PairingCode?
        init(_ code: PairingCode?) { self.code = code }
    }

    @Test func anExpiredCodeIsRefused() throws {
        var generator = SeededGenerator(state: 11)
        let old = PairingCode(issuedAt: Date().addingTimeInterval(-3600), using: &generator)
        var admin = PairingAdminSession(own: adminPrint, host: hostPrint, details: adminDetails,
                                        method: .pairingCode(old.value), crypto: FakeCrypto.make())
        var host = PairingHostSession(own: hostPrint, admin: adminPrint, details: hostDetails,
                                      enrolmentKey: nil, code: old, crypto: FakeCrypto.make(seed: 50))
        let (adminEvents, _) = try run(admin: &admin, host: &host, first: admin.start())
        #expect(adminEvents.contains { if case .failed = $0 { true } else { false } })
    }
}
