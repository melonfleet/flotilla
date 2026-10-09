import Foundation
import FlotillaCore

/// The DNS section's loading and actions, kept out of `AppModel.swift` and out of the view.
///
/// Three sources make a row (see `LocalDNS`): `container system dns list`, the runtime's resolver
/// files in `/etc/resolver` (world-readable, so no administrator is needed to *read* them), and
/// `config.toml`'s `[dns] domain`. Creating or deleting a domain needs root and goes through
/// `runPrivileged` — the Flotilla Helper, or the administrator prompt; choosing the domain
/// containers are named under edits `config.toml` and restarts the runtime, which needs neither.
extension AppModel {

    /// The result of an action the user started. `nil` from the async calls below means it worked.
    enum DNSActionResult: Equatable {
        case cancelled
        case failed(String)
    }

    /// The domain containers are named under, as a row — `nil` when none is set.
    var containerDNSRow: LocalDNSDomain? { dnsDomains.first(where: \.registersContainers) }

    func refreshDNS() async {
        // Only a missing CLI stops the section: the resolver files and config.toml are readable
        // with the runtime stopped, and those rows are still true.
        if let preflight, case .missing = preflight {
            setDNSState(.unavailable(Self.registryUnavailableReason(for: preflight)
                                     ?? "container is unavailable."))
            return
        }
        if dnsState != .loaded { setDNSState(.loading) }
        let (domains, containerDomain) = await Task.detached { [cli] in
            // Best effort: the files below are the same facts, and a row Flotilla can read from
            // them should not vanish because one process failed.
            let listed = (try? cli.dnsDomainNames()) ?? []
            let files = Self.readResolverFiles()
            let config = try? String(contentsOfFile: ContainerConfigFile.defaultPath(), encoding: .utf8)
            let containerDomain = config.flatMap(ContainerConfigFile.dnsDomain(in:))
            return (LocalDNS.domains(listed: listed, resolverFiles: files,
                                     containerDomain: containerDomain), containerDomain)
        }.value
        setDNS(domains, containerDomain: containerDomain, state: .loaded)
    }

    /// The runtime's files in `/etc/resolver`, parsed. Other software's files there are skipped by
    /// name, and anything that does not parse is skipped rather than guessed at.
    nonisolated static func readResolverFiles() -> [DNSResolverFile] {
        let directory = DNSResolverFile.directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name in
            guard DNSResolverFile.domain(fromFilename: name) != nil,
                  let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8)
            else { return nil }
            return DNSResolverFile.parse(text)
        }
    }

    /// Creates a domain — through the Flotilla Helper when the owner has approved it, otherwise behind
    /// the administrator prompt (`runPrivileged`).
    func createDNSDomain(_ domain: String, localhost: String?) async -> DNSActionResult? {
        let prompt = localhost == nil
            ? "flotilla wants to add the local domain “\(domain)” to this Mac’s DNS settings."
            : "flotilla wants to point the local name “\(domain)” at this Mac."
        let outcome = await runPrivileged(.create(domain: domain, localhost: localhost), prompt: prompt)
        await refreshDNS()
        switch outcome {
        case .succeeded:
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns,
                                          subject: domain, action: "Created"))
            return nil
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Deletes domains — one helper request or **one** administrator prompt however many there are.
    func deleteDNSDomains(_ domains: [String]) async -> DNSActionResult? {
        let prompt = domains.count == 1
            ? "flotilla wants to remove the local domain “\(domains[0])” from this Mac’s DNS settings."
            : "flotilla wants to remove \(domains.count) local domains from this Mac’s DNS settings."
        let outcome = await runPrivileged(.delete(domains), prompt: prompt)
        await refreshDNS()
        switch outcome {
        case .succeeded:
            for domain in domains {
                recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns,
                                              subject: domain, action: "Deleted"))
            }
            return nil
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }

    /// Makes `domain` the one containers are named under, or stops naming them when `nil` — by
    /// editing `config.toml`'s `[dns] domain` and restarting the runtime, which reads it at start.
    ///
    /// **Stops every running container.** The only callers confirm first and say so; this method
    /// does not ask. If the runtime is not running, the file is written and nothing restarts: the
    /// setting is read when it next starts.
    ///
    /// This pulls `config.toml` editing forward from Phase 3 (decision 8; DECISIONS, 6 October),
    /// for this one key. `ContainerConfigFile.setting` changes that line and no other.
    func setContainerDNSDomain(_ domain: String?) async -> DNSActionResult? {
        let path = ContainerConfigFile.defaultPath()
        let previous = containerDNSDomain
        do {
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let updated = ContainerConfigFile.setting(dnsDomain: domain, in: existing)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return .failed("Couldn't update container's settings: \(error.localizedDescription)")
        }
        let subject = domain ?? previous ?? "containers"
        recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .dns, subject: subject,
                                      action: domain == nil ? "No longer used for containers"
                                                            : "Used for containers"))
        if runtimeUsable { await restartRuntime() }
        await refreshDNS()
        return nil
    }

    /// How many containers a restart would stop, for the confirmation that precedes one.
    var runningContainerCount: Int { containers.filter { $0.state.isRunning }.count }
}
