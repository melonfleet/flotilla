import SwiftUI
import AppKit
import Darwin
import CryptoKit
import FlotillaCore

/// Flotilla's SSH key, the user's own, and which hosts Flotilla has put its key on — what the SSH
/// tab's key card says (Kamal, 18 October).
///
/// What is read is whether key files exist, by name; the key types `ssh-add -L` prints; and the
/// public half of Flotilla's own key, `~/.ssh/flotilla_ed25519.pub`, for the body that finds its
/// line in a host's `authorized_keys` (`SSHKeySetup`). No private key is ever opened. "On this host"
/// is only what Flotilla saw: an `ssh-copy-id` it ran that ended with 0, for that host and user,
/// with this key. Any other way of knowing would mean signing in to find out, which the page does not
/// do behind the user's back.
///
/// The hosts are kept plist-native under `sshKeyHosts` in Flotilla's own domain so Regenerate can
/// list the hosts that had the old key after a relaunch: host fingerprints, user names and the
/// SHA-256 of the public key's body. Non-secret metadata, none of it a credential (Q20) — but it
/// does say which account is on which host, so the body itself is not kept, only its digest (Kyle,
/// 18 October). The body is held in memory only, in `status`, for finding the key's line on a host.
@MainActor
@Observable
final class SSHKeyState {
    private(set) var status: SSHKeySetup.Status?
    private(set) var hosts: SSHKeyHosts
    /// After a Regenerate: the other hosts that had the old key and do not have the new one yet.
    private(set) var oldKeyHosts: [SSHKeyHosts.Entry] = []
    /// The one key operation running anywhere in the app, if any (`SSHKeySetup.OperationGate`). In
    /// memory only, so quitting releases it with everything else.
    private(set) var gate = SSHKeySetup.OperationGate()

    @ObservationIgnored private let defaults: UserDefaults?
    static let hostsKey = "sshKeyHosts"

    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        let stored = defaults?.object(forKey: Self.hostsKey)
        hosts = SSHKeyHosts(plist: stored)
        // Before the digest the body itself was kept under `key`: rewrite it as its digest, on disk.
        if let old = stored as? [String: Any], let body = old["key"] as? String, let digest = Self.digest(body),
           let entries = old["hosts"] as? [[String: String]] {
            hosts = SSHKeyHosts(keyDigest: digest, entries: entries.compactMap { item in
                item["host"].flatMap { $0.isEmpty ? nil : SSHKeyHosts.Entry(host: $0, user: item["user"]) }
            })
            persist()
        }
    }

    /// The SHA-256 of a public key's body, as `SSHKeyHosts` keys it. Nil for anything not a body.
    nonisolated static func digest(_ body: String?) -> String? {
        guard let body, SSHKeySetup.isKeyBody(body) else { return nil }
        return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `~/.ssh` of the user Flotilla runs as.
    nonisolated static var sshDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path
    }

    func refresh() async {
        status = await Blocking.run { Self.read() }
    }

    // MARK: Hosts with the key

    func isCopied(host: String, user: String?) -> Bool {
        hosts.has(.init(host: host, user: user), keyDigest: Self.digest(status?.flotillaKeyBody))
    }

    /// After an `ssh-copy-id` that ended with 0: the key whose body is on disk now is on that host.
    func recordCopied(host: String, user: String?) {
        guard let digest = Self.digest(Self.files().flotillaKeyBody) else { return }
        let entry = SSHKeyHosts.Entry(host: host, user: user)
        hosts.record(entry, keyDigest: digest)
        oldKeyHosts.removeAll { $0 == entry }
        persist()
    }

    func forget(host: String, user: String?, keyBody: String) {
        hosts.forget(.init(host: host, user: user), keyDigest: Self.digest(keyBody))
        persist()
    }

    /// The hosts that have `keyBody` as far as Flotilla knows, except `excluding`.
    func hosts(with keyBody: String?, excluding: SSHKeyHosts.Entry) -> [SSHKeyHosts.Entry] {
        hosts.hosts(for: Self.digest(keyBody)).filter { $0 != excluding }
    }

    func setOldKeyHosts(_ entries: [SSHKeyHosts.Entry]) { oldKeyHosts = entries }
    func dismissOldKeyHosts() { oldKeyHosts = [] }

    private func persist() { defaults?.set(hosts.plist, forKey: Self.hostsKey) }

    // MARK: One operation at a time

    /// A token for a key step on `host`, or nil while any key step — this host's or another's — runs.
    func begin(host: String, hostName: String) -> UUID? { gate.begin(host: host, hostName: hostName) }

    /// Released by its own token only: on finish, failure, cancel or the step's session being closed.
    func end(_ token: UUID) { gate.end(token) }

    /// The host another key step is running for, for every other card to say so.
    func running(otherThan host: String) -> String? { gate.running(otherThan: host)?.hostName }

    // MARK: Reading

    /// The files alone, without asking the agent: a few `stat`s and one small read, quick enough
    /// to check again at the moment a button is clicked rather than trusting a status read before.
    nonisolated static func files() -> SSHKeySetup.Status {
        SSHKeySetup.status(sshDirectory: sshDirectory, agent: .unavailable,
                           fileExists: { FileManager.default.fileExists(atPath: $0) },
                           readPublicKey: readPublicKey)
    }

    /// Flotilla's `.pub`, at most 16 KB, and only if it is a regular file — never a private key,
    /// which `SSHKeySetup.status` never asks for.
    nonisolated private static func readPublicKey(_ path: String) -> String? {
        guard path.hasSuffix("/" + SSHKeySetup.flotillaPublicKeyName),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Blocking: runs `ssh-add -L` (bounded at five seconds) and checks thirteen file names.
    nonisolated private static func read() -> SSHKeySetup.Status {
        var status = files()
        status.agent = agent()
        return status
    }

    nonisolated private static func agent() -> SSHKeySetup.Agent {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHKeySetup.agentExecutable)
        process.arguments = SSHKeySetup.agentArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        // A wedged agent socket must not hold the read forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { return .unavailable }
        return SSHKeySetup.parseAgent(output: String(decoding: data.prefix(256_000), as: UTF8.self),
                                      exitCode: process.terminationStatus)
    }

    // MARK: Renaming

    /// A rename that failed, and where that left things.
    struct MoveFailure: Error {
        let reason: String
        /// Files a rename moved whose undo failed too: where each one is now. Empty when everything
        /// is back where it was.
        let stranded: [String]

        /// "Your previous key is at …" when something could not be put back — never silent.
        var whereThingsAre: String {
            stranded.isEmpty ? "" : " Your previous key is at \(stranded.map(homeAbbreviated).joined(separator: " and "))."
        }
    }

    /// Renames each pair in order, never over an existing file (`RENAME_EXCL`, one system call, so
    /// nothing can appear at the destination between a check and the rename). If one fails, those
    /// already done are put back, and any that cannot be are reported as `stranded` (Kyle, 18
    /// October: a failed undo used to be dropped). Nothing is ever deleted.
    nonisolated static func move(_ moves: [(from: String, to: String)]) -> MoveFailure? {
        var done: [(from: String, to: String)] = []
        for move in moves {
            if renamex_np(move.from, move.to, UInt32(RENAME_EXCL)) != 0 {
                let reason = String(cString: strerror(errno))
                let stranded = done.reversed().compactMap { undo in
                    renamex_np(undo.to, undo.from, UInt32(RENAME_EXCL)) == 0 ? nil : undo.to
                }
                return MoveFailure(reason: reason, stranded: stranded)
            }
            done.append(move)
        }
        return nil
    }

    /// `lstat` of one path, for Regenerate's rollback: nil if nothing is there. A symlink is
    /// reported as itself, never followed.
    nonisolated static func stamp(_ path: String) -> SSHKeySetup.FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SSHKeySetup.FileStamp(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                                     isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
                                     ownedByUser: info.st_uid == getuid())
    }

    /// Removes exactly the file `recorded` names (Kyle, 18 October), never whatever is at `path`
    /// now — `SSHKeySetup.removeMade`, in a directory this call makes for itself. Nil from
    /// `PrivateDirectory` means no such directory could be made, and nothing was touched.
    nonisolated static func remove(_ path: String, ifStill recorded: SSHKeySetup.FileStamp) -> SSHKeySetup.RollbackRemoval {
        guard let directory = PrivateDirectory(beside: path) else {
            return .failed("Flotilla couldn\u{2019}t make a private folder in ~/.ssh", setAside: nil)
        }
        defer { directory.close() }
        return SSHKeySetup.removeMade(path, ifStill: recorded, in: directory)
    }

    /// `mkdtemp` beside the key, mode 0700 and the user's, held open by descriptor: every step inside
    /// it — the rename in, the `lstat`, the unlink, the rename back — is relative to that descriptor
    /// (`renameatx_np`, `fstatat`, `unlinkat`), so it is the directory Flotilla made even if its name
    /// in `~/.ssh` is swapped, and only the user can change what is inside it.
    final class PrivateDirectory: SSHKeySetup.RollbackDirectory {
        private static let entry = "file"
        let path: String
        private let fd: Int32
        private let identity: SSHKeySetup.FileStamp

        var entryPath: String { path + "/" + Self.entry }

        init?(beside keyPath: String) {
            let parent = (keyPath as NSString).deletingLastPathComponent
            var template = Array((parent + "/.flotilla-rollback-XXXXXX").utf8CString)
            guard mkdtemp(&template) != nil else { return nil }
            let path = String(cString: template)
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat()
            // Whatever the descriptor reached must be a directory of the user's that only the user
            // can write to — the one mkdtemp made, not one swapped in at its name.
            guard fd >= 0, fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_mode & 0o077 == 0 else {
                if fd >= 0 { Darwin.close(fd) }
                return nil
            }
            self.path = path
            self.fd = fd
            identity = Self.stamp(info)
        }

        func moveIn(_ source: String) -> SSHKeySetup.RollbackMove {
            if renameatx_np(AT_FDCWD, source, fd, Self.entry, UInt32(RENAME_EXCL)) == 0 { return .moved }
            return errno == ENOENT ? .missing : .failed(String(cString: strerror(errno)))
        }

        func stampEntry() -> SSHKeySetup.FileStamp? {
            var info = stat()
            guard fstatat(fd, Self.entry, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return Self.stamp(info)
        }

        func unlinkEntry() -> String? {
            unlinkat(fd, Self.entry, 0) == 0 ? nil : String(cString: strerror(errno))
        }

        func moveBack(to destination: String) -> Bool {
            renameatx_np(fd, Self.entry, AT_FDCWD, destination, UInt32(RENAME_EXCL)) == 0
        }

        /// Removes the directory if it is empty — an entry that could not go back keeps it — and only
        /// while its name still reaches the directory Flotilla made. `rmdir` removes nothing but an
        /// empty directory, so a swap between the check and it can cost nothing but that.
        func close() {
            var info = stat()
            if lstat(path, &info) == 0, Self.stamp(info).isSameFile(as: identity) { rmdir(path) }
            Darwin.close(fd)
        }

        private static func stamp(_ info: stat) -> SSHKeySetup.FileStamp {
            SSHKeySetup.FileStamp(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
                                  isRegularFile: (info.st_mode & S_IFMT) == S_IFREG, ownedByUser: info.st_uid == getuid())
        }
    }
}

/// `~/…` for a path in the home folder, for showing a command — never for running one.
func homeAbbreviated(_ text: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return text.replacingOccurrences(of: home.hasSuffix("/") ? home : home + "/", with: "~/")
}

/// What the SSH tab's key card can do — each one a method on `HostSSHTab`, which runs it in the tab's
/// terminal.
struct SSHKeyActions {
    let makeKey: () -> Void
    let copyKey: () -> Void
    let tryIt: () -> Void
    /// The name Regenerate would rename the current key to, now.
    let archiveName: () -> String?
    let regenerate: (_ removeOldFromHost: Bool) -> Void
    let removeFromHost: () -> Void
    let copyToOtherHost: (SSHKeyHosts.Entry) -> Void
    /// A host's name as the page shows it.
    let hostName: (SSHKeyHosts.Entry) -> String
}

/// The SSH tab's key card: whether a session will ask for a password, Flotilla's key and the user's
/// own reported apart, and — behind "Set Up SSH Key…" — the three visible steps that make Flotilla's
/// key, put it on the host, and try it; then Regenerate and Remove from this host, each behind a
/// confirmation that says exactly what will run.
///
/// Each step is a button with a sentence saying what it will run, and runs it in the SSH tab's own
/// terminal, where the user answers its prompts. Flotilla never stores or logs a password or a
/// passphrase and never reads a private key (Q20): ssh-keygen asks for the passphrase and
/// ssh-copy-id for the host's password in the PTY, and the keystrokes pass through Flotilla's
/// terminal view on the way — which is what the card says, rather than "never sees" (Kyle, 18
/// October).
struct SSHKeyCard: View {
    let keys: SSHKeyState
    let hostName: String
    /// This host's fingerprint, as `SSHKeyHosts` keys it.
    let hostKey: String
    /// The validated address and user, when there is an argv at all.
    let host: String?
    let user: String?
    /// The host another key step is running for: every key button here waits for it.
    let busyElsewhere: String?
    let outcome: SessionOutcome?
    let actions: SSHKeyActions

    private enum Confirming { case regenerate(archive: String), remove }

    @State private var settingUp = false
    @State private var confirming: Confirming?
    @State private var removeOldFromHost = true

    private var status: SSHKeySetup.Status? { keys.status }
    private var copied: Bool { host != nil && keys.isCopied(host: hostKey, user: user) }
    private var who: String { user.map { "\($0)\u{2019}s" } ?? "your" }
    private var destination: String {
        guard let host else { return "<host>" }
        return user.map { "\($0)@\(host)" } ?? host
    }
    private var thisHost: SSHKeyHosts.Entry { .init(host: hostKey, user: user) }

    var body: some View {
        DetailCard(title: "Sign in with an SSH key", minHeight: nil) {
            summary
            if let busyElsewhere {
                Label("Key setup is running for \(busyElsewhere).", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityHint("Flotilla runs one key step at a time; these buttons come back when it ends")
            }
            if let outcome { SessionOutcomeNote(outcome: outcome) }
            if !keys.oldKeyHosts.isEmpty { oldKeyHostsPanel }
            // Kept open across a step: the step's terminal replaced this card while it ran.
            if settingUp || copied || outcome != nil {
                steps
            } else if status != nil {
                Button("Set Up SSH Key\u{2026}") { settingUp = true }
                    .accessibilityHint("Shows the steps; nothing runs until you click one")
            }
            if let status, status.canRegenerate || status.canRemoveFromHost {
                Divider().padding(.vertical, 2)
                manage(status)
            }
            Divider().padding(.vertical, 2)
            byHand
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summary: some View {
        if let status {
            VStack(alignment: .leading, spacing: 6) {
                if copied {
                    Label("Signed in with Flotilla\u{2019}s key: Flotilla put it on \(hostName).", systemImage: "key.fill")
                        .font(.callout)
                } else if status.hasFlotillaKey {
                    Label("Flotilla has its own key, ~/.ssh/\(SSHKeySetup.flotillaKeyName). Until \(hostName) has it, ssh tries your own keys and then asks for \(who) password.",
                          systemImage: "key").font(.callout).lineLimit(4)
                } else {
                    Label("Flotilla doesn\u{2019}t have a key of its own yet, so ssh tries your own keys and then asks for \(who) password. A key for Flotilla lets you go straight in.",
                          systemImage: "key.slash").font(.callout).lineLimit(4)
                }
                Text(ownKeysLine(status)).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        } else {
            Label("Looking for SSH keys\u{2026}", systemImage: "key").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The user's own keys, said apart from Flotilla's, and that they are left alone.
    private func ownKeysLine(_ status: SSHKeySetup.Status) -> String {
        var found = status.publicKeys.map { "~/.ssh/\($0)" }
        for name in status.privateKeys where !status.publicKeys.contains(name + ".pub") { found.append("~/.ssh/\(name)") }
        let agent = status.agentKeyCount
        if agent > 0 { found.append(agent == 1 ? "one key in the SSH agent" : "\(agent) keys in the SSH agent") }
        guard !found.isEmpty else { return "You have no SSH keys of your own in ~/.ssh or the agent." }
        let list = found.count == 1 ? found[0] : found.dropLast().joined(separator: ", ") + " and " + found.last!
        let use = status.hasFlotillaKey ? "Flotilla\u{2019}s sessions don\u{2019}t offer them" : "ssh offers them until Flotilla has its own"
        return "Your own keys: \(list). \(use), and Flotilla never changes or copies them."
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Make Flotilla\u{2019}s key") {
                if status?.pathIsSafe == false {
                    Label(SSHKeySetup.unsafePathExplanation, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning).lineLimit(4)
                } else if status?.hasFlotillaKey == true {
                    Label("It has one: ~/.ssh/\(SSHKeySetup.flotillaKeyName)", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.online)
                } else if status?.canRegenerate == true {
                    // Half a pair: never made over, only renamed (Kyle, 18 October).
                    Text("Only half of Flotilla\u{2019}s key is in ~/.ssh — \(status?.flotillaPrivateKey == true ? SSHKeySetup.flotillaKeyName : SSHKeySetup.flotillaPublicKeyName) without its pair. Regenerate Key, below, sets it aside and makes a new one.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                } else if status?.canMakeKey == true {
                    makeKeyButton
                }
            }
            step(2, "Put it on \(hostName)") {
                if status?.pathIsSafe == false {
                    Text("Not from Flotilla, for the reason above.").font(.caption).foregroundStyle(.secondary)
                } else if status?.keyToCopy != nil, host != nil {
                    Text("Runs ssh-copy-id in this tab. ssh asks for \(who) password on \(hostName) once, and adds Flotilla\u{2019}s public key to that account\u{2019}s ~/.ssh/authorized_keys. The private key stays on this Mac. Your passphrase and password go to ssh through this terminal; Flotilla doesn\u{2019}t store or log them.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(5)
                    SessionCommandLine(text: copyCommand(destination))
                    Button("Copy Key to \(hostName)", action: actions.copyKey)
                        .disabled(busyElsewhere != nil)
                } else {
                    Text("Once Flotilla has a key.").font(.caption).foregroundStyle(.secondary)
                }
            }
            step(3, "Try it") {
                Text("Starts an SSH session with Flotilla\u{2019}s key. It should go straight in; if the key has a passphrase, ssh asks for that instead.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if copied {
                    Button("Try It", action: actions.tryIt).buttonStyle(.borderedProminent)
                } else {
                    Button("Try It", action: actions.tryIt)
                }
            }
        }
    }

    private var makeKeyButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs ssh-keygen in this tab and saves a key for Flotilla\u{2019}s hosts as ~/.ssh/\(SSHKeySetup.flotillaKeyName). Your own keys aren\u{2019}t touched. It asks for a passphrase, which protects the key on this Mac. Your passphrase goes to ssh-keygen through this terminal; Flotilla doesn\u{2019}t store or log it.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(5)
            SessionCommandLine(text: keygenCommand)
            Button("Make a Key", action: actions.makeKey)
                .disabled(busyElsewhere != nil)
        }
    }

    private var keygenCommand: String {
        (["ssh-keygen"] + SSHKeySetup.keygenOptions + ["-f", "~/.ssh/" + SSHKeySetup.flotillaKeyName]).joined(separator: " ")
    }

    private func copyCommand(_ destination: String) -> String {
        "ssh-copy-id -i ~/.ssh/\(SSHKeySetup.flotillaPublicKeyName) \(destination)"
    }

    // MARK: Regenerate and Remove

    @ViewBuilder
    private func manage(_ status: SSHKeySetup.Status) -> some View {
        switch confirming {
        case .regenerate(let archive)?:
            regenerateConfirmation(status, archive: archive)
        case .remove?:
            removeConfirmation
        case nil:
            HStack(spacing: 8) {
                if status.canRegenerate {
                    Button("Regenerate Key\u{2026}") {
                        if let archive = actions.archiveName() { confirming = .regenerate(archive: archive) }
                    }
                    .disabled(host == nil || busyElsewhere != nil)
                    .accessibilityHint("Shows what will happen; nothing runs until you confirm")
                }
                if status.canRemoveFromHost {
                    Button("Remove Key from \(hostName)\u{2026}") { confirming = .remove }
                        .disabled(host == nil || busyElsewhere != nil)
                        .accessibilityHint("Shows what will happen; nothing runs until you confirm")
                }
            }
        }
    }

    private func regenerateConfirmation(_ status: SSHKeySetup.Status, archive: String) -> some View {
        let others = keys.hosts(with: status.flotillaKeyBody, excluding: thisHost)
        let canRemoveOld = status.flotillaKeyBody != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Regenerate Flotilla\u{2019}s key?").font(.callout.weight(.semibold))
            step(1, "Set the current key aside") {
                Text("Renames ~/.ssh/\(SSHKeySetup.flotillaKeyName) and its .pub to ~/.ssh/\(archive). Nothing is deleted.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            step(2, "Make a new key") {
                Text("Runs ssh-keygen in this tab. It asks for a passphrase for the new key.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                SessionCommandLine(text: keygenCommand)
            }
            step(3, "Put it on \(hostName)") {
                Text("Runs ssh-copy-id in this tab. ssh may ask for \(who) password on \(hostName) once.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                SessionCommandLine(text: copyCommand(destination))
            }
            step(4, "Take the old key off \(hostName)") {
                Toggle("Remove the old key from \(hostName)\u{2019}s authorized_keys", isOn: $removeOldFromHost)
                    .disabled(!canRemoveOld)
                Text(canRemoveOld
                     ? "Signs in to \(hostName) with the new key and deletes only the lines holding the old one from ~/.ssh/authorized_keys, after saving the file as ~/.ssh/authorized_keys.flotilla-bak there. It changes nothing unless the new key is already in the file. If this fails, the new key still works."
                     : "Flotilla can\u{2019}t read the old public key, so it can\u{2019}t find its line on \(hostName). Remove it there by hand if you want it gone.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(5)
            }
            if !others.isEmpty {
                Label("\(names(others)) also \(others.count == 1 ? "has" : "have") the old key, and will ask for a password until \(others.count == 1 ? "it has" : "they have") the new one. Flotilla offers to copy it afterwards.",
                      systemImage: "info.circle").font(.caption).lineLimit(4)
            }
            Text("Your own keys aren\u{2019}t touched.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { confirming = nil }
                Button("Regenerate Key") {
                    confirming = nil
                    actions.regenerate(removeOldFromHost && canRemoveOld)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busyElsewhere != nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var removeConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove Flotilla\u{2019}s key from \(hostName)?").font(.callout.weight(.semibold))
            Text("Signs in to \(hostName) with ssh and deletes only the lines holding Flotilla\u{2019}s key from \(who) ~/.ssh/authorized_keys there, after saving the file as ~/.ssh/authorized_keys.flotilla-bak. The key on this Mac stays, and so do other hosts\u{2019} copies. After this, ssh on \(hostName) tries your own keys and then asks for a password.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(6)
            HStack {
                Button("Cancel") { confirming = nil }
                Button("Remove Key", role: .destructive) {
                    confirming = nil
                    actions.removeFromHost()
                }
                .disabled(busyElsewhere != nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    /// After a Regenerate: the other hosts that had the old key, each with its own button.
    private var oldKeyHostsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(keys.oldKeyHosts.count == 1 ? "This host" : "These hosts") had the old key, and will ask for a password until \(keys.oldKeyHosts.count == 1 ? "it has" : "they have") the new one. Each copy runs ssh-copy-id in this tab.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
            ForEach(keys.oldKeyHosts, id: \.self) { entry in
                Button("Copy to \(actions.hostName(entry)) too") { actions.copyToOtherHost(entry) }
                    .disabled(busyElsewhere != nil)
            }
            Button("Not Now") { keys.dismissOldKeyHosts() }.buttonStyle(.link)
        }
    }

    private func names(_ entries: [SSHKeyHosts.Entry]) -> String {
        let all = entries.map(actions.hostName)
        return all.count == 1 ? all[0] : all.dropLast().joined(separator: ", ") + " and " + all.last!
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                content()
            }
        }
    }

    /// The same, by hand, and where it is documented. OpenSSH's own manual pages: Apple has no
    /// current guide to SSH keys (its one is for the retired Server app), and the man pages are the
    /// tools' own documentation. `ssh-copy-id` is not part of OpenBSD's OpenSSH, so it has no page
    /// there; `man ssh-copy-id` is on every Mac.
    private var byHand: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("By hand, in Terminal").font(.callout.weight(.semibold))
            Text("Run \(keygenCommand) to make Flotilla\u{2019}s key, then \(copyCommand(destination)) to put it on \(hostName) — see man ssh-copy-id. Flotilla\u{2019}s sessions use that key whenever it exists.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            ForEach(Self.guides, id: \.1) { title, url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(title, systemImage: "arrow.up.forward.square").foregroundStyle(Theme.link)
                }
                .buttonStyle(.link)
                .help(url.absoluteString)
                .accessibilityHint("Opens in your browser")
            }
        }
    }

    private static let guides: [(String, URL)] = [
        ("ssh-keygen(1) — making a key", ExternalLinks.opensshKeygen),
        ("ssh(1) — how keys sign you in", ExternalLinks.opensshAuthentication),
    ]
}
