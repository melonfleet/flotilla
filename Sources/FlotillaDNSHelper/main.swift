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
