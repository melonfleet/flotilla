import Foundation
import CryptoKit
import FlotillaCore
import FlotillaNet

/// Sending one of This Mac's images to hosts (PLAN.md Phase D, D2; research/WIRE-STREAMS-D2.md).
///
/// This Mac is the image source (Phase B decision): it saves the image once, with whatever registry
/// sign-in it has, and each host loads the archive itself. No credential leaves this Mac — only the
/// image does.
extension AppModel {
    /// Whether `host` can be sent an image now, and if not, why — the same answer the form shows.
    func sendState(of image: ContainerImage, to host: HostRef) -> (text: String, warning: Bool, sendable: Bool) {
        guard case .peer(let fingerprint) = host else { return ("this Mac", false, false) }
        let live = hostMode.live[fingerprint]
        switch live?.state {
        case .failed?: return ("not answering", true, false)
        case .checking?, nil: return ("checking…", false, false)
        case .connected?: break
        }
        if let version = live?.containerVersion, !ImageTransfer.hostCanLoad(containerVersion: version) {
            return ("needs container \(ImageTransfer.minimumContainer) or later — it has \(version)", true, false)
        }
        let theirs = hostMode.imageSnapshots[fingerprint]?.items.first { $0.reference == image.reference }
        if let theirs {
            return ImageTransfer.hostHasSame(image, as: theirs) ? ("already has it", false, false)
                : ("has a different \(ContainerImage.shortReference(image.reference)) — sending replaces it", true, true)
        }
        return ("will receive it", false, true)
    }

    /// Saves `image` once and sends it to every host in `hosts` at the same time.
    ///
    /// The panel has a line for the save and one per host, with bytes sent as it goes; a partial
    /// send is reported as a failure that names what did arrive. The archive is deleted when every
    /// host is done with it.
    ///
    /// - Returns: whether every host loaded it.
    @discardableResult
    func sendImage(_ image: ContainerImage, to hosts: [HostRef]) async -> Bool {
        let reference = image.reference
        let panel = OperationProgress(title: "Send an image to \(hosts.count) host\(hosts.count == 1 ? "" : "s")",
                                      command: (["container"] + ContainerCLI.saveImageArguments(
                                          reference, platform: ImageTransfer.platform(for: image) ?? "linux/arm64",
                                          archive: "<archive>")).joined(separator: " "))
        activeOperation = panel

        guard let platform = ImageTransfer.platform(for: image) else {
            panel.fail("\(reference) has no linux/arm64 or linux/amd64 variant, so no host could run it.")
            return false
        }

        // A folder of our own, for this one send; the CLI that saves into it is scoped to it alone.
        let folder: URL
        do {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("dev.melonfleet.Flotilla.outgoing", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            panel.fail("Couldn't make room for the archive: \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("image.tar")

        let saveStep = panel.begin("Saving \(platform) on \(hostLabel)")
        let saver = ContainerCLI(host: cli.host, mountPolicy: .roots([folder.path]), wirePolicy: .localOwner)
        let size: UInt64, digest: String
        do {
            (size, digest) = try await Task.detached {
                try saver.saveImage(reference, platform: platform, to: archive.path)
                return try Self.measure(archive)
            }.value
            panel.finish(saveStep, detail: ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
        } catch {
            panel.finish(saveStep, detail: String(describing: error), failed: true)
            panel.fail("Couldn't save \(reference): \(error)")
            return false
        }

        struct Job { let host: HostRef; let name: String; let step: UUID; let remote: RemoteHost }
        var jobs: [Job] = []
        var failures: [(name: String, reason: String)] = []
        for host in hosts {
            let name = hostMode.hostName(host, local: hostLabel)
            let step = panel.begin("Sending to \(name)")
            guard case .peer(let fingerprint) = host, let remote = hostMode.remoteHost(for: fingerprint) else {
                let reason = "That host isn't paired, or can't be found on the network."
                panel.finish(step, detail: reason, failed: true)
                failures.append((name, reason))
                continue
            }
            jobs.append(Job(host: host, name: name, step: step, remote: remote))
        }

        let total = Int64(clamping: size)
        let outcomes = await withTaskGroup(of: (Int, Result<CommandResult, Error>).self) { group in
            for (index, job) in jobs.enumerated() {
                let remote = job.remote, step = job.step
                let meter = SendMeter(total: size)
                group.addTask {
                    do {
                        let result = try await remote.upload(file: archive, bytes: size, sha256: digest,
                                                             label: reference) { sent in
                            guard let detail = meter.detail(sent: sent, total: total) else { return }
                            Task { @MainActor in panel.update(step, detail: detail) }
                        }
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<CommandResult, Error>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var sent: [String] = []
        for (index, outcome) in outcomes.sorted(by: { $0.0 < $1.0 }) {
            let job = jobs[index]
            switch outcome {
            case .failure(let error):
                let reason = HostModeController.describe(error)
                panel.finish(job.step, detail: reason, failed: true)
                failures.append((job.name, reason))
            case .success(let result) where result.exitCode != 0:
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "image load exited \(result.exitCode)" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                panel.finish(job.step, detail: reason, failed: true)
                failures.append((job.name, reason))
            case .success(let result):
                // What the host's own loader says it loaded — not the label this Mac sent.
                let loaded = result.stdout.split(separator: "\n").last.map(String.init)
                panel.finish(job.step, detail: loaded)
                sent.append(job.name)
                recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present", kind: .image,
                                              subject: "\(reference) on \(job.name)", action: "Sent"))
            }
        }

        let listStep = panel.begin("Refreshing hosts")
        for job in jobs { if case .peer(let fingerprint) = job.host { await hostMode.refreshHost(fingerprint) } }
        panel.finish(listStep)

        guard failures.isEmpty else {
            let lines = failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
            let summary = sent.isEmpty
                ? "No host received \(reference).\n\n\(lines)"
                : "Sent to \(sent.joined(separator: ", ")), but not to \(failures.count) host\(failures.count == 1 ? "" : "s").\n\n\(lines)"
                    + "\n\nA dropped transfer starts again from the beginning."
            panel.fail(summary)
            return false
        }
        panel.succeed("\(reference) sent to \(sent.count) host\(sent.count == 1 ? "" : "s")")
        return true
    }

    /// The archive's size and SHA-256, read in pieces so a large image is never in memory at once.
    nonisolated static func measure(_ file: URL) throws -> (UInt64, String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
            size += UInt64(piece.count)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Turns bytes sent into a progress line, at most once per percent — a gigabyte arrives as a
/// thousand pieces, and the panel needs a hundred updates, not a thousand.
private final class SendMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private let total: UInt64
    init(total: UInt64) { self.total = max(1, total) }

    func detail(sent: UInt64, total display: Int64) -> String? {
        let percent = Int(sent * 100 / total)
        let changed = lock.withLock {
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
        guard changed else { return nil }
        if sent >= total { return "loading…" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: sent), countStyle: .file)) of "
            + ByteCountFormatter.string(fromByteCount: display, countStyle: .file)
    }
}
