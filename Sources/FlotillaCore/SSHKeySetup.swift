import Foundation

/// The SSH tab's key help (Kamal, 18 October): whether this Mac's user has an SSH key, and the two
/// fixed commands that make one and put it on a host, so the next session goes straight in instead
/// of asking for a password.
///
/// **Flotilla never stores or logs a password or a passphrase, and never reads a private key
/// (Q20).** What it looks at is whether a key file exists — by name, never by content — and the
/// algorithm names `ssh-add -L` prints for the agent's keys. Both commands run in the SSH tab's
/// PTY, where `ssh-keygen` asks for a passphrase and `ssh-copy-id` asks for the host's password.
/// That terminal is Flotilla's own SwiftTerm view, so the keystrokes do pass through Flotilla's
/// process on their way to the PTY (Kyle, 18 October): they are written to it and kept nowhere.
///
/// **The argv is fixed.** `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`, and
/// `ssh-copy-id -i <key>.pub <user>@<host>` with the host and user through `RemoteAccess`'s
/// validators and the key one of the five names OpenSSH looks for, in this user's `~/.ssh`. No
/// option a value could choose.
///
/// **No shell between — except the one inside `ssh-copy-id`.** It is a shell script, and builds
/// its `GET_ID` from the `-i` path and `eval`s it, so a `$(…)` in the home directory's name ran
/// locally (Kyle, 18 October, confirmed with a harmless marker). Every path either command is given
/// must therefore pass `isShellInert`; a home directory that does not gets neither command, and
/// the card says why (`CopyProblem.unsafePath`).
public enum SSHKeySetup {

    public static let keygenExecutable = "/usr/bin/ssh-keygen"
    public static let copyIDExecutable = "/usr/bin/ssh-copy-id"
    public static let agentExecutable = "/usr/bin/ssh-add"

    /// The type and the file `keygenArguments` names, before the path: what the card shows.
    public static let keygenType = ["-t", "ed25519"]
    public static let keygenKeyName = "id_ed25519"

    /// `ssh-keygen -t ed25519 -f <~/.ssh/id_ed25519>`: the user answers only the passphrase.
    ///
    /// **Never overwrites (Kyle, 18 October).** ssh-keygen asks before replacing a file and would
    /// replace it on a `y`, so asking is not enough: this is offered only when `Status.canMakeKey`
    /// — no default identity in `~/.ssh` at all, private *or* public — and the file is named, so
    /// the user cannot type an existing one at a "where to save" prompt either.
    public static func keygenArguments(sshDirectory: String) throws(CopyProblem) -> [String] {
        guard isSSHDirectory(sshDirectory) else { throw .unsafePath }
        return keygenType + ["-f", path(sshDirectory, keygenKeyName)]
    }

    /// `ssh-add -L`: the agent's public keys. Read-only.
    public static let agentArguments = ["-L"]

    /// OpenSSH's default identities (ssh(1), `-i`), most preferred first, plus `id_dsa`, which
    /// current ssh no longer offers but whose file is still a key nobody should lose.
    public static let privateKeyNames = ["id_ed25519", "id_ecdsa", "id_ed25519_sk", "id_ecdsa_sk", "id_rsa", "id_dsa"]

    /// Their public halves, without `id_dsa` — the one `ssh-copy-id` is pointed at is the first
    /// that exists.
    public static let publicKeyNames = ["id_ed25519.pub", "id_ecdsa.pub", "id_ed25519_sk.pub",
                                        "id_ecdsa_sk.pub", "id_rsa.pub"]

    /// Letters, digits, `/`, `.`, `_` and `-`, starting with `/`, and no `..` component: a path no
    /// shell can read as anything but itself. Deliberately narrower than what a path may contain —
    /// a space, a quote, `$`, a backtick, `;` or a non-ASCII letter all refuse, because
    /// `ssh-copy-id` evaluates the path and this cannot know how its quoting goes wrong.
    public static func isShellInert(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count < 1024 else { return false }
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-"
        guard path.allSatisfy({ allowed.contains($0) }) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// `~/.ssh`, absolute and shell-inert.
    public static func isSSHDirectory(_ directory: String) -> Bool {
        isShellInert(directory) && directory.hasSuffix("/.ssh")
    }

    /// What the agent said.
    public enum Agent: Sendable, Equatable {
        /// The key types it holds (`ssh-ed25519`, `ssh-rsa`, …) — the first field of each line only.
        /// The key and its comment, which is often `user@host`, are not kept.
        case keys([String])
        /// "The agent has no identities." — exit 1.
        case empty
        /// No agent, or ssh-add could not run — exit 2, or anything unexpected.
        case unavailable
    }

    /// `ssh-add -L`'s output and exit code, as `Agent`.
    public static func parseAgent(output: String, exitCode: Int32) -> Agent {
        switch exitCode {
        case 0:
            let types = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                guard let type = line.split(separator: " ", maxSplits: 1).first.map(String.init),
                      isKeyType(type) else { return nil }
                return type
            }
            return types.isEmpty ? .empty : .keys(types)
        case 1:
            return .empty
        default:
            return .unavailable
        }
    }

    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `sk-ssh-ed25519@openssh.com`, `ssh-rsa`, and their
    /// certificate forms: a line that does not start with one is a message, not a key.
    static func isKeyType(_ type: String) -> Bool {
        let known = ["ssh-", "ecdsa-", "sk-ssh-", "sk-ecdsa-"]
        return known.contains { type.hasPrefix($0) } && type.count < 64
            && type.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-@.".unicodeScalars.contains($0) }
    }

    /// What this Mac's user has.
    public struct Status: Sendable, Equatable {
        /// The public key files found in `~/.ssh`, by name, in `publicKeyNames` order.
        public var publicKeys: [String]
        /// The private key files found there, by name, in `privateKeyNames` order — whether or not
        /// their public half is beside them.
        public var privateKeys: [String]
        public var agent: Agent
        /// Whether `~/.ssh`'s path is one the two commands may be given (`isSSHDirectory`).
        public var pathIsSafe: Bool

        public init(publicKeys: [String], privateKeys: [String] = [], agent: Agent, pathIsSafe: Bool = true) {
            self.publicKeys = publicKeys
            self.privateKeys = privateKeys
            self.agent = agent
            self.pathIsSafe = pathIsSafe
        }

        /// A key ssh would offer: a default identity file, or one in the agent.
        public var hasKey: Bool {
            if !publicKeys.isEmpty { return true }
            if case .keys(let types) = agent { return !types.isEmpty }
            return false
        }

        /// The file `ssh-copy-id` copies. Nil with keys only in the agent: copying those is
        /// `ssh-copy-id` without `-i`, which this flow does not offer, so the page says how instead.
        public var keyToCopy: String? { pathIsSafe ? publicKeys.first : nil }

        /// Whether Make a Key is offered: a safe path, and no default identity file of either half.
        /// A private key without its `.pub` is still a key; making one would put it at risk.
        public var canMakeKey: Bool { pathIsSafe && publicKeys.isEmpty && privateKeys.isEmpty }

        /// A private key in `~/.ssh` with no public half to copy.
        public var privateKeyWithoutPublic: String? {
            publicKeys.isEmpty ? privateKeys.first : nil
        }
    }

    /// The status, from which files exist and what the agent said. `fileExists` is given the full
    /// path; nothing is opened.
    public static func status(sshDirectory: String, agent: Agent,
                              fileExists: (String) -> Bool) -> Status {
        let publicKeys = publicKeyNames.filter { fileExists(path(sshDirectory, $0)) }
        let privateKeys = privateKeyNames.filter { fileExists(path(sshDirectory, $0)) }
        return Status(publicKeys: publicKeys, privateKeys: privateKeys, agent: agent,
                      pathIsSafe: isSSHDirectory(sshDirectory))
    }

    public enum CopyProblem: Error, Equatable, CustomStringConvertible {
        case address(RemoteAccess.ArgumentProblem)
        case key
        /// `~/.ssh`'s path has a character a shell could act on.
        case unsafePath

        public var description: String {
            switch self {
            case .address(let problem): problem.description
            case .key: "That isn\u{2019}t one of the key files Flotilla will pass to ssh-copy-id."
            case .unsafePath: SSHKeySetup.unsafePathExplanation
            }
        }
    }

    /// `-i <~/.ssh/name.pub> [user@]host`. `ssh-copy-id` has no `-l`, so the user goes in the
    /// destination — safe because neither validator allows an `@`, so the split is unambiguous,
    /// and neither value may start with `-`.
    public static func copyIDArguments(sshDirectory: String, publicKey: String, host: String,
                                       user: String?) throws(CopyProblem) -> [String] {
        guard isSSHDirectory(sshDirectory) else { throw .unsafePath }
        guard publicKeyNames.contains(publicKey) else { throw .key }
        guard RemoteAccess.isValidHost(host) else { throw .address(.host) }
        let destination: String
        if let user, !user.isEmpty {
            guard RemoteAccess.isValidUser(user) else { throw .address(.user) }
            destination = "\(user)@\(host)"
        } else {
            destination = host
        }
        return ["-i", path(sshDirectory, publicKey), destination]
    }

    /// Why neither command is offered, for the card.
    public static let unsafePathExplanation =
        "Your home folder\u{2019}s path has a space or a symbol in it, and ssh-copy-id would read that as a command, "
        + "so Flotilla won\u{2019}t run it or ssh-keygen here. Do it by hand in Terminal, below."

    private static func path(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
