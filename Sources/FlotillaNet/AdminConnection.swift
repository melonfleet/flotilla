import Foundation
import Network
import FlotillaCore
import FlotillaTrust

/// Why talking to a host did not produce a result.
public enum RemoteHostError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreachable(String)
    case rejected(WireMessage.Reject)
    /// The host answered the request without running it, or it failed there.
    case failed(WireMessage.Failure)
    case timedOut
    case closed(String?)
    case notTrusted
    case protocolError(String)
    /// Pairing ended without a pairing — the host's own reason, or the owner's answer.
    case pairingFailed(String)

    public var description: String {
        switch self {
        case .unreachable(let why): "Couldn't reach the host: \(why)"
        case .rejected(let reject): reject.message
        case .failed(let failure): failure.message
        case .timedOut: "The host didn't answer in time."
        case .closed(let why): "The connection closed\(why.map { ": \($0)" } ?? ".")"
        case .notTrusted: "This host hasn't been paired with this Mac."
        case .protocolError(let why): "The host broke the protocol: \(why)"
        case .pairingFailed(let why): why
        }
    }
}

/// The admin Mac's connection to one host (PLAN.md Phase B, B3): TLS with this Mac's identity, the
/// hello/welcome handshake, numbered requests with deadlines, keepalive pings, and pairing.
///
/// It reports the host's fingerprint and leaves trust to the caller: `RemoteHost` (B3b) sends
/// commands only to a host its own `PeerBook` has approved.
public final class AdminConnection: @unchecked Sendable {
    public let endpoint: NWEndpoint
    let identity: DeviceIdentity
    let crypto: PairingCrypto
    private let connection: WireConnection
    private var session: WireClientSession
    /// Callbacks rather than continuations underneath, so a caller that must block — `RemoteHost`'s
    /// synchronous `ContainerHost` face — can wait on this connection's own queue without needing a
    /// thread from Swift's cooperative pool. The async methods wrap these.
    private var connectCompletion: (@Sendable (Result<WireMessage.Welcome, Error>) -> Void)?
    private var pending: [UInt32: @Sendable (Result<CommandResult, Error>) -> Void] = [:]
    /// Requests over the agreed concurrency wait here for a slot rather than failing: the limit
    /// protects the host, and the caller should not have to know it exists.
    private var waiting: [(arguments: [String], timeout: TimeInterval?,
                           completion: @Sendable (Result<CommandResult, Error>) -> Void)] = []
    private var deadlines: [UInt32: DispatchSourceTimer] = [:]
    /// Follows being read (D2): where each one's output and end go.
    private var follows: [UInt32: (data: @Sendable (WireMessage.StreamChannel, Data) -> Void,
                                   end: @Sendable (WireMessage.StreamEnd) -> Void)] = [:]
    /// Uploads being sent (D2): the file, and how far it has got.
    private var uploads: [UInt32: OutgoingUpload] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var connectTimer: DispatchSourceTimer?
    private var reachTimer: DispatchSourceTimer?
    private var pairingTimer: DispatchSourceTimer?
    static let connectTimeout: TimeInterval = 20
    /// How long TCP and TLS alone may take before this attempt is given up for another
    /// (`RemoteHost` retries). Measured 7 October: in the first moment after Flotilla starts,
    /// macOS can refuse its local-network lookups ("Local network prohibited" in the system log)
    /// while it is still applying the app's Local Network permission. The connection then sits in
    /// `preparing` and never recovers — only a fresh one does. On a LAN this phase takes well under
    /// a second, so six is generous for a slow link and short enough to retry inside 20.
    public static let reachTimeout: TimeInterval = 6
    private let reachTimeout: TimeInterval
    /// The reason an attempt ends with when it never reached the host — `RemoteHost` retries
    /// exactly this one.
    public static let notReachedReason = "couldn\u{2019}t reach it on the network"
    /// Long enough for two people to compare four words.
    static let pairingTimeout: TimeInterval = 300
    private var pairingSession: PairingAdminSession?
    private var pairingHandler: ((PairingAdminSession.Event) -> Void)?
    private var pairingContinuation: CheckedContinuation<PairingOutcome, Error>?
    private var closedReason: String??

    public init(endpoint: NWEndpoint, identity: DeviceIdentity, info: WirePeerInfo,
                limits: WireLimits = .default, crypto: PairingCrypto = .system,
                reachTimeout: TimeInterval = AdminConnection.reachTimeout) {
        self.endpoint = endpoint
        self.reachTimeout = reachTimeout
        self.identity = identity
        self.crypto = crypto
        session = WireClientSession(peer: info, limits: limits)
        connection = WireConnection(NWConnection(to: endpoint, using: WireTLS.parameters(identity: identity, server: false)),
                                    limits: limits, label: "admin-connection")
    }

    /// Whether this connection has ended — a closed one is never reused.
    public var isClosed: Bool { connection.queue.sync { closedReason != nil } }

    /// The host's fingerprint, once connected.
    public var hostFingerprint: PeerFingerprint? { connection.peerFingerprint }

    /// Connects and shakes hands. The welcome says whether the host trusts this Mac.
    public func connect() async throws -> WireMessage.Welcome {
        try await withCheckedThrowingContinuation { continuation in
            connect { continuation.resume(with: $0) }
        }
    }

    /// The same, calling back on this connection's queue.
    public func connect(completion: @escaping @Sendable (Result<WireMessage.Welcome, Error>) -> Void) {
        connection.queue.async { [self] in
            connectCompletion = completion
            // TCP, TLS and the welcome all inside one deadline: a host that completes TLS and then
            // says nothing must not hold a caller for ever (Iris's review, 7 October).
            connectTimer = timer(after: Self.connectTimeout) { [weak self] in
                guard let self, self.connectCompletion != nil else { return }
                self.connection.close("no welcome in time")
            }
            reachTimer = timer(after: reachTimeout) { [weak self] in
                guard let self, self.connectCompletion != nil else { return }
                self.connection.close(Self.notReachedReason)
            }
            connection.onReady = { [weak self] in
                guard let self else { return }
                self.reachTimer?.cancel()
                self.connection.send(self.session.hello())
            }
            connection.onMessage = { [weak self] message in self?.received(message) }
            connection.onClose = { [weak self] reason in self?.closed(reason) }
            connection.start()
        }
    }

    /// Runs `arguments` on the host and returns its result. Refused locally, at once, if the
    /// Allowlist would refuse it there.
    public func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            run(arguments, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    /// The same, calling back on this connection's queue.
    public func run(_ arguments: [String], timeout: TimeInterval?,
                    completion: @escaping @Sendable (Result<CommandResult, Error>) -> Void) {
        connection.queue.async { [self] in
            if let reason = closedReason { return completion(.failure(RemoteHostError.closed(reason))) }
            if case .ready = session.state, session.inFlight.count >= session.limits.maxConcurrentRequests {
                // A command the Allowlist refuses still fails at once; only a full pipe waits.
                do { _ = try Allowlist.validated(arguments, wirePolicy: .remotePeer) }
                catch { return completion(.failure(error)) }
                waiting.append((arguments, timeout, completion))
                return
            }
            do {
                let outgoing = try session.request(arguments, timeout: timeout)
                pending[outgoing.id] = completion
                if outgoing.deadline > 0 {
                    deadlines[outgoing.id] = timer(after: outgoing.deadline) { [weak self] in
                        self?.session.abandon(outgoing.id)
                        self?.settle(outgoing.id, .failure(RemoteHostError.timedOut))
                    }
                }
                connection.send(outgoing.message)
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func close() { connection.close(nil) }

    /// This Mac's and the host's IPv4 addresses on this connection (see `WireConnection`).
    public var ipv4Addresses: (local: String?, remote: String?) { connection.ipv4Addresses }

    /// A host call (D3): the answer is an ordinary result, JSON in its stdout, or a failure.
    /// Refused at once if the host predates host calls; never queued, there are only ever a few.
    public func call(_ call: HostCall) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            connection.queue.async { [self] in
                if let reason = closedReason { return continuation.resume(throwing: RemoteHostError.closed(reason)) }
                do {
                    let outgoing = try session.call(call)
                    pending[outgoing.id] = { continuation.resume(with: $0) }
                    deadlines[outgoing.id] = timer(after: outgoing.deadline) { [weak self] in
                        self?.session.abandon(outgoing.id)
                        self?.settle(outgoing.id, .failure(RemoteHostError.timedOut))
                    }
                    connection.send(outgoing.message)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Whether the host negotiated streams (version 2). `false` before the welcome.
    public var canStream: Bool { connection.queue.sync { session.canStream } }

    // MARK: Streams (PLAN.md Phase D, D2; research/WIRE-STREAMS-D2.md)

    /// Follows `arguments` on the host — only `logs --follow`, which the host checks again.
    /// `onData` and `onEnd` are called on this connection's queue; `onEnd` exactly once, including
    /// when the connection drops. Returns a stop, or throws if the host can't stream.
    public func follow(_ arguments: [String],
                       onData: @escaping @Sendable (WireMessage.StreamChannel, Data) -> Void,
                       onEnd: @escaping @Sendable (WireMessage.StreamEnd) -> Void) throws -> @Sendable () -> Void {
        // It waits on the connection's queue, so it must never be called from it.
        dispatchPrecondition(condition: .notOnQueue(connection.queue))
        return try connection.queue.sync { [self] in
            if let reason = closedReason { throw RemoteHostError.closed(reason) }
            let (outgoing, credit) = try session.follow(arguments)
            follows[outgoing.id] = (onData, onEnd)
            connection.send(outgoing.message)
            connection.send(credit)
            let id = outgoing.id
            return { [weak self] in
                guard let self else { return }
                self.connection.queue.async {
                    guard let entry = self.follows.removeValue(forKey: id) else { return }
                    if let cancel = self.session.stopFollow(id) { self.connection.send(cancel) }
                    entry.end(.init(id: id, reason: "stopped"))
                }
            }
        }
    }

    /// Sends the archive at `file` (`bytes` long, with this SHA-256) to the host, which loads it
    /// itself. `progress` reports bytes sent, on this connection's queue. The answer is the host's
    /// `image load` result.
    public func upload(file: URL, bytes: UInt64, sha256: String, label: String,
                       progress: @escaping @Sendable (UInt64) -> Void) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            connection.queue.async { [self] in
                if let reason = closedReason { return continuation.resume(throwing: RemoteHostError.closed(reason)) }
                do {
                    let handle = try FileHandle(forReadingFrom: file)
                    let outgoing = try session.upload(bytes: bytes, sha256: sha256, label: label)
                    uploads[outgoing.id] = OutgoingUpload(handle: handle, declared: bytes, progress: progress)
                    pending[outgoing.id] = { [weak self] result in
                        self?.uploads.removeValue(forKey: outgoing.id).map { try? $0.handle.close() }
                        continuation.resume(with: result)
                    }
                    connection.send(outgoing.message)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends as much of an upload as its credit allows, then its end once every byte is out.
    private func pump(_ id: UInt32) {
        guard var upload = uploads[id] else { return }
        do {
            while upload.sent < upload.declared {
                let remaining = upload.declared - upload.sent
                let room = min(session.uploadCredit(id), UInt64(session.uploadChunkCeiling), remaining)
                // Only the last piece may be small: wait for credit rather than send a sliver.
                let smallest = min(UInt64(session.streamLimits.minUploadChunkBytes), UInt64(session.uploadChunkCeiling), remaining)
                guard room > 0, room >= smallest else { break }
                guard let data = try upload.handle.read(upToCount: Int(room)), !data.isEmpty else {
                    throw WireError.streamViolation("the archive is shorter than it was")
                }
                connection.send(try session.uploadChunk(id, data))
                upload.sent += UInt64(data.count)
                upload.progress(upload.sent)
            }
            if upload.sent == upload.declared, !upload.ended {
                connection.send(try session.uploadEnd(id))
                upload.ended = true
            }
            uploads[id] = upload
        } catch {
            if let cancel = session.cancel(id) { connection.send(cancel) }
            session.abandon(id)
            settle(id, .failure(error))
        }
    }

    // MARK: Pairing

    public enum PairingOutcome: Sendable, Equatable {
        /// Code pairing finished: both owners confirmed. Record it with `PeerBook.pairConfirmed`.
        case paired(PeerFingerprint, PeerDetails)
        /// Enrolment: the host proved it holds the key and was given this answer.
        case enrolment(PeerFingerprint, PeerDetails, PeerBook.Outcome)
    }

    /// Pairs with an untrusted host on this connection.
    ///
    /// - `confirmWords`: code pairing — show the owner the words; return their answer.
    /// - `recordEnrolment`: enrolment — put the host in the approval list and return the outcome.
    public func pair(details: PeerDetails, method: PairingAdminSession.Method,
                     confirmWords: @escaping @Sendable ([String], PeerDetails) async -> Bool,
                     recordEnrolment: @escaping @Sendable (PeerFingerprint, PeerDetails) async -> PeerBook.Outcome)
        async throws -> PairingOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PairingOutcome, Error>) in
            connection.queue.async { [self] in
                guard let host = connection.peerFingerprint else {
                    return continuation.resume(throwing: RemoteHostError.closed(nil))
                }
                pairingContinuation = continuation
                pairingTimer = timer(after: Self.pairingTimeout) { [weak self] in
                    guard let self, self.pairingContinuation != nil else { return }
                    self.connection.close("pairing took too long")
                }
                var pairing = PairingAdminSession(own: identity.fingerprint, host: host, details: details,
                                                  method: method, crypto: crypto)
                let start = pairing.start()
                pairingSession = pairing
                pairingHandler = { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .send(let message): self.connection.send(message)
                    case .failed(let why): self.finishPairing(.failure(RemoteHostError.pairingFailed(why)))
                    case .paired(let fingerprint, let details): self.finishPairing(.success(.paired(fingerprint, details)))
                    case .enrolmentRequested(let fingerprint, let hostDetails):
                        Task {
                            let outcome = await recordEnrolment(fingerprint, hostDetails)
                            self.connection.queue.async {
                                guard var pairing = self.pairingSession else { return }
                                let reply = pairing.finishEnrolment(outcome)
                                self.pairingSession = pairing
                                self.connection.send(reply)
                                self.finishPairing(.success(.enrolment(fingerprint, hostDetails, outcome)))
                            }
                        }
                    case .confirmWords(let words, let hostDetails):
                        Task {
                            let yes = await confirmWords(words, hostDetails)
                            self.connection.queue.async {
                                guard var pairing = self.pairingSession else { return }
                                let events = pairing.confirm(yes)
                                self.pairingSession = pairing
                                events.forEach { self.pairingHandler?($0) }
                            }
                        }
                    }
                }
                connection.send(start)
            }
        }
    }

    /// Exactly once, on the connection's queue.
    private func finishPairing(_ result: Result<PairingOutcome, Error>) {
        pairingTimer?.cancel()
        pairingHandler = nil
        pairingContinuation?.resume(with: result)
        pairingContinuation = nil
    }

    // MARK: Internals

    private func received(_ message: WireMessage) {
        do {
            for event in try session.receive(message) {
                switch event {
                case .connected(let welcome):
                    connectTimer?.cancel()
                    connection.adopt(session.limits)
                    startPings()
                    connectCompletion?(.success(welcome))
                    connectCompletion = nil
                case .rejected(let reject):
                    connectCompletion?(.failure(RemoteHostError.rejected(reject)))
                    connectCompletion = nil
                    connection.close(reject.message)
                case .streamData(let id, let channel, let data):
                    follows[id]?.data(channel, data)
                    // Read, so the host may send as much again.
                    if let more = session.grant(id, bytes: UInt64(data.count)) { connection.send(more) }
                case .streamEnded(let end):
                    follows.removeValue(forKey: end.id)?.end(end)
                case .uploadCredit(let id):
                    pump(id)
                case .completed(let id, let result): settle(id, .success(result))
                case .failed(let failure): settle(failure.id, .failure(RemoteHostError.failed(failure)))
                case .send(let reply): connection.send(reply)
                case .pong: break
                case .closed(let reason): connection.close(reason)
                case .pairing(let message):
                    guard var pairing = pairingSession else { continue }
                    let events = try pairing.receive(message)
                    pairingSession = pairing
                    events.forEach { pairingHandler?($0) }
                }
            }
        } catch {
            connection.close("protocol error: \(error)")
        }
    }

    private func settle(_ id: UInt32, _ result: Result<CommandResult, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?(result)
        // A slot is free: send the next waiting request.
        if closedReason == nil, !waiting.isEmpty {
            let next = waiting.removeFirst()
            run(next.arguments, timeout: next.timeout, completion: next.completion)
        }
    }

    private func closed(_ reason: String?) {
        closedReason = .some(reason)
        pingTimer?.cancel()
        reachTimer?.cancel()
        connectCompletion?(.failure(RemoteHostError.unreachable(reason ?? "closed")))
        connectCompletion = nil
        for id in Array(pending.keys) { settle(id, .failure(RemoteHostError.closed(reason))) }
        let open = follows
        follows.removeAll()
        for (id, entry) in open { entry.end(.init(id: id, reason: reason ?? "The connection closed.")) }
        let stranded = waiting
        waiting.removeAll()
        for request in stranded { request.completion(.failure(RemoteHostError.closed(reason))) }
        if let handler = pairingHandler {
            pairingHandler = nil
            handler(.failed(reason ?? "The connection closed during pairing."))
        }
    }

    private func startPings() {
        let interval = session.limits.pingInterval
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.connection.send(.ping(.init(nonce: UInt64.random(in: .min ... .max))))
        }
        timer.resume()
        pingTimer = timer
    }

    private func timer(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: fire)
        timer.resume()
        return timer
    }
}

/// An upload in progress on the admin side.
private struct OutgoingUpload {
    let handle: FileHandle
    let declared: UInt64
    let progress: @Sendable (UInt64) -> Void
    var sent: UInt64 = 0
    var ended = false
}
