import Foundation
import Network
import FlotillaCore
import FlotillaTrust

/// A paired host as a `ContainerHost` (PLAN.md Phase B): the same interface `LocalHost` gives this
/// Mac, so every `ContainerCLI` call works against another Mac unchanged — built with
/// `wirePolicy: .remotePeer`, so the Allowlist refuses locally what the host would refuse anyway.
///
/// **It pins the host.** Each connection's certificate must carry the fingerprint the owner
/// approved; a different key at the same address — a reinstalled Mac, or an impostor — gets nothing
/// sent to it. And the host must say it trusts this Mac; if it no longer does, that is an error to
/// show, not a reason to pair again silently.
///
/// One connection, opened on first use and reopened after it drops. `ContainerHost.run` is
/// synchronous and is called from detached tasks, so it waits on the async connection; never call
/// it on the main thread.
public final class RemoteHost: ContainerHost, @unchecked Sendable {
    public let endpoint: NWEndpoint
    public let fingerprint: PeerFingerprint
    let identity: DeviceIdentity
    let info: WirePeerInfo
    private let lock = NSLock()
    private var connection: AdminConnection?
    private var welcome: WireMessage.Welcome?

    let reachTimeout: TimeInterval

    public init(endpoint: NWEndpoint, fingerprint: PeerFingerprint, identity: DeviceIdentity, info: WirePeerInfo,
                reachTimeout: TimeInterval = AdminConnection.reachTimeout) {
        self.endpoint = endpoint
        self.reachTimeout = reachTimeout
        self.fingerprint = fingerprint
        self.identity = identity
        self.info = info
    }

    /// What the host said about itself on the current connection.
    public var hostInfo: WirePeerInfo? { lock.lock(); defer { lock.unlock() }; return welcome?.peer }

    public func close() {
        lock.lock()
        let open = connection
        connection = nil
        welcome = nil
        lock.unlock()
        open?.close()
    }

    // MARK: Running

    /// Runs `arguments` on the host, calling back on the connection's queue.
    public func run(_ arguments: [String], timeout: TimeInterval?,
                    completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void) {
        connection { [weak self] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let open):
                let host = self
                open.run(arguments, timeout: timeout) { outcome in
                    // Measured 7 October: written as `case .failure(RemoteHostError.closed)` this
                    // never matched — an expression pattern, not a case pattern — so a host that
                    // restarted left a dead connection that every later call reused.
                    if case .failure(let error) = outcome, case .closed? = error as? RemoteHostError {
                        host?.forget(open)
                    }
                    completion(outcome)
                }
            }
        }
    }

    public func run(_ arguments: [String], timeout: TimeInterval?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            run(arguments, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    /// Callers waiting for a connection that is already being made.
    private var waiters: [@Sendable (Result<AdminConnection, Error>) -> Void] = []
    private var connecting = false

    /// The open connection, or a new one — pinned and trusted, or an error. **One attempt at a
    /// time**: callers arriving while it is under way wait for it, rather than each opening their
    /// own (measured 7 October — forty simultaneous first calls opened forty connections, and the
    /// host's per-address limit reset all but four).
    private func connection(_ completion: @escaping @Sendable (Result<AdminConnection, Error>) -> Void) {
        let action: () -> Void = lock.withLock {
            // A connection that has closed underneath us is dropped here, whatever any caller saw.
            if let open = connection, !open.isClosed { return { completion(.success(open)) } }
            connection = nil
            welcome = nil
            waiters.append(completion)
            if connecting { return {} }
            connecting = true
            return { [self] in openConnection() }
        }
        action()
    }

    /// Attempts that never reach the host are made again, a second apart, this many times in all —
    /// see `AdminConnection.reachTimeout` for the launch-time case this exists for. A host that is
    /// really off the network costs three short attempts rather than one long one.
    static let reachAttempts = 3

    private func openConnection(attempt: Int = 1) {
        let fresh = AdminConnection(endpoint: endpoint, identity: identity, info: info, reachTimeout: reachTimeout)
        let expected = fingerprint
        fresh.connect { [weak self] result in
            guard let self else { return }
            // A case pattern on the cast, not `.failure(RemoteHostError.unreachable(…))`: that
            // spelling against an `Error` is the kind that compiles and never matches (see `run`).
            if case .failure(let error) = result, case .unreachable(let reason)? = error as? RemoteHostError,
               reason == AdminConnection.notReachedReason, attempt < Self.reachAttempts {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.openConnection(attempt: attempt + 1)
                }
                return
            }
            let outcome: Result<AdminConnection, Error>
            switch result {
            case .failure(let error): outcome = .failure(error)
            case .success(let welcome):
                if fresh.hostFingerprint != expected {
                    fresh.close()
                    outcome = .failure(RemoteHostError.protocolError(
                        "A different Mac answered at this address — its key isn't the one you approved."))
                } else if !welcome.trusted {
                    fresh.close()
                    outcome = .failure(RemoteHostError.notTrusted)
                } else {
                    outcome = .success(fresh)
                }
            }
            let waiting: [@Sendable (Result<AdminConnection, Error>) -> Void] = self.lock.withLock {
                if case .success = outcome, case .success(let welcome) = result {
                    self.connection = fresh
                    self.welcome = welcome
                }
                self.connecting = false
                defer { self.waiters.removeAll() }
                return self.waiters
            }
            for waiter in waiting { waiter(outcome) }
        }
    }

    private func forget(_ stale: AdminConnection) {
        lock.withLock { if connection === stale { connection = nil; welcome = nil } }
    }

    // MARK: ContainerHost

    public func run(_ args: [String]) throws -> CommandResult {
        try run(args, timeout: 0)
    }

    /// Blocks until the host answers. It waits on the connection's own queue, never on Swift's
    /// cooperative pool, so many hosts queried at once cannot starve the pool of threads.
    public func run(_ args: [String], timeout: TimeInterval) throws -> CommandResult {
        precondition(!Thread.isMainThread, "RemoteHost.run blocks; call it from a detached task")
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        run(args, timeout: timeout > 0 ? timeout : nil) { result in
            box.set(result)
            semaphore.signal()
        }
        semaphore.wait()
        return try box.get()
    }

    /// Sends the archive at `file` to the host, which checks it and loads it itself (PLAN.md
    /// Phase D, D2). `progress` reports bytes sent, from the connection's queue. The answer is the
    /// host's own `image load` result.
    public func upload(file: URL, bytes: UInt64, sha256: String, label: String,
                       progress: @escaping @Sendable (UInt64) -> Void) async throws -> CommandResult {
        let open: AdminConnection = try await withCheckedThrowingContinuation { continuation in
            connection { continuation.resume(with: $0) }
        }
        do {
            return try await open.upload(file: file, bytes: bytes, sha256: sha256, label: label, progress: progress)
        } catch {
            if case .closed? = error as? RemoteHostError { forget(open) }
            if case WireError.streamsUnsupported? = error as? WireError {
                throw RemoteHostError.protocolError("That Mac's Flotilla is too old to receive images. Update it first.")
            }
            throw error
        }
    }

    /// A followed command on the host (PLAN.md Phase D, D2) — `container logs --follow` there, its
    /// lines here, through the same `ContainerCLI` path This Mac's live logs take. Returns at once;
    /// the follow opens when the connection does, and a cancel before then stops it as it opens.
    /// Every way it can fail arrives through `onEnd` with a reason, as a child that died would.
    public func stream(_ args: [String],
                       onLine: @escaping @Sendable (String, OutputChannel) -> Void,
                       onEnd: @escaping @Sendable (CommandStreamEnd) -> Void) throws -> CommandStream {
        let follow = RemoteFollow(onLine: onLine, onEnd: onEnd)
        connection { [weak self] result in
            switch result {
            case .failure(let error): follow.fail(Self.describe(error))
            case .success(let open):
                // Off the connection's queue: a fresh connection calls back on it, and `follow`
                // waits on it — measured 7 October, a deadlock on the first follow of a connection.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let stop = try open.follow(args, onData: { channel, data in follow.receive(channel, data) },
                                                   onEnd: { end in follow.ended(end) })
                        follow.arm(stop)
                    } catch {
                        if case .closed? = error as? RemoteHostError { self?.forget(open) }
                        follow.fail(Self.describe(error))
                    }
                }
            }
        }
        return CommandStream(stop: { follow.cancel() })
    }

    private static func describe(_ error: Error) -> String {
        if case WireError.streamsUnsupported? = error as? WireError {
            return "That Mac's Flotilla is too old to follow logs live. Update it, or turn Live off to fetch them."
        }
        return String(describing: error)
    }
}

/// One follow on a host, from the caller's side: turns the host's pieces back into lines, and
/// makes sure the caller hears exactly one end however the follow stops.
private final class RemoteFollow: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String, OutputChannel) -> Void
    private let onEnd: @Sendable (CommandStreamEnd) -> Void
    private var stop: (@Sendable () -> Void)?
    private var cancelled = false
    private var finished = false

    init(onLine: @escaping @Sendable (String, OutputChannel) -> Void,
         onEnd: @escaping @Sendable (CommandStreamEnd) -> Void) {
        self.onLine = onLine
        self.onEnd = onEnd
    }

    /// The follow is open; a cancel that came first stops it now.
    func arm(_ stop: @escaping @Sendable () -> Void) {
        let stopNow: Bool = lock.withLock {
            if cancelled { return true }
            self.stop = stop
            return false
        }
        if stopNow { stop() }
    }

    func cancel() {
        let stop: (@Sendable () -> Void)? = lock.withLock {
            cancelled = true
            defer { self.stop = nil }
            return self.stop
        }
        if let stop { stop() } else { finish(CommandStreamEnd(exitCode: 0, cancelled: true)) }
    }

    /// A host sends whole lines, each ending in a newline, so a piece splits cleanly.
    func receive(_ channel: WireMessage.StreamChannel, _ data: Data) {
        guard lock.withLock({ !finished }) else { return }
        let output: OutputChannel = switch channel {
        case .stderr: .stderr
        case .notice: .notice
        case .stdout, .data: .stdout
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for line in lines { onLine(String(line), output) }
    }

    func ended(_ end: WireMessage.StreamEnd) {
        let cancelled = lock.withLock { self.cancelled }
        if let dropped = end.dropped, dropped > 0, !cancelled {
            onLine("\(dropped) lines were dropped in all: Flotilla fell behind", .notice)
        }
        finish(CommandStreamEnd(exitCode: end.exitCode ?? (cancelled ? 0 : 1), cancelled: cancelled,
                                reason: cancelled ? nil : end.reason))
    }

    func fail(_ reason: String) {
        finish(CommandStreamEnd(exitCode: 1, cancelled: lock.withLock { cancelled }, reason: reason))
    }

    private func finish(_ end: CommandStreamEnd) {
        let first: Bool = lock.withLock {
            defer { finished = true }
            return !finished
        }
        if first { onEnd(end) }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CommandResult, Error> = .failure(RemoteHostError.closed(nil))
    func set(_ value: Result<CommandResult, Error>) { lock.lock(); result = value; lock.unlock() }
    func get() throws -> CommandResult { lock.lock(); defer { lock.unlock() }; return try result.get() }
}

extension PeerEndpoint {
    /// The Network.framework endpoint for this hint.
    public var nwEndpoint: NWEndpoint? {
        switch self {
        case .bonjour(let name):
            return .service(name: name, type: WireTLS.serviceType, domain: "local.", interface: nil)
        case .address(let host, let port):
            guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
    }

    /// The hint for an endpoint the owner chose, if it is one we can remember.
    public init?(_ endpoint: NWEndpoint) {
        switch endpoint {
        case .service(let name, _, _, _): self = .bonjour(name: name)
        case .hostPort(let host, let port): self = .address(host: "\(host)", port: port.rawValue)
        default: return nil
        }
    }
}
