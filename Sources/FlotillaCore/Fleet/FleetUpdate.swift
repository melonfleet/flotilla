import Foundation

/// Updating the fleet from the admin Mac (PLAN.md Phase E; DECISIONS Q38). Pure, so the rules are
/// tested without a fleet.
public enum FleetUpdate {
    /// The build number in an app version as hosts report it — `0.0.0 (312)` → 312 — or `nil`.
    /// The build number is a commit count (make-app.sh), so it only ever goes up.
    public static func build(of appVersion: String?) -> Int? {
        guard let appVersion, let open = appVersion.lastIndex(of: "("), let close = appVersion.lastIndex(of: ")"),
              open < close else { return nil }
        return Int(appVersion[appVersion.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    /// Where a host stands against the admin's build.
    public enum Standing: Sendable, Equatable {
        case current
        case behind(Int)
        /// Newer than the admin: never "updated" backwards.
        case ahead(Int)
        case unknown
    }

    public static func standing(host: Int?, admin: Int?) -> Standing {
        guard let host, let admin else { return .unknown }
        if host == admin { return .current }
        return host < admin ? .behind(host) : .ahead(host)
    }

    /// One host, as the rolling update sees it.
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var name: String
        public var build: Int?
        public var connected: Bool
        /// The host's wire version allows updates from here.
        public var canReceive: Bool
        /// The admin build this host last failed to update to, if any — never retried automatically.
        public var failedBuild: Int?

        public init(id: String, name: String, build: Int?, connected: Bool, canReceive: Bool, failedBuild: Int? = nil) {
            self.id = id; self.name = name; self.build = build; self.connected = connected
            self.canReceive = canReceive; self.failedBuild = failedBuild
        }
    }

    /// The next host a rolling update should take, or `nil` when none is due: connected, able to
    /// receive, behind the admin, and not already failed on this build. Oldest first, then by name,
    /// so the order is the same every time.
    public static func next(_ candidates: [Candidate], admin: Int) -> Candidate? {
        candidates
            .filter { $0.connected && $0.canReceive && $0.failedBuild != admin }
            .filter { if case .behind = standing(host: $0.build, admin: admin) { true } else { false } }
            .sorted { ($0.build ?? 0, $0.name) < ($1.build ?? 0, $1.name) }
            .first
    }
}
