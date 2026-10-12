import Foundation

// Restart policies and health checks (DECISIONS Q53, the owner, 12 October).
//
// `container` 1.5 has neither, and doesn't report a container's exit code: a container that
// exited with 3 shows only `"state": "stopped"`. So Flotilla can't tell a crash from a clean exit,
// and the only restart policy it can honestly offer is "restart if it stops unexpectedly" — any
// stop Flotilla didn't make. The Mac that runs the container runs its policy, so it carries on
// while an admin is away.
//
// This file is the policy and the decisions, with no clock and no I/O of its own: the app feeds it
// what it sees and does what it says, so every rule here is tested on its own.

/// What Flotilla does for one container, kept by the Mac that runs it.
public struct ContainerPolicy: Codable, Sendable, Equatable {
    public enum Restart: String, Codable, Sendable, CaseIterable {
        /// Flotilla leaves it alone. The default.
        case never
        /// Started again whenever it stops, unless the stop was made in Flotilla.
        case unlessStopped

        public var title: String {
            switch self {
            case .never: "Never"
            case .unlessStopped: "If it stops unexpectedly"
            }
        }
    }

    public var restart: Restart
    public var health: HealthCheck?
    /// Restart when the health check says unhealthy. Off by default: unhealthy is a notice first.
    public var restartWhenUnhealthy: Bool

    public init(restart: Restart = .never, health: HealthCheck? = nil, restartWhenUnhealthy: Bool = false) {
        self.restart = restart
        self.health = health
        self.restartWhenUnhealthy = restartWhenUnhealthy
    }

    /// Nothing to do: no restart policy and no health check.
    public var isEmpty: Bool { restart == .never && health == nil }

    /// Why this policy can't be kept, or nil.
    public var problem: String? { health?.problem }
}

/// How Flotilla checks a container is doing its job.
public struct HealthCheck: Codable, Sendable, Equatable {
    public enum Probe: Codable, Sendable, Equatable {
        /// A connection to this published host port is accepted.
        case port(Int)
        /// `GET http://127.0.0.1:<port><path>` returns 2xx or 3xx. Only the container's own published
        /// port and a path: never a URL, so a check can't be pointed at another machine.
        case http(port: Int, path: String)
        /// This argv, run in the container through the allowlisted `exec`, exits 0. Never a shell
        /// string: `sh -c …` must be written as such, and is then the owner's own choice.
        case command([String])

        public var title: String {
            switch self {
            case .port(let port): "Port \(port) answers"
            case .http(let port, let path): "HTTP \(path) on \(port) returns OK"
            case .command(let argv): "\(argv.joined(separator: " ")) succeeds"
            }
        }
    }

    public var probe: Probe
    /// Seconds between checks.
    public var interval: Int
    /// Seconds one check may take.
    public var timeout: Int
    /// Failures in a row before it counts as unhealthy.
    public var retries: Int
    /// Seconds after a start before a failure counts.
    public var startPeriod: Int

    public init(probe: Probe, interval: Int = 30, timeout: Int = 5, retries: Int = 3, startPeriod: Int = 30) {
        self.probe = probe
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
    }

    public static let intervals = 5...3600
    public static let timeouts = 1...60
    public static let retryCounts = 1...10
    public static let startPeriods = 0...600
    /// The interactive-exec grammar's own limit (`Allowlist.interactiveExec`).
    public static let maxCommandTokens = 8
    public static let maxPathLength = 256

    /// Why this check can't be run, or nil. The bounds keep a check from becoming load: a probe
    /// every second, or a command that may run a minute every five seconds, is not a health check.
    public var problem: String? {
        guard Self.intervals.contains(interval) else { return "The interval is 5 seconds to an hour." }
        guard Self.timeouts.contains(timeout) else { return "The timeout is 1 to 60 seconds." }
        guard timeout < interval else { return "The timeout must be shorter than the interval." }
        guard Self.retryCounts.contains(retries) else { return "Retries are 1 to 10." }
        guard Self.startPeriods.contains(startPeriod) else { return "The start period is up to 10 minutes." }
        switch probe {
        case .port(let port):
            return (1...65535).contains(port) ? nil : "A port is 1 to 65535."
        case .http(let port, let path):
            guard (1...65535).contains(port) else { return "A port is 1 to 65535." }
            guard path.hasPrefix("/"), path.count <= Self.maxPathLength else {
                return "The path starts with / and is at most \(Self.maxPathLength) characters."
            }
            // A path, not a URL in disguise: no scheme, no host, nothing that isn't printable.
            guard !path.contains("://"), !path.hasPrefix("//"),
                  path.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
                return "The path can't contain spaces, control characters or another address."
            }
            return nil
        case .command(let argv):
            guard !argv.isEmpty, argv.count <= Self.maxCommandTokens else {
                return "The command is 1 to \(Self.maxCommandTokens) words."
            }
            guard argv.allSatisfy({ !$0.isEmpty && !$0.contains("\u{0}") }) else {
                return "A word of the command is empty or contains a null."
            }
            return nil
        }
    }
}

/// One thing Flotilla did or saw for a container, and why: its page's history.
public struct PolicyEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case restarted, restartFailed, gaveUp, unhealthy, healthy, deliberateStop
    }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var detail: String

    public init(date: Date, kind: Kind, detail: String) {
        self.id = UUID(); self.date = date; self.kind = kind; self.detail = detail
    }
}

/// The decisions: what to restart, when to check, when to raise a notice. Pure; the caller owns
/// the clock and the I/O.
public struct PolicyEngine: Sendable {
    /// The waits before each restart in a run of them.
    public static let backoff: [TimeInterval] = [0, 10, 30, 60, 120, 300]
    /// Restarts within `window` before Flotilla stops trying.
    public static let maxRestarts = 5
    public static let window: TimeInterval = 600
    /// Running this long after a restart resets the count.
    public static let stableAfter: TimeInterval = 600
    public static let historyLimit = 50

    public enum Health: String, Codable, Sendable { case unknown, starting, healthy, unhealthy }

    /// What the engine knows about one container.
    public struct Watch: Codable, Sendable, Equatable {
        public var running = false
        /// Flotilla stopped it on purpose; cleared when it runs again.
        public var stoppedDeliberately = false
        public var startedAt: Date?
        public var restarts: [Date] = []
        public var nextRestartAt: Date?
        public var gaveUp = false
        public var health: Health = .unknown
        public var failuresInARow = 0
        public var nextProbeAt: Date?
        public var probing = false
        public var lastProbe: Date?
        public var lastProbeDetail: String?
        public var history: [PolicyEvent] = []
    }

    public enum Action: Equatable, Sendable {
        case restart(String)
        case probe(String, HealthCheck.Probe, timeout: Int)
        /// A notice for this container's state changed: the app reconciles its notices.
        case changed(String)
    }

    public private(set) var watches: [String: Watch] = [:]

    public init(watches: [String: Watch] = [:]) { self.watches = watches }

    // MARK: What the app tells it

    /// Flotilla is about to stop it on purpose: that stop is not one to undo.
    public mutating func noteDeliberateStop(_ id: String, at now: Date) {
        var watch = watches[id] ?? Watch()
        watch.stoppedDeliberately = true
        watch.nextRestartAt = nil
        log(&watch, .deliberateStop, "Stopped in Flotilla", at: now)
        watches[id] = watch
    }

    /// A container's state as the latest list shows it. Returns what to do now.
    public mutating func observe(_ id: String, running: Bool, policy: ContainerPolicy, at now: Date) -> [Action] {
        var watch = watches[id] ?? Watch()
        defer { watches[id] = watch }
        let was = watch.running
        watch.running = running
        if running {
            if !was {
                watch.startedAt = now
                watch.stoppedDeliberately = false
                watch.nextRestartAt = nil
                if let health = policy.health {
                    watch.health = .starting
                    watch.failuresInARow = 0
                    watch.nextProbeAt = now.addingTimeInterval(TimeInterval(health.startPeriod))
                }
            }
            // Ten minutes up: the run of restarts is over.
            if let started = watch.startedAt, now.timeIntervalSince(started) >= Self.stableAfter, !watch.restarts.isEmpty {
                watch.restarts.removeAll()
                if watch.gaveUp { watch.gaveUp = false; return [.changed(id)] }
            }
            if policy.health == nil, watch.health != .unknown {
                watch.health = .unknown
                return [.changed(id)]
            }
            return []
        }
        // Not running.
        watch.health = policy.health == nil ? .unknown : watch.health
        watch.nextProbeAt = nil
        guard policy.restart == .unlessStopped, !watch.stoppedDeliberately, !watch.gaveUp else { return [] }
        if watch.nextRestartAt == nil {
            watch.restarts.removeAll { now.timeIntervalSince($0) > Self.window }
            guard watch.restarts.count < Self.maxRestarts else {
                watch.gaveUp = true
                log(&watch, .gaveUp, "Stopped \(Self.maxRestarts) times in \(Int(Self.window / 60)) minutes; not restarting it again", at: now)
                return [.changed(id)]
            }
            let wait = Self.backoff[min(watch.restarts.count, Self.backoff.count - 1)]
            watch.nextRestartAt = now.addingTimeInterval(wait)
        }
        return due(&watch, id, policy: policy, at: now)
    }

    /// Scheduled work that has come due — restarts and checks. Call every few seconds.
    public mutating func tick(policies: [String: ContainerPolicy], at now: Date) -> [Action] {
        var actions: [Action] = []
        for id in watches.keys.sorted() {
            guard var watch = watches[id], let policy = policies[id] else { continue }
            actions += due(&watch, id, policy: policy, at: now)
            watches[id] = watch
        }
        return actions
    }

    /// What became of a restart Flotilla tried.
    public mutating func restartFinished(_ id: String, error: String?, at now: Date) {
        guard var watch = watches[id] else { return }
        if let error {
            log(&watch, .restartFailed, error, at: now)
        } else {
            log(&watch, .restarted, "Stopped unexpectedly; started again", at: now)
        }
        watches[id] = watch
    }

    /// What a health check found. Returns what to do now.
    public mutating func probeFinished(_ id: String, ok: Bool, detail: String, policy: ContainerPolicy, at now: Date) -> [Action] {
        guard var watch = watches[id], let health = policy.health else { return [] }
        defer { watches[id] = watch }
        watch.probing = false
        watch.lastProbe = now
        watch.lastProbeDetail = detail
        guard watch.running else { return [] }
        watch.nextProbeAt = now.addingTimeInterval(TimeInterval(health.interval))
        if ok {
            watch.failuresInARow = 0
            guard watch.health != .healthy else { return [] }
            let wasUnhealthy = watch.health == .unhealthy
            watch.health = .healthy
            if wasUnhealthy { log(&watch, .healthy, detail, at: now) }
            return [.changed(id)]
        }
        // A failure inside the start period doesn't count: the service may still be starting.
        if let started = watch.startedAt, now.timeIntervalSince(started) < TimeInterval(health.startPeriod) { return [] }
        watch.failuresInARow += 1
        guard watch.failuresInARow >= health.retries, watch.health != .unhealthy else { return [] }
        watch.health = .unhealthy
        log(&watch, .unhealthy, detail, at: now)
        var actions: [Action] = [.changed(id)]
        if policy.restartWhenUnhealthy, !watch.gaveUp {
            watch.restarts.removeAll { now.timeIntervalSince($0) > Self.window }
            if watch.restarts.count < Self.maxRestarts {
                watch.restarts.append(now)
                actions.append(.restart(id))
            } else {
                watch.gaveUp = true
                log(&watch, .gaveUp, "Unhealthy and restarted \(Self.maxRestarts) times in \(Int(Self.window / 60)) minutes; not restarting it again", at: now)
            }
        }
        return actions
    }

    /// A container that is gone, or whose policy was removed.
    public mutating func forget(_ id: String) { watches[id] = nil }

    /// Starting again by hand clears a "gave up".
    public mutating func clearGaveUp(_ id: String) {
        watches[id]?.gaveUp = false
        watches[id]?.restarts.removeAll()
    }

    // MARK: Inside

    private func due(_ watch: inout Watch, _ id: String, policy: ContainerPolicy, at now: Date) -> [Action] {
        var actions: [Action] = []
        if !watch.running, let at = watch.nextRestartAt, now >= at, policy.restart == .unlessStopped,
           !watch.stoppedDeliberately, !watch.gaveUp {
            watch.nextRestartAt = nil
            watch.restarts.append(now)
            actions.append(.restart(id))
        }
        if watch.running, let health = policy.health, !watch.probing, let at = watch.nextProbeAt, now >= at {
            watch.probing = true
            actions.append(.probe(id, health.probe, timeout: health.timeout))
        }
        return actions
    }

    private func log(_ watch: inout Watch, _ kind: PolicyEvent.Kind, _ detail: String, at now: Date) {
        watch.history.insert(PolicyEvent(date: now, kind: kind, detail: detail), at: 0)
        if watch.history.count > Self.historyLimit { watch.history.removeLast(watch.history.count - Self.historyLimit) }
    }
}
