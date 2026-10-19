import Foundation

/// Decides when a change in the network path is worth reconnecting every host for (13 October: Good
/// Morning switched Tailscale on, and the mini stayed "not answering" until Refresh).
///
/// `NWPathMonitor` reports far more often than the network changes — every update repeats the
/// path — so only a different set of interfaces or gateways counts, and only once there is a
/// usable path to reconnect over. The first report is the baseline, not a change.
public struct NetworkChangeFilter: Sendable, Equatable {
    private var last: Set<String>?
    private var lastSatisfied = false

    public init() {}

    /// `signature` is whatever identifies the path: interface names and gateways.
    /// Returns whether to reconnect now.
    public mutating func observe(satisfied: Bool, signature: [String]) -> Bool {
        let now = Set(signature)
        defer { last = now; lastSatisfied = satisfied }
        guard let last else { return false }
        guard satisfied else { return false }
        return now != last || !lastSatisfied
    }
}

/// What the admin makes of a host that has been sent a Flotilla update (Q38), from what the host
/// itself says.
///
/// The admin cannot hear a host while it relaunches, and on 13 October it called an update failed
/// at four minutes although the host had been running the new build for seven: a silent host is
/// not a failed update. The verdict comes from the host's own answer — the build it reports — and
/// from silence only when it has lasted far longer than any relaunch.
public struct UpdateWatch: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The host reports the new build (or a newer one).
        case confirmed
        /// Installed as far as anyone can tell, not confirmed yet. Not a failure.
        case waiting(Waiting)
        case failed(String)
    }
    public enum Waiting: Sendable, Equatable {
        /// Not answering — usually the relaunch, or a network that has not come back.
        case silent
        /// Answering on the old build, still within the time the relaunch may take.
        case stillOldBuild
    }

    public let target: Int
    public let startedAt: Date
    public private(set) var lastAnswered: Date
    /// How long the old build may go on answering after the update was sent: the host replies,
    /// then relaunches a moment later.
    public let oldBuildGrace: TimeInterval
    /// How long silence may last before the update is called lost.
    public let silenceLimit: TimeInterval

    public init(target: Int, startedAt: Date, oldBuildGrace: TimeInterval = 120, silenceLimit: TimeInterval = 1800) {
        self.target = target
        self.startedAt = startedAt
        self.lastAnswered = startedAt
        self.oldBuildGrace = oldBuildGrace
        self.silenceLimit = silenceLimit
    }

    /// One look at the host. `answered` is whether this attempt heard from its Flotilla at all;
    /// `build` is the build it reported, if it did.
    public mutating func observe(answered: Bool, build: Int?, at now: Date) -> Verdict {
        guard answered else {
            if now.timeIntervalSince(lastAnswered) > silenceLimit {
                return .failed("It installed the update but has been silent for \(Int(silenceLimit / 60)) minutes, "
                               + "so Flotilla can't confirm build \(target).")
            }
            return .waiting(.silent)
        }
        lastAnswered = now
        guard let build else { return .waiting(.stillOldBuild) }
        if build >= target { return .confirmed }
        if now.timeIntervalSince(startedAt) > oldBuildGrace {
            return .failed("It answered on build \(build), not build \(target), so the update didn't take.")
        }
        return .waiting(.stillOldBuild)
    }
}
