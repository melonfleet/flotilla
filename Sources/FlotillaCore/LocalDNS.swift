import Foundation

// Local DNS domains — the DNS section (6 October).
//
// Two things make a domain work, and they live in different places (proven on `container` 1.5.0;
// DECISIONS, groups section):
//
// 1. **macOS's resolver** sends `*.domain` lookups to the runtime's DNS server. That is a file the
//    runtime writes as root, `/etc/resolver/containerization.<domain>`, by
//    `sudo container system dns create <domain>`. World-readable, so Flotilla reads the details from
//    it rather than from `dns list`, which returns bare names.
// 2. **The runtime registers containers** under one domain, set in
//    `~/.config/container/config.toml` as `[dns] domain = "…"`, read at service start. There is no
//    CLI to write it; changing it means editing the file and restarting the service, which stops
//    every container.
//
// A domain can also be a **host alias** (`dns create --localhost <ipv4>`): inside containers the
// name resolves to an address the runtime redirects to the Mac's own localhost, so a container can
// reach a service running on the Mac (`host.container.internal`). Its resolver file says so with
// `options localhost:<ip>` and uses port 1053 rather than 2053.
//
// Everything here is pure, so it is tested without a runtime, an administrator or the files.

/// One local DNS domain, as Flotilla shows it.
/// Codable because a host sends its rows to the admin Mac (D3, `HostDNSStatus`).
public struct LocalDNSDomain: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        /// Containers are looked up under it (`web.flotilla`).
        case containers
        /// It resolves to the Mac itself, through the given address, for reaching host services.
        case hostAlias(String)
    }

    public let name: String
    public let kind: Kind
    /// Whether macOS's resolver knows the domain — the `/etc/resolver` file exists. A domain the
    /// runtime lists without one is half set up, and the section says so.
    public let resolverInstalled: Bool
    /// Whether containers are registered under this domain (`config.toml`'s `[dns] domain`).
    public let registersContainers: Bool

    public var id: String { name }

    public init(name: String, kind: Kind, resolverInstalled: Bool, registersContainers: Bool) {
        self.name = name
        self.kind = kind
        self.resolverInstalled = resolverInstalled
        self.registersContainers = registersContainers
    }

    public var isHostAlias: Bool { if case .hostAlias = kind { true } else { false } }
    public var hostAliasAddress: String? { if case .hostAlias(let ip) = kind { ip } else { nil } }

    /// How a container named `web` is reached under this domain, or `nil` for a host alias.
    public func containerAddress(for container: String) -> String? {
        isHostAlias ? nil : "\(container).\(name)"
    }

    // Sort keys for the table.
    public var nameSortKey: String { name }
    public var kindSortKey: String { isHostAlias ? "1" : "0" }
    public var statusSortKey: Int { (registersContainers ? 0 : 2) + (resolverInstalled ? 0 : 1) }
}

/// The parts of `/etc/resolver/containerization.<domain>` Flotilla reads.
public struct DNSResolverFile: Equatable, Sendable {
    /// The prefix the runtime gives its resolver files, so they are told apart from other software's.
    public static let filenamePrefix = "containerization."
    public static let directory = "/etc/resolver"

    public let domain: String
    public let port: Int?
    public let localhostAddress: String?

    /// Parses the runtime's resolver file. `nil` when it has no `domain` line, so a file that is
    /// not the runtime's is never mistaken for a domain.
    public static func parse(_ text: String) -> DNSResolverFile? {
        var domain: String?
        var port: Int?
        var localhost: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "domain": domain = parts[1].trimmingCharacters(in: .whitespaces)
            case "port": port = Int(parts[1].trimmingCharacters(in: .whitespaces))
            case "options":
                // `options localhost:203.0.113.113`, the runtime's own spelling.
                for option in parts[1].split(separator: " ") where option.hasPrefix("localhost:") {
                    localhost = String(option.dropFirst("localhost:".count))
                }
            default: continue
            }
        }
        guard let domain, !domain.isEmpty else { return nil }
        return DNSResolverFile(domain: domain, port: port, localhostAddress: localhost)
    }

    /// The domain a resolver filename belongs to, or `nil` if it is not one of the runtime's.
    public static func domain(fromFilename name: String) -> String? {
        guard name.hasPrefix(filenamePrefix) else { return nil }
        let domain = String(name.dropFirst(filenamePrefix.count))
        return domain.isEmpty ? nil : domain
    }
}

public enum LocalDNS {
    /// Why a well-formed domain should still not be created, or `nil`.
    ///
    /// `local` is the one refused outright: macOS resolves `.local` with multicast DNS (Bonjour),
    /// and a resolver file for it would send every printer, AirPlay and `name.local` lookup on the
    /// Mac to the container runtime instead.
    public static func reservedProblem(_ domain: String) -> String? {
        guard domain == "local" || domain.hasSuffix(".local") else { return nil }
        return "macOS keeps .local for Bonjour — a domain under it would break printers, AirPlay "
            + "and other name.local lookups on this Mac. Try test instead."
    }

    /// The section's rows: every domain the runtime lists or that has a resolver file, sorted.
    ///
    /// - Parameters:
    ///   - listed: `container system dns list`. It reads the same files today; kept as the
    ///     runtime's own answer in case it stops doing so.
    ///   - resolverFiles: the runtime's files in `/etc/resolver`, already parsed.
    ///   - containerDomain: `config.toml`'s `[dns] domain`, if set.
    public static func domains(listed: [String], resolverFiles: [DNSResolverFile],
                               containerDomain: String?) -> [LocalDNSDomain] {
        let files = Dictionary(resolverFiles.map { ($0.domain, $0) },
                               uniquingKeysWith: { first, _ in first })
        // The configured domain is a row even with no resolver file: containers are named under
        // it, and only this Mac can't look the names up — the half-set-up state worth showing.
        var names = Set(listed).union(files.keys)
        if let containerDomain, !containerDomain.isEmpty { names.insert(containerDomain) }
        return names.sorted().map { name in
            let file = files[name]
            let kind: LocalDNSDomain.Kind = file?.localhostAddress.map { .hostAlias($0) } ?? .containers
            return LocalDNSDomain(name: name, kind: kind, resolverInstalled: file != nil,
                                  registersContainers: name == containerDomain && !kind.isAlias)
        }
    }
}

private extension LocalDNSDomain.Kind {
    var isAlias: Bool { if case .hostAlias = self { true } else { false } }
}

/// `~/.config/container/config.toml`, read and edited **only** for `[dns] domain`.
///
/// Not a TOML parser, and deliberately so: the file belongs to the runtime and may hold settings
/// Flotilla knows nothing about, so the editor touches one key in one table and leaves every
/// other byte as it found it — comments, ordering, other tables, other keys in `[dns]`. A full
/// parse-and-rewrite would normalise the file on its way through, which is a change to someone
/// else's configuration nobody asked for.
public enum ContainerConfigFile {
    /// `~/.config/container/config.toml`.
    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".config/container/config.toml")
    }

    /// The `[dns] domain` value, or `nil` if the file has none.
    public static func dnsDomain(in text: String) -> String? {
        var inDNS = false
        for raw in text.components(separatedBy: "\n") {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inDNS = (line == "[dns]"); continue }
            guard inDNS, let value = value(ofKey: "domain", in: line) else { continue }
            return value
        }
        return nil
    }

    /// `text` with `[dns] domain` set to `domain`, or removed when `domain` is `nil`.
    ///
    /// Adds a `[dns]` table at the end if there is none, and the key at the end of the table if
    /// the table has none. Every other line is kept exactly.
    public static func setting(dnsDomain domain: String?, in text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        // A trailing newline splits into a final empty element; keep it out of the edit and put it
        // back at the end.
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }

        var dnsStart: Int?
        var dnsEnd = lines.count          // exclusive: the next table, or the end
        var keyLine: Int?
        for (index, raw) in lines.enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if dnsStart != nil, dnsEnd == lines.count { dnsEnd = index }
                if line == "[dns]" { dnsStart = index }
                continue
            }
            if dnsStart != nil, dnsEnd == lines.count, value(ofKey: "domain", in: line) != nil {
                keyLine = index
            }
        }

        let newLine = domain.map { "domain = \"\($0)\"" }
        switch (dnsStart, keyLine, newLine) {
        case (_, let key?, let line?):
            lines[key] = line
        case (_, let key?, nil):
            lines.remove(at: key)
        case (_?, nil, let line?):
            // After the table's last non-blank line, so a blank line separating it from the next
            // table stays where it was.
            var insertAt = dnsEnd
            while insertAt > (dnsStart ?? 0) + 1,
                  lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(line, at: insertAt)
        case (nil, nil, let line?):
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[dns]")
            lines.append(line)
        case (_, nil, nil):
            break
        }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? "" : joined + "\n"
    }

    /// `domain = "x"` → `x`, for this key only; `nil` for any other line.
    private static func value(ofKey key: String, in line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        guard line[..<equals].trimmingCharacters(in: .whitespaces) == key else { return nil }
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'",
           value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// The line without a `#` comment, unless the `#` is inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }
}

/// Which `container` binary may be run **as an administrator**.
///
/// The app's own binary path is a user setting (`containerBinaryPath`), and that is fine for
/// running as the user. It is not fine for running as root: anything able to write Flotilla's
/// preferences could point it at its own program and have it run with the owner's password. So the
/// administrator path accepts only the binary in a known install directory, **owned by root and
/// writable by no one else — and the same of the directory**, or the file could be swapped between
/// the check and the run. A symlink is refused rather than followed, for the same reason. This is
/// what Apple's installer leaves: `root:wheel`, `-rwxr-xr-x`, in a `root:wheel` `/usr/local/bin`
/// (measured 6 October).
public enum AdminExecutable {
    /// The file facts the check needs, injected so the rule is tested without real files.
    public struct Facts: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case file, directory, other }

        public let ownerUID: Int
        public let permissions: Int     // POSIX mode bits, e.g. 0o755
        public let kind: Kind

        public init(ownerUID: Int, permissions: Int, kind: Kind) {
            self.ownerUID = ownerUID
            self.permissions = permissions
            self.kind = kind
        }

        /// Owned by root and not writable by group or others.
        var isRootControlled: Bool { ownerUID == 0 && permissions & 0o022 == 0 }
    }

    public static let installDirectory = "/usr/local/bin"
    public static let path = installDirectory + "/container"

    /// Why the installed binary may not be run as root, or `nil` if it may.
    public static func problem(file: Facts?, directory: Facts?) -> String? {
        guard let directory, directory.kind == .directory, directory.isRootControlled else {
            return "\(installDirectory) can be changed without an administrator, so Flotilla "
                + "won't run container from it as one."
        }
        guard let file, file.kind == .file else {
            return "\(path) isn't a plain file. Run the command in Terminal with sudo instead."
        }
        guard file.isRootControlled else {
            return "\(path) can be changed without an administrator, so Flotilla won't run it "
                + "as one. Reinstall container, or run the command in Terminal with sudo."
        }
        return nil
    }

    /// The real facts for `path`, **without** following a symlink.
    public static func facts(at path: String) -> Facts? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attributes[.type] as? FileAttributeType
        return Facts(ownerUID: (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1,
                     permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777,
                     kind: type == .typeRegular ? .file : type == .typeDirectory ? .directory : .other)
    }

    /// The check, against the real files.
    public static func installedProblem() -> String? {
        problem(file: facts(at: path), directory: facts(at: installDirectory))
    }
}

/// The AppleScript the administrator prompt runs: `do shell script "…" with administrator
/// privileges`, for one or more **validated** commands.
///
/// Pure, so the quoting is tested here rather than trusted in the app. Two layers: each argument is
/// single-quoted for `/bin/sh` (a `'` inside becomes `'\''`), then the whole line is escaped as an
/// AppleScript string literal (`\` and `"`). The Allowlist already refuses every character either
/// layer cares about, so neither should ever have work to do — the quoting is there so that stays
/// true if a shape is ever loosened.
///
/// Several commands join with `&&` into **one** prompt: deleting three domains asks for the
/// password once, and stops at the first failure rather than reporting success for the rest.
public enum AdminScript {
    public static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The shell line: the installed binary, by absolute path, then each command's arguments.
    public static func shellLine(_ commands: [ValidatedCommand],
                                 executable: String = AdminExecutable.path) -> String {
        commands.map { command in
            ([executable] + command.arguments).map(shellQuoted).joined(separator: " ")
        }.joined(separator: " && ")
    }

    /// What a person would type to do the same by hand — shown in the form, so the prompt never
    /// asks for a password to run something the screen did not say.
    public static func displayLine(_ command: ValidatedCommand) -> String {
        (["sudo", "container"] + command.arguments).joined(separator: " ")
    }

    public static func source(_ commands: [ValidatedCommand], prompt: String,
                              executable: String = AdminExecutable.path) -> String {
        "do shell script " + appleScriptString(shellLine(commands, executable: executable))
            + " with prompt " + appleScriptString(prompt)
            + " with administrator privileges"
    }
}
