import Foundation
import AppKit
import FlotillaCore
import FlotillaNet

/// Flotilla installing its prerequisites: Apple's `container`, then its recommended kernel
/// (DECISIONS Q39).
///
/// - **On an admin Mac** it is the owner's choice, every time: Flotilla downloads Apple's signed
///   installer for the version this build expects, checks it is Apple's, and hands it to Apple's
///   Installer, where the owner approves with their password. Then the service and the kernel.
/// - **On a host** nobody may be at the keyboard, so the Flotilla Helper installs the package, after
///   checking — as root, on its own copy — that it is Apple's, notarised and the version asked for.
///   An upgrade, which stops every running container, happens by itself only when none is running;
///   otherwise the admin starts it from Hosts, with the count shown first.
extension AppModel {

    /// Where a setup has got to — what the banner and onboarding show.
    struct RuntimeSetupProgress: Equatable {
        enum Phase: Equatable {
            case downloading(started: Date)
            case checking
            /// The package is open in Apple's Installer; Flotilla waits for it to finish.
            case waitingForInstaller
            case installing
            case starting
            case installingKernel
            case failed(String)
        }
        var version: String
        var phase: Phase
    }

    /// The runtime this Mac has, from the installer's receipt — readable without root, and true
    /// even with the service stopped.
    nonisolated static func installedContainerVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--pkg-info", ContainerRuntime.packageIdentifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ContainerPackageCheck.receiptVersion(String(decoding: data, as: UTF8.self))
    }

    /// Whether this Mac needs `container` installed — the button the banner and onboarding offer.
    var needsContainerInstall: Bool {
        switch preflight {
        case .missing?, .tooOld?: true
        default: false
        }
    }

    // MARK: Download and check

    /// Apple's package for `version`, downloaded into a private folder and checked — the same checks
    /// the helper repeats as root. Returns where it is.
    func downloadContainerPackage(_ version: String) async throws -> URL {
        guard let url = ContainerRuntime.packageURL(version: version) else {
            throw SelfUpdate.Failure.refused("“\(version)” isn't a container version.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.melonfleet.Flotilla.runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(ContainerRuntime.packageFilename(version: version))
        try? FileManager.default.removeItem(at: destination)

        runtimeSetup = RuntimeSetupProgress(version: version, phase: .downloading(started: Date()))
        // A file download, not a byte stream: 118 MB read a byte at a time through an async
        // sequence is minutes of overhead for nothing.
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw SelfUpdate.Failure.failed("GitHub didn't have container \(version)'s installer.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= ContainerRuntime.maxPackageBytes else {
            try? FileManager.default.removeItem(at: temporary)
            throw SelfUpdate.Failure.refused("That download isn't the size of a container installer.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)

        runtimeSetup = RuntimeSetupProgress(version: version, phase: .checking)
        let problem = await Task.detached { Self.checkPackage(destination, version: version) }.value
        if let problem {
            try? FileManager.default.removeItem(at: destination)
            throw SelfUpdate.Failure.refused(problem)
        }
        return destination
    }

    /// The helper's checks, here too, so a bad download is reported before anyone is asked for a
    /// password. `pkgutil` needs no root to read a signature or expand a package.
    nonisolated static func checkPackage(_ package: URL, version: String) -> String? {
        func run(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let signature = PackageSignatureReport.parse(run(["--check-signature", package.path]))
        let expanded = package.deletingLastPathComponent().appendingPathComponent("expanded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: expanded) }
        _ = run(["--expand", package.path, expanded.path])
        let info = (try? String(contentsOf: expanded.appendingPathComponent("PackageInfo"), encoding: .utf8))
            .flatMap(ComponentPackageInfo.parse)
        return ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: version,
                                             installedVersion: installedContainerVersion())
    }

    // MARK: The admin Mac — the owner approves in Apple's Installer

    /// Downloads, checks, and opens Apple's Installer; then waits for the install, starts the
    /// service and installs the kernel. Only ever from a button.
    func installContainerInteractively(version: String = ContainerRuntime.expectedVersion) async {
        guard runtimeSetup == nil || isSetupFinished else { return }
        do {
            let package = try await downloadContainerPackage(version)
            runtimeSetup = RuntimeSetupProgress(version: version, phase: .waitingForInstaller)
            NSWorkspace.shared.open(package)
            // Apple's Installer runs as its own app; Flotilla learns it finished from the receipt.
            let deadline = Date().addingTimeInterval(30 * 60)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                if Self.installedContainerVersion() == version { break }
            }
            guard Self.installedContainerVersion() == version else {
                runtimeSetup = RuntimeSetupProgress(version: version, phase: .failed(
                    "container \(version) wasn't installed. Run the installer again, or download it from Apple's releases page."))
                return
            }
            recordActivity(ContainerEvent(date: Date(), from: "missing", to: "installed", kind: .runtime,
                                          subject: hostLabel, action: "container \(version) installed"))
            await finishRuntimeSetup(version: version)
        } catch {
            runtimeSetup = RuntimeSetupProgress(version: version, phase: .failed(String(describing: error)))
        }
    }

    private var isSetupFinished: Bool {
        if case .failed? = runtimeSetup?.phase { return true }
        return false
    }

    /// After `container` is in place: start the service, then the recommended kernel if there is none.
    private func finishRuntimeSetup(version: String) async {
        runtimeSetup = RuntimeSetupProgress(version: version, phase: .starting)
        await reload()
        if case .serviceStopped? = preflight { await startRuntime() }
        if case .needsKernel? = preflight {
            runtimeSetup = RuntimeSetupProgress(version: version, phase: .installingKernel)
            await installKernel()
        }
        runtimeSetup = nil
        await reload()
    }

    // MARK: A host — the helper installs, nobody needs to be here

    /// Brings a host's runtime to the version this Flotilla expects. Automatic (launch, and every
    /// half hour) only installs, or upgrades with nothing running; `allowStoppingContainers` is the
    /// admin's explicit upgrade, which the admin confirmed with the count. Returns why not, or nil.
    @discardableResult
    func ensureHostRuntime(allowStoppingContainers: Bool = false) async -> String? {
        guard hostMode.mode == .host || allowStoppingContainers else { return nil }
        if !allowStoppingContainers && !settingsStore[SettingsKeys.autoInstallRuntime] { return nil }
        guard runtimeSetup == nil || isSetupFinished else { return "A runtime setup is already under way here." }
        let version = ContainerRuntime.expectedVersion
        let installed = await Task.detached { Self.installedContainerVersion() }.value
        let running = containers.filter { $0.state.isRunning }.count
        switch RuntimeSetup.plan(installed: installed, expected: version, runningContainers: running) {
        case .nothing, .newer:
            // Installed — but a fresh install, or a removed kernel, may still want the kernel.
            if case .needsKernel? = preflight { await installKernel() }
            if case .serviceStopped? = preflight, settingsStore[SettingsKeys.autoStartContainerService] == .always {
                await startRuntime()
            }
            return nil
        case .upgrade(let automatic) where !automatic && !allowStoppingContainers:
            return "container \(version) is available; \(running) container\(running == 1 ? " is" : "s are") running, so the upgrade waits for you."
        case .install, .upgrade:
            break
        }
        guard helperEnabled else {
            return "\(hostLabel) needs its Flotilla Helper switched on to install container by itself."
        }
        do {
            let package = try await downloadContainerPackage(version)
            defer { try? FileManager.default.removeItem(at: package) }
            if installed != nil, runtimeUsable {
                runtimeSetup = RuntimeSetupProgress(version: version, phase: .installing)
                try await Task.detached { [cli] in try cli.stopSystem() }.value
            }
            runtimeSetup = RuntimeSetupProgress(version: version, phase: .installing)
            if let failure = await PrivilegedHelper.send(.installContainer(path: package.path, version: version)) {
                runtimeSetup = RuntimeSetupProgress(version: version, phase: .failed(failure))
                return failure
            }
            recordActivity(ContainerEvent(date: Date(), from: installed ?? "missing", to: version, kind: .runtime,
                                          subject: hostLabel, action: installed == nil ? "container \(version) installed"
                                                                                       : "container upgraded to \(version)"))
            await finishRuntimeSetup(version: version)
            return nil
        } catch {
            let message = String(describing: error)
            runtimeSetup = RuntimeSetupProgress(version: version, phase: .failed(message))
            return message
        }
    }

    /// The host's half-hourly look, and one at launch.
    func startHostRuntimeWatch() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while let self, !Task.isCancelled {
                await self.ensureHostRuntime()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }
}

// MARK: - The admin's view of each host's runtime

extension AppModel {
    enum HostRuntimeState: Equatable {
        case current
        /// Behind the version this Flotilla expects — Upgrade.
        case behind(String)
        /// No `container` there — Install.
        case missing
        case newer
        case unknown
        /// The host's Flotilla predates runtime setup from here.
        case tooOldToAsk
        case working
    }

    func hostRuntimeState(_ fingerprint: PeerFingerprint) -> HostRuntimeState {
        if hostMode.settingUpRuntime.contains(fingerprint) { return .working }
        guard let live = hostMode.live[fingerprint] else { return .unknown }
        let canAsk = (hostMode.remoteHost(for: fingerprint)?.protocolVersion ?? 0) >= WireProtocol.runtimeSetupVersion
        guard let version = live.containerVersion else {
            // Connected and answering, but the CLI isn't there: what a host without container says.
            if case .failed(let why) = live.state, why.localizedCaseInsensitiveContains("not found") || why.localizedCaseInsensitiveContains("not installed") {
                return canAsk ? .missing : .tooOldToAsk
            }
            return .unknown
        }
        switch RuntimeSetup.plan(installed: version, runningContainers: 0) {
        case .nothing: return .current
        case .newer: return .newer
        case .upgrade, .install: return canAsk ? .behind(version) : .tooOldToAsk
        }
    }

    /// Installs or upgrades `container` on a host — the owner confirmed, with the count of what stops.
    @discardableResult
    func setUpRuntime(on fingerprint: PeerFingerprint) async -> String? {
        guard let remote = hostMode.remoteHost(for: fingerprint) else { return "That host can't be reached." }
        let name = hostMode.hostName(.peer(fingerprint), local: hostLabel)
        hostMode.settingUpRuntime.insert(fingerprint)
        defer { hostMode.settingUpRuntime.remove(fingerprint) }
        do {
            _ = try await remote.call(.setUpRuntime)
            recordActivity(ContainerEvent(date: Date(), from: "", to: ContainerRuntime.expectedVersion, kind: .host,
                                          subject: name, action: "container set up at \(ContainerRuntime.expectedVersion)"))
            await hostMode.refreshHost(fingerprint)
            return nil
        } catch {
            let message = HostModeController.describe(error)
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: name,
                                          action: "container setup failed: \(message)"))
            return message
        }
    }
}
