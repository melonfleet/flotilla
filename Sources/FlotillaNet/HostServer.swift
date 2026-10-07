import Foundation
import Network
import FlotillaCore
import FlotillaTrust

/// What a listening host asks of the app: who it trusts, what it is showing, and what the owner
/// says. Called on a connection's queue; implementations hop to their own.
public protocol HostServerDelegate: AnyObject, Sendable {
    /// Whether this key is an approved admin in the host's `PeerBook`.
    func isTrusted(_ fingerprint: PeerFingerprint) -> Bool
    /// The code on this host's screen, if the owner asked for one.
    func currentPairingCode() -> PairingCode?
    /// A wrong code was tried; count it against the code.
    func pairingCodeFailed()
    /// The enrolment key from this host's profile, or pasted.
    func enrolmentKey() -> EnrolmentKey?
    /// Trust this admin: its key was named by the enrolment key, or both owners confirmed the words.
    func trust(admin: PeerFingerprint, details: PeerDetails, method: Peer.Method)
    /// Code pairing: show the owner these words and the admin's details; call `reply` with their answer.
    func confirmWords(_ words: [String], admin: PeerDetails, reply: @escaping @Sendable (Bool) -> Void)
    /// Whether the owner removed or turned away this admin — its enrolment key then counts for nothing.
    func isBlocked(_ fingerprint: PeerFingerprint) -> Bool
    /// Enrolment: what the admin Mac made of this host's request.
    func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String)
    /// A trusted admin's command, for the host's own record (Activity).
    func ran(_ command: ValidatedCommand, for admin: PeerFingerprint)
}

extension HostServerDelegate {
    public func ran(_ command: ValidatedCommand, for admin: PeerFingerprint) {}
}

/// Host mode's listener (PLAN.md Phase B, B3): accepts TLS connections on the host-mode port, gives
/// each a `WireHostSession` — trusted or not, by the caller's fingerprint — runs what a trusted
/// admin asks through `ContainerHost`, and routes a stranger's pairing to `PairingHostSession`.
public final class HostServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var identity: DeviceIdentity
        public var port: UInt16
        public var info: WirePeerInfo
        public var details: PeerDetails
        public var limits: WireLimits
        public var mountPolicy: MountPolicy
        /// Advertise over Bonjour under this name, or not at all when `nil`.
        public var bonjourName: String?
        /// Admission (Iris's review, 7 October): connections at once, from one address, and commands
        /// running at once across every connection — counted until the process actually exits,
        /// not until the caller stops waiting, so a cancel cannot free a slot early.
        public var maxConnections = 32
        public var maxConnectionsPerAddress = 4
        public var maxRunningCommands = 8
        /// How long a connection may take to finish TLS, and a pairing to finish (it waits on people).
        public var readyTimeout: TimeInterval = 10
        public var pairingTimeout: TimeInterval = 180
        /// This Mac's local hostname, advertised beside the name.
        public var hostname: String?

        public init(identity: DeviceIdentity, port: UInt16 = WireProtocol.defaultPort, info: WirePeerInfo,
                    details: PeerDetails, limits: WireLimits = .default, mountPolicy: MountPolicy = .denyHostPaths,
                    bonjourName: String? = nil) {
            self.identity = identity
            self.port = port
            self.info = info
            self.details = details
            self.limits = limits
            self.mountPolicy = mountPolicy
            self.bonjourName = bonjourName
        }
    }

    public enum State: Sendable, Equatable { case stopped, starting, listening(port: UInt16), failed(String) }

    public let configuration: Configuration
    let host: ContainerHost
    let crypto: PairingCrypto
    weak var delegate: HostServerDelegate?
    private let queue = DispatchQueue(label: "dev.melonfleet.Flotilla.host-server")
    private var listener: NWListener?
    private var handlers: [ObjectIdentifier: HostConnectionHandler] = [:]
    private var addresses: [ObjectIdentifier: String] = [:]
    private let runLock = NSLock()
    private var running = 0

    /// A slot for one command, host-wide, or `false` if all are taken.
    func reserveRun() -> Bool {
        runLock.withLock {
            guard running < configuration.maxRunningCommands else { return false }
            running += 1
            return true
        }
    }

    func releaseRun() { runLock.withLock { running -= 1 } }

    public private(set) var state: State = .stopped
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(configuration: Configuration, host: ContainerHost, delegate: HostServerDelegate,
                crypto: PairingCrypto = .system) {
        self.configuration = configuration
        self.host = host
        self.delegate = delegate
        self.crypto = crypto
    }

    public func start() throws {
        let parameters = WireTLS.parameters(identity: configuration.identity, server: true)
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw NWError.posix(.EINVAL)
        }
        let listener = try NWListener(using: parameters, on: port)
        if let name = configuration.bonjourName {
            // The fingerprint rides along, so an admin recognises this host by its key whatever it
            // is called — a rename changes the name, never the key. Not secret: TLS shows it to
            // anyone who connects.
            listener.service = NWListener.Service(name: name, type: WireTLS.serviceType, domain: nil,
                                                  txtRecord: WireTLS.txtRecord(for: configuration.identity.fingerprint,
                                                                               macOSVersion: configuration.details.macOSVersion,
                                                                               hostname: configuration.hostname))
        }
        listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        set(.starting)
        listener.start(queue: queue)
    }

    /// Stops listening and closes every connection.
    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for handler in handlers.values { handler.connection.close("host mode stopped") }
            handlers.removeAll()
            set(.stopped)
        }
    }

    /// Closes every live connection from this key — on revocation, at once (PLAN.md Phase B).
    public func disconnect(_ fingerprint: PeerFingerprint) {
        queue.async { [self] in
            for handler in handlers.values where handler.connection.peerFingerprint == fingerprint {
                handler.connection.close("access revoked")
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: set(.listening(port: listener?.port?.rawValue ?? configuration.port))
        case .failed(let error): set(.failed(error.localizedDescription))
        case .cancelled: set(.stopped)
        default: break
        }
    }

    private func set(_ new: State) {
        state = new
        onStateChange?(new)
    }

    /// Turns a connection away before anything is built for it when the host, or that address, is
    /// at its limit — a flood of connections then costs a refused socket each, not a session.
    private func accept(_ nw: NWConnection) {
        let address: String = if case .hostPort(let host, _) = nw.endpoint { "\(host)" } else { "\(nw.endpoint)" }
        guard handlers.count < configuration.maxConnections,
              addresses.values.filter({ $0 == address }).count < configuration.maxConnectionsPerAddress else {
            nw.cancel()
            return
        }
        let connection = WireConnection(nw, limits: configuration.limits, label: "host-connection")
        let handler = HostConnectionHandler(connection: connection, server: self)
        let key = ObjectIdentifier(handler)
        handlers[key] = handler
        addresses[key] = address
        connection.onClose = { [weak self] _ in
            self?.queue.async { self?.handlers[key] = nil; self?.addresses[key] = nil }
        }
        handler.start()
    }
}

/// One accepted connection on the host.
final class HostConnectionHandler: @unchecked Sendable {
    let connection: WireConnection
    unowned let server: HostServer
    private var session: WireHostSession?
    private var pairing: PairingHostSession?
    private var handshakeTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var pairingTimer: DispatchSourceTimer?

    init(connection: WireConnection, server: HostServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        // TLS must finish in time, or the connection goes: a peer that opens and stalls holds nothing.
        handshakeTimer = timer(after: server.configuration.readyTimeout) { [weak self] in
            if self?.session == nil { self?.connection.close("TLS took too long") }
        }
        connection.onReady = { [weak self] in self?.ready() }
        connection.onMessage = { [weak self] message in self?.received(message) }
        let previous = connection.onClose
        connection.onClose = { [weak self] reason in
            self?.handshakeTimer?.cancel()
            self?.idleTimer?.cancel()
            self?.pairingTimer?.cancel()
            previous?(reason)
        }
        connection.start()
    }

    private var limits: WireLimits { session?.limits ?? server.configuration.limits }

    private func ready() {
        guard let peer = connection.peerFingerprint else { return connection.close("no certificate") }
        let trusted = server.delegate?.isTrusted(peer) ?? false
        session = WireHostSession(peer: server.configuration.info, limits: server.configuration.limits,
                                  mountPolicy: server.configuration.mountPolicy, trusted: trusted)
        handshakeTimer?.cancel()
        handshakeTimer = timer(after: server.configuration.limits.handshakeTimeout) { [weak self] in
            if case .awaitingHello = self?.session?.state { self?.connection.close("no hello in time") }
        }
        resetIdle()
    }

    private func received(_ message: WireMessage) {
        resetIdle()
        guard var session else { return }
        do {
            let events = try session.receive(message)
            self.session = session
            if case .ready = session.state {
                handshakeTimer?.cancel()
                connection.adopt(session.limits)
            }
            for event in events { handle(event) }
        } catch {
            connection.close("protocol error: \(error)")
        }
    }

    private func handle(_ event: WireHostSession.Event) {
        switch event {
        case .send(let message): connection.send(message)
        case .close(let reason): connection.close(reason)
        case .execute(let id, let command, let deadline): execute(id, command, deadline)
        case .cancel(let id):
            if let reply = session?.fail(id, code: .cancelled, message: "Cancelled.") { connection.send(reply) }
        case .pairing(let message): pair(message)
        }
    }

    /// Runs off the connection's queue — a long pull must not stall pings — and reports back on it.
    /// A cancelled command is answered at once and its eventual result discarded: `ContainerHost`
    /// cannot stop a child mid-run (Q15), so the honest answer is that the caller stopped waiting.
    private func execute(_ id: UInt32, _ command: ValidatedCommand, _ deadline: TimeInterval) {
        guard server.reserveRun() else {
            if let reply = session?.fail(id, code: .busy, message: "This host is already running as many commands as it allows. Try again shortly.") {
                connection.send(reply)
            }
            return
        }
        let server = self.server
        let host = server.host
        if let admin = connection.peerFingerprint { server.delegate?.ran(command, for: admin) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<CommandResult, Error> = Result { try host.run(command.arguments, timeout: deadline) }
            // Released when the process is done, whether or not anyone still waits for it.
            server.releaseRun()
            guard let self else { return }
            self.connection.queue.async {
                let reply: WireMessage?
                switch outcome {
                case .success(let result): reply = self.session?.complete(id, with: result)
                case .failure(let error):
                    let code: WireFailureCode = if case ContainerCLIError.timedOut = error { .timedOut } else { .internalError }
                    reply = self.session?.fail(id, code: code, message: String(describing: error))
                }
                if let reply { self.connection.send(reply) }
            }
        }
    }

    // MARK: Pairing

    private func pair(_ message: WireMessage) {
        guard let admin = connection.peerFingerprint, let delegate = server.delegate else { return }
        if pairing == nil {
            pairing = PairingHostSession(own: server.configuration.identity.fingerprint, admin: admin,
                                         details: server.configuration.details,
                                         enrolmentKey: delegate.enrolmentKey(),
                                         currentCode: { [weak delegate] in delegate?.currentPairingCode() },
                                         adminBlocked: delegate.isBlocked(admin), crypto: server.crypto)
            // A pairing has an end, whatever keeps the connection alive in the meantime.
            pairingTimer = timer(after: server.configuration.pairingTimeout) { [weak self] in
                guard let state = self?.pairing?.state, state != .done else { return }
                self?.connection.close("pairing took too long")
            }
        }
        guard var pairing else { return }
        do {
            let events = try pairing.receive(message)
            self.pairing = pairing
            handlePairing(events)
        } catch {
            connection.close("pairing error: \(error)")
        }
    }

    private func handlePairing(_ events: [PairingHostSession.Event]) {
        guard let delegate = server.delegate else { return }
        for event in events {
            switch event {
            case .send(let message): connection.send(message)
            case .adminTrusted(let admin, let details): delegate.trust(admin: admin, details: details, method: .enrolmentKey)
            case .enrolmentAnswered(let outcome, let message): delegate.enrolmentAnswered(outcome, message: message)
            case .codeFailed: delegate.pairingCodeFailed()
            case .confirmWords(let words, let details):
                delegate.confirmWords(words, admin: details) { [weak self] confirmed in
                    guard let self else { return }
                    self.connection.queue.async {
                        guard var pairing = self.pairing else { return }
                        let next = pairing.confirm(confirmed)
                        self.pairing = pairing
                        self.handlePairing(next)
                    }
                }
            case .paired(let admin, let details): delegate.trust(admin: admin, details: details, method: .pairingCode)
            case .failed: break
            case .close(let reason): connection.close(reason)
            }
        }
    }

    // MARK: Timers

    private func resetIdle() {
        idleTimer?.cancel()
        idleTimer = timer(after: limits.idleTimeout) { [weak self] in self?.connection.close("idle") }
    }

    private func timer(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: connection.queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: fire)
        timer.resume()
        return timer
    }
}
