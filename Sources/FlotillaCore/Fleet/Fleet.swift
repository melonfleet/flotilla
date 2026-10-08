import Foundation

/// Which Mac something lives on (PLAN.md Phase C): this one, or a paired host, named by its key —
/// never by its name, which can change, and two Macs can share.
public enum HostRef: Sendable, Hashable, Codable, CustomStringConvertible {
    case local
    case peer(PeerFingerprint)

    public var isLocal: Bool { self == .local }

    /// A short, stable token for building row identities: `local`, or the key's first 16 hex
    /// characters. Two hosts' containers called `web` therefore never share a row id.
    public var token: String {
        switch self {
        case .local: "local"
        case .peer(let fingerprint): String(fingerprint.hex.prefix(16))
        }
    }

    public var description: String { token }

    /// A row id for `name` on this host. This Mac's rows keep the bare name, so everything that
    /// already keys on it — selection, tags, the activity feed — is unchanged.
    public func rowID(_ name: String) -> String {
        isLocal ? name : "\(token)/\(name)"
    }
}

/// The last answer a host gave for one kind of list, kept when later asks fail — so a host that
/// drops shows what it last had, marked with its age, rather than an empty table that reads as
/// "nothing there" (PLAN.md Phase C).
public struct FleetSnapshot<Item: Sendable>: Sendable {
    public private(set) var items: [Item]
    /// When `items` was fetched; `nil` before the first success.
    public private(set) var fetchedAt: Date?
    /// The most recent failure, cleared by the next success.
    public private(set) var lastError: String?
    public private(set) var lastAttempt: Date?

    public init() {
        items = []
    }

    public mutating func succeeded(_ items: [Item], at now: Date) {
        self.items = items
        fetchedAt = now
        lastAttempt = now
        lastError = nil
    }

    /// Keeps the previous items: they are the best answer there is.
    public mutating func failed(_ error: String, at now: Date) {
        lastError = error
        lastAttempt = now
    }

    /// Whether what is shown is older than a fresh answer would be — a failure since, or an age
    /// past `freshFor`.
    public func isStale(at now: Date, freshFor: TimeInterval) -> Bool {
        guard let fetchedAt else { return lastAttempt != nil }
        return lastError != nil || now.timeIntervalSince(fetchedAt) > freshFor
    }

    /// "12 seconds ago", for the stale marker. `nil` before the first success.
    public func age(at now: Date) -> TimeInterval? {
        fetchedAt.map { now.timeIntervalSince($0) }
    }
}

/// How often to ask a host: the normal interval while it answers, doubling after each failure up
/// to a ceiling, and back to normal at the first answer (PLAN.md Phase C: back off unreachable
/// hosts). A Mac that is asleep or off the network costs a connection attempt every few minutes,
/// not every few seconds.
public struct HostBackoff: Sendable, Equatable {
    public let base: TimeInterval
    public let ceiling: TimeInterval
    public private(set) var failures = 0
    public private(set) var nextAttempt: Date?

    public init(base: TimeInterval = 30, ceiling: TimeInterval = 300) {
        self.base = base
        self.ceiling = ceiling
    }

    public var interval: TimeInterval {
        guard failures > 0 else { return base }
        return min(ceiling, base * pow(2, Double(min(failures, 16))))
    }

    public func isDue(at now: Date) -> Bool { nextAttempt.map { now >= $0 } ?? true }

    public mutating func succeeded(at now: Date) {
        failures = 0
        nextAttempt = now.addingTimeInterval(base)
    }

    public mutating func failed(at now: Date) {
        failures += 1
        nextAttempt = now.addingTimeInterval(interval)
    }

    /// Ask now, whatever the schedule says — the owner pressed Refresh.
    public mutating func forceDue() { nextAttempt = nil }
}
