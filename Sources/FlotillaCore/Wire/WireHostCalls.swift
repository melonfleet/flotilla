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
    /// `system dns create`, run by the host's DNS helper.
    case dnsCreate(domain: String, localhost: String?)
    /// `system dns delete`, run by the host's DNS helper.
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
        case .dnsStatus: return nil
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
    public var mutates: Bool { self != .dnsStatus }

    /// How long the host may take. A runtime restart waits for every container to stop.
    public var timeout: TimeInterval {
        switch self {
        case .dnsStatus: 30
        case .dnsCreate, .dnsDelete: 60
        case .setContainerDNSDomain: 300
        }
    }

    /// For the host's own record.
    public var auditDescription: String {
        switch self {
        case .dnsStatus: "read DNS settings"
        case .dnsCreate(let domain, let localhost): localhost == nil ? "created DNS domain \(domain)" : "created host alias \(domain)"
        case .dnsDelete(let domains): "deleted DNS domain" + (domains.count == 1 ? " \(domains[0])" : "s \(domains.joined(separator: ", "))")
        case .setContainerDNSDomain(let domain): domain.map { "named containers under \($0)" } ?? "stopped naming containers"
        }
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
