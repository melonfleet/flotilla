import Foundation

/// Waiting for a group member to be ready before the next one starts (Q21 amended, 6 October).
///
/// Pure and injectable — the clock, the sleep, the "still running?" question and the port probe
/// are all passed in — so the rule is tested without a network or a runtime. The app supplies a
/// real TCP connect (`TCPProbe`) and the live container list.
///
/// **Ready means the port accepts a TCP connection.** That is the right signal for the stacks it
/// exists for: the official Postgres, MySQL and MariaDB images run their first-start setup with
/// networking off and only listen on TCP once it is done.
public enum Readiness {
    public enum Outcome: Equatable, Sendable {
        case ready
        /// The time limit passed with the port still closed.
        case timedOut
        /// The container stopped while we waited — its own logs say why.
        case stopped
    }

    /// Long enough for a database's first start on a laptop (MariaDB's first initialisation takes
    /// tens of seconds); short enough that a service that will never answer is reported.
    public static let defaultTimeout: TimeInterval = 120
    public static let pollInterval: TimeInterval = 1

    /// The address the Mac reaches a container at: its first network's IPv4 without the prefix
    /// length (`192.168.70.4/24` → `192.168.70.4`). Measured 6 October: the Mac connects to a
    /// container's port this way on a custom network, published or not.
    public static func address(fromIPv4 cidr: String?) -> String? {
        guard let cidr, let host = cidr.split(separator: "/").first, !host.isEmpty else { return nil }
        return String(host)
    }

    /// Polls until the port answers, the container stops, or `timeout` passes. Probes once more
    /// after the deadline's last sleep, so a port that opens in the final interval is not missed.
    ///
    /// Runs on the caller's actor (`#isolation`), so the app's closures may read main-actor state.
    public static func wait(isolation: isolated (any Actor)? = #isolation,
                            timeout: TimeInterval = defaultTimeout,
                            interval: TimeInterval = pollInterval,
                            now: () -> Date = Date.init,
                            sleep: (TimeInterval) async -> Void,
                            isRunning: () async -> Bool,
                            probe: () async -> Bool) async -> Outcome {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if await probe() { return .ready }
            if !(await isRunning()) { return .stopped }
            if now() >= deadline { return .timedOut }
            await sleep(interval)
        }
    }
}
