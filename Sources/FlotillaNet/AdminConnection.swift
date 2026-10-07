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

    public var description: String {
        switch self {
        case .unreachable(let why): "Couldn't reach the host: \(why)"
        case .rejected(let reject): reject.message
        case .failed(let failure): failure.message
        case .timedOut: "The host didn't answer in time."
        case .closed(let why): "The connection closed\(why.map { ": \($0)" } ?? ".")"
        case .notTrusted: "This host hasn't been paired with this Mac."
        case .protocolError(let why): "The host broke the protocol: \(why)"
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
    private var connectContinuation: CheckedContinuation<WireMessage.Welcome, Error>?
    private var pending: [UInt32: CheckedContinuation<CommandResult, Error>] = [:]
    private var deadlines: [UInt32: DispatchSourceTimer] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var pairingSession: PairingAdminSession?
    private var pairingHandler: ((PairingAdminSession.Event) -> Void)?
    private var pairingContinuation: CheckedContinuation<PairingOutcome, Error>?
    private var closedReason: String??

    public init(endpoint: NWEndpoint, identity: DeviceIdentity, info: WirePeerInfo,
                limits: WireLimits = .default, crypto: PairingCrypto = .system) {
        self.endpoint = endpoint
        self.identity = identity
        self.crypto = crypto
        session = WireClientSession(peer: info, limits: limits)
        connection = WireConnection(NWConnection(to: endpoint, using: WireTLS.parameters(identity: identity, server: false)),
                                    limits: limits, label: "admin-connection")
    }

    /// The host's fingerprint, once connected.
    public var hostFingerprint: PeerFingerprint? { connection.peerFingerprint }

    /// Connects and shakes hands. The welcome says whether the host trusts this Mac.
    public func connect() async throws -> WireMessage.Welcome {
        try await withCheckedThrowingContinuation { continuation in
            connection.queue.async { [self] in
                connectContinuation = continuation
                connection.onReady = { [weak self] in
                    guard let self else { return }
                    self.connection.send(self.session.hello())
                }
                connection.onMessage = { [weak self] message in self?.received(message) }
                connection.onClose = { [weak self] reason in self?.closed(reason) }
                connection.start()
            }
        }
    }

    /// Runs `arguments` on the host and returns its result. Refused locally, at once, if the
    /// Allowlist would refuse it there.
    public func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            connection.queue.async { [self] in
                if let reason = closedReason { return continuation.resume(throwing: RemoteHostError.closed(reason)) }
                do {
                    let outgoing = try session.request(arguments, timeout: timeout)
                    pending[outgoing.id] = continuation
                    if outgoing.deadline > 0 {
                        deadlines[outgoing.id] = timer(after: outgoing.deadline) { [weak self] in
                            self?.session.abandon(outgoing.id)
                            self?.settle(outgoing.id, .failure(RemoteHostError.timedOut))
                        }
                    }
                    connection.send(outgoing.message)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() { connection.close(nil) }

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
                var pairing = PairingAdminSession(own: identity.fingerprint, host: host, details: details,
                                                  method: method, crypto: crypto)
                let start = pairing.start()
                pairingSession = pairing
                pairingHandler = { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .send(let message): self.connection.send(message)
                    case .failed(let why): self.finishPairing(.failure(RemoteHostError.protocolError(why)))
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
                    connection.adopt(session.limits)
                    startPings()
                    connectContinuation?.resume(returning: welcome)
                    connectContinuation = nil
                case .rejected(let reject):
                    connectContinuation?.resume(throwing: RemoteHostError.rejected(reject))
                    connectContinuation = nil
                    connection.close(reject.message)
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
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func closed(_ reason: String?) {
        closedReason = .some(reason)
        pingTimer?.cancel()
        connectContinuation?.resume(throwing: RemoteHostError.unreachable(reason ?? "closed"))
        connectContinuation = nil
        for id in Array(pending.keys) { settle(id, .failure(RemoteHostError.closed(reason))) }
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
