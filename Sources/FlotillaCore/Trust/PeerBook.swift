import Foundation

/// What a Mac says about itself when it asks to join — shown to the owner at approval so it can be
/// checked against the inventory (the owner, 7 October). Self-reported, so it informs the decision
/// and never makes it: the fingerprint is the identity.
public struct PeerDetails: Sendable, Hashable, Codable {
    public var computerName: String
    public var model: String?
    public var serialNumber: String?
    public var macOSVersion: String?
    public var address: String?

    public init(computerName: String, model: String? = nil, serialNumber: String? = nil,
                macOSVersion: String? = nil, address: String? = nil) {
        self.computerName = computerName
        self.model = model
        self.serialNumber = serialNumber
        self.macOSVersion = macOSVersion
        self.address = address
    }
}

/// How the admin Mac reaches a host: the name it advertises over Bonjour, or the address the owner
/// typed. A hint for finding it, never its identity — the fingerprint is checked on every connection.
public enum PeerEndpoint: Sendable, Hashable, Codable {
    case bonjour(name: String)
    case address(host: String, port: UInt16)
}

/// One Mac this Mac knows: on the admin Mac, a host; on a host, its admin.
public struct Peer: Sendable, Hashable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable { case admin, host }

    public enum Status: String, Sendable, Codable {
        /// Proved it holds the enrolment key; waiting for the owner. Never trusted in this state.
        case pending
        case approved
        /// Turned away by the owner. Kept so the same key cannot simply ask again.
        case rejected
        /// Was approved, no longer is. Live sessions are closed when this is set (B3).
        case revoked
    }

    public enum Method: String, Sendable, Codable { case enrolmentKey = "enrolment-key", pairingCode = "pairing-code" }

    public let fingerprint: PeerFingerprint
    public var role: Role
    public var status: Status
    public var method: Method
    public var details: PeerDetails
    /// The owner's own name for it, if they gave one; otherwise the computer name is shown.
    public var nickname: String?
    public var requestedAt: Date
    public var decidedAt: Date?
    public var lastSeen: Date?
    /// Admin side: where the host was last reached. Optional so older books still decode.
    public var endpoint: PeerEndpoint?

    public var id: PeerFingerprint { fingerprint }
    public var displayName: String { nickname ?? details.computerName }
    public var isTrusted: Bool { status == .approved }
}

/// Every Mac this one trusts, has turned away, or is waiting on — the trust half of Phase B.
///
/// Content, not configuration, like `TagBook` and `GroupBook`: persisted plist-native by the app
/// (B2b), never through `SettingsStore`, and Foundation-only so the rules are tested on Linux.
/// Keyed by fingerprint; a name or an address is never the key.
public struct PeerBook: Sendable, Equatable, Codable {
    /// An unanswered request lapses after this long (the owner, 7 October: seven days).
    public static let pendingLifetime: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var peers: [Peer] = []

    public init(peers: [Peer] = []) { self.peers = peers }

    public subscript(_ fingerprint: PeerFingerprint) -> Peer? {
        peers.first { $0.fingerprint == fingerprint }
    }

    public func isTrusted(_ fingerprint: PeerFingerprint) -> Bool { self[fingerprint]?.isTrusted == true }

    /// Turned away or removed by the owner. Nothing automatic — an enrolment key above all — may
    /// undo that; only the owner's explicit approval or a code pairing they confirm.
    public func isBlocked(_ fingerprint: PeerFingerprint) -> Bool {
        switch self[fingerprint]?.status {
        case .rejected?, .revoked?: true
        default: false
        }
    }

    public var pending: [Peer] { peers.filter { $0.status == .pending } }
    public var approved: [Peer] { peers.filter { $0.status == .approved } }

    public enum Outcome: Sendable, Equatable {
        case addedPending
        /// Already waiting; the details were refreshed.
        case stillPending
        case alreadyApproved
        /// Turned away or revoked before. It stays out until the owner changes their mind.
        case blocked
    }

    /// A Mac that proved it holds the enrolment key asks to join. It waits for the owner.
    public mutating func requestEnrolment(_ fingerprint: PeerFingerprint, role: Peer.Role, details: PeerDetails,
                                          method: Peer.Method = .enrolmentKey, at now: Date) -> Outcome {
        if let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) {
            switch peers[index].status {
            case .approved:
                peers[index].lastSeen = now
                return .alreadyApproved
            case .rejected, .revoked:
                return .blocked
            case .pending:
                peers[index].details = details
                peers[index].lastSeen = now
                return .stillPending
            }
        }
        peers.append(Peer(fingerprint: fingerprint, role: role, status: .pending, method: method,
                          details: details, nickname: nil, requestedAt: now, decidedAt: nil, lastSeen: now, endpoint: nil))
        return .addedPending
    }

    /// The owner approves a waiting Mac, or re-admits one they turned away or revoked.
    @discardableResult
    public mutating func approve(_ fingerprint: PeerFingerprint, at now: Date) -> Bool {
        set(fingerprint, to: .approved, from: [.pending, .rejected, .revoked], at: now)
    }

    @discardableResult
    public mutating func reject(_ fingerprint: PeerFingerprint, at now: Date) -> Bool {
        set(fingerprint, to: .rejected, from: [.pending], at: now)
    }

    /// A host trusts the admin its enrolment key names — the profile the owner deployed is that
    /// approval — **unless the owner has since removed or turned that admin away** (Iris's review,
    /// 7 October: a removed admin re-enrolled itself at once, because the key still named it).
    /// Returns whether the admin is trusted now.
    @discardableResult
    public mutating func admitByEnrolmentKey(_ fingerprint: PeerFingerprint, details: PeerDetails, at now: Date) -> Bool {
        guard !isBlocked(fingerprint) else { return false }
        pairConfirmed(fingerprint, role: .admin, details: details, method: .enrolmentKey, at: now)
        return true
    }

    /// Takes trust away from an approved Mac. The transport closes its sessions (B3).
    @discardableResult
    public mutating func revoke(_ fingerprint: PeerFingerprint, at now: Date) -> Bool {
        set(fingerprint, to: .revoked, from: [.approved], at: now)
    }

    /// Pairing by one-time code ends with both owners confirming the words on their screens, so a
    /// Mac paired that way is approved directly — the confirmation is the approval.
    public mutating func pairConfirmed(_ fingerprint: PeerFingerprint, role: Peer.Role, details: PeerDetails,
                                       method: Peer.Method = .pairingCode, at now: Date) {
        if let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) {
            peers[index].status = .approved
            peers[index].method = method
            peers[index].details = details
            peers[index].decidedAt = now
            peers[index].lastSeen = now
        } else {
            peers.append(Peer(fingerprint: fingerprint, role: role, status: .approved, method: method,
                              details: details, nickname: nil, requestedAt: now, decidedAt: now, lastSeen: now, endpoint: nil))
        }
    }

    /// Forgets a Mac entirely — so it could ask again from scratch.
    public mutating func remove(_ fingerprint: PeerFingerprint) {
        peers.removeAll { $0.fingerprint == fingerprint }
    }

    /// What a peer says about itself now — its computer name after a rename, its macOS after an
    /// update. The owner's nickname, if any, is left alone. Returns whether anything changed.
    @discardableResult
    public mutating func refresh(_ fingerprint: PeerFingerprint, computerName: String?, macOSVersion: String?) -> Bool {
        guard let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return false }
        var details = peers[index].details
        if let computerName, !computerName.isEmpty { details.computerName = computerName }
        if let macOSVersion, !macOSVersion.isEmpty { details.macOSVersion = macOSVersion }
        guard details != peers[index].details else { return false }
        peers[index].details = details
        return true
    }

    public mutating func rename(_ fingerprint: PeerFingerprint, to nickname: String?) {
        guard let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        peers[index].nickname = trimmed?.isEmpty == false ? trimmed : nil
    }

    public mutating func setEndpoint(_ fingerprint: PeerFingerprint, _ endpoint: PeerEndpoint) {
        guard let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        peers[index].endpoint = endpoint
    }

    public mutating func markSeen(_ fingerprint: PeerFingerprint, at now: Date) {
        guard let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        peers[index].lastSeen = now
    }

    /// Drops requests nobody answered within `pendingLifetime`. Returns what lapsed, for Activity.
    @discardableResult
    public mutating func expirePending(at now: Date) -> [Peer] {
        let lapsed = peers.filter { $0.status == .pending && now.timeIntervalSince($0.requestedAt) >= Self.pendingLifetime }
        peers.removeAll { lapsed.contains($0) }
        return lapsed
    }

    private mutating func set(_ fingerprint: PeerFingerprint, to status: Peer.Status,
                              from allowed: Set<Peer.Status>, at now: Date) -> Bool {
        guard let index = peers.firstIndex(where: { $0.fingerprint == fingerprint }),
              allowed.contains(peers[index].status) else { return false }
        peers[index].status = status
        peers[index].decidedAt = now
        return true
    }
}
