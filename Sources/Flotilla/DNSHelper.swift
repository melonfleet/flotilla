import Foundation
import ServiceManagement
import FlotillaCore
import FlotillaPrivileged

/// The app's side of the DNS helper (decision 19, amended 7 October): installing and removing it,
/// asking whether it is approved, and sending it requests.
///
/// Installing registers an `SMAppService` daemon; macOS then lists it in System Settings ▸ Login
/// Items, and nothing runs as root until the owner switches it on there. Until then — and on any
/// build that is not Developer ID signed — DNS changes go through the password prompt exactly as
/// before (`AdminCommandRunner`). `AppModel.runPrivilegedDNS` makes that choice in one place.
@MainActor
enum DNSHelper {
    enum Status: Equatable {
        /// This build cannot use a helper: it is not Developer ID signed, so the helper would refuse
        /// it and it would refuse the helper.
        case unavailable
        case notInstalled
        /// Registered, waiting for the owner to switch it on in Login Items.
        case awaitingApproval
        case enabled
    }

    private static var service: SMAppService { .daemon(plistName: DNSHelperInterface.plistName) }
    /// Read once: a running process's signature does not change, and the screens ask often.
    private static let team = DNSHelperInterface.ownTeamIdentifier()

    static var status: Status {
        guard team != nil else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .awaitingApproval
        case .notRegistered, .notFound: return .notInstalled
        @unknown default: return .notInstalled
        }
    }

    /// Registers the daemon. macOS shows its own notification and lists it in Login Items; the
    /// helper runs only once the owner switches it on there.
    static func install() throws {
        try service.register()
    }

    static func remove() async throws {
        try await service.unregister()
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// One request. `nil` means it worked; otherwise the reason, in words fit for an alert.
    static func send(_ request: PrivilegedDNSRequest) async -> String? {
        guard let team else {
            return "This copy of Flotilla isn't signed, so it can't use the DNS helper."
        }
        let connection = NSXPCConnection(machServiceName: DNSHelperInterface.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DNSHelperProtocol.self)
        // The app checks the helper as the helper checks the app: same team, the helper's identity.
        connection.setCodeSigningRequirement(
            DNSHelperInterface.requirement(identifier: DNSHelperInterface.label, team: team))
        connection.resume()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume("Flotilla couldn't reach its DNS helper: \(error.localizedDescription)")
            } as? DNSHelperProtocol
            guard let proxy else {
                once.resume("Flotilla couldn't reach its DNS helper.")
                return
            }
            switch request {
            case .create(let domain, let localhost):
                proxy.createDomain(domain, localhost: localhost) { once.resume($0) }
            case .delete(let domains):
                proxy.deleteDomains(domains) { once.resume($0) }
            }
        }
    }
}

/// What may be asked of the helper — the whole of it.
enum PrivilegedDNSRequest: Sendable {
    case create(domain: String, localhost: String?)
    case delete([String])
}

/// XPC can call the error handler and the reply both; a continuation must resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension AppModel {
    /// Whether DNS changes go through the helper rather than the password prompt. Read fresh each
    /// time: approval is given or withdrawn in System Settings, which tells the app nothing.
    var dnsHelperEnabled: Bool { DNSHelper.status == .enabled }

    /// The one place a privileged DNS change is made: through the helper when the owner has
    /// approved it, otherwise behind the administrator prompt. Either way the request is validated
    /// — here for the prompt, and again by the helper itself.
    func runPrivilegedDNS(_ request: PrivilegedDNSRequest, prompt: String) async -> AdminCommandRunner.Outcome {
        if dnsHelperEnabled {
            if let failure = await DNSHelper.send(request) { return .failed(failure) }
            return .succeeded
        }
        var commands: [ValidatedCommand] = []
        switch request {
        case .create(let domain, let localhost):
            switch ContainerCLI.dnsCreateCommand(domain: domain, localhost: localhost) {
            case .success(let command): commands = [command]
            case .failure(let error): return .failed(String(describing: error))
            }
        case .delete(let domains):
            for domain in domains {
                switch ContainerCLI.dnsDeleteCommand(domain: domain) {
                case .success(let command): commands.append(command)
                case .failure(let error): return .failed(String(describing: error))
                }
            }
        }
        return AdminCommandRunner.run(commands, prompt: prompt)
    }
}
