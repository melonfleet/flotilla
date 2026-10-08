import Foundation
import FlotillaCore
import FlotillaPrivileged

/// Flotilla's DNS helper: a root daemon that creates and deletes `container`'s local DNS domains,
/// so changing one does not ask for the administrator password every time (decision 19, amended
/// 7 October). See `DNSHelperInterface` for the contract.
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
final class DNSHelperService: NSObject, NSXPCListenerDelegate, DNSHelperProtocol, @unchecked Sendable {
    /// One request at a time. Two creates racing on `/etc/resolver` gain nothing.
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DNSHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func helperVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(DNSHelperInterface.version)
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

// No team, no service: an ad-hoc or unsigned helper has nothing to require of its callers, and a
// root daemon that accepted anyone would be the general privileged runner decision 19 forbids.
guard let team = DNSHelperInterface.ownTeamIdentifier() else {
    FileHandle.standardError.write(Data("dns-helper: not Developer ID signed; refusing to run.\n".utf8))
    exit(1)
}

let listener = NSXPCListener(machServiceName: DNSHelperInterface.label)
listener.setConnectionCodeSigningRequirement(
    DNSHelperInterface.requirement(identifier: DNSHelperInterface.appIdentifier, team: team))
let service = DNSHelperService()
listener.delegate = service
listener.resume()
dispatchMain()
