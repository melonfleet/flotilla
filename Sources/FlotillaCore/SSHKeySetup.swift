import Foundation

/// The SSH tab's key help (Kamal, 18 October): whether this Mac's user has an SSH key, and the two
/// fixed commands that make one and put it on a host, so the next session goes straight in instead
/// of asking for a password.
///
/// **Flotilla never reads, stores or logs a password, a private key or a passphrase (Q20).** What
/// it looks at is whether a *public* key file exists — by name, never by content — and the
/// algorithm names `ssh-add -L` prints for the agent's keys. Both commands run in the SSH tab's
/// PTY, where `ssh-keygen` asks for a passphrase and `ssh-copy-id` asks for the host's password,
/// and the keystrokes go to those processes and nowhere else.
///
/// **The argv is fixed.** `ssh-keygen -t ed25519`, and `ssh-copy-id -i <key>.pub <user>@<host>`
/// with the host and user through `RemoteAccess`'s validators and the key one of the five names
/// OpenSSH looks for, in this user's `~/.ssh`. No shell between, no option a value could choose.
public enum SSHKeySetup {

    public static let keygenExecutable = "/usr/bin/ssh-keygen"
    public static let copyIDExecutable = "/usr/bin/ssh-copy-id"
    public static let agentExecutable = "/usr/bin/ssh-add"

    /// `ssh-keygen -t ed25519`: the user answers where to save it (Enter keeps `~/.ssh/id_ed25519`)
    /// and the passphrase. Offered only when no key exists, and ssh-keygen itself asks before it
    /// overwrites one — two guards, so a key is never replaced by a click.
    public static let keygenArguments = ["-t", "ed25519"]

    /// `ssh-add -L`: the agent's public keys. Read-only.
    public static let agentArguments = ["-L"]

    /// The public halves of OpenSSH's default identities (ssh(1), `-i`), most preferred first —
    /// the one `ssh-copy-id` is pointed at is the first that exists.
    public static let publicKeyNames = ["id_ed25519.pub", "id_ecdsa.pub", "id_ed25519_sk.pub",
                                        "id_ecdsa_sk.pub", "id_rsa.pub"]

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
        public var agent: Agent

        public init(publicKeys: [String], agent: Agent) {
            self.publicKeys = publicKeys
            self.agent = agent
        }

        /// A key ssh would offer: a default identity file, or one in the agent.
        public var hasKey: Bool {
            if !publicKeys.isEmpty { return true }
            if case .keys(let types) = agent { return !types.isEmpty }
            return false
        }

        /// The file `ssh-copy-id` copies. Nil with keys only in the agent: copying those is
        /// `ssh-copy-id` without `-i`, which this flow does not offer, so the page says how instead.
        public var keyToCopy: String? { publicKeys.first }
    }

    /// The status, from which files exist and what the agent said. `fileExists` is given the full
    /// path; nothing is opened.
    public static func status(sshDirectory: String, agent: Agent,
                              fileExists: (String) -> Bool) -> Status {
        let found = publicKeyNames.filter { fileExists(path(sshDirectory, $0)) }
        return Status(publicKeys: found, agent: agent)
    }

    public enum CopyProblem: Error, Equatable, CustomStringConvertible {
        case address(RemoteAccess.ArgumentProblem)
        case key

        public var description: String {
            switch self {
            case .address(let problem): problem.description
            case .key: "That isn\u{2019}t one of the key files Flotilla will pass to ssh-copy-id."
            }
        }
    }

    /// `-i <~/.ssh/name.pub> [user@]host`. `ssh-copy-id` has no `-l`, so the user goes in the
    /// destination — safe because neither validator allows an `@`, so the split is unambiguous,
    /// and neither value may start with `-`.
    public static func copyIDArguments(sshDirectory: String, publicKey: String, host: String,
                                       user: String?) throws(CopyProblem) -> [String] {
        guard publicKeyNames.contains(publicKey), sshDirectory.hasPrefix("/"),
              !sshDirectory.contains("\n"), sshDirectory.hasSuffix("/.ssh") else { throw .key }
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

    private static func path(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
