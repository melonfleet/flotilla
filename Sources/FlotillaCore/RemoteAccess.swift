import Foundation

/// macOS's own ways into a host — Remote Login (SSH), Screen Sharing and File Sharing — as a host's
/// page offers them in its tab pill (Kamal, 17 October; DECISIONS #2 amended). Foundation-only, so
/// the argv rules and the reachability rules are tested on Linux with everything else.
///
/// **None of this is a Flotilla transport.** Flotilla's own link to a host is still
/// Network.framework and mTLS only. The SSH tab runs the user's own `/usr/bin/ssh` with the user's
/// own keys, agent and `~/.ssh/config`; it carries no Flotilla command, and Flotilla never asks for,
/// stores or logs a credential of any kind (Q20) — what is typed into the terminal passes through
/// Flotilla's terminal view to ssh's PTY and is kept nowhere. What it does decide is the argv, and that is
/// why the argv is built here, from two validated strings and nothing else.
public enum RemoteAccess {

    public enum Service: String, CaseIterable, Sendable {
        case ssh, screenSharing, fileSharing

        /// The port its listener holds on a Mac where it is on: what a host checks to report it.
        public var port: Int {
            switch self {
            case .ssh: 22
            case .screenSharing: 5900
            case .fileSharing: 445
            }
        }

        /// Its switch in launchd, the fallback when the listeners cannot be read.
        public var launchdLabel: String {
            switch self {
            case .ssh: SystemReport.remoteLoginLabel
            case .screenSharing: SystemReport.screenSharingLabel
            case .fileSharing: SystemReport.fileSharingLabel
            }
        }
    }

    /// What the host last said about one service. `unknown` is a host that has not said — an older
    /// Flotilla, or one that has not finished its first read — and is never drawn as off.
    public enum State: Sendable, Equatable {
        case on, off, unknown

        public init(_ reported: Bool?) {
            self = switch reported {
            case true?: .on
            case false?: .off
            case nil: .unknown
            }
        }
    }

    public static func state(of service: Service, in facts: HostFacts?) -> State {
        switch service {
        case .ssh: State(facts?.remoteLogin)
        case .screenSharing: State(facts?.screenSharing)
        case .fileSharing: State(facts?.fileSharing)
        }
    }

    // MARK: Where

    /// The name or address to reach a host at, by the same rule the wire uses (`PeerBook.reach`):
    /// where Bonjour sees it now, else the address its owner typed, else where it was last reached.
    ///
    /// A Bonjour endpoint is a service name ("Kamal's Mac mini"), which no other tool can connect
    /// to; it becomes the host's own Bonjour host name, `Kamals-Mac-mini.local`, which it reports in
    /// `HostFacts.localHostName`. With neither, the host's first reported address.
    public static func address(advertised: PeerEndpoint?, typed: PeerEndpoint?, last: PeerEndpoint?,
                               facts: HostFacts?) -> String? {
        let bonjourHost = facts?.localHostName.flatMap { $0.isEmpty ? nil : "\($0).local" }
        let fallback = bonjourHost ?? facts?.ipv4Addresses?.first
        switch PeerBook.reach(advertised: advertised, typed: typed, last: last) {
        case .address(let host, _)?: return host
        case .bonjour?, nil: return fallback
        }
    }

    // MARK: SSH

    /// The Mac's own client. Never a configurable path: what runs is the system's signed binary.
    public static let sshExecutable = "/usr/bin/ssh"

    public enum ArgumentProblem: Error, Equatable, CustomStringConvertible {
        case host
        case user

        /// Without the value: an alert is a disclosure surface, and a user name is one of the things
        /// this project keeps finding in places it should not be.
        public var description: String {
            switch self {
            case .host: "That host name isn\u{2019}t one Flotilla will pass to ssh: letters, digits, dots, hyphens, or an IP address."
            case .user: "That user name isn\u{2019}t one Flotilla will pass to ssh: letters, digits, dots, hyphens and underscores, not starting with a hyphen or a dot."
            }
        }
    }

    /// A host name, an IPv4 address or an IPv6 literal, and nothing else.
    ///
    /// The rule exists for three reasons. A leading `-` would be read by ssh as an option (and ssh
    /// reads options *after* the destination too, so position alone does not protect it). A `@`,
    /// `:` port or `ssh://` URI would let the value choose a user or a port the page did not show.
    /// And ssh expands `%h` and `%r` into the user's own `ProxyCommand` and `Match exec` lines,
    /// which run in a shell — the class of CVE-2023-51385 — so shell metacharacters, spaces and
    /// control characters never reach it, whatever the user's config does with them.
    public static func isValidHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count), let first = host.unicodeScalars.first,
              first != "-", first != "." else { return false }
        if host.contains(":") {
            // An IPv6 literal: hex digits and colons only, at least two colons. No scope (`%en0`),
            // no brackets, no port.
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
            return host.unicodeScalars.allSatisfy(hex.contains) && host.filter { $0 == ":" }.count >= 2
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return host.unicodeScalars.allSatisfy(allowed.contains) && !host.contains("..")
    }

    /// A macOS short name: letters, digits, `.`, `_` and `-`, not starting with `-` or `.`, at most
    /// 64. Stricter than ssh, which is the safe direction for the same reasons as the host.
    public static func isValidUser(_ user: String) -> Bool {
        guard (1...64).contains(user.utf8.count), let first = user.unicodeScalars.first,
              first != "-", first != "." else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return user.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The arguments after `/usr/bin/ssh`: `-l <user> <host>`, or `<host>` alone when no user is
    /// named, so ssh uses the user's `~/.ssh/config` or, without one, this Mac's user name.
    ///
    /// No shell is involved — these become `execve`'s argv directly — and nothing else is added:
    /// no `-o` options, no command, no `-t` (the PTY already makes the session interactive). The
    /// user is passed with `-l` rather than as `user@host`, so it can never be parsed as part of
    /// the destination. `--` is not needed because the host cannot start with `-`; validation, not
    /// position, is what keeps it out of the option parser.
    public static func sshArguments(host: String, user: String?) throws(ArgumentProblem) -> [String] {
        guard isValidHost(host) else { throw .host }
        guard let user, !user.isEmpty else { return [host] }
        guard isValidUser(user) else { throw .user }
        return ["-l", user, host]
    }

    /// What the SSH tab's process inherits from Flotilla's own environment, on top of the
    /// terminal's (`TERM`, `LANG`, `HOME`, `USER`): the agent's socket, so the user's keys and the
    /// Keychain work as in Terminal; `SHELL` and `PATH` for the user's own `ProxyCommand`; and
    /// `TMPDIR` for ssh's control sockets. Nothing else is passed through — this is a list of what
    /// to include, not of what to leave out.
    public static let passedEnvironment = ["SSH_AUTH_SOCK", "SHELL", "PATH", "TMPDIR"]

    public static func sshEnvironment(base: [String], inherited: [String: String]) -> [String] {
        var environment = base
        for key in passedEnvironment {
            guard let value = inherited[key], !value.isEmpty,
                  !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { continue }
            environment.removeAll { $0.hasPrefix("\(key)=") }
            environment.append("\(key)=\(value)")
        }
        return environment
    }
}
