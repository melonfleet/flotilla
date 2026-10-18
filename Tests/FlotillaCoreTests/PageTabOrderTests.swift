import Foundation
import Testing
@testable import FlotillaCore

@Suite struct PageTabOrderTests {
    @Test func theOrderIsOverviewDataInspectThenTheWaysIn() {
        #expect(PageTabKind.allCases == [.overview, .view, .settings, .history, .inspect,
                                         .session, .files, .screen])
        #expect(PageTabKind.allCases.filter { $0.group == .data } == [.overview, .view, .settings, .history, .inspect])
        #expect(PageTabKind.allCases.filter { $0.group == .access } == [.session, .files, .screen])
    }

    /// Each page as it is now listed, which must already be canonical.
    @Test func everyPageShapeIsCanonical() {
        let container: [PageTabKind] = [.overview, .view, .history, .inspect, .session, .files]
        let remoteContainer: [PageTabKind] = [.overview, .view, .history, .inspect]
        let machine: [PageTabKind] = [.overview, .settings, .history, .inspect, .session]
        let host: [PageTabKind] = [.overview, .view, .view, .view, .settings, .history, .session, .files, .screen]
        let simple: [PageTabKind] = [.overview, .inspect]
        for page in [container, remoteContainer, machine, host, simple] {
            #expect(PageTabOrder.isCanonical(page))
        }
    }

    @Test func outOfOrderIsCaught() {
        // The order before 18 October: Terminal second on containers, Screen Sharing before Files.
        #expect(!PageTabOrder.isCanonical([.overview, .session, .history, .inspect, .view, .files]))
        #expect(!PageTabOrder.isCanonical([.overview, .session, .screen, .files]))
        #expect(!PageTabOrder.isCanonical([.inspect, .overview]))
    }

    @Test func arrangingIsStableWithinAKind() {
        let given: [(String, PageTabKind)] = [("Terminal", .session), ("Updates", .view), ("Overview", .overview),
                                              ("Inspect", .inspect), ("System", .view), ("Files", .files),
                                              ("Flotilla", .view), ("Logs", .history)]
        let arranged = PageTabOrder.arranged(given) { $0.1 }.map(\.0)
        #expect(arranged == ["Overview", "Updates", "System", "Flotilla", "Logs", "Inspect", "Terminal", "Files"])
    }

    @Test func oneDividerWhereTheWaysInBegin() {
        #expect(PageTabOrder.dividers([.overview, .view, .history, .inspect, .session, .files])
                == [false, false, false, false, true, false])
        // No ways in, no divider; only ways in, none either.
        #expect(PageTabOrder.dividers([.overview, .inspect]) == [false, false])
        #expect(PageTabOrder.dividers([.session, .files]) == [false, false])
        #expect(PageTabOrder.dividers([]) == [])
    }
}

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

    @Test func statusFindsDefaultPublicKeysByNameInPreferenceOrder() {
        let present: Set = ["/home/u/.ssh/id_rsa.pub", "/home/u/.ssh/id_ed25519.pub", "/home/u/.ssh/id_dsa.pub"]
        let status = SSHKeySetup.status(sshDirectory: "/home/u/.ssh", agent: .unavailable) { present.contains($0) }
        #expect(status.publicKeys == ["id_ed25519.pub", "id_rsa.pub"])
        #expect(status.hasKey)
        #expect(status.keyToCopy == "id_ed25519.pub")
    }

    @Test func noFilesAndNoAgentIsNoKey() {
        let none = SSHKeySetup.status(sshDirectory: "/home/u/.ssh", agent: .empty) { _ in false }
        #expect(!none.hasKey)
        #expect(none.keyToCopy == nil)
        let agentOnly = SSHKeySetup.status(sshDirectory: "/home/u/.ssh", agent: .keys(["ssh-ed25519"])) { _ in false }
        #expect(agentOnly.hasKey)
        #expect(agentOnly.keyToCopy == nil)
    }

    @Test func copyIDArgvIsFixed() throws {
        #expect(try SSHKeySetup.copyIDArguments(sshDirectory: "/home/u/.ssh", publicKey: "id_ed25519.pub",
                                                host: "Kamals-Mac-mini.local", user: "kamal")
                == ["-i", "/home/u/.ssh/id_ed25519.pub", "kamal@Kamals-Mac-mini.local"])
        #expect(try SSHKeySetup.copyIDArguments(sshDirectory: "/home/u/.ssh", publicKey: "id_rsa.pub",
                                                host: "10.20.4.17", user: nil)
                == ["-i", "/home/u/.ssh/id_rsa.pub", "10.20.4.17"])
    }

    @Test func copyIDRefusesWhatCouldBeAnOptionOrAnotherFile() {
        #expect(throws: SSHKeySetup.CopyProblem.address(.host)) {
            try SSHKeySetup.copyIDArguments(sshDirectory: "/home/u/.ssh", publicKey: "id_ed25519.pub", host: "-oProxyCommand=sh", user: "u")
        }
        #expect(throws: SSHKeySetup.CopyProblem.address(.user)) {
            try SSHKeySetup.copyIDArguments(sshDirectory: "/home/u/.ssh", publicKey: "id_ed25519.pub", host: "mini.internal", user: "a@b")
        }
        // A private key, a path, or a directory that is not ~/.ssh.
        for key in ["id_ed25519", "../id_ed25519.pub", "/etc/passwd", "authorized_keys"] {
            #expect(throws: SSHKeySetup.CopyProblem.key) {
                try SSHKeySetup.copyIDArguments(sshDirectory: "/home/u/.ssh", publicKey: key, host: "mini.internal", user: "u")
            }
        }
        #expect(throws: SSHKeySetup.CopyProblem.key) {
            try SSHKeySetup.copyIDArguments(sshDirectory: "relative/.ssh", publicKey: "id_ed25519.pub", host: "mini.internal", user: "u")
        }
    }

    @Test func keygenNeverChoosesAFileOrAPassphrase() {
        #expect(SSHKeySetup.keygenArguments == ["-t", "ed25519"])
        #expect(!SSHKeySetup.keygenArguments.contains { ["-f", "-N", "-P", "-y", "-q"].contains($0) })
        #expect(SSHKeySetup.agentArguments == ["-L"])
    }
}
