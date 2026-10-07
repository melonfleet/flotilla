import Foundation
import CryptoKit
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
    /// A trusted admin's host call (D3), already validated. Answer exactly once: JSON (or nothing)
    /// on success, or why not. Called on a connection's queue; implementations hop to their own.
    func perform(_ call: HostCall, for admin: PeerFingerprint,
                 reply: @escaping @Sendable (Result<String, HostCallFailure>) -> Void)
}

/// Why a host would not, or could not, do what a host call asked.
public struct HostCallFailure: Error, Sendable {
    public var code: WireFailureCode
    public var message: String
    public init(_ code: WireFailureCode, _ message: String) { self.code = code; self.message = message }
}

extension HostServerDelegate {
    public func ran(_ command: ValidatedCommand, for admin: PeerFingerprint) {}
    public func perform(_ call: HostCall, for admin: PeerFingerprint,
                        reply: @escaping @Sendable (Result<String, HostCallFailure>) -> Void) {
        reply(.failure(HostCallFailure(.refused, "This host doesn't take that request.")))
    }
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
        /// Streams (D2): their per-connection bounds, and host-wide counts kept apart from
        /// `maxRunningCommands` so a row of live log views cannot starve real commands.
        public var streamLimits: WireStreamLimits = .default
        /// Eight follows and eight commands: the host runs at most sixteen children for admins.
        public var maxFollows = 8
        public var maxUploads = 2
        /// Free space an upload must leave: twice the archive (it is unpacked into the image
        /// store too) plus this, after every other upload's reservation.
        public var uploadReserveBytes: UInt64 = 2 << 30
        /// An upload must keep moving: no piece for this long ends it…
        public var uploadIdleTimeout: TimeInterval = 60
        /// …and so does taking longer than this plus a minute per 512 MiB.
        public var uploadBaseTimeout: TimeInterval = 30 * 60
        /// Where received archives wait to be loaded. Swept at start.
        public var transferRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.melonfleet.Flotilla.transfers", isDirectory: true)

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

    private var followCount = 0
    private var uploadCount = 0

    /// A slot for one follow, host-wide.
    func reserveFollow() -> Bool {
        runLock.withLock {
            guard followCount < configuration.maxFollows else { return false }
            followCount += 1
            return true
        }
    }
    func releaseFollow() { runLock.withLock { followCount -= 1 } }

    func reserveUpload() -> Bool {
        runLock.withLock {
            guard uploadCount < configuration.maxUploads else { return false }
            uploadCount += 1
            return true
        }
    }
    func releaseUpload() { runLock.withLock { uploadCount -= 1 } }

    /// Disk promised to uploads in progress, host-wide (Iris's review, High 3). An upload holds
    /// its reservation until its loader has exited and its folder is gone.
    private var diskReservations: [UUID: UInt64] = [:]

    /// Reserves `bytes` if `free`, less every other reservation, still leaves the reserve.
    func reserveDisk(_ bytes: UInt64, free: UInt64) -> UUID? {
        runLock.withLock {
            let others = diskReservations.values.reduce(0, &+)
            guard free >= others &+ bytes &+ configuration.uploadReserveBytes else { return nil }
            let token = UUID()
            diskReservations[token] = bytes
            return token
        }
    }

    /// Whether `needed` more still fits beside every other reservation — asked again before each
    /// grant of credit, because the disk is shared with everything else on the Mac.
    func diskStillFits(_ token: UUID, needed: UInt64, free: UInt64) -> Bool {
        runLock.withLock {
            let others = diskReservations.filter { $0.key != token }.values.reduce(0, &+)
            return free >= others &+ needed &+ configuration.uploadReserveBytes
        }
    }

    func releaseDisk(_ token: UUID) { runLock.withLock { _ = diskReservations.removeValue(forKey: token) } }

    /// The `container` this host runs, read at most every ten minutes — an upgrade between two
    /// uploads is seen, and a burst of uploads does not spawn a process each.
    private var containerVersion: (value: String?, read: Date)?
    func currentContainerVersion() -> String? {
        if let cached = runLock.withLock({ containerVersion }), Date().timeIntervalSince(cached.read) < 600 {
            return cached.value
        }
        let cli = ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: .localOwner)
        let value = (try? cli.versions())?.first { $0.appName.lowercased().contains("container") }?.version
        runLock.withLock { containerVersion = (value, Date()) }
        return value
    }

    /// Removes what a previous run left in the transfer folder — an archive only ever waits while
    /// its upload does. Only this user's own folders, named as an upload names them, are touched.
    private func sweepTransfers() {
        IncomingUpload.sweep(root: configuration.transferRoot)
    }

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
        sweepTransfers()
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
            self?.endStreams()
            previous?(reason)
        }
        connection.start()
    }

    private var limits: WireLimits { session?.limits ?? server.configuration.limits }

    private func ready() {
        guard let peer = connection.peerFingerprint else { return connection.close("no certificate") }
        let trusted = server.delegate?.isTrusted(peer) ?? false
        session = WireHostSession(peer: server.configuration.info, limits: server.configuration.limits,
                                  mountPolicy: server.configuration.mountPolicy, trusted: trusted,
                                  streamLimits: server.configuration.streamLimits)
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
        case .startFollow(let id, let command): startFollow(id, command)
        case .stopFollow(let id): followStreams[id]?.cancel()
        case .startUpload(let id, let upload): startUpload(id, upload)
        case .uploadChunk(let id, let data): write(id, data)
        case .uploadFinished(let id, let sha256): finishUpload(id, sha256)
        case .hostCall(let id, let call): perform(id, call)
        case .abortUpload(let id): discardUpload(id)
        }
    }

    // MARK: Streams (D2; research/WIRE-STREAMS-D2.md)

    private var followStreams: [UInt32: CommandStream] = [:]
    private var incoming: [UInt32: IncomingUpload] = [:]
    /// Batches follow output: lines are buffered as they come and sent every tick, so a chatty
    /// command becomes a few large frames rather than one per line (Iris's review, High 2).
    private var followTick: DispatchSourceTimer?

    private func sendAll(_ messages: [WireMessage]) { messages.forEach { connection.send($0) } }

    private func startFollow(_ id: UInt32, _ command: ValidatedCommand) {
        guard server.reserveFollow() else {
            sendAll(session?.followEnded(id, exitCode: nil, reason: "This host is already streaming as many logs as it allows.") ?? [])
            return
        }
        if let admin = connection.peerFingerprint { server.delegate?.ran(command, for: admin) }
        let queue = connection.queue
        let server = self.server
        do {
            followStreams[id] = try server.host.stream(command.arguments, onLine: { [weak self] line, channel in
                queue.async {
                    guard let self, var session = self.session else { return }
                    // The host's own command never produces a notice; anything but stderr is output.
                    session.followOutput(id, channel: channel == .stderr ? .stderr : .stdout, line: Data((line + "\n").utf8))
                    self.session = session
                }
            }, onEnd: { [weak self] end in
                server.releaseFollow()
                queue.async {
                    guard let self, var session = self.session else { return }
                    self.followStreams[id] = nil
                    let out = session.followEnded(id, exitCode: end.cancelled ? nil : end.exitCode,
                                                  reason: end.cancelled ? "stopped" : end.reason)
                    self.session = session
                    self.sendAll(out)
                    self.tickFollows()
                }
            })
            tickFollows()
        } catch {
            server.releaseFollow()
            sendAll(session?.followEnded(id, exitCode: nil, reason: String(describing: error)) ?? [])
        }
    }

    /// Runs the batching tick while any follow is open, and stops it when none is.
    private func tickFollows() {
        if followStreams.isEmpty {
            followTick?.cancel()
            followTick = nil
            return
        }
        guard followTick == nil else { return }
        let tick = DispatchSource.makeTimerSource(queue: connection.queue)
        tick.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        tick.setEventHandler { [weak self] in
            guard let self, var session = self.session, session.followsPending else { return }
            let out = session.flushFollows()
            self.session = session
            self.sendAll(out)
        }
        tick.resume()
        followTick = tick
    }

    private func freeSpace() -> UInt64 {
        let root = server.configuration.transferRoot
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return UInt64(max(0, free))
    }

    private func startUpload(_ id: UInt32, _ upload: WireMessage.Upload) {
        let server = self.server
        // Reading the host's `container` version may start a process: off this queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let version = server.currentContainerVersion()
            self?.connection.queue.async { self?.admitUpload(id, upload, containerVersion: version) }
        }
    }

    private func admitUpload(_ id: UInt32, _ upload: WireMessage.Upload, containerVersion: String?) {
        func refuse(_ code: WireFailureCode, _ message: String) {
            if let reply = session?.fail(id, code: code, message: message) { connection.send(reply) }
        }
        // Older loaders trust what is inside an archive (Iris's review, High 4).
        guard ImageTransfer.hostCanLoad(containerVersion: containerVersion) else {
            return refuse(.refused, "This host needs container \(ImageTransfer.minimumContainer) or later to receive images"
                          + (containerVersion.map { " — it has \($0)." } ?? "."))
        }
        guard server.reserveUpload() else {
            return refuse(.busy, "This host is already receiving as many images as it allows.")
        }
        // The archive, and the image store's copy of it.
        let needed = upload.bytes.multipliedReportingOverflow(by: 2).partialValue
        guard let token = server.reserveDisk(needed, free: freeSpace()) else {
            server.releaseUpload()
            return refuse(.refused, "This host hasn't room for that image: it needs about "
                          + ByteCountFormatter.string(fromByteCount: Int64(clamping: needed &+ server.configuration.uploadReserveBytes),
                                                      countStyle: .file) + " free.")
        }
        do {
            let sink = try IncomingUpload(root: server.configuration.transferRoot, reservation: token)
            incoming[id] = sink
            armUploadTimers(id, bytes: upload.bytes)
            if let credit = session?.acceptUpload(id) { connection.send(credit) }
        } catch {
            server.releaseDisk(token)
            server.releaseUpload()
            refuse(.internalError, "This host couldn't make room for the image: \(error.localizedDescription)")
        }
    }

    /// No piece for a minute, or the whole taking longer than its allowance, ends an upload.
    private func armUploadTimers(_ id: UInt32, bytes: UInt64) {
        guard let sink = incoming[id] else { return }
        let configuration = server.configuration
        let allowance = configuration.uploadBaseTimeout + 60 * Double(bytes / (512 << 20))
        sink.deadline = timer(after: allowance) { [weak self] in
            self?.connection.queue.async { self?.abandonUpload(id, "The image took too long to arrive.") }
        }
        resetUploadIdle(id)
    }

    private func resetUploadIdle(_ id: UInt32) {
        guard let sink = incoming[id] else { return }
        sink.idle?.cancel()
        sink.idle = timer(after: server.configuration.uploadIdleTimeout) { [weak self] in
            self?.connection.queue.async { self?.abandonUpload(id, "The image stopped arriving.") }
        }
    }

    /// Gives up on an upload still arriving, and says why.
    private func abandonUpload(_ id: UInt32, _ message: String) {
        guard incoming[id] != nil else { return }
        discardUpload(id)
        if let reply = session?.fail(id, code: .timedOut, message: message) { connection.send(reply) }
    }

    private func write(_ id: UInt32, _ data: Data) {
        guard let sink = incoming[id] else { return }
        resetUploadIdle(id)
        do {
            try sink.append(data)
            // Before inviting more, check the disk still has room for what is still to arrive and
            // for the image store's copy of the whole archive. What is written is already off `free`.
            if let remaining = session?.uploadRemaining(id), remaining > 0 {
                let needed = remaining &+ (sink.written &+ remaining)
                guard server.diskStillFits(sink.reservation, needed: needed, free: freeSpace()) else {
                    return abandonUpload(id, "This host ran short of disk space while receiving the image.")
                }
            }
            if let credit = session?.uploadWrote(id, bytes: UInt64(data.count)) { connection.send(credit) }
        } catch {
            discardUpload(id)
            let message = (error as NSError).code == Int(ENOSPC) || (error as? POSIXError)?.code == .ENOSPC
                ? "This host ran out of disk space while receiving the image."
                : "Writing the image failed: \(error.localizedDescription)"
            if let reply = session?.fail(id, code: .internalError, message: message) { connection.send(reply) }
        }
    }

    /// Every byte is here: check it is what was announced, then load it — with a command this host
    /// builds itself, for a file it chose, validated like any other. From here the upload cannot be
    /// stopped: a cancel only means the admin stops waiting (Iris's review, High 5).
    private func finishUpload(_ id: UInt32, _ sha256: String) {
        guard let sink = incoming.removeValue(forKey: id) else { return }
        sink.stopTimers()
        let server = self.server
        func finish(_ reply: WireMessage?) {
            sink.discard()
            server.releaseDisk(sink.reservation)
            server.releaseUpload()
            if let reply { connection.send(reply) }
        }
        guard sink.digest() == sha256 else {
            return finish(session?.fail(id, code: .invalidRequest, message: "The image arrived damaged — its digest didn't match."))
        }
        let command: ValidatedCommand
        do {
            command = try Allowlist.validated(["image", "load", "--input", sink.archive.path],
                                              mountPolicy: .roots([sink.directory.path]))
        } catch {
            return finish(session?.fail(id, code: .internalError, message: String(describing: error)))
        }
        guard server.reserveRun() else {
            return finish(session?.fail(id, code: .busy, message: "This host is already running as many commands as it allows."))
        }
        if let admin = connection.peerFingerprint { server.delegate?.ran(command, for: admin) }
        let host = server.host
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try host.run(command.arguments, timeout: command.timeoutHint) }
            server.releaseRun()
            // The archive goes only once the loader is done with it, and the disk with it.
            sink.discard()
            server.releaseDisk(sink.reservation)
            server.releaseUpload()
            guard let self else { return }
            self.connection.queue.async {
                let reply: WireMessage? = switch outcome {
                case .success(let result): self.session?.complete(id, with: result)
                case .failure(let error): self.session?.fail(id, code: .internalError, message: String(describing: error))
                }
                if let reply { self.connection.send(reply) }
            }
        }
    }

    private func discardUpload(_ id: UInt32) {
        guard let sink = incoming.removeValue(forKey: id) else { return }
        sink.stopTimers()
        sink.discard()
        server.releaseDisk(sink.reservation)
        server.releaseUpload()
    }

    /// The connection is gone: stop every follow, discard every half-received archive. A loader
    /// already running keeps its archive until it exits.
    private func endStreams() {
        connection.queue.async { [self] in
            followStreams.values.forEach { $0.cancel() }
            followStreams.removeAll()
            followTick?.cancel()
            followTick = nil
            for id in Array(incoming.keys) { discardUpload(id) }
        }
    }

    /// A host call (D3): counted against the host's command slots — it may start the DNS helper or
    /// restart the runtime — and answered on this connection's queue. Like a request, a cancel only
    /// means the admin stops waiting.
    private func perform(_ id: UInt32, _ call: HostCall) {
        guard let admin = connection.peerFingerprint, let delegate = server.delegate else {
            if let reply = session?.fail(id, code: .internalError, message: "This host isn't ready.") { connection.send(reply) }
            return
        }
        guard server.reserveRun() else {
            if let reply = session?.fail(id, code: .busy, message: "This host is already running as many commands as it allows.") {
                connection.send(reply)
            }
            return
        }
        let server = self.server
        let once = HostCallOnce()
        delegate.perform(call, for: admin) { [weak self] outcome in
            guard once.claim() else { return }
            server.releaseRun()
            guard let self else { return }
            self.connection.queue.async {
                let reply: WireMessage? = switch outcome {
                case .success(let json): self.session?.complete(id, with: CommandResult(stdout: json, stderr: "", exitCode: 0))
                case .failure(let failure): self.session?.fail(id, code: failure.code, message: failure.message)
                }
                if let reply { self.connection.send(reply) }
            }
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

/// An archive arriving on a host: a fresh private folder (0700) under the transfer root, one file
/// in it (0600), and a running SHA-256. Nothing outside this folder is ever written, and the folder
/// goes on every path out (`discard`).
///
/// Every step is taken without following links, and the root and the folder must be directories
/// this user owns that no one else can enter (Iris's review, Medium 6): a link or a borrowed folder
/// planted where the root should be would otherwise steer every archive somewhere else.
final class IncomingUpload: @unchecked Sendable {
    let directory: URL
    let archive: URL
    let reservation: UUID
    private let handle: FileHandle
    private var hasher = SHA256()
    private(set) var written: UInt64 = 0
    var idle: DispatchSourceTimer?
    var deadline: DispatchSourceTimer?

    init(root: URL, reservation: UUID) throws {
        self.reservation = reservation
        let rootFD = try Self.openPrivateDirectory(at: root.path, create: true)
        defer { close(rootFD) }
        // A new folder per upload, named at random, so nothing can be waiting in it.
        let name = UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        directory = root.appendingPathComponent(name, isDirectory: true)
        archive = directory.appendingPathComponent("image.tar")
        do {
            let folderFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folderFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(folderFD) }
            try Self.checkPrivate(folderFD)
            let fileFD = openat(folderFD, "image.tar", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fileFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        } catch {
            _ = unlinkat(rootFD, name, AT_REMOVEDIR)
            throw error
        }
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        written += UInt64(data.count)
    }

    func digest() -> String {
        try? handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func stopTimers() {
        idle?.cancel()
        deadline?.cancel()
        idle = nil
        deadline = nil
    }

    func discard() {
        stopTimers()
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Opens `path` as a directory without following a link, making it (0700) when absent, and
    /// refuses it unless this user owns it and no one else may enter.
    static func openPrivateDirectory(at path: String, create: Bool) throws -> Int32 {
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do { try checkPrivate(fd) } catch { close(fd); throw error }
        return fd
    }

    private static func checkPrivate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    /// Removes leftover upload folders: only directories under a private root, owned by this user,
    /// named as `init` names them. Anything else there is left alone.
    static func sweep(root: URL) {
        guard let rootFD = try? openPrivateDirectory(at: root.path, create: false) else { return }
        close(rootFD)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where UUID(uuidString: name) != nil {
            var info = stat()
            let path = root.appendingPathComponent(name).path
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// A delegate's reply may come once only; a second would free a command slot twice.
private final class HostCallOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}
