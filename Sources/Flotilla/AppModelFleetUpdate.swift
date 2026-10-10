import Foundation
import FlotillaCore
import FlotillaNet

/// Keeping the fleet on the admin Mac's Flotilla (DECISIONS Q38).
///
/// The admin zips the app it is running, once per build, and sends it to each host over the same
/// bounded upload as Send to Hosts. The host checks it is genuine and newer, waits until it is idle,
/// swaps it in and relaunches; the admin then waits for the host to come back on the new build.
/// Rolling by default: one host at a time, stopping at the first that does not come back.
extension AppModel {

    // MARK: Host side

    func performInstallUpdate(_ archive: URL, isIdle: @escaping @Sendable () -> Bool) async -> Result<String, HostCallFailure> {
        let keepAwake = power.begin("installing a Flotilla update")
        defer { power.end(keepAwake) }
        let prepared: Result<SelfUpdate.Prepared, Error> = await Task.detached {
            Result { try SelfUpdate.prepare(archive: archive, isIdle: isIdle) }
        }.value
        let outcome: Result<String, Error>
        switch prepared {
        case .failure(let error):
            outcome = .failure(error)
        case .success(let update) where SelfUpdate.canReplaceItself:
            outcome = await Task.detached { Result { try SelfUpdate.swap(update); return update.version } }.value
        case .success(let update):
            // Installed by a package, owned by root: the helper swaps it (Q43).
            switch await runPrivileged(.installFlotillaUpdate(path: update.app.path), prompt: "") {
            case .succeeded: outcome = .success(update.version)
            case .failed(let why): outcome = .failure(SelfUpdate.Failure.refused(why))
            default: outcome = .failure(SelfUpdate.Failure.failed("The Flotilla Helper didn't install the update."))
            }
        }
        switch outcome {
        case .success(let version):
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: "Flotilla",
                                          action: "Updated to \(version) by the admin Mac"))
            // Answer first, then go: the admin hears "installed" before the connection drops.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                SelfUpdate.relaunch()
            }
            return .success(version)
        case .failure(let error):
            let refused: Bool = if case SelfUpdate.Failure.refused = error { true } else { false }
            return .failure(HostCallFailure(refused ? .refused : .internalError, String(describing: error)))
        }
    }

    // MARK: Admin side

    var ownBuild: Int? { SelfUpdate.ownBuild }

    /// A host's build, as it last reported it.
    func hostBuild(_ fingerprint: PeerFingerprint) -> Int? {
        FleetUpdate.build(of: hostMode.live[fingerprint]?.appVersion)
    }

    /// Whether the host's connection allows updates from here (wire version 6).
    func canReceiveUpdate(_ fingerprint: PeerFingerprint) -> Bool {
        (hostMode.remoteHost(for: fingerprint)?.protocolVersion ?? 0) >= WireProtocol.appUpdatesVersion
    }

    /// What the Hosts table says about a host's Flotilla.
    enum HostUpdateState: Equatable {
        case current, ahead, unknown
        case available
        /// Behind, but on a Flotilla too old to take updates from here.
        case manualOnly
        case updating
        case failed(String)
    }

    func updateState(_ fingerprint: PeerFingerprint) -> HostUpdateState {
        if hostMode.updating.contains(fingerprint) { return .updating }
        switch FleetUpdate.standing(host: hostBuild(fingerprint), admin: ownBuild) {
        case .current: return .current
        case .ahead: return .ahead
        case .unknown: return .unknown
        case .behind:
            if let failure = hostMode.updateFailures[fingerprint], failure.build == ownBuild { return .failed(failure.message) }
            return canReceiveUpdate(fingerprint) ? .available : .manualOnly
        }
    }

    var autoUpdateHosts: Bool { settingsStore[SettingsKeys.autoUpdateHosts] }

    /// This Mac's app, zipped once per build in a private folder.
    private func updatePackage() async throws -> (url: URL, bytes: UInt64, sha256: String) {
        guard let build = ownBuild else { throw SelfUpdate.Failure.refused("This Mac's Flotilla has no build number.") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.melonfleet.Flotilla.outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let zip = folder.appendingPathComponent("Flotilla-\(build).zip")
        let app = Bundle.main.bundleURL
        return try await Task.detached {
            if !FileManager.default.fileExists(atPath: zip.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw SelfUpdate.Failure.failed("Couldn't package this Mac's Flotilla.") }
            }
            let (bytes, digest) = try AppModel.measure(zip)
            return (zip, bytes, digest)
        }.value
    }

    /// Updates one host and waits for it to come back on this Mac's build. `nil` means it did.
    @discardableResult
    func updateHost(_ fingerprint: PeerFingerprint) async -> String? {
        guard let target = ownBuild, let remote = hostMode.remoteHost(for: fingerprint) else {
            return "That host can't be reached."
        }
        let name = hostMode.hostName(.peer(fingerprint), local: hostLabel)
        hostMode.updating.insert(fingerprint)
        defer { hostMode.updating.remove(fingerprint) }
        do {
            let package = try await updatePackage()
            let result = try await remote.upload(file: package.url, bytes: package.bytes, sha256: package.sha256,
                                                 label: "Flotilla build \(target)", purpose: .appUpdate) { _ in }
            _ = result
        } catch {
            return failUpdate(fingerprint, name: name, target: target, HostModeController.describe(error))
        }
        // It relaunches: wait for it to answer again, on the new build.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(4))
            await hostMode.refreshHost(fingerprint)
            if hostBuild(fingerprint) == target {
                hostMode.updateFailures.removeValue(forKey: fingerprint)
                recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: name,
                                              action: "Updated Flotilla to build \(target)"))
                return nil
            }
        }
        return failUpdate(fingerprint, name: name, target: target, "It installed the update but didn't come back on build \(target) within four minutes.")
    }

    private func failUpdate(_ fingerprint: PeerFingerprint, name: String, target: Int, _ raw: String) -> String {
        let message = Self.explainUpdateFailure(raw)
        hostMode.updateFailures[fingerprint] = (target, message)
        recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .host, subject: name,
                                      action: "Flotilla update failed: \(message)"))
        return message
    }

    /// A host on a build from before Q43 answers a root-owned app with macOS's bare permission error;
    /// say what it means and what to do instead (beta 2's test, 9 October).
    static func explainUpdateFailure(_ message: String) -> String {
        guard message.localizedCaseInsensitiveContains("permission to save the file") else { return message }
        return "Flotilla there was installed by a package, so it can't replace itself, and its version is too old "
            + "to hand the update to its Flotilla Helper. Install this build there once with the package; "
            + "after that it updates like the others."
    }

    /// The hosts behind this Mac, as the rolling order sees them.
    private var updateCandidates: [FleetUpdate.Candidate] {
        hostMode.trustedHosts.map { peer in
            FleetUpdate.Candidate(id: peer.fingerprint.hex, name: peer.displayName, build: hostBuild(peer.fingerprint),
                                  // Its Flotilla answering is what matters, not its `container`: a host
                                  // without container is exactly one that may need the update (8 October).
                                  connected: hostMode.live[peer.fingerprint]?.state == .connected
                                      || hostMode.live[peer.fingerprint]?.appVersion != nil,
                                  canReceive: canReceiveUpdate(peer.fingerprint),
                                  failedBuild: hostMode.updateFailures[peer.fingerprint]?.build)
        }
    }

    /// Hosts this Mac is newer than and can update now.
    var hostsWithUpdates: [PeerFingerprint] {
        hostMode.trustedHosts.map(\.fingerprint).filter { updateState($0) == .available }
    }

    /// Updates hosts one at a time — the next due each time — and stops at the first failure.
    /// `automatic` runs only when the setting is on; Update All passes false and runs regardless.
    func rollOutUpdates(automatic: Bool = true) async {
        guard !hostMode.rollingOut, let target = ownBuild else { return }
        if automatic && !autoUpdateHosts { return }
        hostMode.rollingOut = true
        defer { hostMode.rollingOut = false }
        let keepAwake = power.begin("updating hosts")
        defer { power.end(keepAwake) }
        while let next = FleetUpdate.next(updateCandidates, admin: target),
              let fingerprint = PeerFingerprint(hex: next.id) {
            if await updateHost(fingerprint) != nil { break }
        }
    }
}
