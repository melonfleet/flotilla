import Foundation
import IOKit
import Network
import FlotillaCore
import FlotillaTrust
import FlotillaNet

/// Host mode inside the app (PLAN.md Phase B, B3b): this Mac's identity, the `PeerBook`, the
/// listener when this Mac is a host, the pairing code it shows, the fingerprint-words prompt, the
/// fleet enrolment key when it is an admin, and Bonjour discovery.
///
/// One owner for all of it, on the main actor. The listener asks its questions from its own
/// threads, so it talks to `HostDelegateBridge` — a locked snapshot of what it may know — and the
/// bridge posts what happens back here.
@MainActor
@Observable
final class HostModeController {
    enum ListenerStatus: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// The four words both owners compare, waiting for this owner's answer.
    struct WordsPrompt: Identifiable {
        let id = UUID()
        let words: [String]
        /// The other Mac, as it describes itself.
        let peer: PeerDetails
        let role: Peer.Role
        let reply: (Bool) -> Void
    }

    struct DiscoveredHost: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    let settings: SettingsStore
    private(set) var identity: DeviceIdentity?
    private(set) var identityProblem: String?
    private(set) var book: PeerBook
    private(set) var listener: ListenerStatus = .off
    private(set) var pairingCode: PairingCode?
    var wordsPrompt: WordsPrompt?
    /// Host side: what the admin Mac said about this Mac's enrolment.
    private(set) var enrolmentStatus: String?
    private(set) var adminKey: EnrolmentKey?
    private(set) var discovered: [DiscoveredHost] = []

    @ObservationIgnored private let containerHost: ContainerHost
    @ObservationIgnored private let bookStore: PeerBookStore
    @ObservationIgnored private let keyStore: EnrolmentKeyStore
    @ObservationIgnored private let identityStore: DeviceIdentityStore
    @ObservationIgnored private var server: HostServer?
    @ObservationIgnored private let bridge = HostDelegateBridge()
    @ObservationIgnored private var browser: NWBrowser?
    /// When each discovered Mac was last asked to enrol, by Bonjour name.
    @ObservationIgnored private var autoEnrolAttempts: [String: Date] = [:]
    @ObservationIgnored private var autoEnrolTimer: Timer?
    /// How long before a Mac that refused is asked again — its profile may arrive later.
    static let autoEnrolRetry: TimeInterval = 120
    @ObservationIgnored var recordActivity: ((ContainerEvent) -> Void)?

    init(settings: SettingsStore, containerHost: ContainerHost,
         bookStore: PeerBookStore = PeerBookStore(), keyStore: EnrolmentKeyStore = .standard,
         identityStore: DeviceIdentityStore = .standard) {
        self.settings = settings
        self.containerHost = containerHost
        self.bookStore = bookStore
        self.keyStore = keyStore
        self.identityStore = identityStore
        book = bookStore.load()
        adminKey = keyStore.adminKey()
        mode = settings[SettingsKeys.mode]
        bridge.controller = self
    }

    /// Held here, not read through: `SettingsStore` is not observable, so a view reading the
    /// store would never redraw when the mode changed (measured: the listener started and the pane
    /// still showed admin-only sections). `apply()` refreshes it on every settings change.
    private(set) var mode: RunMode
    var isHost: Bool { mode != .client }
    var isAdmin: Bool { mode != .host }

    /// The hosts this admin knows, and the admins this host trusts.
    var hosts: [Peer] { book.peers.filter { $0.role == .host } }
    var admins: [Peer] { book.peers.filter { $0.role == .admin } }

    /// Called once at launch, and again when the mode or port changes.
    func apply() {
        let newMode = settings[SettingsKeys.mode]
        if newMode != mode { mode = newMode }
        let lapsed = book.expirePending(at: Date())
        if !lapsed.isEmpty {
            save()
            for peer in lapsed { record(peer.displayName, "Request expired") }
        }
        if isHost { startListening() } else { stopListening() }
        if isAdmin { startBrowsing() } else { stopBrowsing() }
        refreshBridge()
    }

    // MARK: Identity

    /// This Mac's identity, created the first time it is needed.
    @discardableResult
    func ensureIdentity() -> DeviceIdentity? {
        if let identity { return identity }
        do {
            identity = try identityStore.loadOrCreate()
            identityProblem = nil
        } catch {
            identityProblem = "\(error)"
        }
        return identity
    }

    /// What this Mac says about itself when pairing. The serial number goes only to the Mac it is
    /// pairing with, over TLS, so the owner can check it against the inventory — never into a
    /// support bundle or an export.
    var ownDetails: PeerDetails {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return PeerDetails(computerName: Host.current().localizedName ?? "Mac",
                           model: Self.sysctlString("hw.model"),
                           serialNumber: Self.serialNumber(),
                           macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    var ownInfo: WirePeerInfo {
        WirePeerInfo(name: Host.current().localizedName ?? "Mac",
                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                     macOSVersion: ownDetails.macOSVersion)
    }

    // MARK: Listening (host)

    private func startListening() {
        let port = UInt16(clamping: settings[SettingsKeys.hostListenPort])
        if let server, server.configuration.port == port, listener != .off { return }
        stopListening()
        guard let identity = ensureIdentity() else {
            listener = .failed(identityProblem ?? "No identity.")
            return
        }
        let configuration = HostServer.Configuration(
            identity: identity, port: port, info: ownInfo, details: ownDetails,
            bonjourName: settings[SettingsKeys.bonjourEnabled] ? ownInfo.name : nil)
        let server = HostServer(configuration: configuration, host: containerHost, delegate: bridge)
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state) }
        }
        do {
            try server.start()
            self.server = server
            listener = .starting
        } catch {
            listener = .failed(error.localizedDescription)
        }
    }

    private func stopListening() {
        server?.stop()
        server = nil
        listener = .off
    }

    private func listenerChanged(_ state: HostServer.State) {
        switch state {
        case .stopped: listener = .off
        case .starting: listener = .starting
        case .listening(let port): listener = .listening(port: port)
        case .failed(let why): listener = .failed(why)
        }
    }

    /// Host side: show a fresh one-time code.
    func showPairingCode() {
        pairingCode = PairingCode()
        refreshBridge()
    }

    func hidePairingCode() {
        pairingCode = nil
        refreshBridge()
    }

    /// Host side: the profile's key, or one the owner pasted.
    var hostEnrolmentKey: (key: EnrolmentKey, source: EnrolmentKeyStore.Source)? {
        if settings.isLocked(SettingsKeys.enrolmentKey) {
            return (try? EnrolmentKey(text: settings[SettingsKeys.enrolmentKey])).map { ($0, .profile) }
        }
        return keyStore.hostKey()
    }

    var managedEnrolmentKeyProblem: String? {
        guard settings.isLocked(SettingsKeys.enrolmentKey) else { return nil }
        do { _ = try EnrolmentKey(text: settings[SettingsKeys.enrolmentKey]); return nil }
        catch { return "\(error)" }
    }

    func setPastedEnrolmentKey(_ text: String) throws {
        try keyStore.setPastedHostKey(text)
        refreshBridge()
    }

    func removePastedEnrolmentKey() {
        keyStore.removePastedHostKey()
        refreshBridge()
    }

    // MARK: Fleet enrolment key (admin)

    /// Creates the key, or replaces it. Replacing stops new enrolments with the old one; Macs
    /// already enrolled are unaffected.
    func rotateEnrolmentKey() {
        guard let identity = ensureIdentity() else { return }
        let existed = adminKey != nil
        do {
            adminKey = try keyStore.rotate(for: identity.fingerprint)
            record("Fleet enrolment key", existed ? "Replaced" : "Created")
            // A new key changes every answer: ask the Macs already found again, now.
            autoEnrolAttempts.removeAll()
            apply()
            enrolDiscovered()
        } catch {
            identityProblem = "\(error)"
        }
    }

    // MARK: The book

    func approve(_ fingerprint: PeerFingerprint) {
        guard book.approve(fingerprint, at: Date()) else { return }
        save()
        record(name(fingerprint), "Approved")
    }

    func reject(_ fingerprint: PeerFingerprint) {
        guard book.reject(fingerprint, at: Date()) else { return }
        save()
        record(name(fingerprint), "Turned away")
    }

    /// Takes trust away and closes any live connection from that key at once.
    func revoke(_ fingerprint: PeerFingerprint) {
        guard book.revoke(fingerprint, at: Date()) else { return }
        save()
        server?.disconnect(fingerprint)
        record(name(fingerprint), "Access removed")
    }

    /// Forgets a Mac entirely; it can ask again from scratch.
    func remove(_ fingerprint: PeerFingerprint) {
        let label = name(fingerprint)
        book.remove(fingerprint)
        save()
        server?.disconnect(fingerprint)
        record(label, "Removed")
    }

    func rename(_ fingerprint: PeerFingerprint, to nickname: String?) {
        book.rename(fingerprint, to: nickname)
        save()
    }

    private func name(_ fingerprint: PeerFingerprint) -> String { book[fingerprint]?.displayName ?? "A Mac" }

    private func save() {
        try? bookStore.save(book)
        refreshBridge()
    }

    // MARK: Adding a host (admin)

    enum AddHostOutcome: Equatable {
        case paired(String)
        case waitingForApproval(String)
        case alreadyPaired(String)
        case failed(String)
    }

    /// Connects to a host and pairs with it — by the code it shows, or by this admin's enrolment key.
    func addHost(at endpoint: NWEndpoint, code: String?) async -> AddHostOutcome {
        guard let identity = ensureIdentity() else { return .failed(identityProblem ?? "No identity.") }
        let connection = AdminConnection(endpoint: endpoint, identity: identity, info: ownInfo)
        defer { connection.close() }
        do {
            let welcome = try await connection.connect()
            guard let hostPrint = connection.hostFingerprint else { return .failed("The host presented no identity.") }
            // Pairing a Mac with itself would put both halves of the words prompt on one screen.
            guard hostPrint != identity.fingerprint else { return .failed("That address is this Mac.") }
            if welcome.trusted, book.isTrusted(hostPrint) { return .alreadyPaired(welcome.peer.name) }
            let method: PairingAdminSession.Method
            if let code, !code.trimmingCharacters(in: .whitespaces).isEmpty {
                method = .pairingCode(code)
            } else if let adminKey {
                method = .enrolmentKey(adminKey)
            } else {
                return .failed("Enter the code the other Mac shows, or create a fleet enrolment key first.")
            }
            let outcome = try await connection.pair(
                details: ownDetails, method: method,
                confirmWords: { [weak self] words, details in
                    await self?.askWords(words, peer: details, role: .host) ?? false
                },
                recordEnrolment: { [weak self] fingerprint, details in
                    await self?.recordEnrolment(fingerprint, details) ?? .blocked
                })
            switch outcome {
            case .paired(let fingerprint, let details):
                book.pairConfirmed(fingerprint, role: .host, details: details, at: Date())
                save()
                record(details.computerName, "Paired")
                return .paired(details.computerName)
            case .enrolment(_, let details, let result):
                switch result {
                case .alreadyApproved: return .alreadyPaired(details.computerName)
                case .blocked: return .failed("\(details.computerName) was turned away before. Approve it from Hosts to let it in.")
                case .addedPending, .stillPending: return .waitingForApproval(details.computerName)
                }
            }
        } catch {
            return .failed("\(error)")
        }
    }

    private func recordEnrolment(_ fingerprint: PeerFingerprint, _ details: PeerDetails) -> PeerBook.Outcome {
        let outcome = book.requestEnrolment(fingerprint, role: .host, details: details, at: Date())
        save()
        if outcome == .addedPending { record(details.computerName, "Asked to join") }
        return outcome
    }

    /// Shows the words and waits for the owner.
    func askWords(_ words: [String], peer: PeerDetails, role: Peer.Role) async -> Bool {
        await withCheckedContinuation { continuation in
            wordsPrompt = WordsPrompt(words: words, peer: peer, role: role) { [weak self] answer in
                self?.wordsPrompt = nil
                continuation.resume(returning: answer)
            }
        }
    }

    // MARK: Discovery (admin)

    /// Browses for hosts advertising Flotilla. While this admin has an enrolment key, each found
    /// host it does not already know is asked to enrol — when found, when the key is created, and
    /// again every couple of minutes (measured 7 October: a VM given its key after it was found
    /// never appeared, because the only ask had come first). A host whose key names this admin
    /// then waits in Hosts for approval; any other host refuses and is asked again later.
    private func startBrowsing() {
        guard browser == nil else { return }
        autoEnrolTimer = Timer.scheduledTimer(withTimeInterval: Self.autoEnrolRetry / 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enrolDiscovered() }
        }
        let browser = NWBrowser(for: .bonjour(type: WireTLS.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.discoveredChanged(found) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopBrowsing() {
        autoEnrolTimer?.invalidate()
        autoEnrolTimer = nil
        browser?.cancel()
        browser = nil
        discovered = []
    }

    private func discoveredChanged(_ found: [DiscoveredHost]) {
        let own = Host.current().localizedName
        discovered = found.filter { $0.name != own }.sorted { $0.name < $1.name }
        enrolDiscovered()
    }

    /// Asks each found Mac this admin does not know to enrol, at most once per retry interval.
    private func enrolDiscovered() {
        guard adminKey != nil else { return }
        let known = Set(hosts.map(\.details.computerName))
        let now = Date()
        for host in discovered where !known.contains(host.name) {
            if let last = autoEnrolAttempts[host.name], now.timeIntervalSince(last) < Self.autoEnrolRetry { continue }
            autoEnrolAttempts[host.name] = now
            Task { _ = await addHost(at: host.endpoint, code: nil) }
        }
    }

    // MARK: Bridge events (host side)

    fileprivate func adminTrusted(_ fingerprint: PeerFingerprint, details: PeerDetails, method: Peer.Method) {
        book.pairConfirmed(fingerprint, role: .admin, details: details, method: method, at: Date())
        save()
        if method == .pairingCode { pairingCode = nil; refreshBridge() }
        record(details.computerName, method == .enrolmentKey ? "Admin Mac enrolled this Mac" : "Paired as admin")
    }

    fileprivate func codeFailed() {
        guard var code = pairingCode else { return }
        if !code.recordFailure(at: Date()) {
            pairingCode = nil
            record("Pairing code", "Withdrawn after too many wrong tries")
        } else {
            pairingCode = code
        }
        refreshBridge()
    }

    fileprivate func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String) {
        enrolmentStatus = message
    }

    fileprivate func ran(_ command: ValidatedCommand, admin: PeerFingerprint) {
        guard command.mutates else { return }
        record(name(admin), "Ran " + command.auditDescription)
    }

    private func refreshBridge() {
        bridge.update(trustedAdmins: Set(book.approved.filter { $0.role == .admin }.map(\.fingerprint)),
                      code: pairingCode, key: hostEnrolmentKey?.key)
    }

    private func record(_ subject: String, _ action: String) {
        recordActivity?(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: subject, action: action))
    }

    // MARK: Facts about this Mac

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    private static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// What the listener may know, from any thread: a locked snapshot the controller refreshes, and a
/// way to send events back to the main actor.
final class HostDelegateBridge: HostServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var trustedAdmins: Set<PeerFingerprint> = []
    private var code: PairingCode?
    private var key: EnrolmentKey?
    @MainActor weak var controller: HostModeController?

    func update(trustedAdmins: Set<PeerFingerprint>, code: PairingCode?, key: EnrolmentKey?) {
        lock.lock(); defer { lock.unlock() }
        self.trustedAdmins = trustedAdmins
        self.code = code
        self.key = key
    }

    func isTrusted(_ fingerprint: PeerFingerprint) -> Bool { lock.lock(); defer { lock.unlock() }; return trustedAdmins.contains(fingerprint) }
    func currentPairingCode() -> PairingCode? { lock.lock(); defer { lock.unlock() }; return code }
    func enrolmentKey() -> EnrolmentKey? { lock.lock(); defer { lock.unlock() }; return key }

    func pairingCodeFailed() { Task { @MainActor in self.controller?.codeFailed() } }

    func trust(admin: PeerFingerprint, details: PeerDetails, method: Peer.Method) {
        // Trusted now, for the next connection, before the main actor catches up.
        lock.lock(); trustedAdmins.insert(admin); lock.unlock()
        Task { @MainActor in self.controller?.adminTrusted(admin, details: details, method: method) }
    }

    func confirmWords(_ words: [String], admin: PeerDetails, reply: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in
            guard let controller = self.controller else { return reply(false) }
            reply(await controller.askWords(words, peer: admin, role: .admin))
        }
    }

    func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String) {
        Task { @MainActor in self.controller?.enrolmentAnswered(outcome, message: message) }
    }

    func ran(_ command: ValidatedCommand, for admin: PeerFingerprint) {
        Task { @MainActor in self.controller?.ran(command, admin: admin) }
    }
}
