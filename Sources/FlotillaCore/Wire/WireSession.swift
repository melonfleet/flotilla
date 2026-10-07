import Foundation

/// The host's half of a connection: a state machine with no I/O. The transport feeds it decoded
/// messages and acts on the events it returns — send this, run that, stop the other, hang up.
///
/// It is where a request becomes something that may run. Every request is validated **here, on the
/// host**, by the same `Allowlist` the app uses, as a `.remotePeer`: a command marked local-only is
/// refused whatever the admin Mac thought of it, host paths obey this host's `MountPolicy`, and
/// `exec` is held to the process list. What the requesting side checked is a courtesy; this is the
/// check (DECISIONS Q1, Q14).
///
/// Trust is not decided here. By the time a session exists, the TLS layer (B2/B3) has already
/// pinned the peer's key to an approved identity; a session only governs what that peer may do.
public struct WireHostSession: Sendable {
    public enum State: Sendable, Equatable {
        case awaitingHello
        case ready(version: UInt16, peer: WirePeerInfo)
        case closed
    }

    public enum Event: Sendable, Equatable {
        /// Deliver this to the peer.
        case send(WireMessage)
        /// Run this, with this deadline (0 = none), and report back through `complete` or `fail`.
        case execute(id: UInt32, command: ValidatedCommand, deadline: TimeInterval)
        /// Stop request `id` if it is still running, then report it through `fail(…, .cancelled)`.
        case cancel(id: UInt32)
        /// Close the connection once anything queued before this has been sent.
        case close(reason: String)
        /// A pairing message, for `PairingHostSession` — the only conversation an untrusted caller
        /// may have.
        case pairing(WireMessage)
    }

    public let peer: WirePeerInfo
    /// Whether the TLS layer found the caller's key in this host's peer book.
    public let trusted: Bool
    public private(set) var state: State = .awaitingHello
    /// This host's own limits until the handshake, then the intersection with the peer's.
    public private(set) var limits: WireLimits
    public private(set) var inFlight: Set<UInt32> = []

    private let versions: ClosedRange<UInt16>
    private let mountPolicy: MountPolicy
    private let execPolicy: ExecPolicy
    private let allowlistLimits: Allowlist.Limits

    /// `mountPolicy` may not be `.unrestricted`: a remote peer with every host path is the owner's
    /// whole disk, which is why `ContainerCLI` refuses the same combination.
    public init(peer: WirePeerInfo, limits: WireLimits = .default,
                versions: ClosedRange<UInt16> = WireProtocol.supportedVersions,
                mountPolicy: MountPolicy = .denyHostPaths,
                execPolicy: ExecPolicy = .processListOnly,
                allowlistLimits: Allowlist.Limits = .default,
                trusted: Bool = true) {
        precondition(mountPolicy != .unrestricted, "a host session never grants every host path")
        self.trusted = trusted
        self.peer = peer
        self.limits = limits
        self.versions = versions
        self.mountPolicy = mountPolicy
        self.execPolicy = execPolicy
        self.allowlistLimits = allowlistLimits
    }

    /// Handles one message. Throws on a protocol violation, after which the transport closes the
    /// connection without another word — a peer that broke the protocol gets no more of it.
    public mutating func receive(_ message: WireMessage) throws -> [Event] {
        if state == .closed { throw WireError.closed }
        switch (state, message) {
        case (.awaitingHello, .hello(let hello)):
            guard let version = WireProtocol.negotiate(versions, hello.versions) else {
                state = .closed
                return [.send(.reject(.init(code: .versionMismatch,
                                            message: "This host speaks protocol \(versions.lowerBound)–\(versions.upperBound).",
                                            versions: versions))),
                        .close(reason: "version mismatch")]
            }
            limits = limits.intersection(hello.limits)
            state = .ready(version: version, peer: hello.peer)
            return [.send(.welcome(.init(version: version, peer: peer, limits: limits, trusted: trusted)))]

        case (.ready, .request(let request)):
            guard trusted else {
                return [.send(.failure(.init(id: request.id, code: .refused,
                                             message: "This Mac hasn't been paired with this host.")))]
            }
            return [try handle(request)]

        case (.ready, .pairStart), (.ready, .pairProof), (.ready, .pairResult), (.ready, .pairConfirm):
            // Pairing is for strangers. A trusted caller has nothing to pair.
            guard !trusted else { throw WireError.unexpected(message.frameType) }
            return [.pairing(message)]

        case (.ready, .cancel(let cancel)):
            // A cancel that crosses its own result is normal, not a fault.
            return inFlight.contains(cancel.id) ? [.cancel(id: cancel.id)] : []

        case (_, .ping(let ping)):
            return [.send(.pong(ping))]
        case (_, .pong):
            return []
        case (_, .close(let close)):
            state = .closed
            return [.close(reason: close.reason)]

        default:
            throw WireError.unexpected(message.frameType)
        }
    }

    private mutating func handle(_ request: WireMessage.Request) throws -> Event {
        guard !inFlight.contains(request.id) else { throw WireError.duplicateRequestID(request.id) }
        guard inFlight.count < limits.maxConcurrentRequests else {
            return .send(.failure(.init(id: request.id, code: .busy,
                                        message: "This host is already running \(inFlight.count) requests from you.")))
        }
        let command: ValidatedCommand
        switch Allowlist.validate(request.arguments, limits: allowlistLimits, mountPolicy: mountPolicy,
                                  execPolicy: execPolicy, wirePolicy: .remotePeer) {
        case .success(let validated): command = validated
        case .failure(let error):
            return .send(.failure(.init(id: request.id, code: .refused, message: String(describing: error))))
        }
        inFlight.insert(request.id)
        return .execute(id: request.id, command: command,
                        deadline: Self.deadline(hint: command.timeoutHint, requested: request.timeout))
    }

    /// The command's own deadline, or the caller's if it is shorter. Never longer: the hint is the
    /// host's ceiling (Q15), and a remote caller does not get to lift it.
    static func deadline(hint: TimeInterval, requested: TimeInterval?) -> TimeInterval {
        guard let requested, requested > 0 else { return hint }
        return hint > 0 ? min(hint, requested) : requested
    }

    /// The result of request `id`, trimmed to the agreed output ceiling. `nil` if `id` is no longer
    /// in flight — it was cancelled and already answered.
    public mutating func complete(_ id: UInt32, with result: CommandResult) -> WireMessage? {
        guard inFlight.remove(id) != nil else { return nil }
        let cap = limits.maxOutputBytesPerStream
        let out = Data(result.stdout.utf8), err = Data(result.stderr.utf8)
        return .result(.init(id: id, exitCode: result.exitCode,
                             stdout: out.prefix(cap), stderr: err.prefix(cap),
                             stdoutTruncated: result.stdoutTruncated || out.count > cap,
                             stderrTruncated: result.stderrTruncated || err.count > cap))
    }

    /// Request `id` ended without a result. `nil` if it is no longer in flight.
    public mutating func fail(_ id: UInt32, code: WireFailureCode, message: String) -> WireMessage? {
        guard inFlight.remove(id) != nil else { return nil }
        return .failure(.init(id: id, code: code, message: message))
    }
}

/// The admin Mac's half of a connection: the same idea from the other side. It numbers requests,
/// keeps to the agreed concurrency, checks each command against the Allowlist before it leaves (so
/// a refusal is instant and needs no round trip), and **bounds what it accepts** — a host that has
/// been compromised is a peer like any other, and its replies are held to the same limits.
public struct WireClientSession: Sendable {
    public enum State: Sendable, Equatable {
        case notStarted
        case awaitingWelcome
        case ready(version: UInt16, host: WirePeerInfo)
        case closed
    }

    public enum Event: Sendable, Equatable {
        case connected(WireMessage.Welcome)
        case rejected(WireMessage.Reject)
        case completed(id: UInt32, result: CommandResult)
        case failed(WireMessage.Failure)
        /// Deliver this to the host (the answer to its ping).
        case send(WireMessage)
        case pong(nonce: UInt64)
        case closed(reason: String)
        /// A pairing message, for `PairingAdminSession`.
        case pairing(WireMessage)
    }

    /// A request ready to send, with the deadline the requesting side should hold it to.
    public struct Outgoing: Sendable, Equatable {
        public let id: UInt32
        public let message: WireMessage
        /// Seconds until the caller gives up (the command's own deadline plus the round-trip
        /// grace), or 0 for none.
        public let deadline: TimeInterval
    }

    public let peer: WirePeerInfo
    public private(set) var state: State = .notStarted
    public private(set) var limits: WireLimits
    public private(set) var inFlight: Set<UInt32> = []

    private let versions: ClosedRange<UInt16>
    private var nextID: UInt32 = 1

    public init(peer: WirePeerInfo, limits: WireLimits = .default,
                versions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
        self.peer = peer
        self.limits = limits
        self.versions = versions
    }

    /// The first message on a new connection.
    public mutating func hello() -> WireMessage {
        state = .awaitingWelcome
        return .hello(.init(versions: versions, peer: peer, limits: limits))
    }

    /// A request for `arguments`, or a thrown `AllowlistError` / `WireError` if it cannot be sent.
    public mutating func request(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Outgoing {
        guard case .ready = state else { throw state == .closed ? WireError.closed : WireError.notConnected }
        guard inFlight.count < limits.maxConcurrentRequests else {
            throw WireError.tooManyRequests(limit: limits.maxConcurrentRequests)
        }
        // The same check the host makes, for an instant answer. The host makes it again.
        let command = try Allowlist.validated(arguments, wirePolicy: .remotePeer)
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        inFlight.insert(id)
        let own = WireHostSession.deadline(hint: command.timeoutHint, requested: timeout)
        return Outgoing(id: id,
                        message: .request(.init(id: id, arguments: arguments, timeout: timeout)),
                        deadline: own > 0 ? own + limits.deadlineGrace : 0)
    }

    /// Asks the host to stop request `id`. The answer arrives as a failure (`.cancelled`) or, if
    /// the command finished first, as its result.
    public func cancel(_ id: UInt32) -> WireMessage? {
        inFlight.contains(id) ? .cancel(.init(id: id)) : nil
    }

    /// Gives up on request `id` locally — its deadline passed. A late answer is then ignored.
    public mutating func abandon(_ id: UInt32) {
        inFlight.remove(id)
        abandoned.insert(id)
    }
    private var abandoned: Set<UInt32> = []

    public mutating func receive(_ message: WireMessage) throws -> [Event] {
        if state == .closed { throw WireError.closed }
        switch (state, message) {
        case (.awaitingWelcome, .welcome(let welcome)):
            guard versions.contains(welcome.version) else {
                throw WireError.versionMismatch(peer: welcome.version...welcome.version)
            }
            // Keep our own limits where the host's are looser: a host cannot widen them.
            limits = limits.intersection(welcome.limits)
            state = .ready(version: welcome.version, host: welcome.peer)
            return [.connected(welcome)]

        case (.awaitingWelcome, .reject(let reject)):
            state = .closed
            return [.rejected(reject)]

        case (.ready, .result(let result)):
            guard try settle(result.id) else { return [] }
            guard result.stdout.count <= limits.maxOutputBytesPerStream,
                  result.stderr.count <= limits.maxOutputBytesPerStream else {
                throw WireError.frameTooLarge(result.stdout.count + result.stderr.count)
            }
            return [.completed(id: result.id, result: result.commandResult)]

        case (.ready, .failure(let failure)):
            guard try settle(failure.id) else { return [] }
            return [.failed(failure)]

        case (.ready, .pairChallenge), (.ready, .pairProof), (.ready, .pairResult), (.ready, .pairConfirm):
            return [.pairing(message)]

        case (_, .ping(let ping)):
            return [.send(.pong(ping))]
        case (_, .pong(let ping)):
            return [.pong(nonce: ping.nonce)]
        case (_, .close(let close)):
            state = .closed
            return [.closed(reason: close.reason)]

        default:
            throw WireError.unexpected(message.frameType)
        }
    }

    /// True if `id` was waiting for an answer; false for one we gave up on; throws for an id we
    /// never sent — a host answering questions nobody asked is not following the protocol.
    private mutating func settle(_ id: UInt32) throws -> Bool {
        if inFlight.remove(id) != nil { return true }
        if abandoned.remove(id) != nil { return false }
        throw WireError.unknownRequestID(id)
    }
}
