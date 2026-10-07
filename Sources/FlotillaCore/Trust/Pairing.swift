import Foundation

/// The cryptography pairing needs, passed in. FlotillaCore stays Foundation-only and builds on
/// Linux, so the real implementation — CryptoKit's HMAC-SHA256 and SHA-256, the system's random
/// bytes — is the app's (B2b). Here it is a seam, so the protocol's rules are tested on their own.
public struct PairingCrypto: Sendable {
    /// HMAC-SHA256 of `message` under `key`.
    public var mac: @Sendable (_ key: [UInt8], _ message: [UInt8]) -> [UInt8]
    /// SHA-256 of `bytes`.
    public var digest: @Sendable (_ bytes: [UInt8]) -> [UInt8]
    /// Fresh random bytes.
    public var random: @Sendable (_ count: Int) -> [UInt8]

    public init(mac: @escaping @Sendable ([UInt8], [UInt8]) -> [UInt8],
                digest: @escaping @Sendable ([UInt8]) -> [UInt8],
                random: @escaping @Sendable (Int) -> [UInt8]) {
        self.mac = mac
        self.digest = digest
        self.random = random
    }
}

/// What both sides compute and compare. Everything that identifies this exchange is in it — both
/// TLS fingerprints **as each side saw them**, both nonces, and which side is proving — so a proof
/// cannot be replayed, reflected back, or carried across a machine in the middle: that machine
/// presents its own key to each side, the fingerprints differ, and the proofs do not verify.
enum PairingTranscript {
    static let nonceBytes = 32

    static func bytes(label: String, admin: PeerFingerprint, host: PeerFingerprint,
                      adminNonce: Data, hostNonce: Data) -> [UInt8] {
        Array(("flotilla-pair-v1/" + label).utf8) + admin.bytes + host.bytes + Array(adminNonce) + Array(hostNonce)
    }

    /// The words both screens show: from a digest of both fingerprints, sorted so each side gets
    /// the same digest whichever it is.
    static func words(_ a: PeerFingerprint, _ b: PeerFingerprint, crypto: PairingCrypto) -> [String] {
        let sorted = [a.bytes, b.bytes].sorted { $0.lexicographicallyPrecedes($1) }
        return FingerprintWords.words(for: crypto.digest(Array("flotilla-words-v1".utf8) + sorted[0] + sorted[1]))
    }

    /// Constant time, so how long a wrong proof takes to refuse says nothing about how wrong it was.
    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The admin Mac's side of pairing with one host, on a TLS connection whose host key it has
/// observed but not yet trusted.
///
/// **Enrolment key**: the admin opens; the host answers with a proof keyed by the key's secret; if
/// it verifies, the host goes into the owner's approval list (`PeerBook.requestEnrolment`) and is
/// told whether it is pending, approved or blocked. The host trusts the admin because the key named
/// it, so no proof is needed that way.
///
/// **Pairing code**: the admin opens; the host sends a nonce; the admin proves it knows the code;
/// the host proves it back; both show the same words, and pairing completes only when both owners
/// have confirmed them.
public struct PairingAdminSession: Sendable {
    public enum Method: Sendable, Equatable {
        case enrolmentKey(EnrolmentKey)
        /// What the owner typed; normalised before use.
        case pairingCode(String)
    }

    public enum Event: Sendable, Equatable {
        case send(WireMessage)
        /// Enrolment: the host proved it holds the key. Record it with `PeerBook.requestEnrolment`
        /// and pass the outcome to `finishEnrolment`.
        case enrolmentRequested(PeerFingerprint, PeerDetails)
        /// Code pairing: show these to the owner and ask them to compare.
        case confirmWords([String], PeerDetails)
        /// Code pairing: both owners confirmed. Record it with `PeerBook.pairConfirmed`.
        case paired(PeerFingerprint, PeerDetails)
        case failed(String)
    }

    public enum State: Sendable, Equatable {
        case idle, awaitingProof, awaitingChallenge, awaitingHostProof, confirming, done, failed
    }

    public private(set) var state: State = .idle
    public let own: PeerFingerprint
    public let host: PeerFingerprint
    let details: PeerDetails
    let method: Method
    let crypto: PairingCrypto
    var adminNonce = Data()
    var hostNonce = Data()
    var hostDetails: PeerDetails?
    var localConfirmed = false
    var remoteConfirmed = false

    public init(own: PeerFingerprint, host: PeerFingerprint, details: PeerDetails, method: Method, crypto: PairingCrypto) {
        self.own = own
        self.host = host
        self.details = details
        self.method = method
        self.crypto = crypto
    }

    public mutating func start() -> WireMessage {
        adminNonce = Data(crypto.random(PairingTranscript.nonceBytes))
        switch method {
        case .enrolmentKey:
            state = .awaitingProof
            return .pairStart(.init(method: .enrolmentKey, nonce: adminNonce, details: details))
        case .pairingCode:
            state = .awaitingChallenge
            return .pairStart(.init(method: .pairingCode, nonce: adminNonce, details: details))
        }
    }

    public mutating func receive(_ message: WireMessage) throws -> [Event] {
        switch (state, message, method) {
        case (_, .pairResult(let result), _) where result.outcome == .refused || result.outcome == .blocked:
            state = .failed
            return [.failed(result.message)]

        case (.awaitingProof, .pairProof(let proof), .enrolmentKey(let key)):
            guard let nonce = proof.nonce, nonce.count == PairingTranscript.nonceBytes,
                  let hostDetails = proof.details else { throw WireError.malformedHeader(.pairProof) }
            hostNonce = nonce
            let expected = crypto.mac(key.secret, PairingTranscript.bytes(label: "enrol-host", admin: own, host: host,
                                                                          adminNonce: adminNonce, hostNonce: hostNonce))
            guard PairingTranscript.equal(expected, Array(proof.mac)) else {
                state = .failed
                return [.send(.pairResult(.init(outcome: .refused, message: "That proof doesn't match this admin's enrolment key."))),
                        .failed("The Mac didn't prove it holds the enrolment key.")]
            }
            self.hostDetails = hostDetails
            return [.enrolmentRequested(host, hostDetails)]

        case (.awaitingChallenge, .pairChallenge(let challenge), .pairingCode(let typed)):
            guard challenge.nonce.count == PairingTranscript.nonceBytes else { throw WireError.malformedHeader(.pairChallenge) }
            hostNonce = challenge.nonce
            state = .awaitingHostProof
            let mac = crypto.mac(Array(PairingCode.normalise(typed).utf8),
                                 PairingTranscript.bytes(label: "code-admin", admin: own, host: host,
                                                         adminNonce: adminNonce, hostNonce: hostNonce))
            return [.send(.pairProof(.init(mac: Data(mac))))]

        case (.awaitingHostProof, .pairProof(let proof), .pairingCode(let typed)):
            guard let hostDetails = proof.details else { throw WireError.malformedHeader(.pairProof) }
            let expected = crypto.mac(Array(PairingCode.normalise(typed).utf8),
                                      PairingTranscript.bytes(label: "code-host", admin: own, host: host,
                                                              adminNonce: adminNonce, hostNonce: hostNonce))
            guard PairingTranscript.equal(expected, Array(proof.mac)) else {
                state = .failed
                return [.failed("The other Mac couldn't prove it showed that code.")]
            }
            self.hostDetails = hostDetails
            state = .confirming
            return [.confirmWords(PairingTranscript.words(own, host, crypto: crypto), hostDetails)]

        case (.confirming, .pairConfirm(let confirm), _):
            guard confirm.confirmed else {
                state = .failed
                return [.failed("The owner of the other Mac said the words don't match.")]
            }
            remoteConfirmed = true
            return completeIfConfirmed()

        default:
            throw WireError.unexpected(message.frameType)
        }
    }

    /// Enrolment: what the owner's approval list made of the request, sent back to the host.
    public mutating func finishEnrolment(_ outcome: PeerBook.Outcome) -> WireMessage {
        state = outcome == .blocked ? .failed : .done
        switch outcome {
        case .addedPending, .stillPending:
            return .pairResult(.init(outcome: .pending, message: "Waiting for the owner to approve this Mac."))
        case .alreadyApproved:
            return .pairResult(.init(outcome: .approved, message: "This Mac is already approved."))
        case .blocked:
            return .pairResult(.init(outcome: .blocked, message: "The owner turned this Mac away."))
        }
    }

    /// Code pairing: this side's owner compared the words.
    public mutating func confirm(_ confirmed: Bool) -> [Event] {
        guard state == .confirming else { return [] }
        guard confirmed else {
            state = .failed
            return [.send(.pairConfirm(.init(confirmed: false))), .failed("You said the words don't match.")]
        }
        localConfirmed = true
        return [.send(.pairConfirm(.init(confirmed: true)))] + completeIfConfirmed()
    }

    private mutating func completeIfConfirmed() -> [Event] {
        guard localConfirmed, remoteConfirmed, let hostDetails else { return [] }
        state = .done
        return [.paired(host, hostDetails)]
    }
}

/// The host's side of pairing, for a connection from a Mac it does not yet trust.
public struct PairingHostSession: Sendable {
    public enum Event: Sendable, Equatable {
        case send(WireMessage)
        /// Enrolment: the key named this admin. Trust it (`PeerBook.pairConfirmed` as `.admin`, or
        /// the enrolment equivalent) — the owner's profile chose it.
        case adminTrusted(PeerFingerprint, PeerDetails)
        /// Enrolment: the admin's answer — pending approval, approved, or blocked.
        case enrolmentAnswered(WireMessage.PairOutcome, String)
        /// Code pairing: a wrong proof. The app counts it against the code.
        case codeFailed
        case confirmWords([String], PeerDetails)
        case paired(PeerFingerprint, PeerDetails)
        case failed(String)
        case close(String)
    }

    public enum State: Sendable, Equatable {
        case idle, awaitingResult, awaitingAdminProof, confirming, done, failed
    }

    public private(set) var state: State = .idle
    public let own: PeerFingerprint
    public let admin: PeerFingerprint
    let details: PeerDetails
    /// The key from this host's configuration profile, if it has one.
    let enrolmentKey: EnrolmentKey?
    /// The code on this host's screen, if the owner asked for one and it is still usable.
    let code: PairingCode?
    let crypto: PairingCrypto
    var adminNonce = Data()
    var hostNonce = Data()
    var adminDetails: PeerDetails?
    var localConfirmed = false
    var remoteConfirmed = false

    public init(own: PeerFingerprint, admin: PeerFingerprint, details: PeerDetails,
                enrolmentKey: EnrolmentKey?, code: PairingCode?, crypto: PairingCrypto) {
        self.own = own
        self.admin = admin
        self.details = details
        self.enrolmentKey = enrolmentKey
        self.code = code
        self.crypto = crypto
    }

    public mutating func receive(_ message: WireMessage, at now: Date = Date()) throws -> [Event] {
        switch (state, message) {
        case (.idle, .pairStart(let start)):
            guard start.nonce.count == PairingTranscript.nonceBytes else { throw WireError.malformedHeader(.pairStart) }
            adminNonce = start.nonce
            adminDetails = start.details
            hostNonce = Data(crypto.random(PairingTranscript.nonceBytes))
            switch start.method {
            case .enrolmentKey:
                // Only the admin the profile named. Any other Mac that found this one is refused
                // before anything about it is believed.
                guard let key = enrolmentKey, key.names(admin) else {
                    return refuse("This Mac wasn't set up to enrol with that admin Mac.")
                }
                state = .awaitingResult
                let mac = crypto.mac(key.secret, PairingTranscript.bytes(label: "enrol-host", admin: admin, host: own,
                                                                         adminNonce: adminNonce, hostNonce: hostNonce))
                return [.adminTrusted(admin, start.details),
                        .send(.pairProof(.init(mac: Data(mac), nonce: hostNonce, details: details)))]
            case .pairingCode:
                guard let code, code.isUsable(at: now) else {
                    return refuse("This Mac isn't showing a pairing code. Ask for a new one on this Mac.")
                }
                state = .awaitingAdminProof
                return [.send(.pairChallenge(.init(nonce: hostNonce)))]
            }

        case (.awaitingResult, .pairResult(let result)):
            state = result.outcome == .blocked || result.outcome == .refused ? .failed : .done
            return [.enrolmentAnswered(result.outcome, result.message)]

        case (.awaitingAdminProof, .pairProof(let proof)):
            guard let code else { return refuse("The pairing code is gone.") }
            let expected = crypto.mac(code.keyBytes, PairingTranscript.bytes(label: "code-admin", admin: admin, host: own,
                                                                             adminNonce: adminNonce, hostNonce: hostNonce))
            guard PairingTranscript.equal(expected, Array(proof.mac)) else {
                return [.codeFailed] + refuse("That isn't the code this Mac is showing.")
            }
            state = .confirming
            let mac = crypto.mac(code.keyBytes, PairingTranscript.bytes(label: "code-host", admin: admin, host: own,
                                                                        adminNonce: adminNonce, hostNonce: hostNonce))
            return [.send(.pairProof(.init(mac: Data(mac), details: details))),
                    .confirmWords(PairingTranscript.words(own, admin, crypto: crypto), adminDetails ?? PeerDetails(computerName: "?"))]

        case (.confirming, .pairConfirm(let confirm)):
            guard confirm.confirmed else {
                state = .failed
                return [.failed("The owner of the admin Mac said the words don't match."), .close("words did not match")]
            }
            remoteConfirmed = true
            return completeIfConfirmed()

        default:
            throw WireError.unexpected(message.frameType)
        }
    }

    public mutating func confirm(_ confirmed: Bool) -> [Event] {
        guard state == .confirming else { return [] }
        guard confirmed else {
            state = .failed
            return [.send(.pairConfirm(.init(confirmed: false))), .failed("You said the words don't match."),
                    .close("words did not match")]
        }
        localConfirmed = true
        return [.send(.pairConfirm(.init(confirmed: true)))] + completeIfConfirmed()
    }

    private mutating func completeIfConfirmed() -> [Event] {
        guard localConfirmed, remoteConfirmed else { return [] }
        state = .done
        return [.paired(admin, adminDetails ?? PeerDetails(computerName: "?"))]
    }

    private mutating func refuse(_ message: String) -> [Event] {
        state = .failed
        return [.send(.pairResult(.init(outcome: .refused, message: message))), .failed(message), .close(message)]
    }
}
