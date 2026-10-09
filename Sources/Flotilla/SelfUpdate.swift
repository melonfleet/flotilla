import Foundation
import AppKit
import Security
import FlotillaCore
import FlotillaNet
import FlotillaPrivileged

/// A host installing the Flotilla its admin Mac sent (DECISIONS Q38).
///
/// The admin's new power is "install a newer genuine build", never "run code", so everything about
/// the bundle is checked here, on the host, before it replaces anything:
///
/// - it is `dev.melonfleet.Flotilla`, signed by Apple-issued Developer ID under **this host's own
///   team** — the same requirement the Flotilla Helper uses — with every nested binary valid;
/// - its build number is **higher** than the one running here: never a downgrade, never a sideways
///   swap.
///
/// Only Flotilla is replaced and relaunched. Containers run under `container`'s own services and
/// are not touched, and the swap waits until nothing is running for an admin. Where a package
/// installed Flotilla owned by root, the Flotilla Helper makes the swap after checking it all again
/// as root (Q43).
enum SelfUpdate {
    static let bundleIdentifier = HelperInterface.appIdentifier
    /// How long an update waits for the host to be idle before giving up.
    static let idleWait: TimeInterval = 600

    static var ownBuild: Int? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
    }

    enum Failure: Error, CustomStringConvertible {
        case refused(String)
        case failed(String)
        var description: String {
            switch self { case .refused(let why), .failed(let why): why }
        }
    }

    /// A checked update, waiting to be swapped in.
    struct Prepared: Sendable {
        let app: URL
        /// As hosts report it: `1.5.0.0-beta.3 (352)`.
        let version: String
    }

    /// Whether this process can replace its own app. Not where a package installed it: that app is
    /// owned by root, and the swap goes through the Flotilla Helper instead (Q43).
    static var canReplaceItself: Bool {
        let app = Bundle.main.bundleURL
        let fileManager = FileManager.default
        return app.pathExtension == "app"
            && fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: app.path)
            && fileManager.isWritableFile(atPath: app.appendingPathComponent("Contents").path)
    }

    /// Unpacks `archive`, checks the app inside, and waits for `isIdle`. Blocking: call off the main
    /// actor. Nothing is replaced yet — `swap` does that, or the helper.
    static func prepare(archive: URL, isIdle: @Sendable () -> Bool) throws -> Prepared {
        guard let team = HelperInterface.ownTeamIdentifier() else {
            throw Failure.refused("This host's Flotilla isn't Developer ID signed, so it can't check an update. Update it by hand.")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.refused("This host isn't running from an app bundle.") }

        // Unpacked beside the archive, in the upload's own private folder.
        let unpacked = archive.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw Failure.refused("The update isn't one app.") }

        // Genuine: our identifier, our team, every nested binary valid.
        let requirementText = HelperInterface.requirement(identifier: bundleIdentifier, team: team)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw Failure.refused("The update's signature couldn't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure.refused("The update isn't Flotilla signed by this host's own team, so it wasn't installed.")
        }

        // Newer, by build number — read from the bundle the signature just covered.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              let newBuild = (info?["CFBundleVersion"] as? String).flatMap({ Int($0) }) else {
            throw Failure.refused("The update has no build number.")
        }
        if let ownBuild, newBuild <= ownBuild {
            throw Failure.refused("This host already has build \(ownBuild); the update is \(newBuild).")
        }
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        // Idle: nothing running for an admin, nothing followed, no other transfer.
        let deadline = Date().addingTimeInterval(idleWait)
        while !isIdle() {
            guard Date() < deadline else { throw Failure.failed("This host stayed busy for ten minutes, so the update waited. Try again.") }
            Thread.sleep(forTimeInterval: 2)
        }
        return Prepared(app: app, version: "\(short) (\(newBuild))")
    }

    /// Puts a prepared update in place of the running app, as this user. Blocking.
    static func swap(_ prepared: Prepared) throws {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        // Copied beside the running app (same volume), then swapped in in one step.
        let staging = parent.appendingPathComponent(".Flotilla-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [prepared.app.path, staging.path])
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.failed("Flotilla couldn't be replaced: \(error.localizedDescription)")
        }
    }

    /// Quits, and opens the app again once this process has gone. The relaunch waits on this
    /// process's id, so the new copy never starts beside the old one.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.failed("\(tool) exited \(process.terminationStatus).") }
    }
}
