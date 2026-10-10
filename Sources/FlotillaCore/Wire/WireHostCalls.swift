import Foundation

// Host calls, wire version 3 (PLAN.md Phase D, D3; DECISIONS Q36).
//
// A few things an admin asks of a host are not a `container` argv: what its DNS looks like (resolver
// files and `config.toml` as well as `dns list`), changes that need root (made by the host's own DNS
// helper, never by a command the peer sent), and choosing the domain its containers are named under
// (a file and a runtime restart). Each is a **typed** call, validated by the host exactly as its
// helper validates it, answered with an ordinary `result` (JSON in stdout) or `failure`.

/// What an admin may ask of a host beyond `container` commands — the whole of it.
public enum HostCall: Sendable, Equatable, Codable {
    /// The host's DNS rows, the domain its containers are named under, and its helper's state.
    case dnsStatus
    /// The host's chip, memory and disk, for Overview (version 4).
    case hostFacts
    /// The host's Flotilla settings — values, sources, sensitive ones without their value — for
    /// its page's Settings tab (version 8).
    case settingsReport
    /// The names of every other Mac's containers, for the host to answer (version 5, Q37). An
    /// empty table turns names across Macs off there.
    case setFleetNames(FleetNameTable)
    /// Install or upgrade `container` to the version the host's Flotilla expects, then the kernel —
    /// even if that stops running containers: the admin confirmed, with the count (version 7, Q39).
    case setUpRuntime
    /// `system dns create`, run by the host's Flotilla Helper.
    case dnsCreate(domain: String, localhost: String?)
    /// `system dns delete`, run by the host's Flotilla Helper.
    case dnsDelete(domains: [String])
    /// Name the host's containers under `domain` (or under none): edits its `config.toml` and
    /// restarts its runtime, which stops every container there.
    case setContainerDNSDomain(domain: String?)

    /// The most domains one delete may name.
    public static let maxDomainsPerDelete = 32

    /// Why the host must refuse this call, or `nil`. The same rules This Mac's DNS screens and the
    /// helper apply; a peer gets no looser grammar.
    public var problem: String? {
        func check(_ domain: String) -> String? {
            if let reserved = LocalDNS.reservedProblem(domain) { return reserved }
            if case .failure(let error) = ContainerCLI.dnsDeleteCommand(domain: domain) { return String(describing: error) }
            return nil
        }
        switch self {
        case .dnsStatus, .hostFacts, .settingsReport, .setUpRuntime: return nil
        case .setFleetNames(let table): return table.problem
        case .dnsCreate(let domain, let localhost):
            if let reserved = LocalDNS.reservedProblem(domain) { return reserved }
            if case .failure(let error) = ContainerCLI.dnsCreateCommand(domain: domain, localhost: localhost) {
                return String(describing: error)
            }
            return nil
        case .dnsDelete(let domains):
            guard !domains.isEmpty, domains.count <= Self.maxDomainsPerDelete else {
                return "A delete names between 1 and \(Self.maxDomainsPerDelete) domains."
            }
            return domains.lazy.compactMap(check).first
        case .setContainerDNSDomain(let domain):
            return domain.flatMap(check)
        }
    }

    /// Whether it changes the host.
    public var mutates: Bool { self != .dnsStatus && self != .hostFacts && self != .settingsReport }

    /// The protocol version a host must speak to be asked this.
    public var minimumVersion: UInt16 {
        switch self {
        case .hostFacts: WireProtocol.hostFactsVersion
        case .setFleetNames: WireProtocol.fleetNamesVersion
        case .setUpRuntime: WireProtocol.runtimeSetupVersion
        case .settingsReport: WireProtocol.settingsReportVersion
        default: WireProtocol.hostCallsVersion
        }
    }

    /// How long the host may take. A runtime restart waits for every container to stop.
    public var timeout: TimeInterval {
        switch self {
        case .dnsStatus, .hostFacts, .settingsReport: 30
        case .dnsCreate, .dnsDelete, .setFleetNames: 60
        case .setUpRuntime: 1800
        case .setContainerDNSDomain: 300
        }
    }

    /// For the host's own record.
    public var auditDescription: String {
        switch self {
        case .dnsStatus: "read DNS settings"
        case .hostFacts: "read its chip, memory and disk"
        case .settingsReport: "read its Flotilla settings"
        case .setUpRuntime: "installed or upgraded container"
        case .setFleetNames(let table): table.zones.isEmpty ? "turned off names across Macs"
                                                            : "updated names across Macs (\(table.zones.count) zones)"
        case .dnsCreate(let domain, let localhost): localhost == nil ? "created DNS domain \(domain)" : "created host alias \(domain)"
        case .dnsDelete(let domains): "deleted DNS domain" + (domains.count == 1 ? " \(domains[0])" : "s \(domains.joined(separator: ", "))")
        case .setContainerDNSDomain(let domain): domain.map { "named containers under \($0)" } ?? "stopped naming containers"
        }
    }
}

/// A host's answer to `.hostFacts`: what Overview shows for a Mac. Everything optional — a figure the
/// host could not read is left out rather than guessed.
public struct HostFacts: Sendable, Equatable, Codable {
    /// `Apple M1`, from `machdep.cpu.brand_string`.
    public var chip: String?
    public var cores: Int?
    /// The model identifier, `Macmini9,1`.
    public var model: String?
    public var macOSVersion: String?
    public var memoryTotalBytes: Int64?
    /// App memory plus wired plus compressed — the figure Activity Monitor calls Memory Used.
    public var memoryUsedBytes: Int64?
    /// The whole machine's CPU, as a percentage of every core.
    public var cpuPercent: Double?
    public var diskTotalBytes: Int64?
    /// Free for important use, as Finder counts it.
    public var diskFreeBytes: Int64?

    // For a host's page (the owner, 9 October). Added without a protocol bump: every field is
    // optional, so an older host's answer simply leaves them out.

    /// When the host read these facts — the page's "Last inventory update".
    public var readAt: Date?
    public var serialNumber: String?
    public var bootTime: Date?
    /// This Mac's IPv4 addresses on its network interfaces, loopback left out.
    public var ipv4Addresses: [String]?
    /// The same addresses with their interface's prefix, `10.20.4.17/23` — what Hosts groups by
    /// when it groups by subnet.
    public var ipv4Interfaces: [String]?
    public var timeZone: String?
    /// Whether the Mac has a battery, whether it is running on it, and its charge.
    public var hasBattery: Bool?
    public var onBattery: Bool?
    public var batteryPercent: Int?
    public var power: SystemReport.PowerSettings?
    public var fileVault: Bool?
    /// The macOS firewall (System Settings ▸ Network ▸ Firewall).
    public var firewall: Bool?
    /// Whether the Mac logs a user in automatically at startup — never which user. With FileVault
    /// on it cannot, and Flotilla then waits for a sign-in after a restart (`EnergyAdvice`).
    public var autoLogin: Bool?
    /// Whether Flotilla is a login item there, so it opens when its user is signed in.
    public var launchesAtLogin: Bool?
    public var remoteLogin: Bool?
    public var screenSharing: Bool?
    public var fileSharing: Bool?
    /// The account Flotilla runs under there — the one signed in. What SSH, Screen Sharing and File
    /// Sharing connect as unless the admin says otherwise.
    public var loginUser: String?
    /// Flotilla itself: where it is, whether a package installed it owned by root (so updates go
    /// through the helper, Q43), its role, and its helper.
    public var appPath: String?
    public var appOwnedByRoot: Bool?
    public var role: String?
    public var helper: HostDNSStatus.Helper?
    public var helperVersion: Int?
    public var acceptsAdminUpdates: Bool?
    public var installsContainerItself: Bool?
    public var kernelInstalled: Bool?

    public init(chip: String? = nil, cores: Int? = nil, model: String? = nil, macOSVersion: String? = nil,
                memoryTotalBytes: Int64? = nil, memoryUsedBytes: Int64? = nil, cpuPercent: Double? = nil,
                diskTotalBytes: Int64? = nil, diskFreeBytes: Int64? = nil) {
        self.chip = chip; self.cores = cores; self.model = model; self.macOSVersion = macOSVersion
        self.memoryTotalBytes = memoryTotalBytes; self.memoryUsedBytes = memoryUsedBytes; self.cpuPercent = cpuPercent
        self.diskTotalBytes = diskTotalBytes; self.diskFreeBytes = diskFreeBytes
    }
}

/// A host's answer to `.dnsStatus`.
public struct HostDNSStatus: Sendable, Equatable, Codable {
    public enum Helper: String, Sendable, Codable {
        /// Switched on: DNS changes can be made from the admin Mac.
        case enabled
        /// Installed, waiting for the host's owner to switch it on in Login Items.
        case awaitingApproval
        case notInstalled
        /// This build of Flotilla cannot use a helper (not Developer ID signed).
        case unavailable
    }

    public var domains: [LocalDNSDomain]
    public var containerDomain: String?
    public var helper: Helper

    public init(domains: [LocalDNSDomain], containerDomain: String?, helper: Helper) {
        self.domains = domains
        self.containerDomain = containerDomain
        self.helper = helper
    }
}

extension WireMessage {
    /// Admin → host: a typed call (version 3).
    public struct HostCallRequest: Sendable, Equatable, Codable {
        public var id: UInt32
        public var call: HostCall
        public init(id: UInt32, call: HostCall) { self.id = id; self.call = call }
    }
}

// MARK: - Host

extension WireHostSession {
    var hostCallsNegotiated: Bool {
        if case .ready(let version, _) = state { return version >= WireProtocol.hostCallsVersion }
        return false
    }

    mutating func handleHostCall(_ request: WireMessage.HostCallRequest) throws -> [Event] {
        guard hostCallsNegotiated else { throw WireError.unexpected(.hostCall) }
        guard trusted else {
            return [.send(.failure(.init(id: request.id, code: .refused, message: "This Mac hasn't been paired with this host.")))]
        }
        guard !idInUse(request.id) else { throw WireError.duplicateRequestID(request.id) }
        guard inFlight.count < limits.maxConcurrentRequests else {
            return [.send(.failure(.init(id: request.id, code: .busy,
                                         message: "This host is already running \(inFlight.count) requests from you.")))]
        }
        if let problem = request.call.problem {
            return [.send(.failure(.init(id: request.id, code: .refused, message: problem)))]
        }
        if case .ready(let version, _) = state, version < request.call.minimumVersion {
            return [.send(.failure(.init(id: request.id, code: .refused, message: "Not on this connection's version.")))]
        }
        inFlight.insert(request.id)
        return [.hostCall(id: request.id, call: request.call)]
    }
}

// MARK: - Admin

extension WireClientSession {
    /// Whether the host this session talks to answers host calls.
    public var canHostCall: Bool {
        if case .ready(let version, _) = state { return version >= WireProtocol.hostCallsVersion }
        return false
    }

    /// A host call. Its answer is an ordinary result or failure.
    public mutating func call(_ call: HostCall) throws -> Outgoing {
        guard case .ready = state else { throw state == .closed ? WireError.closed : WireError.notConnected }
        guard canHostCall else { throw WireError.hostCallsUnsupported }
        if case .ready(let version, _) = state, version < call.minimumVersion { throw WireError.hostCallsUnsupported }
        guard inFlight.count < limits.maxConcurrentRequests else {
            throw WireError.tooManyRequests(limit: limits.maxConcurrentRequests)
        }
        if let problem = call.problem { throw WireError.hostCallRefused(problem) }
        let id = takeID()
        inFlight.insert(id)
        return Outgoing(id: id, message: .hostCall(.init(id: id, call: call)),
                        deadline: call.timeout + limits.deadlineGrace)
    }
}
