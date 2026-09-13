import Foundation
import Testing
@testable import FlotillaCore

/// Pins the registry vocabulary, the host shape, and the catalogue's rules.
///
/// The decoding half exists because of a near miss worth recording: `container registry list`
/// prints columns headed `HOSTNAME  USERNAME  MODIFIED  CREATED`, and the JSON calls those
/// fields `name`/`id`, `username`, `modificationDate`, `creationDate`. A decoder written from the
/// human-readable output would have compiled, run, decoded nothing, and shown an empty table to
/// someone with logins — the exact silent failure this project keeps finding. The fixture was
/// captured from the real CLI against a throwaway local registry.
@Suite("Registries")
struct RegistryTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Decoding

    @Test("a captured registry login decodes whole")
    func decodesFixture() throws {
        let logins = try JSONDecoder.flotilla.decode([RegistryLogin].self,
                                                     from: fixture("registries"))
        let login = try #require(logins.first)
        #expect(logins.count == 1)
        #expect(login.id == "localhost:5001")
        #expect(login.name == "localhost:5001")
        #expect(login.username == "fixture-user")
        #expect(login.creationDate == "2026-09-13T12:49:46Z")
        #expect(login.modificationDate == "2026-09-13T12:49:46Z")
    }

    /// `[]` is what the CLI returns for a Mac with no logins, which is the normal state for
    /// someone who only pulls public images. It must decode as "none", never fail.
    @Test("no logins is an empty list, not an error")
    func decodesEmpty() throws {
        let logins = try JSONDecoder.flotilla.decode([RegistryLogin].self, from: Data("[]".utf8))
        #expect(logins.isEmpty)
    }

    // MARK: The host shape

    /// The operand of `registry login` is the host a password is sent to, so everything that
    /// could make the destination ambiguous has to be refused.
    @Test("a registry host accepts real servers and refuses anything ambiguous")
    func hostShape() {
        for good in ["docker.io", "ghcr.io", "registry.example.com", "registry.example.com:5000",
                     "localhost", "localhost:5001", "127.0.0.1:5000", "public.ecr.aws",
                     "123456789012.dkr.ecr.eu-west-1.amazonaws.com", "my-registry.internal"] {
            #expect(Allowlist.accepts(good, as: .registryHost), Comment(rawValue: "refused \(good)"))
        }
        for bad in [
            "",                                  // nothing
            "https://ghcr.io",                   // a scheme: the shape is a host
            "ghcr.io/apple",                     // a repository path, not a server
            "user@ghcr.io",                      // credentials smuggled into the host
            "ghcr.io:0", "ghcr.io:70000",        // not a port
            "ghcr.io:", "ghcr.io:abc",           // not a port either
            ".ghcr.io", "ghcr.io.",              // empty label
            "gh..cr.io",                         // empty label in the middle
            "-ghcr.io", "ghcr-.io",              // label may not start or end with a hyphen
            "ghcr io",                           // a space
            "ghcr.io?x=1", "ghcr.io#f",          // query, fragment
            "dоcker.io",                         // Cyrillic о — reads identically, resolves elsewhere
        ] {
            #expect(!Allowlist.accepts(bad, as: .registryHost),
                    Comment(rawValue: "accepted \(bad)"))
        }
    }

    /// The shape is narrower than `.imageReference` on purpose — that one would take a whole
    /// repository path, which is what would let a login be pointed somewhere other than it says.
    @Test("an image reference is not a registry host")
    func hostIsNarrowerThanAReference() {
        #expect(Allowlist.accepts("ghcr.io/apple/x:latest", as: .imageReference))
        #expect(!Allowlist.accepts("ghcr.io/apple/x:latest", as: .registryHost))
    }

    /// `accepts` must refuse the shapes whose answer depends on a `MountPolicy`, rather than
    /// quietly evaluating them against the permissive default and returning a misleading yes.
    @Test("accepts refuses to judge host-path shapes")
    func acceptsRefusesPathShapes() {
        for shape in [ValueShape.mountSpec, .absolutePath, .copyEndpoint, .hostBuildPath] {
            #expect(!Allowlist.accepts("/tmp", as: shape))
        }
    }

    // MARK: The login command

    /// The whole security argument for this family in one test: the allowlist must have no way
    /// to put a password on the command line, because argv is readable by every process running
    /// as this user.
    @Test("registry login has no password flag and cannot grow one by accident")
    func loginNeverCarriesAPasswordInArgv() throws {
        let spec = try #require(Allowlist.commands.first { $0.name == "registry login" })
        for flag in spec.flags {
            let long = flag.long ?? ""
            #expect(!long.contains("password") || long == "password-stdin",
                    Comment(rawValue: "`--\(long)` could carry a secret in argv"))
            // A password flag could also arrive short-form. `-p` must not exist here either.
            #expect(flag.short != "p", Comment(rawValue: "`-p` on registry login"))
        }
        // And the obvious spelling is refused outright rather than ignored.
        #expect(throws: (any Error).self) {
            try Allowlist.validated(["registry", "login", "--password", "hunter2", "ghcr.io"])
        }
    }

    /// The credential store is the owner's, and so is the inventory of it.
    @Test("every registry command is local-only, with a stated reason")
    func registryFamilyIsLocalOnly() throws {
        for name in ["registry list", "registry login", "registry logout"] {
            let spec = try #require(Allowlist.commands.first { $0.name == name })
            guard case .localOnly(let reason) = spec.exposure else {
                Issue.record("\(name) is reachable over the wire"); continue
            }
            #expect(!reason.isEmpty)
            #expect(throws: (any Error).self) {
                try Allowlist.validated(spec.path + ["ghcr.io"], wirePolicy: .remotePeer)
            }
        }
    }

    // MARK: The catalogue

    /// The entry requirement for a built-in row: a single, real, account-independent hostname.
    /// A row whose host is a template would be a row that cannot be used.
    @Test("every built-in registry has a usable, unique host")
    func builtInCatalogue() {
        let hosts = KnownRegistry.builtIn.map(\.id)
        #expect(Set(hosts).count == hosts.count)
        for registry in KnownRegistry.builtIn {
            #expect(Allowlist.accepts(registry.id, as: .registryHost),
                    Comment(rawValue: "\(registry.id) is not a usable host"))
            #expect(!registry.isUserAdded)
            #expect(!registry.name.isEmpty)
            #expect(!registry.summary.isEmpty)
            // No placeholders. `<account>.dkr.ecr…` is what Add Registry… is for.
            #expect(!registry.id.contains("<"))
        }
        // Exactly one registry is what a host-less reference resolves to.
        #expect(KnownRegistry.builtIn.count { $0.isImplicitDefault } == 1)
        #expect(KnownRegistry.builtIn.first { $0.isImplicitDefault }?.id == "docker.io")
    }

    @Test("a host is normalised, checked and de-duplicated when added")
    func addingRegistries() throws {
        var book = RegistryBook()
        try book.add(host: "  Registry.Example.COM:5000 ", name: " Staging ")
        let added = try #require(book.userAdded.first)
        // Lowercased, because a hostname is case-insensitive and two rows for one registry is
        // one row that can never match what `registry list` reports.
        #expect(added.id == "registry.example.com:5000")
        #expect(added.name == "Staging")
        #expect(added.isUserAdded)

        #expect(throws: RegistryBook.RegistryError.duplicate("registry.example.com:5000")) {
            try book.add(host: "REGISTRY.EXAMPLE.COM:5000", name: "Again")
        }
        #expect(throws: RegistryBook.RegistryError.duplicate("ghcr.io")) {
            try book.add(host: "ghcr.io", name: "Mine")
        }
        #expect(throws: RegistryBook.RegistryError.invalidHost("https://x.example")) {
            try book.add(host: "https://x.example", name: "Bad")
        }
        #expect(throws: RegistryBook.RegistryError.emptyHost) {
            try book.add(host: "   ", name: "Nameless")
        }
    }

    /// A name is for recognising the row, and for a self-hosted registry the host *is* how you
    /// recognise it — so an omitted name is filled in rather than refused.
    @Test("an omitted name falls back to the host")
    func nameFallsBack() throws {
        var book = RegistryBook()
        try book.add(host: "registry.internal:5000", name: "")
        #expect(book.userAdded.first?.name == "registry.internal:5000")
    }

    @Test("a built-in registry cannot be removed, and says why")
    func removal() throws {
        var book = RegistryBook()
        try book.add(host: "registry.internal", name: "Mine")
        try book.remove(host: "registry.internal")
        #expect(book.userAdded.isEmpty)

        #expect(throws: RegistryBook.RegistryError.builtIn("docker.io")) {
            try book.remove(host: "docker.io")
        }
        #expect(throws: RegistryBook.RegistryError.notUserAdded("nothing.example")) {
            try book.remove(host: "nothing.example")
        }
    }

    /// The form must be able to ask the same question the executor will ask, or it is back to
    /// a button that refuses without saying why.
    @Test("the add form's problem text matches what would be thrown")
    func problemMatchesThrow() {
        let book = RegistryBook()
        #expect(book.problem(withHost: "ghcr.io")
                == RegistryBook.RegistryError.duplicate("ghcr.io").description)
        #expect(book.problem(withHost: "registry.internal") == nil)
        #expect(book.problem(withHost: "ghcr.io/apple") != nil)
    }
}
