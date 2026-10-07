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

    public init(endpoint: NWEndpoint, fingerprint: PeerFingerprint, identity: DeviceIdentity, info: WirePeerInfo) {
        self.endpoint = endpoint
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
                    if case .failure(RemoteHostError.closed) = outcome { host?.forget(open) }
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
            if let open = connection { return { completion(.success(open)) } }
            waiters.append(completion)
            if connecting { return {} }
            connecting = true
            return { [self] in openConnection() }
        }
        action()
    }

    private func openConnection() {
        let fresh = AdminConnection(endpoint: endpoint, identity: identity, info: info)
        let expected = fingerprint
        fresh.connect { [weak self] result in
            guard let self else { return }
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

    /// Streams (followed logs, live stats) are reserved frame types, not built yet (PLAN.md).
    public func stream(_ args: [String],
                       onLine: @escaping @Sendable (String, OutputChannel) -> Void,
                       onEnd: @escaping @Sendable (CommandStreamEnd) -> Void) throws -> CommandStream {
        throw ContainerCLIError.unsupported("Following output on another Mac isn't available yet.")
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
