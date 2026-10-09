import Foundation
import IOKit
import SystemConfiguration
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
        /// The fingerprint prefix the host advertises, if it does — how a renamed host is still
        /// recognised. Matched, never trusted: the full key is checked when connecting.
        let fingerprintHint: String?
        let macOSVersion: String?
        let hostname: String?
        var id: String { name }

        /// What tells two Macs with the same name apart: hostname, macOS, the key's first characters.
        var distinguishing: String {
            [hostname.map { "\($0).local" }, macOSVersion.map { "macOS \($0)" },
             fingerprintHint.map { "key " + $0.prefix(8).uppercased() }].compactMap { $0 }.joined(separator: " · ")
        }
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

    /// What a paired host last answered, for the Hosts columns. Absent until first asked.
    struct LiveStatus: Equatable {
        enum State: Equatable { case checking, connected, failed(String) }
        var state: State
        var containersRunning: Int?
        var containersTotal: Int?
        var machines: Int?
        var containerVersion: String?
        /// The host's Flotilla, as its welcome said.
        var appVersion: String? = nil
        var checkedAt: Date
    }
    private(set) var live: [PeerFingerprint: LiveStatus] = [:]
    /// Each paired host's containers, as last fetched — kept through failures, with their age
    /// (PLAN.md Phase C). The Containers section lists these beside This Mac's.
    private(set) var containerSnapshots: [PeerFingerprint: FleetSnapshot<Container>] = [:]
    /// The same for images, volumes and networks — fetched on the same ask, so a host costs one
    /// round of reads per interval whichever sections are open.
    private(set) var imageSnapshots: [PeerFingerprint: FleetSnapshot<ContainerImage>] = [:]
    /// Each host's DNS rows (D3), and the rest of what its `.dnsStatus` said — the domain its
    /// containers are named under and whether its helper is switched on.
    private(set) var dnsSnapshots: [PeerFingerprint: FleetSnapshot<LocalDNSDomain>] = [:]
    private(set) var dnsStatus: [PeerFingerprint: HostDNSStatus] = [:]
    /// Each host's chip, memory and disk (version 4), for Overview. Kept when a later ask fails:
    /// the last answer is the best there is, and the table marks the host as not answering.
    private(set) var facts: [PeerFingerprint: HostFacts] = [:]
    private(set) var volumeSnapshots: [PeerFingerprint: FleetSnapshot<ContainerVolume>] = [:]
    private(set) var networkSnapshots: [PeerFingerprint: FleetSnapshot<ContainerNetwork>] = [:]
    @ObservationIgnored private var backoff: [PeerFingerprint: HostBackoff] = [:]
    /// Shown as fresh for this long; older, or after a failed ask, the rows say how old they are.
    static let freshFor: TimeInterval = 75
    @ObservationIgnored private var remotes: [PeerFingerprint: RemoteHost] = [:]

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
    @ObservationIgnored private var enrolmentsInFlight = 0
    /// Bounds on automatic enrolment, so a network full of fake adverts costs little (Iris's review).
    static let maxConcurrentEnrolments = 2
    static let maxDiscovered = 64
    /// How long before a Mac that refused is asked again — its profile may arrive later.
    static let autoEnrolRetry: TimeInterval = 120
    @ObservationIgnored var recordActivity: ((ContainerEvent) -> Void)?
    /// Host side (D3): performs an admin's host call — set by `AppModel`, which owns the DNS code.
    @ObservationIgnored var performHostCall: ((HostCall) async -> Result<String, HostCallFailure>)?
    /// The name the listener is advertising, so a rename of this Mac can be noticed.
    @ObservationIgnored private var advertisedName: String?
    @ObservationIgnored private var renameTimer: Timer?

    // MARK: Imported hosts (DECISIONS Q34)

    /// A host named in an imported `.flotilla` file and not yet paired: who, where, and the key it
    /// must present. **Not in the peer book** — the book is trust, and an imported claim is none;
    /// it becomes a peer only by being paired, and pairing it is refused if the key differs.
    struct ImportedHost: Codable, Hashable, Identifiable {
        let name: String
        let endpoint: PeerEndpoint
        let fingerprint: PeerFingerprint
        var id: String { fingerprint.hex }
    }

    /// Imported hosts the book does not hold yet, in the order they were imported.
    private(set) var importedHosts: [ImportedHost] = []
    /// Where imported hosts and address blocks are kept — this Mac's own bookkeeping, never trust.
    @ObservationIgnored private let localStore: UserDefaults
    static let importedHostsKey = "importedHosts"

    /// Adds a file's hosts as rows to pair. Returns how many were new — one already in the book or
    /// already imported is left as it is.
    @discardableResult
    func importHosts(_ specs: [HostSpec]) -> Int {
        var added = 0
        for spec in specs {
            guard let fingerprint = PeerFingerprint(hex: spec.fingerprint), book[fingerprint] == nil,
                  !importedHosts.contains(where: { $0.fingerprint == fingerprint }) else { continue }
            let endpoint: PeerEndpoint
            if let address = spec.address, let port = spec.port.flatMap(UInt16.init(exactly:)) {
                endpoint = .address(host: address, port: port)
            } else if let bonjour = spec.bonjourName {
                endpoint = .bonjour(name: bonjour)
            } else { continue }
            importedHosts.append(ImportedHost(name: spec.name, endpoint: endpoint, fingerprint: fingerprint))
            record(spec.name, "Imported — not paired yet")
            added += 1
        }
        saveImported()
        return added
    }

    func removeImported(_ fingerprint: PeerFingerprint) {
        importedHosts.removeAll { $0.fingerprint == fingerprint }
        saveImported()
    }

    /// Every fingerprint this Mac knows, in the book or imported — the import review's clash check.
    var knownFingerprints: Set<String> {
        Set(book.peers.map(\.fingerprint.hex) + importedHosts.map(\.fingerprint.hex))
    }

    // MARK: Address blocks (PLAN.md Phase D; DECISIONS Q35)

    /// Each Mac's own `/20`, keyed `local` for This Mac and by fingerprint hex for a host.
    /// Assigned the first time it is needed and kept; a removed host's block is given back.
    private(set) var addressBlocks: [String: IPv4Block] = [:]
    static let addressBlocksKey = "addressBlocks"

    // MARK: Names across Macs (Q37)

    /// This Mac's answers for other Macs' zones: the last table the admin sent (on a host), or the
    /// one built here (on the admin). Kept across launches, so a host answers before the admin
    /// reconnects.
    private(set) var fleetTable: FleetNameTable?
    static let fleetTableKey = "fleetNameTable"
    @ObservationIgnored let fleetResponder = FleetDNSResponder()
    /// The zones this Mac's resolver files were last synced to, so the helper is asked only on a change.
    @ObservationIgnored var syncedFleetZones: [String]?
    /// Why names across Macs aren't fully working here, or `nil`.
    var fleetNamesProblem: String?
    /// Admin side: the table each host was last sent, and what it said.
    @ObservationIgnored var sentFleetTables: [PeerFingerprint: FleetNameTable] = [:]
    private(set) var fleetNamesResults: [PeerFingerprint: String?] = [:]

    func setFleetTable(_ table: FleetNameTable?) {
        fleetTable = table
        localStore.set(table.flatMap { try? PropertyListEncoder().encode($0) }, forKey: Self.fleetTableKey)
    }

    func noteFleetNamesResult(_ fingerprint: PeerFingerprint, _ problem: String?) {
        fleetNamesResults[fingerprint] = .some(problem)
    }

    /// Called after each refresh of the hosts — the admin's moment to rebuild and send the table.
    @ObservationIgnored var onRefreshed: (() -> Void)?

    // MARK: Updating hosts (Q38)

    /// Hosts being sent or installing an update now.
    var updating: Set<PeerFingerprint> = []
    /// Hosts installing or upgrading `container` now (Q39).
    var settingUpRuntime: Set<PeerFingerprint> = []
    /// The admin build a host last failed to update to, and why — not retried automatically.
    var updateFailures: [PeerFingerprint: (build: Int, message: String)] = [:]
    /// A rolling update is under way.
    var rollingOut = false
    /// Host side: performs an update the admin sent — set by `AppModel`.
    @ObservationIgnored var installUpdate: ((URL, @escaping @Sendable () -> Bool) async -> Result<String, HostCallFailure>)?
    static func blockKey(_ host: HostRef) -> String {
        switch host {
        case .local: "local"
        case .peer(let fingerprint): fingerprint.hex
        }
    }

    /// Brings the plan up to date: a block for This Mac and every trusted host, none overlapping
    /// `avoid` — this Mac's interfaces and every network subnet any Mac reported.
    func updateAddressPlan(avoiding avoid: [IPv4Block]) {
        let macs = ["local"] + trustedHosts.map(\.fingerprint.hex)
        let planned = AddressPlan.assign(macs, existing: addressBlocks, avoid: avoid)
        guard planned != addressBlocks else { return }
        addressBlocks = planned
        localStore.set(try? PropertyListEncoder().encode(planned), forKey: Self.addressBlocksKey)
    }

    private func saveImported() {
        localStore.set(try? PropertyListEncoder().encode(importedHosts), forKey: Self.importedHostsKey)
    }

    init(settings: SettingsStore, containerHost: ContainerHost,
         bookStore: PeerBookStore = PeerBookStore(), keyStore: EnrolmentKeyStore = .standard,
         identityStore: DeviceIdentityStore = .standard, localStore: UserDefaults = .standard) {
        self.localStore = localStore
        importedHosts = localStore.data(forKey: Self.importedHostsKey)
            .flatMap { try? PropertyListDecoder().decode([ImportedHost].self, from: $0) } ?? []
        addressBlocks = localStore.data(forKey: Self.addressBlocksKey)
            .flatMap { try? PropertyListDecoder().decode([String: IPv4Block].self, from: $0) } ?? [:]
        fleetTable = localStore.data(forKey: Self.fleetTableKey)
            .flatMap { try? PropertyListDecoder().decode(FleetNameTable.self, from: $0) }
        self.settings = settings
        self.containerHost = containerHost
        self.bookStore = bookStore
        self.keyStore = keyStore
        self.identityStore = identityStore
        book = bookStore.load()
        adminKey = keyStore.adminKey()
        mode = settings[SettingsKeys.mode].effective
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
        let newMode = settings[SettingsKeys.mode].effective
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
        return PeerDetails(computerName: Self.computerName,
                           model: Self.sysctlString("hw.model"),
                           serialNumber: Self.serialNumber(),
                           macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    var ownInfo: WirePeerInfo {
        WirePeerInfo(name: Self.computerName, appVersion: Self.appVersion, macOSVersion: ownDetails.macOSVersion)
    }

    /// This Flotilla's version with its build number — `0.0.0 (304)` — so two builds of one
    /// release can be told apart when comparing Macs (PLAN.md Phase C: version skew).
    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              Int(build) != nil else { return short }
        return "\(short) (\(build))"
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
        let name = Self.computerName
        var configuration = HostServer.Configuration(
            identity: identity, port: port, info: ownInfo, details: ownDetails,
            bonjourName: settings[SettingsKeys.bonjourEnabled] ? name : nil)
        configuration.hostname = Self.localHostname
        advertisedName = Self.nameSignature
        // A rename of this Mac restarts the listener, so it advertises — and introduces itself
        // as — the new name (measured 7 October: a renamed VM kept its old name everywhere).
        renameTimer?.invalidate()
        renameTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isHost, Self.nameSignature != self.advertisedName else { return }
                self.stopListening()
                self.startListening()
            }
        }
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
        renameTimer?.invalidate()
        renameTimer = nil
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
        dropRemote(fingerprint)
        record(name(fingerprint), "Access removed")
    }

    /// Forgets a Mac entirely; it can ask again from scratch.
    func remove(_ fingerprint: PeerFingerprint) {
        let label = name(fingerprint)
        book.remove(fingerprint)
        save()
        server?.disconnect(fingerprint)
        dropRemote(fingerprint)
        record(label, "Removed")
    }

    func rename(_ fingerprint: PeerFingerprint, to nickname: String?) {
        book.rename(fingerprint, to: nickname)
        save()
    }

    private func name(_ fingerprint: PeerFingerprint) -> String { book[fingerprint]?.displayName ?? "A Mac" }

    private func save() {
        try? bookStore.save(book)
        // A host now in the book is no longer an imported claim, whichever way it got there.
        if importedHosts.contains(where: { book[$0.fingerprint] != nil }) {
            importedHosts.removeAll { book[$0.fingerprint] != nil }
            saveImported()
        }
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
    ///
    /// `expecting` is an imported host's fingerprint (Q34): the key it must present. Checked as soon
    /// as the encrypted connection is up and **before** any pairing message, so a different Mac at
    /// that address learns nothing and is asked nothing.
    func addHost(at endpoint: NWEndpoint, code: String?, expecting: PeerFingerprint? = nil) async -> AddHostOutcome {
        guard let identity = ensureIdentity() else { return .failed(identityProblem ?? "No identity.") }
        let connection = AdminConnection(endpoint: endpoint, identity: identity, info: ownInfo)
        defer { connection.close() }
        do {
            let welcome = try await connection.connect()
            guard let hostPrint = connection.hostFingerprint else { return .failed("The host presented no identity.") }
            // Pairing a Mac with itself would put both halves of the words prompt on one screen.
            guard hostPrint != identity.fingerprint else { return .failed("That address is this Mac.") }
            if let expecting, hostPrint != expecting {
                return .failed("The Mac at that address presented a different key from the one in the imported file. "
                               + "It may be another Mac, or this one was reinstalled. Not paired — check with its owner.")
            }
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
                if let hint = PeerEndpoint(endpoint) { book.setEndpoint(fingerprint, hint) }
                save()
                record(details.computerName, "Paired")
                return .paired(details.computerName)
            case .enrolment(let fingerprint, let details, let result):
                if let hint = PeerEndpoint(endpoint) {
                    book.setEndpoint(fingerprint, hint)
                    save()
                }
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
        // One comparison at a time. A second arriving while the owner reads the first is refused,
        // rather than replacing it and leaving the first waiting for ever (Iris's review).
        guard wordsPrompt == nil else { return false }
        return await withCheckedContinuation { continuation in
            wordsPrompt = WordsPrompt(words: words, peer: peer, role: role) { [weak self] answer in
                self?.wordsPrompt = nil
                continuation.resume(returning: answer)
            }
        }
    }

    // MARK: Paired hosts (admin)

    /// The book's entry for a found Mac, matched by the key it advertises.
    func knownHost(advertising host: DiscoveredHost) -> Peer? {
        guard let hint = host.fingerprintHint else { return nil }
        return hosts.first { WireTLS.fingerprintHint($0.fingerprint) == hint }
    }

    /// The `ContainerHost` for an approved host, or `nil` if it is not approved or cannot be
    /// located. Reused, so a host keeps one connection.
    func remoteHost(for fingerprint: PeerFingerprint) -> RemoteHost? {
        guard let peer = book[fingerprint], peer.isTrusted, peer.role == .host,
              let identity = ensureIdentity() else { return nil }
        // Found on the network by its key, whatever it is called now; else where it was last.
        let advertised = discovered.first { $0.fingerprintHint == WireTLS.fingerprintHint(fingerprint) }
        let hint = advertised.flatMap { PeerEndpoint($0.endpoint) } ?? peer.endpoint
        if let cached = remotes[fingerprint], hint == nil || PeerEndpoint(cached.endpoint) == hint { return cached }
        remotes.removeValue(forKey: fingerprint)?.close()
        guard let hint, let endpoint = hint.nwEndpoint else { return nil }
        if peer.endpoint != hint {
            book.setEndpoint(fingerprint, hint)
            save()
        }
        let remote = RemoteHost(endpoint: endpoint, fingerprint: fingerprint, identity: identity, info: ownInfo)
        remotes[fingerprint] = remote
        return remote
    }

    private func dropRemote(_ fingerprint: PeerFingerprint) {
        remotes.removeValue(forKey: fingerprint)?.close()
        live.removeValue(forKey: fingerprint)
        containerSnapshots.removeValue(forKey: fingerprint)
        imageSnapshots.removeValue(forKey: fingerprint)
        dnsSnapshots.removeValue(forKey: fingerprint)
        dnsStatus.removeValue(forKey: fingerprint)
        facts.removeValue(forKey: fingerprint)
        volumeSnapshots.removeValue(forKey: fingerprint)
        networkSnapshots.removeValue(forKey: fingerprint)
        backoff.removeValue(forKey: fingerprint)
    }

    /// Asks every approved host that is due for its version, containers and machines — the Hosts
    /// columns and the fleet-wide Containers list. Read-only calls, through the same Allowlist as
    /// everything else. A host that keeps failing is asked less often (`HostBackoff`); `force`
    /// asks every one now, as Refresh does.
    func refreshLiveStatus(force: Bool = false) async {
        let now = Date()
        let due = hosts.filter { peer in
            guard peer.isTrusted else { return false }
            if force { backoff[peer.fingerprint, default: HostBackoff()].forceDue() }
            return backoff[peer.fingerprint, default: HostBackoff()].isDue(at: now)
        }
        await withTaskGroup(of: Void.self) { group in
            for peer in due {
                group.addTask { await self.refreshLiveStatus(peer.fingerprint) }
            }
        }
        if !due.isEmpty { onRefreshed?() }
    }

    /// The paired, trusted hosts and what each last said about its containers.
    var fleetContainers: [(host: Peer, snapshot: FleetSnapshot<Container>)] { fleet(containerSnapshots) }
    var fleetImages: [(host: Peer, snapshot: FleetSnapshot<ContainerImage>)] { fleet(imageSnapshots) }
    var fleetDNS: [(host: Peer, snapshot: FleetSnapshot<LocalDNSDomain>)] { fleet(dnsSnapshots) }
    var fleetVolumes: [(host: Peer, snapshot: FleetSnapshot<ContainerVolume>)] { fleet(volumeSnapshots) }
    var fleetNetworks: [(host: Peer, snapshot: FleetSnapshot<ContainerNetwork>)] { fleet(networkSnapshots) }

    private func fleet<T>(_ snapshots: [PeerFingerprint: FleetSnapshot<T>]) -> [(host: Peer, snapshot: FleetSnapshot<T>)] {
        hosts.filter(\.isTrusted).compactMap { peer in snapshots[peer.fingerprint].map { (peer, $0) } }
    }

    /// Paired, trusted hosts — the choices every Host filter and Host picker offers.
    var trustedHosts: [Peer] { hosts.filter(\.isTrusted) }

    func hostName(_ host: HostRef, local: String) -> String {
        switch host {
        case .local: local
        case .peer(let fingerprint): hosts.first { $0.fingerprint == fingerprint }?.displayName ?? "a host"
        }
    }

    /// The `ContainerCLI` for a host — This Mac's own, or a paired host's over the wire, held to
    /// `.remotePeer`. `nil` for a host that is not approved or cannot be located.
    func cli(for host: HostRef, local: ContainerCLI) -> ContainerCLI? {
        switch host {
        case .local: return local
        case .peer(let fingerprint):
            return remoteHost(for: fingerprint).map {
                ContainerCLI(host: $0, mountPolicy: .denyHostPaths, wirePolicy: .remotePeer)
            }
        }
    }

    /// After an action on a host: ask it again now, not at the next tick.
    func refreshHost(_ fingerprint: PeerFingerprint) async {
        backoff[fingerprint, default: HostBackoff()].forceDue()
        await refreshLiveStatus(fingerprint)
    }

    private func refreshLiveStatus(_ fingerprint: PeerFingerprint) async {
        guard let remote = remoteHost(for: fingerprint) else {
            live[fingerprint] = LiveStatus(state: .failed("Can't find it on the network. Add it again by address."),
                                           checkedAt: Date())
            return
        }
        var status = live[fingerprint] ?? LiveStatus(state: .checking, checkedAt: Date())
        if status.state != .connected { status.state = .checking }
        live[fingerprint] = status
        let cli = ContainerCLI(host: remote, mountPolicy: .denyHostPaths, wirePolicy: .remotePeer)
        let outcome = await Task.detached { () -> Result<(String?, [Container], Int), Error> in
            Result {
                let version = try cli.versions().first { $0.appName.lowercased().contains("container") }?.version
                return (version, try cli.listContainers(), try cli.machines().count)
            }
        }.value
        // The other lists, each on its own: one failing does not blank the others.
        if case .success = outcome {
            let (images, volumes, networks) = await Task.detached {
                (Result { try cli.listImages() }, Result { try cli.listVolumes() }, Result { try cli.listNetworks() })
            }.value
            let at = Date()
            switch images {
            case .success(let list): imageSnapshots[fingerprint, default: FleetSnapshot()].succeeded(list, at: at)
            case .failure(let error): imageSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: at)
            }
            switch volumes {
            case .success(let list): volumeSnapshots[fingerprint, default: FleetSnapshot()].succeeded(list, at: at)
            case .failure(let error): volumeSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: at)
            }
            switch networks {
            case .success(let list): networkSnapshots[fingerprint, default: FleetSnapshot()].succeeded(list, at: at)
            case .failure(let error): networkSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: at)
            }
            await refreshDNS(fingerprint, remote: remote)
            if let result = try? await remote.call(.hostFacts),
               let answer = try? JSONDecoder().decode(HostFacts.self, from: Data(result.stdout.utf8)) {
                facts[fingerprint] = answer
            }
        }
        let now = Date()
        switch outcome {
        case .success(let (version, containers, machines)):
            containerSnapshots[fingerprint, default: FleetSnapshot()].succeeded(containers, at: now)
            backoff[fingerprint, default: HostBackoff()].succeeded(at: now)
            live[fingerprint] = LiveStatus(state: .connected,
                                           containersRunning: containers.filter { $0.state.isRunning }.count,
                                           containersTotal: containers.count, machines: machines,
                                           containerVersion: version, appVersion: remote.hostInfo?.appVersion,
                                           checkedAt: Date())
            book.markSeen(fingerprint, at: Date())
            // Whatever it calls itself now — a renamed host shows its new name here.
            if let info = remote.hostInfo,
               book.refresh(fingerprint, computerName: info.name, macOSVersion: info.macOSVersion) {
                record(info.name, "Name or version updated")
            }
            save()
        case .failure(let error):
            containerSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: now)
            imageSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: now)
            volumeSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: now)
            networkSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: now)
            backoff[fingerprint, default: HostBackoff()].failed(at: now)
            // Its Flotilla still answered: keep its version, so a host without `container` is still
            // seen as behind and can be updated (measured 8 October, Tahoe showed "—" and was skipped).
            live[fingerprint] = LiveStatus(state: .failed(Self.describe(error)), appVersion: remote.hostInfo?.appVersion,
                                           checkedAt: Date())
            // Connected but a command failed — a host without `container` — still says who it is.
            // Measured 7 October: a renamed VM kept its old name because only success refreshed it.
            if let info = remote.hostInfo,
               book.refresh(fingerprint, computerName: info.name, macOSVersion: info.macOSVersion) {
                record(info.name, "Name or version updated")
                save()
            }
        }
    }

    /// A host's DNS (D3). A host whose Flotilla predates host calls says so in its rows' place.
    func refreshDNS(_ fingerprint: PeerFingerprint, remote: RemoteHost? = nil) async {
        guard let remote = remote ?? remoteHost(for: fingerprint) else { return }
        let at = Date()
        do {
            let result = try await remote.call(.dnsStatus)
            let status = try JSONDecoder().decode(HostDNSStatus.self, from: Data(result.stdout.utf8))
            dnsStatus[fingerprint] = status
            dnsSnapshots[fingerprint, default: FleetSnapshot()].succeeded(status.domains, at: at)
        } catch {
            dnsSnapshots[fingerprint, default: FleetSnapshot()].failed(Self.describe(error), at: at)
        }
    }

    /// Asks a host to do something to its DNS, then reads its DNS again.
    func dnsCall(_ call: HostCall, on fingerprint: PeerFingerprint) async throws {
        guard let remote = remoteHost(for: fingerprint) else {
            throw RemoteHostError.unreachable("That host isn't paired, or can't be found on the network.")
        }
        defer { Task { await self.refreshDNS(fingerprint, remote: remote) } }
        _ = try await remote.call(call)
    }

    /// A remote failure in a sentence. The common one on a Mac without `container` is the CLI's own
    /// "not found", which arrives as the host's failure message.
    nonisolated static func describe(_ error: Error) -> String {
        if let remote = error as? RemoteHostError { return remote.description }
        return "\(error)"
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
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WireTLS.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var hint: String?, os: String?, host: String?
                if case .bonjour(let txt) = result.metadata { hint = txt["fp"]; os = txt["os"]; host = txt["host"] }
                return DiscoveredHost(name: name, endpoint: result.endpoint, fingerprintHint: hint,
                                      macOSVersion: os, hostname: host)
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
        let ownHint = identity.map { WireTLS.fingerprintHint($0.fingerprint) }
        discovered = Array(found.filter { $0.fingerprintHint != ownHint && $0.name != Self.computerName }
            .sorted { $0.name < $1.name }.prefix(Self.maxDiscovered))
        // Forget attempts for adverts that are gone, so the record cannot grow without end.
        let present = Set(discovered.map(\.name))
        autoEnrolAttempts = autoEnrolAttempts.filter { present.contains($0.key) }
        enrolDiscovered()
    }

    /// Asks each found Mac this admin does not know to enrol, at most once per retry interval.
    private func enrolDiscovered() {
        guard adminKey != nil else { return }
        // Known by key when the host advertises one, by name otherwise.
        let knownKeys = Set(hosts.map { WireTLS.fingerprintHint($0.fingerprint) })
        let knownNames = Set(hosts.map(\.details.computerName))
        let now = Date()
        for host in discovered {
            if let hint = host.fingerprintHint { if knownKeys.contains(hint) { continue } }
            else if knownNames.contains(host.name) { continue }
            if let last = autoEnrolAttempts[host.name], now.timeIntervalSince(last) < Self.autoEnrolRetry { continue }
            guard enrolmentsInFlight < Self.maxConcurrentEnrolments else { return }
            autoEnrolAttempts[host.name] = now
            enrolmentsInFlight += 1
            Task {
                _ = await addHost(at: host.endpoint, code: nil)
                enrolmentsInFlight -= 1
            }
        }
    }

    // MARK: Bridge events (host side)

    fileprivate func adminTrusted(_ fingerprint: PeerFingerprint, details: PeerDetails, method: Peer.Method) {
        if method == .enrolmentKey {
            // A removed admin's key does not bring it back; only a code pairing or Allow Again does.
            guard book.admitByEnrolmentKey(fingerprint, details: details, at: Date()) else { return }
        } else {
            book.pairConfirmed(fingerprint, role: .admin, details: details, method: method, at: Date())
        }
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

    /// Host side: let a removed admin Mac back in — the owner's explicit decision.
    func allowAgain(_ fingerprint: PeerFingerprint) {
        guard book.approve(fingerprint, at: Date()) else { return }
        save()
        record(name(fingerprint), "Allowed again")
    }

    fileprivate func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String) {
        enrolmentStatus = message
    }

    fileprivate func ran(_ command: ValidatedCommand, admin: PeerFingerprint) {
        guard command.mutates else { return }
        record(name(admin), "Ran " + command.auditDescription)
    }

    /// An admin's host call: recorded when it changes something, then performed by the model.
    fileprivate func perform(_ call: HostCall, admin: PeerFingerprint) async -> Result<String, HostCallFailure> {
        guard let performHostCall else { return .failure(HostCallFailure(.internalError, "This host isn't ready.")) }
        if call.mutates { record(name(admin), call.auditDescription.prefix(1).uppercased() + call.auditDescription.dropFirst()) }
        return await performHostCall(call)
    }

    private func refreshBridge() {
        bridge.update(trustedAdmins: Set(book.approved.filter { $0.role == .admin }.map(\.fingerprint)),
                      blockedAdmins: Set(admins.filter { book.isBlocked($0.fingerprint) }.map(\.fingerprint)),
                      code: pairingCode, key: hostEnrolmentKey?.key)
        bridge.setAcceptsUpdates(settings[SettingsKeys.acceptAdminUpdates])
    }

    private func record(_ subject: String, _ action: String) {
        recordActivity?(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: subject, action: action))
    }

    // MARK: Facts about this Mac

    /// The computer name as it is now. `Host.current().localizedName` can lag a rename made while
    /// the app runs; SystemConfiguration's answer does not.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// The local hostname (`name` in `name.local`), as System Settings ▸ General ▸ Sharing sets it.
    static var localHostname: String? { SCDynamicStoreCopyLocalHostName(nil) as String? }

    /// Both names, so a change to either re-advertises.
    static var nameSignature: String { computerName + "\u{1}" + (localHostname ?? "") }

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
    private var blockedAdmins: Set<PeerFingerprint> = []
    private var code: PairingCode?
    private var key: EnrolmentKey?
    @MainActor weak var controller: HostModeController?

    private var acceptsUpdates = true
    func setAcceptsUpdates(_ on: Bool) { lock.lock(); acceptsUpdates = on; lock.unlock() }

    func acceptsAppUpdates() -> String? {
        lock.lock(); defer { lock.unlock() }
        return acceptsUpdates ? nil : "This host doesn't take flotilla updates from its admin — its owner turned that off."
    }

    func installUpdate(archive: URL, isIdle: @escaping @Sendable () -> Bool,
                       reply: @escaping @Sendable (Result<String, HostCallFailure>) -> Void) {
        Task { @MainActor in
            guard let install = self.controller?.installUpdate else {
                return reply(.failure(HostCallFailure(.internalError, "This host isn't ready.")))
            }
            reply(await install(archive, isIdle))
        }
    }

    func update(trustedAdmins: Set<PeerFingerprint>, blockedAdmins: Set<PeerFingerprint>,
                code: PairingCode?, key: EnrolmentKey?) {
        lock.lock(); defer { lock.unlock() }
        self.trustedAdmins = trustedAdmins
        self.blockedAdmins = blockedAdmins
        self.code = code
        self.key = key
    }

    func isBlocked(_ fingerprint: PeerFingerprint) -> Bool { lock.lock(); defer { lock.unlock() }; return blockedAdmins.contains(fingerprint) }

    func isTrusted(_ fingerprint: PeerFingerprint) -> Bool { lock.lock(); defer { lock.unlock() }; return trustedAdmins.contains(fingerprint) }
    func currentPairingCode() -> PairingCode? { lock.lock(); defer { lock.unlock() }; return code }
    func enrolmentKey() -> EnrolmentKey? { lock.lock(); defer { lock.unlock() }; return key }

    /// Counted here, at once, under the lock — so the next proof on any connection sees it, not
    /// whenever the main actor catches up (Iris's review: each session had its own copy).
    func pairingCodeFailed() {
        lock.lock()
        if var current = code {
            code = current.recordFailure(at: Date()) ? current : nil
        }
        lock.unlock()
        Task { @MainActor in self.controller?.codeFailed() }
    }

    func trust(admin: PeerFingerprint, details: PeerDetails, method: Peer.Method) {
        // Trusted now, for the next connection, before the main actor catches up — unless the
        // owner removed it and this is only its key talking.
        lock.lock()
        if method == .enrolmentKey, blockedAdmins.contains(admin) { lock.unlock(); return }
        trustedAdmins.insert(admin)
        blockedAdmins.remove(admin)
        lock.unlock()
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

    func perform(_ call: HostCall, for admin: PeerFingerprint,
                 reply: @escaping @Sendable (Result<String, HostCallFailure>) -> Void) {
        Task { @MainActor in
            guard let controller = self.controller else {
                return reply(.failure(HostCallFailure(.internalError, "This host isn't ready.")))
            }
            reply(await controller.perform(call, admin: admin))
        }
    }
}
