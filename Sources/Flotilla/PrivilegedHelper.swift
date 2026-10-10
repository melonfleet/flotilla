import Foundation
import ServiceManagement
import FlotillaCore
import FlotillaPrivileged

/// The app's side of the Flotilla Helper (decision 19, amended 7 October; Q41): installing and removing it,
/// asking whether it is approved, and sending it requests.
///
/// Installing registers an `SMAppService` daemon; macOS then lists it in System Settings ▸ Login
/// Items, and nothing runs as root until the owner switches it on there. Until then — and on any
/// build that is not Developer ID signed — DNS changes go through the password prompt exactly as
/// before (`AdminCommandRunner`). `AppModel.runPrivileged` makes that choice in one place.
@MainActor
enum PrivilegedHelper {
    enum Status: Equatable {
        /// This build cannot use a helper: it is not Developer ID signed, so the helper would refuse
        /// it and it would refuse the helper.
        case unavailable
        case notInstalled
        /// Registered, waiting for the owner to switch it on in Login Items.
        case awaitingApproval
        case enabled
    }

    private static var service: SMAppService { .daemon(plistName: HelperInterface.plistName) }
    private static var legacyService: SMAppService { .daemon(plistName: HelperInterface.legacyPlistName) }
    /// Read once: a running process's signature does not change, and the screens ask often.
    private static let team = HelperInterface.ownTeamIdentifier()

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

    /// Q41: the helper was `dev.melonfleet.Flotilla.dns-helper` until it took on more than DNS. A
    /// Mac that installed it under that name has it unregistered here, once, and the helper
    /// registered under its own name in its place. That carries the owner's earlier choice to
    /// install it, nothing more. Login Items approves an app's background items with one switch, so
    /// a Mac that had the old name on keeps the helper on (measured 8 October); one that never
    /// switched it on still has to.
    static func moveFromLegacyName() async {
        guard team != nil else { return }
        switch legacyService.status {
        case .enabled, .requiresApproval: break
        default: return
        }
        do { try await legacyService.unregister() } catch { return }
        if status == .notInstalled { try? install() }
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The running helper's interface version, or `nil` if it cannot be reached. A helper keeps
    /// running the binary it started with, so after an update it can be older than this app until
    /// it is switched off and on again.
    static func runningVersion() async -> Int? {
        if let version = await runningVersionOnce() { return version }
        // A helper whose app was replaced under it quits when it is next asked (`OwnBinary` in the
        // helper), and launchd starts the new copy on the request after — so ask once more.
        try? await Task.sleep(for: .seconds(1.5))
        return await runningVersionOnce()
    }

    private static func runningVersionOnce() async -> Int? {
        guard let team else { return nil }
        let connection = NSXPCConnection(machServiceName: HelperInterface.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.setCodeSigningRequirement(
            HelperInterface.requirement(identifier: HelperInterface.label, team: team))
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let once = VersionOnce(continuation)
            // `@Sendable`: XPC calls this on its own queue. Written inside this `@MainActor` type, an
            // unmarked closure is main-actor isolated, and Swift traps the moment XPC calls it off the
            // main thread — which crashed every host whose helper connection reported an error (the
            // mini at launch, Tahoe as its helper exited after installing an update; 9 October).
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(nil) } as? HelperProtocol
            guard let proxy else { once.resume(nil); return }
            proxy.helperVersion { once.resume($0) }
        }
    }

    /// One request. `nil` means it worked; otherwise the reason, in words fit for an alert.
    ///
    /// Tried twice when the helper cannot be reached: after the app is replaced the running helper
    /// is stale, quits when asked, and the next request starts the new one (10 October).
    static func send(_ request: HelperRequest) async -> String? {
        let first = await sendOnce(request)
        guard let first, first.hasPrefix(unreachable) else { return first }
        try? await Task.sleep(for: .seconds(1.5))
        return await sendOnce(request)
    }

    private static let unreachable = "Flotilla couldn't reach its Flotilla Helper"

    private static func sendOnce(_ request: HelperRequest) async -> String? {
        guard let team else {
            return "This copy of Flotilla isn't signed, so it can't use the Flotilla Helper."
        }
        switch request {
        case .installFlotillaUpdate:
            if let version = await runningVersion(), version < 4 {
                return "This Mac's Flotilla Helper is from an older Flotilla and can't install updates. "
                    + "Install this update with the package once; after that the helper installs them."
            }
        case .installContainer:
            if let version = await runningVersion(), version < 3 {
                return "The Flotilla Helper is from an older Flotilla. Switch it off and on again in "
                    + "Settings ▸ Advanced to update it."
            }
        case .syncFleetResolvers, .removeFleetResolvers:
            // Added in version 2: an older helper would not know the request at all.
            if let version = await runningVersion(), version < 2 {
                return "The Flotilla Helper is from an older Flotilla. Switch it off and on again in "
                    + "Settings ▸ Advanced to update it."
            }
        default: break
        }
        let connection = NSXPCConnection(machServiceName: HelperInterface.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // The app checks the helper as the helper checks the app: same team, the helper's identity.
        connection.setCodeSigningRequirement(
            HelperInterface.requirement(identifier: HelperInterface.label, team: team))
        connection.resume()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // `@Sendable` for the same reason as in `runningVersion`.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume("Flotilla couldn't reach its Flotilla Helper: \(error.localizedDescription)")
            } as? HelperProtocol
            guard let proxy else {
                once.resume("Flotilla couldn't reach its Flotilla Helper.")
                return
            }
            switch request {
            case .create(let domain, let localhost):
                proxy.createDomain(domain, localhost: localhost) { once.resume($0) }
            case .delete(let domains):
                proxy.deleteDomains(domains) { once.resume($0) }
            case .syncFleetResolvers(let fleetDomain, let zones):
                proxy.syncFleetResolvers(fleetDomain: fleetDomain, zones: zones) { once.resume($0) }
            case .removeFleetResolvers:
                proxy.removeFleetResolvers { once.resume($0) }
            case .installContainer(let path, let version):
                proxy.installContainer(packageAt: path, version: version) { once.resume($0) }
            case .installFlotillaUpdate(let path):
                proxy.installFlotillaUpdate(appAt: path) { once.resume($0) }
            }
        }
    }
}

/// What may be asked of the helper — the whole of it.
enum HelperRequest: Sendable {
    case create(domain: String, localhost: String?)
    case delete([String])
    /// Q37: the resolver files for other Macs' zones. Helper only — never the password prompt.
    case syncFleetResolvers(fleetDomain: String, zones: [String])
    case removeFleetResolvers
    /// Q39: Apple's `container` package, checked by the helper as root. Helper only.
    case installContainer(path: String, version: String)
    /// Q43: a Flotilla update over a root-owned app, checked by the helper as root. Helper only.
    case installFlotillaUpdate(path: String)
}

private final class VersionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int?, Never>?
    init(_ continuation: CheckedContinuation<Int?, Never>) { self.continuation = continuation }
    func resume(_ value: Int?) {
        let pending = lock.withLock { () -> CheckedContinuation<Int?, Never>? in defer { continuation = nil }; return continuation }
        pending?.resume(returning: value)
    }
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
    var helperEnabled: Bool { PrivilegedHelper.status == .enabled }

    /// The one place a privileged DNS change is made: through the helper when the owner has
    /// approved it, otherwise behind the administrator prompt. Either way the request is validated
    /// — here for the prompt, and again by the helper itself.
    func runPrivileged(_ request: HelperRequest, prompt: String) async -> AdminCommandRunner.Outcome {
        if helperEnabled {
            if let failure = await PrivilegedHelper.send(request) { return .failed(failure) }
            return .succeeded
        }
        var commands: [ValidatedCommand] = []
        switch request {
        case .syncFleetResolvers, .removeFleetResolvers:
            return .failed("Names across Macs need the Flotilla Helper switched on. Turn it on in Settings ▸ Advanced.")
        case .installContainer:
            return .failed("Installing container without a person here needs the Flotilla Helper switched on.")
        case .installFlotillaUpdate:
            return .failed("Flotilla here was installed by a package, so only its Flotilla Helper can update it. "
                           + "Switch the helper on in Settings ▸ Advanced, or install the update with the package.")
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
