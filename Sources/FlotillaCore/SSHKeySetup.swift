import Foundation

/// The SSH tab's key help (Kamal, 18 October): Flotilla's own SSH key, `~/.ssh/flotilla_ed25519`,
/// for Flotilla's hosts only, and the fixed commands that make it, put it on a host, replace it and
/// take it off a host again, so a session goes straight in instead of asking for a password.
///
/// **Flotilla's key, never the user's (Kamal, 18 October).** Make a Key writes
/// `flotilla_ed25519`, and Regenerate renames that pair before making another. The user's own keys —
/// OpenSSH's default identities and whatever the agent holds — are detected so the page can say they
/// exist, and are never written, renamed, copied or removed. Flotilla's SSH sessions add
/// `-i ~/.ssh/flotilla_ed25519 -o IdentitiesOnly=yes` only while that key exists (`Identity`), so
/// without it they behave exactly as before: the agent and the default keys.
///
/// **Flotilla never stores or logs a password or a passphrase, and never reads a private key
/// (Q20).** What it looks at is whether a key file exists — by name — the algorithm names
/// `ssh-add -L` prints for the agent's keys, and the *public* half of its own key, whose base64 body
/// is what finds that key's line in a host's `authorized_keys`. Every command runs in the SSH tab's
/// PTY, where `ssh-keygen` asks for a passphrase and `ssh-copy-id` for the host's password. That
/// terminal is Flotilla's own SwiftTerm view, so the keystrokes do pass through Flotilla's process
/// on their way to the PTY (Kyle, 18 October): they are written to it and kept nowhere.
///
/// **The argv is fixed.** Every builder here takes the `~/.ssh` path, a host and a user through
/// `RemoteAccess`'s validators and, for removal, a key body that must be base64 and nothing else. No
/// option a value could choose.
///
/// **No shell between — except two we cannot avoid, and both are given nothing a shell could act
/// on.** `ssh-copy-id` is a shell script that builds its `GET_ID` from the `-i` path and `eval`s it,
/// so a `$(…)` in the home directory's name ran locally (Kyle, 18 October): every path passes
/// `isShellInert` or no command is offered (`CopyProblem.unsafePath`). And a command run over ssh is
/// read by the remote user's login shell: the removal command is one fixed string, and the only
/// values in it are key bodies that passed `isKeyBody` — `[A-Za-z0-9+/]` and trailing `=`.
public enum SSHKeySetup {

    public static let keygenExecutable = "/usr/bin/ssh-keygen"
    public static let copyIDExecutable = "/usr/bin/ssh-copy-id"
    public static let agentExecutable = "/usr/bin/ssh-add"

    // MARK: Flotilla's key

    /// Flotilla's private key in `~/.ssh`, and its public half beside it.
    public static let flotillaKeyName = "flotilla_ed25519"
    public static let flotillaPublicKeyName = flotillaKeyName + ".pub"

    /// The type and the comment `keygenArguments` passes, before the path: what the card shows.
    /// The comment is fixed so that the line ssh-copy-id adds to a host says whose it is, rather
    /// than carrying this Mac's account and computer name, which is ssh-keygen's default.
    public static let keygenOptions = ["-t", "ed25519", "-C", "flotilla"]

    /// `ssh-keygen -t ed25519 -C flotilla -f <~/.ssh/flotilla_ed25519>`: the user answers only the
    /// passphrase.
    ///
    /// **Never overwrites (Kyle, 18 October).** ssh-keygen asks before replacing a file and would
    /// replace it on a `y`, so asking is not enough: this is offered only when `Status.canMakeKey`
    /// — neither half of Flotilla's key exists — and the file is named, so the user cannot type an
    /// existing one at a "where to save" prompt either. Regenerate renames the pair first.
    public static func keygenArguments(sshDirectory: String) throws(CopyProblem) -> [String] {
        guard isSSHDirectory(sshDirectory) else { throw .unsafePath }
        return keygenOptions + ["-f", path(sshDirectory, flotillaKeyName)]
    }

    /// The options a Flotilla SSH session adds while its key exists: Flotilla's key first, and
    /// `IdentitiesOnly` so the agent does not offer the user's other keys ahead of it. **Not** that
    /// key alone (Kyle, 18 October): `IdentitiesOnly` still lets ssh offer any `IdentityFile` the
    /// user's `~/.ssh/config` names — verified with `ssh -G` — and a session keeps that config on
    /// purpose. Where only Flotilla's key may sign in, use `exclusiveArguments`. Only constructible
    /// from a safe `~/.ssh`, so the path has nothing ssh's `%` and `~` expansion could act on either.
    public struct Identity: Sendable, Equatable {
        public let path: String

        public init?(sshDirectory: String) {
            guard SSHKeySetup.isSSHDirectory(sshDirectory) else { return nil }
            path = SSHKeySetup.path(sshDirectory, SSHKeySetup.flotillaKeyName)
        }

        /// Flotilla's key, if its private half is there now. `fileExists` is given the full path.
        public static func present(sshDirectory: String, fileExists: (String) -> Bool) -> Identity? {
            guard let identity = Identity(sshDirectory: sshDirectory), fileExists(identity.path) else { return nil }
            return identity
        }

        public var arguments: [String] { ["-i", path, "-o", "IdentitiesOnly=yes"] }

        /// Flotilla's key and nothing else can sign in: no config file — neither the user's nor the
        /// system's, so no `IdentityFile`, `CertificateFile` or `IdentityAgent` from either — no agent,
        /// and this one identity. `known_hosts` still applies, and `StrictHostKeyChecking` stays at
        /// ssh's default. For the steps whose success has to mean *this* key works.
        public var exclusiveArguments: [String] {
            ["-F", "/dev/null", "-o", "IdentitiesOnly=yes", "-i", path, "-o", "IdentityAgent=none"]
        }
    }

    // MARK: The user's own keys

    /// `ssh-add -L`: the agent's public keys. Read-only.
    public static let agentArguments = ["-L"]

    /// OpenSSH's default identities (ssh(1), `-i`), most preferred first, plus `id_dsa`, which
    /// current ssh no longer offers but whose file is still a key. Detected, never touched.
    public static let privateKeyNames = ["id_ed25519", "id_ecdsa", "id_ed25519_sk", "id_ecdsa_sk", "id_rsa", "id_dsa"]

    /// Their public halves, without `id_dsa`.
    public static let publicKeyNames = ["id_ed25519.pub", "id_ecdsa.pub", "id_ed25519_sk.pub",
                                        "id_ecdsa_sk.pub", "id_rsa.pub"]

    // MARK: Paths

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

    // MARK: The agent

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

    // MARK: Key bodies

    /// A public key's base64 body, and nothing that could be anything else in a shell: `AAAA` first
    /// (every OpenSSH key blob begins with a four-byte length under 2²⁴), then `[A-Za-z0-9+/]`, then
    /// at most two `=`, a multiple of four long, and no longer than an RSA-16384 key's.
    ///
    /// This is the whole of what keeps the removal command fixed: the body is the one value in it.
    public static func isKeyBody(_ body: String) -> Bool {
        guard (16...8192).contains(body.utf8.count), body.utf8.count % 4 == 0, body.hasPrefix("AAAA") else { return false }
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        let padding = body.reversed().prefix { $0 == "=" }.count
        guard padding <= 2 else { return false }
        return body.dropLast(padding).allSatisfy { alphabet.contains($0) }
    }

    /// The body of a `.pub` file's key line — `<type> <base64> [comment]` — or nil if the first line
    /// is not one. Only the body is kept.
    public static func publicKeyBody(fromFile contents: String) -> String? {
        guard let line = contents.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, isKeyType(String(fields[0])), isKeyBody(String(fields[1])) else { return nil }
        return String(fields[1])
    }

    // MARK: Status

    /// What this Mac's user has: their own keys and Flotilla's, reported apart.
    public struct Status: Sendable, Equatable {
        /// The user's own public key files in `~/.ssh`, by name, in `publicKeyNames` order.
        public var publicKeys: [String]
        /// The user's own private key files there, by name, in `privateKeyNames` order.
        public var privateKeys: [String]
        public var agent: Agent
        /// Whether `~/.ssh`'s path is one the commands may be given (`isSSHDirectory`).
        public var pathIsSafe: Bool
        /// Whether each half of Flotilla's key exists.
        public var flotillaPrivateKey: Bool
        public var flotillaPublicKey: Bool
        /// Flotilla's public key's body, when its `.pub` reads as a key.
        public var flotillaKeyBody: String?

        public init(publicKeys: [String] = [], privateKeys: [String] = [], agent: Agent, pathIsSafe: Bool = true,
                    flotillaPrivateKey: Bool = false, flotillaPublicKey: Bool = false, flotillaKeyBody: String? = nil) {
            self.publicKeys = publicKeys
            self.privateKeys = privateKeys
            self.agent = agent
            self.pathIsSafe = pathIsSafe
            self.flotillaPrivateKey = flotillaPrivateKey
            self.flotillaPublicKey = flotillaPublicKey
            self.flotillaKeyBody = flotillaKeyBody
        }

        /// The user's own keys ssh would offer without Flotilla's: a default identity file, or one
        /// in the agent.
        public var hasOwnKey: Bool {
            if !publicKeys.isEmpty || !privateKeys.isEmpty { return true }
            if case .keys(let types) = agent { return !types.isEmpty }
            return false
        }

        /// How many keys the agent holds.
        public var agentKeyCount: Int {
            if case .keys(let types) = agent { return types.count }
            return 0
        }

        /// Both halves of Flotilla's key.
        public var hasFlotillaKey: Bool { flotillaPrivateKey && flotillaPublicKey }

        /// The file `ssh-copy-id` copies: always Flotilla's, never the user's own.
        public var keyToCopy: String? { pathIsSafe && flotillaPublicKey ? flotillaPublicKeyName : nil }

        /// Whether Make a Key is offered: a safe path, and neither half of Flotilla's key. The
        /// user's own keys are another file and do not matter.
        public var canMakeKey: Bool { pathIsSafe && !flotillaPrivateKey && !flotillaPublicKey }

        /// Whether Regenerate is offered: there is something of Flotilla's to rename.
        public var canRegenerate: Bool { pathIsSafe && (flotillaPrivateKey || flotillaPublicKey) }

        /// Whether Remove Key from This Host is offered: Flotilla's key, whose line can be found.
        public var canRemoveFromHost: Bool { pathIsSafe && flotillaPrivateKey && flotillaKeyBody != nil }
    }

    /// The status, from which files exist, what the agent said, and Flotilla's `.pub` file.
    /// `fileExists` and `readPublicKey` are given the full path; `readPublicKey` is only ever given
    /// Flotilla's `.pub`.
    public static func status(sshDirectory: String, agent: Agent, fileExists: (String) -> Bool,
                              readPublicKey: (String) -> String? = { _ in nil }) -> Status {
        let publicKeys = publicKeyNames.filter { fileExists(path(sshDirectory, $0)) }
        let privateKeys = privateKeyNames.filter { fileExists(path(sshDirectory, $0)) }
        let publicPath = path(sshDirectory, flotillaPublicKeyName)
        let hasPublic = fileExists(publicPath)
        return Status(publicKeys: publicKeys, privateKeys: privateKeys, agent: agent,
                      pathIsSafe: isSSHDirectory(sshDirectory),
                      flotillaPrivateKey: fileExists(path(sshDirectory, flotillaKeyName)),
                      flotillaPublicKey: hasPublic,
                      flotillaKeyBody: hasPublic ? readPublicKey(publicPath).flatMap(publicKeyBody(fromFile:)) : nil)
    }

    // MARK: Regenerate: the old pair is renamed, never deleted

    /// `flotilla_ed25519.old-<YYYY-MM-DD>`, then `-2`, `-3`… until neither it nor its `.pub` exists
    /// in `~/.ssh`. The date is the calendar day in `timeZone`. Nil only after 999 tries.
    public static func archiveName(sshDirectory: String, date: Date, timeZone: TimeZone,
                                   fileExists: (String) -> Bool) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let base = "\(flotillaKeyName).old-\(year)-\(two(month))-\(two(dayOfMonth))"
        for attempt in 1...999 {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            if !fileExists(path(sshDirectory, name)), !fileExists(path(sshDirectory, name + ".pub")) { return name }
        }
        return nil
    }

    /// The renames that archive Flotilla's key as `archive`: each half that exists, private first.
    /// Never anything outside `~/.ssh`, and never a name of the user's own.
    public static func archiveMoves(sshDirectory: String, archive: String,
                                    fileExists: (String) -> Bool) throws(CopyProblem) -> [(from: String, to: String)] {
        guard isSSHDirectory(sshDirectory) else { throw .unsafePath }
        guard archive.hasPrefix(flotillaKeyName + ".old-"), isShellInert("/" + archive), !archive.contains("/")
        else { throw .key }
        return [(flotillaKeyName, archive), (flotillaPublicKeyName, archive + ".pub")]
            .filter { fileExists(path(sshDirectory, $0.0)) }
            .map { (path(sshDirectory, $0.0), path(sshDirectory, $0.1)) }
    }

    // MARK: One key operation at a time

    /// The app-wide lock every key step takes — Make a Key, Regenerate (all of it, keygen to
    /// removal), Copy Key, Copy to another host and Remove (Kyle, 18 October: while Regenerate waited
    /// for a passphrase, another host's tab could make a whole key, and cancelling Regenerate then
    /// deleted it). One holder, named by host, released by the token it was given — never by anyone
    /// else's.
    public struct OperationGate: Sendable, Equatable {
        public struct Holder: Sendable, Equatable {
            public let token: UUID
            /// The host fingerprint the operation is for.
            public let host: String
            /// The host as the page names it, for "Key setup is running for …".
            public let hostName: String
        }

        public private(set) var holder: Holder?

        public init() {}

        /// A token if nothing else is running, nil if something is — even for the same host.
        public mutating func begin(host: String, hostName: String) -> UUID? {
            guard holder == nil else { return nil }
            let token = UUID()
            holder = Holder(token: token, host: host, hostName: hostName)
            return token
        }

        /// Releases the lock if `token` holds it; a stale or repeated release changes nothing.
        @discardableResult
        public mutating func end(_ token: UUID) -> Bool {
            guard holder?.token == token else { return false }
            holder = nil
            return true
        }

        /// The operation running for a host other than `host`, if any — what that host's card says.
        public func running(otherThan host: String) -> Holder? {
            holder.flatMap { $0.host == host ? nil : $0 }
        }
    }

    // MARK: A closed step's child, until it has exited

    /// A key step's session from its close to its child's **confirmed** exit (Kyle, 18 October: a
    /// closed session used to release the key lock the moment `terminate()` was sent, and SwiftTerm's
    /// termination is asynchronous, so the next key step could start beside a child still stopping).
    /// Closing sends SIGTERM; a deadline later, SIGKILL; and only the exit itself — SwiftTerm's
    /// `processTerminated`, which comes after the child is reaped — releases anything. A child that
    /// outlives SIGKILL too keeps the lock: nothing else may start beside it.
    public struct ExitBarrier: Sendable, Equatable {
        public enum State: Sendable, Equatable { case running, terminating, killed, exited }

        /// What the session's owner does now.
        public enum Action: Sendable, Equatable {
            /// Send SIGTERM.
            case terminate
            /// Send SIGKILL.
            case kill
            /// The child ended by itself: report how (`onEnd`).
            case ended
            /// The child of a closed session has exited: release what it held (`onClose`).
            case released
            /// Still waiting: SIGKILL went and the child hasn't exited. Say so; keep holding.
            case overdue
            case nothing
        }

        /// From SIGTERM to SIGKILL, and from SIGKILL to calling the child overdue.
        public static let terminateGrace: Duration = .seconds(5)
        public static let killGrace: Duration = .seconds(5)

        public private(set) var state: State = .running

        public init() {}

        public mutating func close() -> Action {
            guard state == .running else { return .nothing }
            state = .terminating
            return .terminate
        }

        /// A grace period passed since the last signal.
        public mutating func deadlinePassed() -> Action {
            switch state {
            case .terminating: state = .killed; return .kill
            case .killed: return .overdue
            case .running, .exited: return .nothing
            }
        }

        /// The child exited (or never started). Once only.
        public mutating func exited() -> Action {
            defer { state = .exited }
            switch state {
            case .running: return .ended
            case .terminating, .killed: return .released
            case .exited: return .nothing
            }
        }
    }

    // MARK: Regenerate: undoing a keygen that did not finish

    /// One file at one of Flotilla's key paths, as `lstat` sees it — a symlink is not followed.
    public struct FileStamp: Sendable, Equatable {
        public var device: UInt64
        public var inode: UInt64
        /// A regular file, not a symlink, directory or anything else.
        public var isRegularFile: Bool
        /// Owned by the user Flotilla runs as.
        public var ownedByUser: Bool

        public init(device: UInt64, inode: UInt64, isRegularFile: Bool, ownedByUser: Bool) {
            self.device = device
            self.inode = inode
            self.isRegularFile = isRegularFile
            self.ownedByUser = ownedByUser
        }

        public func isSameFile(as other: FileStamp) -> Bool { device == other.device && inode == other.inode }
    }

    /// Taken after Regenerate renamed the old pair and before ssh-keygen runs: both of Flotilla's
    /// key paths are empty, and which files — by device and inode — the old pair is now.
    public struct KeygenSnapshot: Sendable, Equatable {
        public let paths: [String]
        /// Every file that existed before ssh-keygen ran that a key path could hold afterwards.
        public let present: [FileStamp]

        /// Nil if either path is not empty — then nothing there could be told apart as new.
        public init?(sshDirectory: String, archived: [FileStamp], stamp: (String) -> FileStamp?) {
            guard SSHKeySetup.isSSHDirectory(sshDirectory) else { return nil }
            let paths = [SSHKeySetup.flotillaKeyName, SSHKeySetup.flotillaPublicKeyName].map { SSHKeySetup.path(sshDirectory, $0) }
            guard paths.allSatisfy({ stamp($0) == nil }) else { return nil }
            self.paths = paths
            present = archived
        }
    }

    /// What ssh-keygen left at Flotilla's key paths, read **the moment it exited** — while the
    /// operation lock is held, so no other key step could have written there since the snapshot.
    /// `made` is each file this ssh-keygen wrote, by identity: a regular file of the user's whose
    /// inode was not present in the snapshot. `foreign` is any other path holding something.
    public struct KeygenOutput: Sendable, Equatable {
        public let made: [String: FileStamp]
        public let foreign: [String]
    }

    public static func keygenOutput(after snapshot: KeygenSnapshot, stamp: (String) -> FileStamp?) -> KeygenOutput {
        var made: [String: FileStamp] = [:]
        var foreign: [String] = []
        for path in snapshot.paths {
            guard let file = stamp(path) else { continue }
            if file.isRegularFile && file.ownedByUser && !snapshot.present.contains(where: { $0.isSameFile(as: file) }) {
                made[path] = file
            } else {
                foreign.append(path)
            }
        }
        return KeygenOutput(made: made, foreign: foreign)
    }

    /// Whether the file found when a rollback is about to remove it is still the exact one ssh-keygen
    /// left — same device and inode, still a regular file of the user's. Recency is never evidence
    /// (Kyle, 18 October): a file another operation wrote is new and the user's too, and is not this.
    public static func isStillMade(_ recorded: FileStamp, now: FileStamp?) -> Bool {
        guard let now else { return false }
        return now.isSameFile(as: recorded) && now.isRegularFile && now.ownedByUser
    }

    /// A directory one rollback creates for itself and holds open — on this Mac, `mkdtemp` in
    /// `~/.ssh`, mode 0700 and the user's, reached through its descriptor (Kyle, 18 October). Only
    /// the user can write inside it, so a process that can write to `~/.ssh` cannot swap the entry
    /// between the check and the unlink. It holds one entry at a time.
    public protocol RollbackDirectory {
        /// Where the entry is, for saying so when it has to stay there.
        var entryPath: String { get }
        /// Renames `path` into the directory, never over anything.
        func moveIn(_ path: String) -> RollbackMove
        /// `lstat` of the entry, relative to the directory's descriptor.
        func stampEntry() -> FileStamp?
        /// Unlinks the entry, relative to the directory's descriptor; nil on success, else why not.
        func unlinkEntry() -> String?
        /// Renames the entry back to `path`, never over anything.
        func moveBack(to path: String) -> Bool
    }

    public enum RollbackMove: Sendable, Equatable { case moved, missing, failed(String) }

    public enum RollbackRemoval: Sendable, Equatable {
        case removed
        /// Not the file ssh-keygen left (or nothing was there); it is still at its path.
        case notMade
        /// Not the file ssh-keygen left, and it could not be put back: where it is now.
        case setAside(String)
        /// The file ssh-keygen left, which could not be unlinked: why, and whether it is back.
        case failed(String, setAside: String?)
    }

    /// Removes exactly the file `recorded` names, never whatever is at `path` now: it is moved into
    /// `directory`, checked there by device and inode, and unlinked there only if it is the same
    /// file. Anything else goes back to `path`, never over anything, and is never unlinked.
    public static func removeMade(_ path: String, ifStill recorded: FileStamp,
                                  in directory: some RollbackDirectory) -> RollbackRemoval {
        switch directory.moveIn(path) {
        case .missing: return .notMade
        case .failed(let reason): return .failed(reason, setAside: nil)
        case .moved: break
        }
        guard isStillMade(recorded, now: directory.stampEntry()) else {
            return directory.moveBack(to: path) ? .notMade : .setAside(directory.entryPath)
        }
        if let reason = directory.unlinkEntry() {
            return .failed(reason, setAside: directory.moveBack(to: path) ? nil : directory.entryPath)
        }
        return .removed
    }

    // MARK: Putting it on a host

    public enum CopyProblem: Error, Equatable, CustomStringConvertible {
        case address(RemoteAccess.ArgumentProblem)
        /// A key file or key body Flotilla will not pass on.
        case key
        /// `~/.ssh`'s path has a character a shell could act on.
        case unsafePath

        public var description: String {
            switch self {
            case .address(let problem): problem.description
            case .key: "That isn\u{2019}t Flotilla\u{2019}s key, so Flotilla won\u{2019}t pass it to ssh."
            case .unsafePath: SSHKeySetup.unsafePathExplanation
            }
        }
    }

    /// `-i <~/.ssh/flotilla_ed25519.pub> [user@]host`. `ssh-copy-id` has no `-l`, so the user goes
    /// in the destination — safe because neither validator allows an `@`, so the split is
    /// unambiguous, and neither value may start with `-`. Only Flotilla's key is ever copied.
    public static func copyIDArguments(sshDirectory: String, host: String, user: String?) throws(CopyProblem) -> [String] {
        guard isSSHDirectory(sshDirectory) else { throw .unsafePath }
        guard RemoteAccess.isValidHost(host) else { throw .address(.host) }
        let destination: String
        if let user, !user.isEmpty {
            guard RemoteAccess.isValidUser(user) else { throw .address(.user) }
            destination = "\(user)@\(host)"
        } else {
            destination = host
        }
        return ["-i", path(sshDirectory, flotillaPublicKeyName), destination]
    }

    // MARK: Taking it off a host

    /// The awk program the removal script runs, as `/bin/sh` sees it inside `"…"` — hence `\"` and
    /// `\$`. It reads `authorized_keys` as sshd(8) does, **one key record per line**:
    /// `[options] keytype base64 [comment]`, where options may hold quoted spaces and `\"`. A line's
    /// key is the field right after a recognised key type (`kt`): the first field if that is a type,
    /// otherwise the first field after the options. Blank lines and `#` lines have none.
    ///
    /// So a body that only appears in a comment — or in an option such as `command="…"` — is never
    /// that line's key (Kyle, 18 October: the old field-by-field match let an old line whose comment
    /// held the new body pass the "new key is there" check, and deleted a new key's line whose comment
    /// held the old body). With `m=1` it prints how many records have key `k`; with `m=0` it prints
    /// every line except those. The quote and the backslash are made with `sprintf` so the program
    /// needs no backslash of its own beyond `\t`, and it has no `!` — csh expands that even inside
    /// single quotes.
    static let keyRecordProgram = [
        #"function kt(t){return t~/^(ssh-|ecdsa-sha2-|sk-ssh-|sk-ecdsa-)[A-Za-z0-9@.-]+\$/}"#,
        ##"function kb(l,i,c,q,n,f){sub(/^[ \t]+/,\"\",l);if(l==\"\"||substr(l,1,1)==\"#\")return \"\";"##,
        #"n=split(l,f,/[ \t]+/);if(n>=2&&kt(f[1]))return f[2];"#,
        #"q=0;for(i=1;i<=length(l);i++){c=substr(l,i,1);if(q&&c==B){i++;continue}if(c==Q){q=1-q;continue}"#,
        #"if(q==0&&(c==\" \"||c==\"\t\"))break}"#,
        #"l=substr(l,i);sub(/^[ \t]+/,\"\",l);n=split(l,f,/[ \t]+/);if(n>=2&&kt(f[1]))return f[2];return \"\"}"#,
        #"BEGIN{Q=sprintf(\"%c\",34);B=sprintf(\"%c\",92)}"#,
        #"{b=kb(\$0)}m==1{if(b==k)hits++;next}b==k{next}{print}END{if(m==1)print hits+0}"#,
    ].joined()

    /// The script that takes one key's lines out of the remote user's `~/.ssh/authorized_keys`.
    /// Run by `/bin/sh` with the key body to remove as `$1` and, optionally, a body that must still
    /// be there afterwards as `$2`.
    ///
    /// A line goes only if its **key record's** base64 field is the body (`keyRecordProgram`) — an
    /// exact string comparison in awk, never a pattern — so options and comments never match, and
    /// nor does a different key. Before any change: the file must exist (3), not be a symlink and be
    /// a regular file (9), be readable (4), hold the key (5) and, when `$2` is given, hold that key
    /// as a record too (6) — so Regenerate can never remove the old key from a host the new key is
    /// not on.
    ///
    /// **The rewrite never touches the original until it is complete** (Kyle, 18 October: a fixed
    /// `authorized_keys.flotilla-tmp` was followed through a planted symlink into `authorized_keys`
    /// itself and emptied it, and `cat >` truncated the original before writing it). The backup is
    /// copied into a fresh `mktemp` file in `~/.ssh` and renamed over `authorized_keys.flotilla-bak`
    /// — a rename replaces a symlink there rather than following it (7). The new contents go to
    /// another `mktemp` file — unpredictable, created exclusively, never a followed symlink — which
    /// is `chmod 600`ed and then renamed over `authorized_keys` with `mv -f`, one atomic `rename(2)`
    /// in the same directory (8). Interrupted anywhere, `authorized_keys` is either the old file or
    /// the new one, never a part of either; at worst an `authorized_keys.XXXXXX` is left behind.
    ///
    /// **It contains no `'`**, because it is sent single-quoted: whatever the remote login shell
    /// is — zsh, bash, sh, fish or csh — it passes the script to `/bin/sh` untouched. **Nor any `!`**,
    /// which csh and tcsh expand even there. Its `"…"` and `\$` are for `/bin/sh`.
    public static let removalScript = [
        #"f="$HOME/.ssh/authorized_keys""#,
        #"[ -L "$f" ] && exit 9"#,
        #"[ -e "$f" ] || exit 3"#,
        #"[ -f "$f" ] || exit 9"#,
        #"p="\#(keyRecordProgram)""#,
        #"n=$(awk -v m=1 -v k="$1" "$p" "$f") || exit 4"#,
        #"[ "$n" -gt 0 ] || exit 5"#,
        #"if [ -n "$2" ]; then m=$(awk -v m=1 -v k="$2" "$p" "$f") || exit 4; [ "$m" -gt 0 ] || exit 6; fi"#,
        #"umask 077"#,
        #"b="$f.flotilla-bak""#,
        #"[ -d "$b" ] && exit 7"#,
        #"t=$(mktemp "$f.XXXXXX") || exit 7"#,
        #"cp -p "$f" "$t" && mv -f "$t" "$b" || { rm -f "$t"; exit 7; }"#,
        #"t=$(mktemp "$f.XXXXXX") || exit 8"#,
        #"awk -v m=0 -v k="$1" "$p" "$f" > "$t" && chmod 600 "$t" && mv -f "$t" "$f" || { rm -f "$t"; exit 8; }"#,
        #"echo "Removed $n line(s). The file before is in ~/.ssh/authorized_keys.flotilla-bak.""#,
    ].joined(separator: "; ")

    /// `$0` for the script: what `ps` on the host shows it as.
    public static let removalScriptName = "flotilla-remove-key"

    /// The command ssh sends: `/bin/sh -c '<removalScript>' flotilla-remove-key '<remove>' ['<keep>']`.
    /// One fixed string with the bodies in it, and each body passes `isKeyBody` first — so it has no
    /// quote, space, `$`, backtick, `;`, newline or backslash to escape with, and cannot start with
    /// `-` or `=`. The two must differ: removing the key being kept is never what was meant.
    public static func removalCommand(remove: String, keep: String? = nil) throws(CopyProblem) -> String {
        guard isKeyBody(remove) else { throw .key }
        if let keep { guard isKeyBody(keep), keep != remove else { throw .key } }
        return "/bin/sh -c '\(removalScript)' \(removalScriptName) '\(remove)'" + (keep.map { " '\($0)'" } ?? "")
    }

    /// `ssh -F /dev/null -o IdentitiesOnly=yes -i <flotilla key> -o IdentityAgent=none
    /// [-o PreferredAuthentications=publickey] [-l user] host <removalCommand>`: signing in with
    /// Flotilla's key and no other (`Identity.exclusiveArguments`) — no config file, so no
    /// `IdentityFile` from it, and no agent.
    ///
    /// With `keep` (Regenerate), only public-key sign-in is allowed too, so the step that removes
    /// the old key is also the proof the new one works: the only key ssh can offer is the new one
    /// (Kyle, 18 October — with the user's config, an `IdentityFile` there could have signed in
    /// instead, and the proof proved nothing). And the script checks the new key's record is there
    /// before it touches anything. Without `keep` (Remove Key from This Host), ssh may ask for a
    /// password if the key is already gone.
    public static func removalArguments(sshDirectory: String, host: String, user: String?,
                                        remove: String, keep: String? = nil) throws(CopyProblem) -> [String] {
        guard let identity = Identity(sshDirectory: sshDirectory) else { throw .unsafePath }
        let command = try removalCommand(remove: remove, keep: keep)
        let destination: [String]
        do { destination = try RemoteAccess.sshArguments(host: host, user: user) } catch { throw .address(error) }
        let publicKeyOnly = keep == nil ? [] : ["-o", "PreferredAuthentications=publickey"]
        return identity.exclusiveArguments + publicKeyOnly + destination + [command]
    }

    /// How a removal ended, from ssh's exit code — the script's own codes, or ssh's 255.
    public enum RemovalOutcome: Sendable, Equatable {
        case removed
        case noAuthorizedKeys
        case unreadable
        case notThere
        case newKeyMissing
        case backupFailed
        case rewriteFailed
        case notARegularFile
        case couldNotSignIn
        case other(Int32?)

        public init(exitCode: Int32?) {
            self = switch exitCode {
            case 0?: .removed
            case 3?: .noAuthorizedKeys
            case 4?: .unreadable
            case 5?: .notThere
            case 6?: .newKeyMissing
            case 7?: .backupFailed
            case 8?: .rewriteFailed
            case 9?: .notARegularFile
            case 255?: .couldNotSignIn
            default: .other(exitCode)
            }
        }

        /// What it means, for the card; `host` is the name the page shows.
        public func description(host: String) -> String {
            switch self {
            case .removed: "The key is off \(host). Its authorized_keys from before is in ~/.ssh/authorized_keys.flotilla-bak there."
            case .noAuthorizedKeys: "\(host) has no ~/.ssh/authorized_keys for that user, so there was nothing to remove."
            case .unreadable: "Flotilla couldn\u{2019}t read ~/.ssh/authorized_keys on \(host). Nothing was changed."
            case .notThere: "That key wasn\u{2019}t in ~/.ssh/authorized_keys on \(host). Nothing was changed."
            case .newKeyMissing: "The new key isn\u{2019}t in ~/.ssh/authorized_keys on \(host), so Flotilla left the old one there. Nothing was changed."
            case .backupFailed: "Flotilla couldn\u{2019}t save a backup of ~/.ssh/authorized_keys on \(host), so it changed nothing."
            case .rewriteFailed: "Writing the new ~/.ssh/authorized_keys on \(host) failed, so the file there is as it was. A copy is in ~/.ssh/authorized_keys.flotilla-bak."
            case .notARegularFile: "~/.ssh/authorized_keys on \(host) is a symbolic link or not an ordinary file, so Flotilla won\u{2019}t rewrite it. Nothing was changed."
            case .couldNotSignIn: "ssh couldn\u{2019}t connect to \(host) or sign in with Flotilla\u{2019}s key. Nothing was changed."
            case .other(let code): "Removing the key from \(host) ended with status \(code.map(String.init) ?? "unknown")."
            }
        }

        public var succeeded: Bool { self == .removed }

        /// Whether the script ran at all — any of its own codes — which, signed in with
        /// `exclusiveArguments`, means Flotilla's key got in. Not ssh's 255, nor anything unknown.
        public var signedIn: Bool {
            switch self {
            case .couldNotSignIn, .other: false
            default: true
            }
        }
    }

    /// Why no command is offered, for the card.
    public static let unsafePathExplanation =
        "Your home folder\u{2019}s path has a space or a symbol in it, and ssh-copy-id would read that as a command, "
        + "so Flotilla won\u{2019}t run it or ssh-keygen here. Do it by hand in Terminal, below."

    static func path(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// Which hosts Flotilla put its key on, and as whom — so the page can say "signed in with
/// Flotilla's key", and so Regenerate can list the hosts that still have the old one. Only what
/// Flotilla saw: an `ssh-copy-id` it ran that ended with 0. A host is its fingerprint's hex, never
/// an address, which can change under it.
///
/// It belongs to one key, named by the **SHA-256 of its public body**, as 64 lowercase hex digits —
/// never the body itself (Kyle, 18 October): the list is non-secret metadata, but a body is a value
/// a host's `authorized_keys` can be searched for, and a digest is enough to tell keys apart.
/// FlotillaCore is Foundation-only, so the app computes the digest. Recording a copy of a different
/// key starts the list again, so a key the user replaced by hand does not inherit the old key's
/// hosts. Kept plist-native by the app.
public struct SSHKeyHosts: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public var host: String
        public var user: String?
        public init(host: String, user: String?) {
            self.host = host
            self.user = (user?.isEmpty ?? true) ? nil : user
        }
    }

    /// The digest of the public key body the entries are for.
    public private(set) var keyDigest: String?
    public private(set) var entries: [Entry]

    public init(keyDigest: String? = nil, entries: [Entry] = []) {
        self.keyDigest = keyDigest
        self.entries = entries
    }

    /// 64 lowercase hex digits: what a SHA-256 written as hex is, and nothing else.
    public static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The hosts that have the key with `keyDigest`, as far as Flotilla knows.
    public func hosts(for keyDigest: String?) -> [Entry] {
        guard let keyDigest, keyDigest == self.keyDigest else { return [] }
        return entries
    }

    public func has(_ entry: Entry, keyDigest: String?) -> Bool { hosts(for: keyDigest).contains(entry) }

    public mutating func record(_ entry: Entry, keyDigest: String) {
        guard Self.isDigest(keyDigest) else { return }
        if keyDigest != self.keyDigest { self.keyDigest = keyDigest; entries = [] }
        if !entries.contains(entry) { entries.append(entry) }
    }

    public mutating func forget(_ entry: Entry, keyDigest: String?) {
        guard keyDigest == self.keyDigest else { return }
        entries.removeAll { $0 == entry }
    }

    // MARK: Plist

    /// `["keySHA256": hex, "hosts": [["host": hex, "user": name], …]]`.
    public var plist: [String: Any] {
        var value: [String: Any] = ["hosts": entries.map { entry -> [String: String] in
            var item = ["host": entry.host]
            if let user = entry.user { item["user"] = user }
            return item
        }]
        if let keyDigest { value["keySHA256"] = keyDigest }
        return value
    }

    /// Anything malformed reads as nothing: the list only ever offers a copy. So does a list from
    /// before the digest, which kept the body under `key`.
    public init(plist: Any?) {
        guard let value = plist as? [String: Any], let digest = value["keySHA256"] as? String, Self.isDigest(digest),
              let hosts = value["hosts"] as? [[String: String]] else { self.init(); return }
        self.init(keyDigest: digest, entries: hosts.compactMap { item in
            guard let host = item["host"], !host.isEmpty else { return nil }
            return Entry(host: host, user: item["user"])
        })
    }
}
