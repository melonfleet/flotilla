import Foundation
import Testing
@testable import FlotillaCore

/// Two real ed25519 public key bodies, made for these tests; their private halves were discarded.
private let oldBody = "AAAAC3NzaC1lZDI1NTE5AAAAIIRdAci2Rs5qVqTVz9DgA9yEda4S+buRQVi/WGGjZ+kc"
private let newBody = "AAAAC3NzaC1lZDI1NTE5AAAAIAxq7UK4RR60WGmBFMvQqlCbyv6wXhaTje1VjeBpTqmo"
private let ssh = "/home/u/.ssh"

@Suite struct SSHKeySetupTests {
    @Test func agentKeysAreTheirTypesOnly() {
        let output = """
        ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKey someone@example-mac
        ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYExample
        sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExample yubikey
        ssh-rsa-cert-v01@openssh.com AAAAHHNzaC1yc2EtY2VydC12MDFAb3BlbnNzaC5jb20Example
        """
        #expect(SSHKeySetup.parseAgent(output: output, exitCode: 0)
                == .keys(["ssh-ed25519", "ecdsa-sha2-nistp256", "sk-ssh-ed25519@openssh.com", "ssh-rsa-cert-v01@openssh.com"]))
    }

    @Test func agentWithNoKeysOrNoAgent() {
        #expect(SSHKeySetup.parseAgent(output: "The agent has no identities.\n", exitCode: 1) == .empty)
        #expect(SSHKeySetup.parseAgent(output: "Could not open a connection to your authentication agent.\n", exitCode: 2)
                == .unavailable)
        #expect(SSHKeySetup.parseAgent(output: "", exitCode: -1) == .unavailable)
        // Exit 0 with a message and no key line is not a key.
        #expect(SSHKeySetup.parseAgent(output: "The agent has no identities.", exitCode: 0) == .empty)
        #expect(SSHKeySetup.parseAgent(output: "\n\n", exitCode: 0) == .empty)
    }

    // MARK: Detection: the user's keys and Flotilla's, apart

    @Test func ownKeysAndFlotillasAreReportedApart() {
        let present: Set = ["\(ssh)/id_rsa.pub", "\(ssh)/id_ed25519.pub", "\(ssh)/id_ed25519", "\(ssh)/id_dsa.pub"]
        let own = SSHKeySetup.status(sshDirectory: ssh, agent: .keys(["ssh-ed25519"])) { present.contains($0) }
        #expect(own.publicKeys == ["id_ed25519.pub", "id_rsa.pub"])
        #expect(own.privateKeys == ["id_ed25519"])
        #expect(own.hasOwnKey)
        #expect(own.agentKeyCount == 1)
        #expect(!own.flotillaPrivateKey && !own.flotillaPublicKey && !own.hasFlotillaKey)
        // The user's own key is never the one copied, and never stops Flotilla making its own.
        #expect(own.keyToCopy == nil)
        #expect(own.canMakeKey)
        #expect(!own.canRegenerate && !own.canRemoveFromHost)

        let both = present.union(["\(ssh)/flotilla_ed25519", "\(ssh)/flotilla_ed25519.pub"])
        var read: [String] = []
        let flotilla = SSHKeySetup.status(sshDirectory: ssh, agent: .empty, fileExists: { both.contains($0) }) {
            read.append($0)
            return "ssh-ed25519 \(newBody) flotilla\n"
        }
        #expect(flotilla.publicKeys == ["id_ed25519.pub", "id_rsa.pub"], "own keys still reported")
        #expect(flotilla.hasFlotillaKey)
        #expect(flotilla.flotillaKeyBody == newBody)
        #expect(flotilla.keyToCopy == "flotilla_ed25519.pub")
        #expect(!flotilla.canMakeKey)
        #expect(flotilla.canRegenerate && flotilla.canRemoveFromHost)
        #expect(read == ["\(ssh)/flotilla_ed25519.pub"], "only Flotilla's public half is ever read")
    }

    @Test func noFilesAndNoAgentIsNoKey() {
        let none = SSHKeySetup.status(sshDirectory: ssh, agent: .empty) { _ in false }
        #expect(!none.hasOwnKey && !none.hasFlotillaKey)
        #expect(none.keyToCopy == nil)
        #expect(none.canMakeKey)
        let agentOnly = SSHKeySetup.status(sshDirectory: ssh, agent: .keys(["ssh-ed25519"])) { _ in false }
        #expect(agentOnly.hasOwnKey)
        #expect(agentOnly.keyToCopy == nil)
    }

    /// Either half of Flotilla's key means no Make a Key (ssh-keygen would overwrite on a `y`);
    /// Regenerate is how a half-pair is replaced, because it renames first.
    @Test func eitherHalfOfFlotillasKeyMeansNoMakeAKey() {
        for name in ["flotilla_ed25519", "flotilla_ed25519.pub"] {
            let status = SSHKeySetup.status(sshDirectory: ssh, agent: .empty) { $0 == "\(ssh)/\(name)" }
            #expect(!status.canMakeKey, "\(name)")
            #expect(status.canRegenerate, "\(name)")
            #expect(!status.canRemoveFromHost, "\(name): no line to find without both halves")
        }
    }

    /// The private-key header is split so check-hygiene's leaked-key scan doesn't take a test input
    /// for a real key; the string the test feeds in is the same.
    @Test func aPublicKeyFileThatIsNotAKeyHasNoBody() {
        let files = ["\(ssh)/flotilla_ed25519", "\(ssh)/flotilla_ed25519.pub"]
        for contents in ["", "garbage", "ssh-ed25519", "ssh-ed25519 $(id) x", "ssh-ed25519 \(newBody)'; rm -rf ~ '",
                         "not-a-type \(newBody)", "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n\(newBody)"] {
            let status = SSHKeySetup.status(sshDirectory: ssh, agent: .empty, fileExists: { files.contains($0) }) { _ in contents }
            #expect(status.flotillaKeyBody == nil, "\(contents.debugDescription)")
            #expect(!status.canRemoveFromHost)
        }
        #expect(SSHKeySetup.publicKeyBody(fromFile: "ssh-ed25519\t\(oldBody)\n") == oldBody)
    }

    // MARK: Naming

    @Test func makeAKeyWritesFlotillasFileAndNeverAPassphrase() throws {
        let argv = try SSHKeySetup.keygenArguments(sshDirectory: ssh)
        #expect(argv == ["-t", "ed25519", "-C", "flotilla", "-f", "/home/u/.ssh/flotilla_ed25519"])
        #expect(!argv.contains { ["-N", "-P", "-y", "-q"].contains($0) })
        #expect(!argv.contains { $0.hasSuffix("/id_ed25519") })
        #expect(SSHKeySetup.agentArguments == ["-L"])
    }

    @Test func theArchiveIsDatedAndNeverReusesAName() {
        let date = Date(timeIntervalSince1970: 1_792_281_600)   // 2026-10-18T00:00:00Z
        let utc = TimeZone(identifier: "UTC")!
        #expect(SSHKeySetup.archiveName(sshDirectory: ssh, date: date, timeZone: utc) { _ in false }
                == "flotilla_ed25519.old-2026-10-18")
        // The calendar day where the user is, not in UTC.
        #expect(SSHKeySetup.archiveName(sshDirectory: ssh, date: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) { _ in false }
                == "flotilla_ed25519.old-2026-10-17")
        // Either half taken moves to the next number.
        let taken: Set = ["\(ssh)/flotilla_ed25519.old-2026-10-18", "\(ssh)/flotilla_ed25519.old-2026-10-18-2.pub"]
        #expect(SSHKeySetup.archiveName(sshDirectory: ssh, date: date, timeZone: utc) { taken.contains($0) }
                == "flotilla_ed25519.old-2026-10-18-3")
        #expect(SSHKeySetup.archiveName(sshDirectory: ssh, date: date, timeZone: utc) { _ in true } == nil)
    }

    @Test func archivingRenamesOnlyFlotillasFilesThatExist() throws {
        let present: Set = ["\(ssh)/flotilla_ed25519", "\(ssh)/flotilla_ed25519.pub", "\(ssh)/id_ed25519"]
        let moves = try SSHKeySetup.archiveMoves(sshDirectory: ssh, archive: "flotilla_ed25519.old-2026-10-18") { present.contains($0) }
        #expect(moves.map(\.from) == ["\(ssh)/flotilla_ed25519", "\(ssh)/flotilla_ed25519.pub"])
        #expect(moves.map(\.to) == ["\(ssh)/flotilla_ed25519.old-2026-10-18", "\(ssh)/flotilla_ed25519.old-2026-10-18.pub"])
        let half = try SSHKeySetup.archiveMoves(sshDirectory: ssh, archive: "flotilla_ed25519.old-2026-10-18") { $0.hasSuffix(".pub") }
        #expect(half.map(\.from) == ["\(ssh)/flotilla_ed25519.pub"])
        for bad in ["id_ed25519", "../flotilla_ed25519.old-x", "flotilla_ed25519.old-$(id)", "flotilla_ed25519.old-a/b", "flotilla_ed25519"] {
            #expect(throws: SSHKeySetup.CopyProblem.key) { try SSHKeySetup.archiveMoves(sshDirectory: ssh, archive: bad) { _ in true } }
        }
        #expect(throws: SSHKeySetup.CopyProblem.unsafePath) {
            try SSHKeySetup.archiveMoves(sshDirectory: "/Users/$(id)/.ssh", archive: "flotilla_ed25519.old-2026-10-18") { _ in true }
        }
    }

    // MARK: argv

    @Test func copyIDCopiesFlotillasKeyOnly() throws {
        #expect(try SSHKeySetup.copyIDArguments(sshDirectory: ssh, host: "Kamals-Mac-mini.local", user: "kamal")
                == ["-i", "/home/u/.ssh/flotilla_ed25519.pub", "kamal@Kamals-Mac-mini.local"])
        #expect(try SSHKeySetup.copyIDArguments(sshDirectory: ssh, host: "10.20.4.17", user: nil)
                == ["-i", "/home/u/.ssh/flotilla_ed25519.pub", "10.20.4.17"])
    }

    @Test func copyIDRefusesWhatCouldBeAnOption() {
        #expect(throws: SSHKeySetup.CopyProblem.address(.host)) {
            try SSHKeySetup.copyIDArguments(sshDirectory: ssh, host: "-oProxyCommand=sh", user: "u")
        }
        #expect(throws: SSHKeySetup.CopyProblem.address(.user)) {
            try SSHKeySetup.copyIDArguments(sshDirectory: ssh, host: "mini.internal", user: "a@b")
        }
        #expect(throws: SSHKeySetup.CopyProblem.unsafePath) {
            try SSHKeySetup.copyIDArguments(sshDirectory: "relative/.ssh", host: "mini.internal", user: "u")
        }
    }

    @Test func sessionsAddFlotillasKeyOnlyWhileItExists() throws {
        #expect(SSHKeySetup.Identity.present(sshDirectory: ssh) { _ in false } == nil)
        // The public half alone is not a key ssh can sign in with.
        #expect(SSHKeySetup.Identity.present(sshDirectory: ssh) { $0.hasSuffix(".pub") } == nil)
        let identity = try #require(SSHKeySetup.Identity.present(sshDirectory: ssh) { $0 == "\(ssh)/flotilla_ed25519" })
        #expect(try RemoteAccess.sshArguments(host: "mini.internal", user: "kamal", identity: identity)
                == ["-i", "/home/u/.ssh/flotilla_ed25519", "-o", "IdentitiesOnly=yes", "-l", "kamal", "mini.internal"])
        #expect(try RemoteAccess.sshArguments(host: "mini.internal", user: nil, identity: identity)
                == ["-i", "/home/u/.ssh/flotilla_ed25519", "-o", "IdentitiesOnly=yes", "mini.internal"])
        // Without it, exactly as before.
        #expect(try RemoteAccess.sshArguments(host: "mini.internal", user: "kamal", identity: nil) == ["-l", "kamal", "mini.internal"])
        // Validation still comes first.
        #expect(throws: RemoteAccess.ArgumentProblem.host) {
            try RemoteAccess.sshArguments(host: "-oProxyCommand=sh", user: "kamal", identity: identity)
        }
    }

    @Test func noIdentityFromAPathAShellOrSshCouldExpand() {
        for directory in ["/Users/$(id)/.ssh", "/Users/a%h/.ssh", "/Users/a b/.ssh", "relative/.ssh", "/Users/u/ssh"] {
            #expect(SSHKeySetup.Identity(sshDirectory: directory) == nil, "\(directory)")
        }
    }

    /// Kyle, 18 October: `ssh-copy-id` evaluates the `-i` path, so a `$(…)` in the home folder's
    /// name ran locally. No command is given a path a shell could act on.
    @Test func aHomePathAShellCouldReadIsRefused() {
        let hostile = ["/Users/$(touch /tmp/pwned)/.ssh", "/Users/`id`/.ssh", "/Users/a;rm -rf x/.ssh",
                       "/Users/Jane Doe/.ssh", "/Users/o'brien/.ssh", "/Users/a\"b/.ssh", "/Users/a|b/.ssh",
                       "/Users/a&b/.ssh", "/Users/a\nb/.ssh", "/Users/${HOME}/.ssh", "/Users/a*/.ssh",
                       "/Users/../etc/.ssh", "/Users/caf\u{E9}/.ssh"]
        for directory in hostile {
            #expect(!SSHKeySetup.isSSHDirectory(directory), "\(directory)")
            #expect(throws: SSHKeySetup.CopyProblem.unsafePath) {
                try SSHKeySetup.copyIDArguments(sshDirectory: directory, host: "mini.internal", user: "u")
            }
            #expect(throws: SSHKeySetup.CopyProblem.unsafePath) { try SSHKeySetup.keygenArguments(sshDirectory: directory) }
            #expect(throws: SSHKeySetup.CopyProblem.unsafePath) {
                try SSHKeySetup.removalArguments(sshDirectory: directory, host: "mini.internal", user: "u", remove: oldBody)
            }
            let status = SSHKeySetup.status(sshDirectory: directory, agent: .empty) { _ in true }
            #expect(!status.pathIsSafe)
            #expect(status.keyToCopy == nil, "no Copy Key offered")
            #expect(!status.canMakeKey && !status.canRegenerate && !status.canRemoveFromHost)
        }
        for directory in ["/Users/kamal/.ssh", "/Users/first.last/.ssh", "/home/u_2-x/.ssh"] {
            #expect(SSHKeySetup.isSSHDirectory(directory), "\(directory)")
        }
    }

    // MARK: Removal

    @Test func keyBodiesAreBase64AndNothingElse() {
        for body in [oldBody, newBody, "AAAAB3NzaC1yc2EAAAADAQABAAAAgQ==", "AAAAB3NzaC1yc2EAAAADAQABAAAAgQE="] {
            #expect(SSHKeySetup.isKeyBody(body), "\(body)")
        }
        let attempts = ["", "AAAA", "'", "\(oldBody)'", "\(oldBody)' '\(newBody)", "\(oldBody)'; rm -rf ~; '",
                        "AAAA$(id)AAAAAAAAAAAAAAAAAAAA", "AAAA`id`AAAAAAAAAAAAAAAAAAAAA", "AAAA;id;AAAAAAAAAAAAAAAAAAAA",
                        "AAAA AAAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA\nAAAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA\\AAAAAAAAAAAAAAAAAAAAAAAAAA",
                        "AAAA\"AAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA|AAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA*AAAAAAAAAAAAAAAAAAAAAAAAAA",
                        "-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA=AAAAAAAAAAAAAAAAAAAAAAAAAA",
                        "AAAAB3NzaC1yc2EAAAADAQABAAAA===", "\(oldBody)A", "BBBB\(oldBody.dropFirst(4))",
                        "AAAA\u{0}AAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAA\u{FF21}AAAAAAAAAAAAAAAAAAAAAAAAAA",
                        "AAAA" + String(repeating: "A", count: 8192)]
        for body in attempts {
            #expect(!SSHKeySetup.isKeyBody(body), "accepted \(body.debugDescription)")
            #expect(throws: SSHKeySetup.CopyProblem.key) { try SSHKeySetup.removalCommand(remove: body) }
            #expect(throws: SSHKeySetup.CopyProblem.key) { try SSHKeySetup.removalCommand(remove: oldBody, keep: body) }
            #expect(throws: SSHKeySetup.CopyProblem.key) {
                try SSHKeySetup.removalArguments(sshDirectory: ssh, host: "mini.internal", user: "u", remove: body)
            }
        }
        #expect(throws: SSHKeySetup.CopyProblem.key) { try SSHKeySetup.removalCommand(remove: oldBody, keep: oldBody) }
    }

    @Test func theRemovalCommandIsFixedButForTheBodies() throws {
        #expect(!SSHKeySetup.removalScript.contains("'"), "sent single-quoted")
        #expect(!SSHKeySetup.removalScript.contains("\n"))
        let command = try SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)
        #expect(command == "/bin/sh -c '\(SSHKeySetup.removalScript)' flotilla-remove-key '\(oldBody)' '\(newBody)'")
        #expect(try SSHKeySetup.removalCommand(remove: oldBody)
                == "/bin/sh -c '\(SSHKeySetup.removalScript)' flotilla-remove-key '\(oldBody)'")
        // Exactly six quotes: the script's pair and each body's.
        #expect(command.filter { $0 == "'" }.count == 6)
    }

    @Test func removalSignsInWithFlotillasKey() throws {
        let regenerate = try SSHKeySetup.removalArguments(sshDirectory: ssh, host: "mini.internal", user: "kamal",
                                                          remove: oldBody, keep: newBody)
        // Flotilla's key and no other: no config file (so no IdentityFile from it), no agent.
        let only = ["-F", "/dev/null", "-o", "IdentitiesOnly=yes", "-i", "/home/u/.ssh/flotilla_ed25519", "-o", "IdentityAgent=none"]
        #expect(Array(regenerate.dropLast()) == only + ["-o", "PreferredAuthentications=publickey", "-l", "kamal", "mini.internal"])
        #expect(regenerate.last == (try SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)))
        let remove = try SSHKeySetup.removalArguments(sshDirectory: ssh, host: "mini.internal", user: nil, remove: newBody)
        #expect(Array(remove.dropLast()) == only + ["mini.internal"])
        #expect(!regenerate.contains { $0.hasPrefix("StrictHostKeyChecking") || $0.hasPrefix("UserKnownHostsFile") },
                "known_hosts still applies")
        #expect(!regenerate.contains("--") && !remove.contains("--"))
        #expect(throws: SSHKeySetup.CopyProblem.address(.host)) {
            try SSHKeySetup.removalArguments(sshDirectory: ssh, host: "-oProxyCommand=sh", user: "u", remove: oldBody)
        }
        #expect(throws: SSHKeySetup.CopyProblem.address(.user)) {
            try SSHKeySetup.removalArguments(sshDirectory: ssh, host: "mini", user: "$(id)", remove: oldBody)
        }
    }

    @Test func removalOutcomesFollowTheScriptsCodes() {
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 0) == .removed)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 0).succeeded)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 5) == .notThere)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 6) == .newKeyMissing)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 255) == .couldNotSignIn)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: nil) == .other(nil))
        #expect(!SSHKeySetup.RemovalOutcome(exitCode: 1).succeeded)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 9) == .notARegularFile)
        #expect(SSHKeySetup.RemovalOutcome(exitCode: 8) == .rewriteFailed)
        // Signed in: the script's own codes. Not ssh's failure, nor an unknown status.
        #expect([0, 3, 4, 5, 6, 7, 8, 9].allSatisfy { SSHKeySetup.RemovalOutcome(exitCode: $0).signedIn })
        #expect(!SSHKeySetup.RemovalOutcome(exitCode: 255).signedIn && !SSHKeySetup.RemovalOutcome(exitCode: nil).signedIn)
    }

    /// The command as the remote end runs it: a login shell's `-c`, here `/bin/sh`'s, in a home of its
    /// own. Not a string comparison — the lines that go, the lines that stay, the backup, and the
    /// refusals that change nothing.
    @Test func theRemovalCommandRemovesExactlyTheOldKeysRecords() throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let original = """
        # keys \(oldBody)
        ssh-ed25519 \(oldBody) flotilla
        ssh-ed25519 \(newBody) flotilla
        from="10.0.0.0/8",no-pty ssh-ed25519 \(oldBody) flotilla
        command="echo two words",no-pty ssh-ed25519 \(oldBody) quoted space in an option
        restrict,command="say \\"hi there\\" now" ssh-ed25519 \(oldBody) escaped quote in an option
        command="ssh-ed25519 \(oldBody)" ssh-ed25519 \(newBody) the old body in an option
          ssh-ed25519 \(oldBody) leading space
        ssh-ed25519 \(oldBody)X not the same key
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQ== \(oldBody)
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQ== \(oldBody)-in-a-comment

        """
        try home.write(original)

        // The new key must be there: a host without it keeps the old one, untouched.
        let unrelated = "AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: unrelated)) == 6)
        #expect(try home.contents() == original)
        #expect(!home.exists("authorized_keys.flotilla-bak"))

        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)) == 0)
        let after = try home.contents()
        #expect(after == """
        # keys \(oldBody)
        ssh-ed25519 \(newBody) flotilla
        command="ssh-ed25519 \(oldBody)" ssh-ed25519 \(newBody) the old body in an option
        ssh-ed25519 \(oldBody)X not the same key
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQ== \(oldBody)
        ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQ== \(oldBody)-in-a-comment

        """)
        #expect(try home.contents("authorized_keys.flotilla-bak") == original)
        #expect(try home.mode() == 0o600)
        #expect(home.leftovers().isEmpty, "no temporary file left: \(home.leftovers())")

        // Gone already: nothing to do, and nothing changed.
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody)) == 5)
        #expect(try home.contents() == after)

        try home.delete("authorized_keys")
        #expect(try home.run(SSHKeySetup.removalCommand(remove: newBody)) == 3)
    }

    /// Kyle, 18 October, first reproduction: the new body in the old key's *comment* passed the
    /// "new key is there" check, and the removal then emptied the file. A comment is not a key.
    @Test func aNewBodyInACommentIsNotTheNewKey() throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let original = "ssh-ed25519 \(oldBody) \(newBody)\n"
        try home.write(original)
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)) == 6)
        #expect(try home.contents() == original)
        #expect(!home.exists("authorized_keys.flotilla-bak"))
    }

    /// Kyle's second: a comment holding the old body deleted the *new* key's line.
    @Test func anOldBodyInACommentDoesNotTakeTheNewKeysLine() throws {
        let home = try RemoteHome()
        defer { home.remove() }
        try home.write("ssh-ed25519 \(newBody) replaces \(oldBody)\nssh-ed25519 \(oldBody) flotilla\n")
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)) == 0)
        #expect(try home.contents() == "ssh-ed25519 \(newBody) replaces \(oldBody)\n")
        // And with only the comment left, there is nothing of the old key to remove.
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody)) == 5)
    }

    /// Kyle's symlink attack: `authorized_keys.flotilla-tmp → authorized_keys` made the old script
    /// empty the file and report success. The temporary file is `mktemp`'s now, the backup is
    /// renamed into place rather than written through, and a symlinked `authorized_keys` is refused.
    @Test func noSymlinkIsWrittenThrough() throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let original = "ssh-ed25519 \(oldBody) flotilla\nssh-ed25519 \(newBody) flotilla\n"
        try home.write(original)
        try home.link("authorized_keys.flotilla-tmp", to: "authorized_keys")
        try home.link("authorized_keys.flotilla-bak", to: "authorized_keys")
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)) == 0)
        #expect(try home.contents() == "ssh-ed25519 \(newBody) flotilla\n")
        #expect(!home.isSymlink("authorized_keys"))
        #expect(!home.isSymlink("authorized_keys.flotilla-bak"), "the backup replaced the link, not its target")
        #expect(try home.contents("authorized_keys.flotilla-bak") == original)
        #expect(home.isSymlink("authorized_keys.flotilla-tmp"), "the planted link is not touched")

        // authorized_keys itself a link: refused, and its target is unchanged.
        let real = home.dotSSH.appendingPathComponent("elsewhere")
        try original.write(to: real, atomically: true, encoding: .utf8)
        try home.delete("authorized_keys")
        try home.link("authorized_keys", to: "elsewhere")
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody)) == 9)
        #expect(try String(contentsOf: real, encoding: .utf8) == original)
        #expect(home.isSymlink("authorized_keys"))

        // Nor a directory.
        try home.delete("authorized_keys")
        try FileManager.default.createDirectory(at: home.file, withIntermediateDirectories: false)
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody)) == 9)
    }

    /// Interrupted while writing the new file — here the whole script is killed with SIGKILL halfway
    /// through awk's output — and when the final rename fails: the original survives both, whole.
    @Test func anInterruptedRewriteLeavesTheOriginal() throws {
        let home = try RemoteHome()
        defer { home.remove() }
        let lines = (0..<200).map { "ssh-ed25519 \(newBody) host-\($0)" } + ["ssh-ed25519 \(oldBody) flotilla"]
        let original = lines.joined(separator: "\n") + "\n"
        try home.write(original)

        // An awk that counts honestly and, asked for the rewrite, writes ten lines and kills the script.
        let realAwk = try #require(["/usr/bin/awk", "/bin/awk"].first { FileManager.default.isExecutableFile(atPath: $0) })
        try home.tool("awk", """
        #!/bin/sh
        if [ "$2" = m=0 ]; then "\(realAwk)" "$@" | head -n 10; kill -9 $PPID; exit 1; fi
        exec "\(realAwk)" "$@"
        """)
        _ = try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody), toolsFirst: true)
        #expect(try home.contents() == original, "the original, untouched")
        try home.delete("bin/awk")
        // Proof the kill landed mid-write: the half-written temporary file is what a SIGKILL leaves.
        let partial = home.leftovers()
        #expect(partial.count == 1)
        for name in partial {
            #expect(try home.contents(name).split(separator: "\n").count == 10)
            try home.delete(name)
        }

        // A rename that fails: status 8, the original, and the temporary file cleaned up.
        try home.tool("mv", """
        #!/bin/sh
        case "$3" in *flotilla-bak) exec /bin/mv "$@";; esac
        exit 1
        """)
        #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody), toolsFirst: true) == 8)
        #expect(try home.contents() == original)
        #expect(home.leftovers().isEmpty, "\(home.leftovers())")
    }

    /// The command goes to the remote user's login shell as one string. Every shell this machine has
    /// must hand it to `/bin/sh` intact — csh and tcsh expand `!` even inside single quotes, which is
    /// why the script has none.
    @Test func everyLoginShellPassesTheScriptThrough() throws {
        #expect(!SSHKeySetup.removalScript.contains("!"), "csh history expansion")
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        #expect(shells.contains("/bin/sh"))
        for shell in shells {
            let home = try RemoteHome()
            defer { home.remove() }
            try home.write("ssh-ed25519 \(oldBody) a\nssh-ed25519 \(newBody) \(oldBody)\n")
            #expect(try home.run(SSHKeySetup.removalCommand(remove: oldBody, keep: newBody), shell: shell) == 0, "\(shell)")
            #expect(try home.contents() == "ssh-ed25519 \(newBody) \(oldBody)\n", "\(shell)")
        }
    }

    // MARK: Regenerate's rollback

    private func stamp(_ inode: UInt64, regular: Bool = true, mine: Bool = true) -> SSHKeySetup.FileStamp {
        .init(device: 1, inode: inode, isRegularFile: regular, ownedByUser: mine)
    }

    @Test func aPartialNewPairIsRemovedOnlyWhereThisRunMadeIt() throws {
        let archived = [stamp(10), stamp(11)]
        // Not empty when the snapshot is taken: no snapshot, so nothing will ever be removed.
        #expect(SSHKeySetup.KeygenSnapshot(sshDirectory: ssh, archived: archived) {
            $0 == "\(ssh)/flotilla_ed25519.pub" ? self.stamp(12) : nil
        } == nil)
        let snapshot = try #require(SSHKeySetup.KeygenSnapshot(sshDirectory: ssh, archived: archived) { _ in nil })
        #expect(snapshot.paths == ["\(ssh)/flotilla_ed25519", "\(ssh)/flotilla_ed25519.pub"])

        // ssh-keygen wrote the private half and stopped: that half, by its inode, is this run's.
        var files = ["\(ssh)/flotilla_ed25519": stamp(20)]
        var output = SSHKeySetup.keygenOutput(after: snapshot) { files[$0] }
        #expect(output.made == ["\(ssh)/flotilla_ed25519": stamp(20)] && output.foreign.isEmpty)

        // Nothing written: nothing to remove.
        files = [:]
        output = SSHKeySetup.keygenOutput(after: snapshot) { files[$0] }
        #expect(output.made.isEmpty && output.foreign.isEmpty)

        // Anything that isn't plainly new is left alone and blocks the restore.
        for (name, file) in [("a symlink", stamp(21, regular: false)), ("someone else's", stamp(22, mine: false)),
                             ("an archived file", stamp(10))] {
            files = ["\(ssh)/flotilla_ed25519.pub": file]
            output = SSHKeySetup.keygenOutput(after: snapshot) { files[$0] }
            #expect(output.made.isEmpty, "\(name)")
            #expect(output.foreign == ["\(ssh)/flotilla_ed25519.pub"], "\(name)")
        }
    }

    /// Kyle, 18 October: while Regenerate waited for a passphrase, another host's tab made a whole
    /// key, and cancelling Regenerate deleted it because it was recent and the user's.
    @Test func aKeyFromAnotherOperationIsNeverThisRuns() throws {
        // The other tab cannot start while Regenerate holds the lock — for any host.
        var gate = SSHKeySetup.OperationGate()
        let regenerate = try #require(gate.begin(host: "aa", hostName: "studio") as UUID?)
        let otherTab = gate.begin(host: "bb", hostName: "minimac")
        let sameTab = gate.begin(host: "aa", hostName: "studio")
        #expect(otherTab == nil && sameTab == nil)

        // And if a file did turn up at the path after ssh-keygen exited — another operation's,
        // brand new and the user's — it is not the inode ssh-keygen left, so it is never removed.
        let snapshot = try #require(SSHKeySetup.KeygenSnapshot(sshDirectory: ssh, archived: [stamp(10), stamp(11)]) { _ in nil })
        let atExit = SSHKeySetup.keygenOutput(after: snapshot) { _ in nil }
        #expect(atExit.made.isEmpty)
        let made = stamp(30)
        #expect(SSHKeySetup.isStillMade(made, now: made))
        #expect(!SSHKeySetup.isStillMade(made, now: stamp(31)))
        #expect(!SSHKeySetup.isStillMade(made, now: SSHKeySetup.FileStamp(device: 2, inode: 30, isRegularFile: true, ownedByUser: true)))
        #expect(!SSHKeySetup.isStillMade(made, now: stamp(30, regular: false)))
        #expect(!SSHKeySetup.isStillMade(made, now: nil))
        let released = gate.end(regenerate)
        #expect(released)
    }

    @Test func theKeyLockIsReleasedOnlyByItsHolder() throws {
        var gate = SSHKeySetup.OperationGate()
        let first = try #require(gate.begin(host: "aa", hostName: "studio") as UUID?)
        #expect(gate.running(otherThan: "bb")?.hostName == "studio")
        #expect(gate.running(otherThan: "aa") == nil)
        // A stale token — an earlier operation's close arriving late — releases nothing.
        let stale = gate.end(UUID())
        #expect(!stale && gate.holder?.token == first)
        let released = gate.end(first)
        let again = gate.end(first)
        #expect(released && !again && gate.holder == nil)
        let second = try #require(gate.begin(host: "bb", hostName: "minimac") as UUID?)
        let late = gate.end(first)
        #expect(!late && gate.holder?.token == second)
    }

    /// Kyle, 18 October: closing a key step's session released the lock as `terminate()` was sent,
    /// before the child had stopped. Only the exit releases; SIGKILL follows the grace period.
    @Test func aClosedStepHoldsTheLockUntilItsChildHasExited() throws {
        var gate = SSHKeySetup.OperationGate()
        let op = try #require(gate.begin(host: "aa", hostName: "studio") as UUID?)
        var barrier = SSHKeySetup.ExitBarrier()
        var signals: [SSHKeySetup.ExitBarrier.Action] = []
        func drive(_ action: SSHKeySetup.ExitBarrier.Action) {
            if action == .released { gate.end(op) } else { signals.append(action) }
        }

        drive(barrier.close())
        #expect(gate.holder?.token == op)
        #expect(gate.begin(host: "bb", hostName: "minimac") == nil)
        drive(barrier.close())                // a second close sends nothing more
        drive(barrier.deadlinePassed())
        #expect(gate.holder?.token == op)
        drive(barrier.deadlinePassed())       // SIGKILL went and it is still there: keep holding
        #expect(gate.holder?.token == op)
        #expect(signals == [.terminate, .nothing, .kill, .overdue])

        drive(barrier.exited())
        #expect(gate.holder == nil)
        // Exactly once: a late repeat and a late deadline do nothing.
        #expect(barrier.exited() == .nothing && barrier.deadlinePassed() == .nothing && barrier.close() == .nothing)
    }

    @Test func aChildThatEndsByItselfIsReportedNotReleasedAndNeverSignalled() {
        var barrier = SSHKeySetup.ExitBarrier()
        #expect(barrier.deadlinePassed() == .nothing)
        #expect(barrier.exited() == .ended)
        // A close or deadline arriving after the exit signals nothing: the pid may be anyone's now.
        #expect(barrier.close() == .nothing && barrier.deadlinePassed() == .nothing)
    }

    /// Kyle, 18 October: rollback checked the aside path's inode, then unlinked that pathname, and
    /// another writer of ~/.ssh could swap the entry between. The check and the unlink are now in a
    /// private directory, and a mismatch there never unlinks.
    @Test func anInodeMismatchInThePrivateDirectoryNeverDeletes() {
        let path = ssh + "/flotilla_ed25519"
        let made = stamp(30)

        let swapped = FakeRollbackDirectory(found: stamp(31))
        #expect(SSHKeySetup.removeMade(path, ifStill: made, in: swapped) == .notMade)
        #expect(swapped.calls == ["in " + path, "stamp", "back " + path])

        let notRegular = FakeRollbackDirectory(found: stamp(30, regular: false))
        #expect(SSHKeySetup.removeMade(path, ifStill: made, in: notRegular) == .notMade)
        #expect(!notRegular.calls.contains("unlink"))

        let stuck = FakeRollbackDirectory(found: stamp(31), canMoveBack: false)
        #expect(SSHKeySetup.removeMade(path, ifStill: made, in: stuck) == .setAside(stuck.entryPath))
        #expect(!stuck.calls.contains("unlink"))

        let gone = FakeRollbackDirectory(found: nil)
        #expect(SSHKeySetup.removeMade(path, ifStill: made, in: gone) == .notMade)
        #expect(!gone.calls.contains("unlink"))

        let missing = FakeRollbackDirectory(found: made, move: .missing)
        #expect(SSHKeySetup.removeMade(path, ifStill: made, in: missing) == .notMade)
        #expect(missing.calls == ["in " + path])
    }

    @Test func theFileKeygenLeftIsUnlinkedInsideThePrivateDirectory() {
        let path = ssh + "/flotilla_ed25519.pub"
        let same = FakeRollbackDirectory(found: stamp(30))
        #expect(SSHKeySetup.removeMade(path, ifStill: stamp(30), in: same) == .removed)
        #expect(same.calls == ["in " + path, "stamp", "unlink"])

        let refused = FakeRollbackDirectory(found: stamp(30), unlinkError: "Operation not permitted")
        #expect(SSHKeySetup.removeMade(path, ifStill: stamp(30), in: refused) == .failed("Operation not permitted", setAside: nil))
        #expect(refused.calls.last == "back " + path)
    }

    // MARK: Which hosts have the key

    @Test func keyHostsBelongToOneKeyByItsDigest() {
        let old = String(repeating: "a1", count: 32)
        let new = String(repeating: "b2", count: 32)
        var hosts = SSHKeyHosts()
        let mini = SSHKeyHosts.Entry(host: "aa11", user: "kamal")
        let studio = SSHKeyHosts.Entry(host: "bb22", user: nil)
        hosts.record(mini, keyDigest: old)
        hosts.record(studio, keyDigest: old)
        hosts.record(mini, keyDigest: old)
        #expect(hosts.hosts(for: old) == [mini, studio])
        #expect(hosts.has(mini, keyDigest: old))
        #expect(!hosts.has(mini, keyDigest: new), "another key is not on it")
        #expect(!hosts.has(SSHKeyHosts.Entry(host: "aa11", user: "root"), keyDigest: old), "another account is not")
        #expect(SSHKeyHosts.Entry(host: "bb22", user: "") == studio)

        // A copy of the new key starts the list again.
        hosts.record(mini, keyDigest: new)
        #expect(hosts.hosts(for: new) == [mini])
        #expect(hosts.hosts(for: old).isEmpty)
        hosts.forget(mini, keyDigest: new)
        #expect(hosts.hosts(for: new).isEmpty)

        // Only a digest is ever recorded: never a key body.
        var bodies = SSHKeyHosts()
        bodies.record(mini, keyDigest: oldBody)
        #expect(bodies == SSHKeyHosts())

        var round = SSHKeyHosts()
        round.record(mini, keyDigest: old)
        round.record(studio, keyDigest: old)
        #expect(SSHKeyHosts(plist: round.plist) == round)
        #expect(round.plist["key"] == nil && round.plist["keySHA256"] as? String == old)
        #expect(SSHKeyHosts(plist: ["keySHA256": "$(id)", "hosts": [["host": "aa11"]]]) == SSHKeyHosts())
        #expect(SSHKeyHosts(plist: ["key": oldBody, "hosts": [["host": "aa11"]]]) == SSHKeyHosts(), "the old body form")
        #expect(SSHKeyHosts(plist: "nonsense") == SSHKeyHosts())
    }
}

/// A remote account's home for the removal script, in a temporary directory: `~/.ssh` and, for
/// tests that replace a tool, `~/bin` ahead of the system's on `PATH`.
private struct RemoteHome {
    let home: URL
    var dotSSH: URL { home.appendingPathComponent(".ssh") }
    var file: URL { dotSSH.appendingPathComponent("authorized_keys") }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("flotilla-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
    func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    func contents(_ name: String = "authorized_keys") throws -> String {
        try String(contentsOf: dotSSH.appendingPathComponent(name), encoding: .utf8)
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dotSSH.appendingPathComponent(name).path) }
    func delete(_ name: String) throws {
        let url = name.hasPrefix("bin/") ? home.appendingPathComponent(name) : dotSSH.appendingPathComponent(name)
        try FileManager.default.removeItem(at: url)
    }
    func link(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: dotSSH.appendingPathComponent(name).path, withDestinationPath: target)
    }
    func isSymlink(_ name: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: dotSSH.appendingPathComponent(name).path)[.type]
            as? FileAttributeType) == .typeSymbolicLink
    }
    func mode() throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    /// `authorized_keys.XXXXXX` files the script left.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dotSSH.path)) ?? [])
            .filter { $0.hasPrefix("authorized_keys.") && $0 != "authorized_keys.flotilla-bak" && $0 != "authorized_keys.flotilla-tmp" }
    }
    func tool(_ name: String, _ script: String) throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent(name)
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `<shell> -c <command>`, as sshd runs a command, with `HOME` here. Bounded, so a hang fails.
    func run(_ command: String, shell: String = "/bin/sh", toolsFirst: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let path = "/usr/bin:/bin"
        process.environment = ["HOME": home.path, "PATH": toolsFirst ? home.appendingPathComponent("bin").path + ":" + path : path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private final class FakeRollbackDirectory: SSHKeySetup.RollbackDirectory {
    let found: SSHKeySetup.FileStamp?
    let move: SSHKeySetup.RollbackMove
    let canMoveBack: Bool
    let unlinkError: String?
    var calls: [String] = []
    let entryPath = ssh + "/.flotilla-rollback-abc123/file"

    init(found: SSHKeySetup.FileStamp?, move: SSHKeySetup.RollbackMove = .moved, canMoveBack: Bool = true,
         unlinkError: String? = nil) {
        self.found = found
        self.move = move
        self.canMoveBack = canMoveBack
        self.unlinkError = unlinkError
    }

    func moveIn(_ path: String) -> SSHKeySetup.RollbackMove { calls.append("in " + path); return move }
    func stampEntry() -> SSHKeySetup.FileStamp? { calls.append("stamp"); return found }
    func unlinkEntry() -> String? { calls.append("unlink"); return unlinkError }
    func moveBack(to path: String) -> Bool { calls.append("back " + path); return canMoveBack }
}
