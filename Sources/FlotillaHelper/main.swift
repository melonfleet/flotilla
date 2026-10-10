import Foundation
import Security
import FlotillaCore
import FlotillaPrivileged

/// The Flotilla Helper: Flotilla's one root daemon, for the few jobs that need root — creating and
/// deleting `container`'s local DNS domains, keeping the fleet resolver files, and installing Apple's
/// `container` package — so none of them asks for the administrator password every time (decision
/// 19, amended 7 October; one helper, Q41). See `HelperInterface` for the contract.
///
/// Everything the app's password path checks, this checks again, here, as root — the app is the
/// caller, not the authority:
///
/// - only Flotilla, signed by the same Developer ID team as this helper, may connect;
/// - requests are typed (create a name / delete names); the argv is built and validated here by
///   the same `Allowlist` the app uses, and `.local` and other reserved names are refused;
/// - only `/usr/local/bin/container`, and only while it and its directory are root-owned and
///   writable by no one else (`AdminExecutable`);
/// - run directly, never through a shell, one request at a time.
final class HelperService: NSObject, NSXPCListenerDelegate, HelperProtocol, @unchecked Sendable {
    /// One request at a time. Two creates racing on `/etc/resolver` gain nothing.
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The app this helper lives in was replaced under it — an update, or a rebuild — so this
        // process runs code that is no longer on disk, and the app's signature check of it fails
        // ("the code on disk does not match what is running"; measured 10 October). Quit, unless a
        // request is under way; launchd starts the new copy on the next request, which the app makes.
        if OwnBinary.replaced, lock.try() {
            FileHandle.standardError.write(Data("flotilla-helper: replaced on disk; exiting so the new copy starts.\n".utf8))
            exit(0)
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func helperVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperInterface.version)
    }

    func createDomain(_ domain: String, localhost: String?, reply: @escaping @Sendable (String?) -> Void) {
        if let problem = LocalDNS.reservedProblem(domain) { reply(problem); return }
        switch ContainerCLI.dnsCreateCommand(domain: domain, localhost: localhost) {
        case .success(let command): reply(run([command]))
        case .failure(let error): reply(String(describing: error))
        }
    }

    func deleteDomains(_ domains: [String], reply: @escaping @Sendable (String?) -> Void) {
        var commands: [ValidatedCommand] = []
        for domain in domains {
            switch ContainerCLI.dnsDeleteCommand(domain: domain) {
            case .success(let command): commands.append(command)
            case .failure(let error): reply(String(describing: error)); return
            }
        }
        reply(run(commands))
    }

    // MARK: Fleet resolver files (DECISIONS Q37)
    //
    // The only files this helper writes itself. Every one is named `flotilla.<zone>`, holds the four
    // fixed lines `FleetResolvers.contents` gives — nameserver 127.0.0.1, port 7869 — and is for a
    // zone under a private-use fleet domain. Nothing not named `flotilla.` is read, written or removed.

    private static let resolverDirectory = URL(fileURLWithPath: DNSResolverFile.directory, isDirectory: true)

    func syncFleetResolvers(fleetDomain: String, zones: [String], reply: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: Self.resolverDirectory.path)) ?? []
        let runtimeZones = Set(names.compactMap(DNSResolverFile.domain(fromFilename:)))
        if let problem = FleetResolvers.problem(fleetDomain: fleetDomain, zones: zones, runtimeZones: runtimeZones) {
            reply(problem); return
        }
        do {
            if !fileManager.fileExists(atPath: Self.resolverDirectory.path) {
                try fileManager.createDirectory(at: Self.resolverDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
            }
            let wanted = Set(zones)
            // Stale files first, so a zone that left the fleet stops resolving even if a write fails.
            for name in names {
                guard let zone = FleetResolvers.zone(fromFilename: name), !wanted.contains(zone) else { continue }
                try removeFile(named: name)
            }
            for zone in zones.sorted() {
                let url = Self.resolverDirectory.appendingPathComponent(FleetResolvers.filename(for: zone))
                let contents = Data(FleetResolvers.contents(for: zone).utf8)
                if (try? Data(contentsOf: url)) == contents, isRegularFile(url.path) { continue }
                // Written beside, then renamed over: a reader never sees half a file, and the rename
                // replaces whatever was there — a link included — rather than writing through it.
                let temporary = Self.resolverDirectory.appendingPathComponent(".flotilla-\(UUID().uuidString)")
                guard fileManager.createFile(atPath: temporary.path, contents: contents,
                                             attributes: [.posixPermissions: 0o644]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                guard rename(temporary.path, url.path) == 0 else {
                    try? fileManager.removeItem(at: temporary)
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
            reply(nil)
        } catch {
            reply("The helper couldn't update this Mac's DNS settings: \(error.localizedDescription)")
        }
    }

    func removeFleetResolvers(reply: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.resolverDirectory.path)) ?? []
        do {
            for name in names where FleetResolvers.zone(fromFilename: name) != nil { try removeFile(named: name) }
            reply(nil)
        } catch {
            reply("The helper couldn't update this Mac's DNS settings: \(error.localizedDescription)")
        }
    }

    // MARK: Installing container (DECISIONS Q39)
    //
    // Apple's package and nothing else. The caller names a file; the helper copies it into a folder
    // only root can write, and every check — signature, notarisation, identifier, version, no
    // downgrade — is made on that copy, which is what `installer` then installs. A swap of the
    // caller's file after the check therefore changes nothing.

    private static let installStaging = URL(fileURLWithPath: "/Library/Application Support/dev.melonfleet.Flotilla/Installers",
                                            isDirectory: true)

    func installContainer(packageAt path: String, version: String, reply: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard ContainerRuntime.isVersion(version) else { reply("That isn't a container version."); return }
        // A regular file, not a link, of a sane size.
        var info = stat()
        guard path.hasPrefix("/"), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Int64(info.st_size) <= ContainerRuntime.maxPackageBytes else {
            reply("The helper was given something that isn't a package file."); return
        }
        let fileManager = FileManager.default
        let staging = Self.installStaging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700, .ownerAccountID: 0])
            let copy = staging.appendingPathComponent("container.pkg")
            try fileManager.copyItem(at: URL(fileURLWithPath: path), to: copy)

            let signature = PackageSignatureReport.parse(capture("/usr/sbin/pkgutil", ["--check-signature", copy.path]).output)
            let expanded = staging.appendingPathComponent("expanded")
            _ = capture("/usr/sbin/pkgutil", ["--expand", copy.path, expanded.path])
            let packageInfo = (try? String(contentsOf: expanded.appendingPathComponent("PackageInfo"), encoding: .utf8))
                .flatMap(ComponentPackageInfo.parse)
            let installed = ContainerPackageCheck.receiptVersion(
                capture("/usr/sbin/pkgutil", ["--pkg-info", ContainerRuntime.packageIdentifier]).output)
            if let problem = ContainerPackageCheck.problem(signature: signature, info: packageInfo,
                                                           requestedVersion: version, installedVersion: installed) {
                reply(problem); return
            }
            if installed == version { reply(nil); return }

            let result = capture("/usr/sbin/installer", ["-pkg", copy.path, "-target", "/"])
            reply(result.status == 0 ? nil : "Apple's installer failed: " + result.output.suffix(600))
        } catch {
            reply("The helper couldn't stage the package: \(error.localizedDescription)")
        }
    }

    // MARK: Flotilla updates over a root-owned app (DECISIONS Q43)
    //
    // A package installs Flotilla owned by root, and Flotilla runs as the user, so on such a Mac the
    // admin's update could never be swapped in (beta 2's test, 9 October). The helper does the swap —
    // of its own app only — after checking, as root and on its own copy, everything the app checks.

    /// The app this helper is inside: `…/Flotilla.app/Contents/MacOS/FlotillaHelper`, three up.
    private static var ownApp: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app",
              (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleIdentifier"]
                as? String == HelperInterface.appIdentifier else { return nil }
        return app
    }

    private static func build(of app: URL) -> Int? {
        ((NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"]
            as? String).flatMap { Int($0) }
    }

    func installFlotillaUpdate(appAt path: String, reply: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let team = HelperInterface.ownTeamIdentifier() else { reply("The helper isn't Developer ID signed."); return }
        guard let destination = Self.ownApp, let installedBuild = Self.build(of: destination) else {
            reply("The helper couldn't find the Flotilla it belongs to."); return
        }
        // A real app folder, not a link to one.
        var info = stat()
        guard path.hasPrefix("/"), path.hasSuffix(".app"), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            reply("The helper was given something that isn't an app."); return
        }
        let fileManager = FileManager.default
        let staging = Self.installStaging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700, .ownerAccountID: 0])
            // Our own copy, owned by root, so what is checked is what is installed.
            let copy = staging.appendingPathComponent("Flotilla.app")
            guard capture("/usr/bin/ditto", [path, copy.path]).status == 0,
                  capture("/usr/sbin/chown", ["-R", "root:wheel", copy.path]).status == 0 else {
                reply("The helper couldn't copy the update."); return
            }
            // Genuine: Flotilla, this helper's own team, every nested binary valid.
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let text = HelperInterface.requirement(identifier: HelperInterface.appIdentifier, team: team)
            guard SecStaticCodeCreateWithPath(copy as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
                                                              | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
                reply("The update isn't Flotilla signed by this Mac's own team, so it wasn't installed."); return
            }
            // Newer, never a downgrade or a sideways swap.
            guard let newBuild = Self.build(of: copy) else { reply("The update has no build number."); return }
            guard newBuild > installedBuild else {
                reply("This Mac already has build \(installedBuild); the update is \(newBuild)."); return
            }
            _ = try fileManager.replaceItemAt(destination, withItemAt: copy)
            reply(nil)
            // The app now holds a newer helper; exit so launchd starts that one on the next request.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        } catch {
            reply("Flotilla couldn't be replaced: \(error.localizedDescription)")
        }
    }

    /// Runs a system tool directly — no shell — and returns its exit status and output.
    private func capture(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(tool) couldn't start") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data.prefix(64_000), as: UTF8.self))
    }

    /// Removes one entry of ours — a file or a link, never a directory, and never by following a link.
    private func removeFile(named name: String) throws {
        let path = Self.resolverDirectory.appendingPathComponent(name).path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { return }
        guard unlink(path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Runs each command in turn and stops at the first failure, as the password path's `&&` does.
    private func run(_ commands: [ValidatedCommand]) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let problem = AdminExecutable.installedProblem() { return problem }
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AdminExecutable.path)
            process.arguments = command.arguments
            // The environment `do shell script … with administrator privileges` gives, near enough:
            // root's home and the system path, nothing inherited.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch {
                return "The helper couldn't start container: \(error.localizedDescription)"
            }
            // Only stderr is piped, so there is no second pipe to deadlock on; these commands write
            // a line at most.
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: output.prefix(2_000), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return message.isEmpty ? "container exited with status \(process.terminationStatus)." : message
            }
        }
        return nil
    }
}

/// The file this process was started from, as it was at launch: replacing the app gives the helper's
/// executable a new file, so a different device or inode at the same path means this process is stale.
enum OwnBinary {
    static let path: String? = {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }()
    static let atLaunch = path.flatMap(identity)

    static func identity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    static var replaced: Bool {
        guard let path, let atLaunch else { return false }
        return identity(path) != atLaunch
    }
}

// No team, no service: an ad-hoc or unsigned helper has nothing to require of its callers, and a
// root daemon that accepted anyone would be the general privileged runner decision 19 forbids.
guard let team = HelperInterface.ownTeamIdentifier() else {
    FileHandle.standardError.write(Data("flotilla-helper: not Developer ID signed; refusing to run.\n".utf8))
    exit(1)
}

_ = OwnBinary.atLaunch   // read now, while the file is still the one this process runs
let listener = NSXPCListener(machServiceName: HelperInterface.label)
listener.setConnectionCodeSigningRequirement(
    HelperInterface.requirement(identifier: HelperInterface.appIdentifier, team: team))
let service = HelperService()
listener.delegate = service
listener.resume()
dispatchMain()
