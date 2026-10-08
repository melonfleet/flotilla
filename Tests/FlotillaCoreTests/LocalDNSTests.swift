import Foundation
import Testing
@testable import FlotillaCore

// The DNS section (2026-10-06). The resolver-file text below is the runtime's own format, read
// from `/etc/resolver/containerization.flotilla` on this Mac after
// `sudo container system dns create flotilla`, and from `HostDNSResolver.swift` at tag 1.5.0 for
// the `--localhost` variant (port 1053, `options localhost:<ip>`).

@Suite("Local DNS")
struct LocalDNSTests {

    private let containerDomainFile = """
        domain flotilla
        search flotilla
        nameserver 127.0.0.1
        port 2053
        """

    private let hostAliasFile = """
        domain host.container.internal
        search host.container.internal
        nameserver 127.0.0.1
        port 1053
        options localhost:203.0.113.113
        """

    // MARK: Resolver files

    @Test("a container domain's resolver file parses")
    func parsesContainerDomain() throws {
        let file = try #require(DNSResolverFile.parse(containerDomainFile))
        #expect(file.domain == "flotilla")
        #expect(file.port == 2053)
        #expect(file.localhostAddress == nil)
    }

    @Test("a host alias carries its localhost address")
    func parsesHostAlias() throws {
        let file = try #require(DNSResolverFile.parse(hostAliasFile))
        #expect(file.domain == "host.container.internal")
        #expect(file.port == 1053)
        #expect(file.localhostAddress == "203.0.113.113")
    }

    @Test("a file with no domain line is not a domain")
    func rejectsForeignFile() {
        #expect(DNSResolverFile.parse("nameserver 10.0.0.1\n") == nil)
        #expect(DNSResolverFile.parse("") == nil)
    }

    @Test("only the runtime's filenames name a domain")
    func filenames() {
        #expect(DNSResolverFile.domain(fromFilename: "containerization.flotilla") == "flotilla")
        #expect(DNSResolverFile.domain(fromFilename: "containerization.") == nil)
        // Another tool's resolver file in /etc/resolver is none of Flotilla's business.
        #expect(DNSResolverFile.domain(fromFilename: "tailscale.ts.net") == nil)
    }

    // MARK: Rows

    @Test("rows combine the list, the resolver files and the container domain")
    func rows() throws {
        let files = [try #require(DNSResolverFile.parse(containerDomainFile)),
                     try #require(DNSResolverFile.parse(hostAliasFile))]
        let rows = LocalDNS.domains(listed: ["flotilla", "host.container.internal", "half"],
                                    resolverFiles: files, containerDomain: "flotilla")
        #expect(rows.map(\.name) == ["flotilla", "half", "host.container.internal"])

        let flotilla = rows[0]
        #expect(flotilla.registersContainers)
        #expect(flotilla.resolverInstalled)
        #expect(flotilla.containerAddress(for: "web") == "web.flotilla")

        // Listed by the runtime but with no resolver file: half set up, and shown as such.
        #expect(!rows[1].resolverInstalled)

        let alias = rows[2]
        #expect(alias.hostAliasAddress == "203.0.113.113")
        #expect(alias.containerAddress(for: "web") == nil)
    }

    @Test("a host alias never registers containers, even if config names it")
    func aliasNeverRegisters() throws {
        let file = try #require(DNSResolverFile.parse(hostAliasFile))
        let rows = LocalDNS.domains(listed: [], resolverFiles: [file],
                                    containerDomain: "host.container.internal")
        #expect(rows.first?.registersContainers == false)
    }

    // MARK: config.toml

    @Test("the dns domain is read from its own table only")
    func readsDomain() {
        #expect(ContainerConfigFile.dnsDomain(in: "[dns]\ndomain = \"flotilla\"\n") == "flotilla")
        #expect(ContainerConfigFile.dnsDomain(in: "[dns]\ndomain='test' # comment\n") == "test")
        // A `domain` key in another table is not the DNS domain.
        #expect(ContainerConfigFile.dnsDomain(in: "[registry]\ndomain = \"docker.io\"\n") == nil)
        #expect(ContainerConfigFile.dnsDomain(in: "") == nil)
    }

    @Test("setting the domain on an empty file adds the table")
    func setsOnEmptyFile() {
        #expect(ContainerConfigFile.setting(dnsDomain: "flotilla", in: "")
                == "[dns]\ndomain = \"flotilla\"\n")
    }

    @Test("setting the domain keeps every other line exactly")
    func preservesOtherContent() {
        let original = """
            # container settings
            [registry]
            domain = "docker.io"

            [dns]
            domain = "test"   # was test
            other = 1

            [kernel]
            path = "/x"
            """ + "\n"
        let changed = ContainerConfigFile.setting(dnsDomain: "flotilla", in: original)
        #expect(changed == original.replacingOccurrences(of: "domain = \"test\"   # was test",
                                                         with: "domain = \"flotilla\""))
        #expect(ContainerConfigFile.dnsDomain(in: changed) == "flotilla")
        // The registry table's own `domain` is untouched.
        #expect(changed.contains("[registry]\ndomain = \"docker.io\""))
    }

    @Test("a dns table without the key gets the key, before the blank line")
    func addsKeyToExistingTable() {
        let original = "[dns]\nother = 1\n\n[kernel]\npath = \"/x\"\n"
        let changed = ContainerConfigFile.setting(dnsDomain: "flotilla", in: original)
        #expect(changed == "[dns]\nother = 1\ndomain = \"flotilla\"\n\n[kernel]\npath = \"/x\"\n")
    }

    @Test("a file with other tables gets a dns table at the end")
    func appendsTable() {
        let changed = ContainerConfigFile.setting(dnsDomain: "flotilla", in: "[kernel]\npath = \"/x\"\n")
        #expect(changed == "[kernel]\npath = \"/x\"\n\n[dns]\ndomain = \"flotilla\"\n")
    }

    @Test("clearing the domain removes only that line")
    func clearsDomain() {
        let changed = ContainerConfigFile.setting(dnsDomain: nil,
                                                  in: "[dns]\ndomain = \"flotilla\"\nother = 1\n")
        #expect(changed == "[dns]\nother = 1\n")
        #expect(ContainerConfigFile.dnsDomain(in: changed) == nil)
    }

    // MARK: Allowlist

    @Test("dns create and delete take a domain and nothing else")
    func allowlistShapes() {
        func ok(_ args: [String]) -> Bool {
            if case .success = Allowlist.validate(args) { true } else { false }
        }
        #expect(ok(["system", "dns", "list", "--format", "json"]))
        #expect(ok(["system", "dns", "create", "flotilla"]))
        #expect(ok(["system", "dns", "create", "--localhost", "203.0.113.113", "host.container.internal"]))
        #expect(ok(["system", "dns", "delete", "flotilla"]))
        // Refused: uppercase, a trailing dot, an address as a domain, a shell metacharacter,
        // an IPv6 or malformed localhost, and two domains at once.
        #expect(!ok(["system", "dns", "create", "Flotilla"]))
        #expect(!ok(["system", "dns", "create", "flotilla."]))
        #expect(!ok(["system", "dns", "create", "10.0.0.1"]))
        #expect(!ok(["system", "dns", "create", "a;rm -rf ~"]))
        #expect(!ok(["system", "dns", "create", "--localhost", "::1", "x"]))
        #expect(!ok(["system", "dns", "create", "--localhost", "999.0.0.1", "x"]))
        #expect(!ok(["system", "dns", "delete", "a", "b"]))
    }

    @Test("only a root-controlled binary in a root-controlled directory runs as administrator")
    func adminExecutable() {
        let dir = AdminExecutable.Facts(ownerUID: 0, permissions: 0o755, kind: .directory)
        let file = AdminExecutable.Facts(ownerUID: 0, permissions: 0o755, kind: .file)
        #expect(AdminExecutable.problem(file: file, directory: dir) == nil)
        // The file owned by the user, or writable by group or others.
        #expect(AdminExecutable.problem(file: .init(ownerUID: 501, permissions: 0o755, kind: .file),
                                        directory: dir) != nil)
        #expect(AdminExecutable.problem(file: .init(ownerUID: 0, permissions: 0o775, kind: .file),
                                        directory: dir) != nil)
        #expect(AdminExecutable.problem(file: .init(ownerUID: 0, permissions: 0o757, kind: .file),
                                        directory: dir) != nil)
        // A symlink is not followed, and a missing file is refused.
        #expect(AdminExecutable.problem(file: .init(ownerUID: 0, permissions: 0o755, kind: .other),
                                        directory: dir) != nil)
        #expect(AdminExecutable.problem(file: nil, directory: dir) != nil)
        // A directory the user can write: the file could be swapped after the check.
        #expect(AdminExecutable.problem(file: file,
                                        directory: .init(ownerUID: 501, permissions: 0o755,
                                                         kind: .directory)) != nil)
        #expect(AdminExecutable.problem(file: file,
                                        directory: .init(ownerUID: 0, permissions: 0o777,
                                                         kind: .directory)) != nil)
    }

    @Test("the configured domain is a row even before macOS can resolve it")
    func configuredDomainWithoutResolver() {
        let rows = LocalDNS.domains(listed: [], resolverFiles: [], containerDomain: "flotilla")
        #expect(rows.count == 1)
        #expect(rows.first?.registersContainers == true)
        #expect(rows.first?.resolverInstalled == false)
    }

    @Test("the create and delete builders validate before anything runs")
    func builders() {
        #expect((try? ContainerCLI.dnsCreateCommand(domain: "flotilla").get().arguments)
                == ["system", "dns", "create", "flotilla"])
        #expect((try? ContainerCLI.dnsCreateCommand(domain: "host.container.internal",
                                                    localhost: "203.0.113.113").get().arguments)
                == ["system", "dns", "create", "--localhost", "203.0.113.113", "host.container.internal"])
        #expect((try? ContainerCLI.dnsCreateCommand(domain: "bad domain").get()) == nil)
        #expect((try? ContainerCLI.dnsDeleteCommand(domain: "flotilla").get().arguments)
                == ["system", "dns", "delete", "flotilla"])
    }

    @Test("the administrator script quotes for the shell, then for AppleScript")
    func adminScript() throws {
        let create = try ContainerCLI.dnsCreateCommand(domain: "flotilla").get()
        let delete = try ContainerCLI.dnsDeleteCommand(domain: "old").get()
        #expect(AdminScript.shellLine([create])
                == "'/usr/local/bin/container' 'system' 'dns' 'create' 'flotilla'")
        // Two commands, one prompt, stopping at the first failure.
        #expect(AdminScript.shellLine([create, delete]).contains("'flotilla' && '/usr/local/bin/container'"))
        #expect(AdminScript.source([create], prompt: "Say \"hi\"")
                == #"do shell script "'/usr/local/bin/container' 'system' 'dns' 'create' 'flotilla'" "#
                   + #"with prompt "Say \"hi\"" with administrator privileges"#)
        // The layers themselves, on input the Allowlist would never pass.
        #expect(AdminScript.shellQuoted("a'b") == #"'a'\''b'"#)
        #expect(AdminScript.appleScriptString(#"a\"b"#) == #""a\\\"b""#)
        #expect(AdminScript.displayLine(create) == "sudo container system dns create flotilla")
    }

    @Test(".local is refused: macOS keeps it for Bonjour")
    func localIsReserved() {
        #expect(LocalDNS.reservedProblem("local") != nil)
        #expect(LocalDNS.reservedProblem("shop.local") != nil)
        #expect(LocalDNS.reservedProblem("test") == nil)
        #expect(LocalDNS.reservedProblem("localhost.test") == nil)
        #expect(LocalDNS.reservedProblem("notlocal") == nil)
    }

    @Test("dns create and delete are refused to a remote peer")
    func localOnly() {
        guard case .failure(.notExposedToWire) = Allowlist.validate(
            ["system", "dns", "create", "flotilla"], wirePolicy: .remotePeer) else {
            Issue.record("dns create must be local-only"); return
        }
    }
}
