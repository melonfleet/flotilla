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
///   team** — the same requirement the DNS helper uses — with every nested binary valid;
/// - its build number is **higher** than the one running here: never a downgrade, never a sideways
///   swap.
///
/// Only Flotilla is replaced and relaunched. Containers run under `container`'s own services and
/// are not touched, and the swap waits until nothing is running for an admin.
enum SelfUpdate {
    static let bundleIdentifier = DNSHelperInterface.appIdentifier
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

    /// Unpacks `archive`, checks the app inside, waits for `isIdle`, and puts it in place of the
    /// running app. Returns the installed version, as hosts report it. Blocking: call off the main
    /// actor.
    static func install(archive: URL, isIdle: @Sendable () -> Bool) throws -> String {
        guard let team = DNSHelperInterface.ownTeamIdentifier() else {
            throw Failure.refused("This host's Flotilla isn't Developer ID signed, so it can't check an update. Update it by hand.")
        }
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app" else { throw Failure.refused("This host isn't running from an app bundle.") }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure.refused("This host can't replace Flotilla in \(parent.lastPathComponent).")
        }

        // Unpacked beside the archive, in the upload's own private folder.
        let unpacked = archive.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw Failure.refused("The update isn't one app.") }

        // Genuine: our identifier, our team, every nested binary valid.
        let requirementText = DNSHelperInterface.requirement(identifier: bundleIdentifier, team: team)
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

        // Copied beside the running app (same volume), then swapped in in one step.
        let staging = parent.appendingPathComponent(".Flotilla-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [app.path, staging.path])
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.failed("Flotilla couldn't be replaced: \(error.localizedDescription)")
        }
        return "\(short) (\(newBuild))"
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
