import Foundation
import Testing
@testable import FlotillaCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/system"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct RemoteAccessArgvTests {
    @Test func sshArgvIsTheUserWithDashLAndTheHostAloneAfterIt() throws {
        #expect(try RemoteAccess.sshArguments(host: "Kamals-Mac-mini.local", user: "kamal")
                == ["-l", "kamal", "Kamals-Mac-mini.local"])
        #expect(try RemoteAccess.sshArguments(host: "10.20.4.17", user: "build_bot")
                == ["-l", "build_bot", "10.20.4.17"])
        #expect(try RemoteAccess.sshArguments(host: "fd7a:115c:a1e0::1", user: "a.b-c")
                == ["-l", "a.b-c", "fd7a:115c:a1e0::1"])
    }

    @Test func noUserLeavesItToSshAndItsConfig() throws {
        #expect(try RemoteAccess.sshArguments(host: "mini.internal", user: nil) == ["mini.internal"])
        #expect(try RemoteAccess.sshArguments(host: "mini.internal", user: "") == ["mini.internal"])
    }

    @Test func nothingButTheTwoValidatedStringsIsEverAdded() throws {
        let argv = try RemoteAccess.sshArguments(host: "mini.internal", user: "kamal")
        #expect(argv.filter { $0.hasPrefix("-") } == ["-l"])
        #expect(!argv.contains("--"))
        #expect(!argv.contains { $0.hasPrefix("-o") })
    }

    /// Everything a destination could use to become an option, a different user or port, or a
    /// shell fragment inside the user's own `ProxyCommand %h`.
    @Test func hostsThatCouldBeOptionsOrShellAreRefused() {
        let bad = ["", "-oProxyCommand=sh", "-p", ".hidden", "user@host", "host:2222", "ssh://host",
                   "host name", "host\tname", "host\nname", "host;id", "host$(id)", "`id`", "host|nc",
                   "host'", "host\"", "a/b", "host%en0", "fe80::1%en0", "[::1]", "host..local",
                   "h\u{0}st", "hôst", String(repeating: "a", count: 254), ":", "::g"]
        for host in bad {
            #expect(!RemoteAccess.isValidHost(host), "accepted \(host.debugDescription)")
            #expect(throws: RemoteAccess.ArgumentProblem.host) { try RemoteAccess.sshArguments(host: host, user: "kamal") }
        }
    }

    @Test func hostsThatAreHostsAreAccepted() {
        for host in ["mini", "mini.local", "Kamals-Mac-mini.local", "10.20.4.17", "mini.tail1234.ts.net",
                     "::1", "fd7a:115c:a1e0::1", "host.", "a-b.example"] {
            #expect(RemoteAccess.isValidHost(host), "refused \(host)")
        }
    }

    @Test func usersThatCouldBeOptionsOrShellAreRefused() {
        let bad = ["-oProxyCommand=sh", "-l", ".dot", "kam al", "k@mal", "k:mal", "k;id", "$(id)",
                   "k\nal", "k/al", "kämal", String(repeating: "a", count: 65)]
        for user in bad {
            #expect(!RemoteAccess.isValidUser(user), "accepted \(user.debugDescription)")
            #expect(throws: RemoteAccess.ArgumentProblem.user) { try RemoteAccess.sshArguments(host: "mini", user: user) }
        }
        for user in ["kamal", "_mbsetupuser", "build.bot", "a-1", "Kamal"] {
            #expect(RemoteAccess.isValidUser(user), "refused \(user)")
        }
    }

    @Test func theProblemNeverRepeatsTheValue() {
        #expect(!RemoteAccess.ArgumentProblem.host.description.contains("kamal"))
        #expect(!"\(RemoteAccess.ArgumentProblem.user)".contains("kamal"))
    }

    @Test func environmentPassesTheAgentAndNothingUnlisted() {
        let inherited = ["SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.x/Listeners", "SHELL": "/bin/zsh",
                         "PATH": "/usr/bin:/bin", "AWS_SECRET_ACCESS_KEY": "nope", "GITHUB_TOKEN": "nope",
                         "TMPDIR": "/var/folders/x/T/", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"]
        let environment = RemoteAccess.sshEnvironment(base: ["TERM=xterm-256color", "HOME=/Users/x"], inherited: inherited)
        #expect(environment.contains("SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.x/Listeners"))
        #expect(environment.contains("TERM=xterm-256color"))
        #expect(environment.contains("SHELL=/bin/zsh"))
        #expect(!environment.contains { $0.hasPrefix("AWS_") || $0.hasPrefix("GITHUB_") || $0.hasPrefix("DYLD_") })
    }

    @Test func environmentDropsAValueThatCouldSmuggleASecondVariable() {
        let environment = RemoteAccess.sshEnvironment(base: [], inherited: ["SHELL": "/bin/zsh\nEVIL=1"])
        #expect(environment.isEmpty)
    }
}

@Suite struct RemoteAccessAddressTests {
    private var facts: HostFacts {
        var facts = HostFacts()
        facts.localHostName = "Kamals-Mac-mini"
        facts.ipv4Addresses = ["10.20.4.17"]
        return facts
    }

    @Test func bonjourBecomesTheHostsOwnLocalName() {
        #expect(RemoteAccess.address(advertised: .bonjour(name: "Kamal’s Mac mini"), typed: .address(host: "mini.ts.net", port: 7868),
                                     last: nil, facts: facts) == "Kamals-Mac-mini.local")
    }

    @Test func typedAddressWhenBonjourCannotSeeIt() {
        #expect(RemoteAccess.address(advertised: nil, typed: .address(host: "mini.ts.net", port: 7868),
                                     last: .address(host: "10.0.0.9", port: 7868), facts: facts) == "mini.ts.net")
        #expect(RemoteAccess.address(advertised: nil, typed: nil, last: .address(host: "10.0.0.9", port: 7868), facts: facts) == "10.0.0.9")
    }

    @Test func anOlderHostWithoutAHostNameFallsBackToItsAddress() {
        var old = facts
        old.localHostName = nil
        #expect(RemoteAccess.address(advertised: .bonjour(name: "mini"), typed: nil, last: nil, facts: old) == "10.20.4.17")
        #expect(RemoteAccess.address(advertised: nil, typed: nil, last: nil, facts: nil) == nil)
    }

    @Test func unreportedIsUnknownNotOff() {
        #expect(RemoteAccess.state(of: .ssh, in: nil) == .unknown)
        var facts = HostFacts()
        facts.remoteLogin = true
        facts.screenSharing = false
        #expect(RemoteAccess.state(of: .ssh, in: facts) == .on)
        #expect(RemoteAccess.state(of: .screenSharing, in: facts) == .off)
        #expect(RemoteAccess.state(of: .fileSharing, in: facts) == .unknown)
    }

    /// An older host's answer has none of the new keys, and must decode as unknown.
    @Test func anOlderHostsFactsDecodeWithTheServicesUnknown() throws {
        let old = try JSONDecoder().decode(HostFacts.self, from: Data(#"{"chip":"Apple M1","cores":8}"#.utf8))
        #expect(old.localHostName == nil)
        for service in RemoteAccess.Service.allCases { #expect(RemoteAccess.state(of: service, in: old) == .unknown) }
    }
}

@Suite struct SharingDetectionTests {
    @Test func listenersFromCapturedNetstat() throws {
        let ports = try #require(SystemReport.listeningPorts(try fixture("netstat-anL-tcp-remote-login")))
        #expect(ports.contains(22))
        #expect(ports.contains(7868))
        // 8021 and the 5178x ports listen on loopback only: no other Mac can reach them.
        #expect(!ports.contains(8021))
        #expect(!ports.contains(51800))
        #expect(!ports.contains(5900))
        #expect(!ports.contains(445))
    }

    @Test func aFailedReadIsNotNothingListening() {
        #expect(SystemReport.listeningPorts("") == nil)
        #expect(SystemReport.listeningPorts("netstat: sysctl: net.inet.tcp.pcblist_n: Operation not permitted") == nil)
    }

    @Test func listenersDecideAndLaunchdIsTheFallback() throws {
        let netstat = SystemReport.listeningPorts(try fixture("netstat-anL-tcp-remote-login"))
        let launchd = try fixture("launchctl-print-disabled-system")
        // The launchd fixture was captured with Remote Login off; the listener says it is on now.
        #expect(SystemReport.sharingOn(.ssh, listening: netstat, printDisabled: launchd) == true)
        #expect(SystemReport.sharingOn(.screenSharing, listening: netstat, printDisabled: launchd) == false)
        #expect(SystemReport.sharingOn(.fileSharing, listening: netstat, printDisabled: launchd) == false)
        #expect(SystemReport.sharingOn(.ssh, listening: nil, printDisabled: launchd) == false)
        #expect(SystemReport.sharingOn(.ssh, listening: nil, printDisabled: #"    "com.openssh.sshd" => enabled"#) == true)
    }
}

@Suite struct PeerConnectAsTests {
    @Test func connectAsIsKeptWithThePeerAndClears() throws {
        let fingerprint = try #require(PeerFingerprint(bytes: Array(repeating: 7, count: 32)))
        var book = PeerBook()
        book.pairConfirmed(fingerprint, role: .host, details: PeerDetails(computerName: "mini"), at: Date())
        book.setConnectAs(fingerprint, "  admin ")
        #expect(book[fingerprint]?.connectAs == "admin")
        let decoded = try JSONDecoder().decode(PeerBook.self, from: JSONEncoder().encode(book))
        #expect(decoded[fingerprint]?.connectAs == "admin")
        book.setConnectAs(fingerprint, " ")
        #expect(book[fingerprint]?.connectAs == nil)
    }
}
