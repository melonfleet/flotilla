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

    /// **This assertion was reversed on purpose**, and the old one is worth remembering: a
    /// built-in used to refuse removal outright, with `RegistryError.builtIn` to say why. That
    /// was defensible — a built-in is code, there is nothing to delete — and it was wrong for
    /// the person using it, because a list of ten registries where you use two is a list you
    /// stop reading. Built-ins are hidden now; see `hidingAndRestoring`.
    @Test("removing works on both kinds, and refuses a host that is neither")
    func removal() throws {
        var book = RegistryBook()
        try book.add(host: "registry.internal", name: "Mine")
        try book.remove(host: "registry.internal")
        #expect(book.userAdded.isEmpty)

        try book.remove(host: "docker.io")
        #expect(!book.all.contains { $0.id == "docker.io" })

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

/// The browser half of signing in.
///
/// `container registry login` takes a username and a password on stdin and nothing else — no
/// device code, no OAuth grant, no callback — so Flotilla cannot hand a sign-in to a browser and
/// get back a credential the runtime can use. What it can do is open the page where the token is
/// made, because on almost every registry the password *is* a token. These pin that the links and
/// the instructions exist exactly where they help and nowhere else.
@Suite("Registry credentials")
struct RegistryCredentialTests {

    /// A "Create a token…" button on a registry that needs no account would lead nowhere, and a
    /// registry that needs one with no link leaves you to go and find the page yourself.
    @Test("every registry that needs a credential says where to get one")
    func tokenPagesMatchTheNeed() {
        for registry in KnownRegistry.builtIn {
            if !registry.hasAccounts {
                // No account exists: a token page or a credential hint would both lead nowhere.
                #expect(registry.tokenURL == nil,
                        Comment(rawValue: "\(registry.id) has no accounts but offers a token page"))
                #expect(registry.credentialHint == nil,
                        Comment(rawValue: "\(registry.id) has no accounts but explains credentials"))
            } else if registry.anonymousPullWorks {
                // Public, but a sign-in exists — ECR Public raises your rate limit. It must say
                // what to type; a token page is optional because the credential is CLI-minted.
                #expect(registry.credentialHint != nil,
                        Comment(rawValue: "\(registry.id) takes a sign-in and does not say what to type"))
            } else {
                #expect(registry.tokenURL != nil,
                        Comment(rawValue: "\(registry.id) needs a credential and says nothing about where to get one"))
                #expect(registry.credentialHint != nil,
                        Comment(rawValue: "\(registry.id) needs a credential and does not say what to type"))
            }
        }
    }

    /// A malformed URL is a button that does nothing. These were each checked to resolve before
    /// they shipped; this checks they are at least parseable and https.
    @Test("every token page is a well-formed https URL")
    func tokenPagesAreWellFormed() throws {
        for registry in KnownRegistry.builtIn {
            guard let raw = registry.tokenURL else { continue }
            let url = try #require(URL(string: raw), Comment(rawValue: "unparseable: \(raw)"))
            #expect(url.scheme == "https", Comment(rawValue: "\(raw) is not https"))
            #expect(url.host != nil)
        }
    }

    /// The per-account registries can never be catalogue rows, so the host is the only thing
    /// available to recognise them by — and getting the region or registry name out of it is what
    /// makes the printed command copy-pasteable rather than a template.
    @Test("a cloud registry is recognised from its host and named in the instructions")
    func cloudHints() throws {
        let ecr = try #require(KnownRegistry.cloudCredentialHint(
            forHost: "123456789012.dkr.ecr.eu-west-1.amazonaws.com"))
        #expect(ecr.contains("--region eu-west-1"))
        #expect(ecr.contains("AWS"))

        let acr = try #require(KnownRegistry.cloudCredentialHint(forHost: "myteam.azurecr.io"))
        #expect(acr.contains("--name myteam"))

        let gar = try #require(KnownRegistry.cloudCredentialHint(
            forHost: "europe-west1-docker.pkg.dev"))
        #expect(gar.contains("oauth2accesstoken"))
        #expect(KnownRegistry.cloudCredentialHint(forHost: "gcr.io") != nil)

        // Everything else gets nothing rather than a guess.
        for host in ["ghcr.io", "docker.io", "registry.internal:5000", "example.amazonaws.com"] {
            #expect(KnownRegistry.cloudCredentialHint(forHost: host) == nil,
                    Comment(rawValue: "invented instructions for \(host)"))
        }
    }

    /// Host matching must be case-insensitive: a hostname is, and `RegistryBook` lowercases on
    /// the way in, but a login read back from the CLI has not been through that.
    @Test("cloud hints ignore host case")
    func cloudHintsIgnoreCase() {
        #expect(KnownRegistry.cloudCredentialHint(forHost: "MyTeam.AzureCR.io") != nil)
    }
}

/// `anonymousPullWorks` means "this registry has no private tier", not "public images are
/// anonymous" — which is true almost everywhere and would make the flag say nothing. Pinned
/// because the first version of the docstring claimed the wider rule.
extension RegistryCredentialTests {
    @Test("only registries with no private tier claim that no sign-in is needed")
    func publicOnlyRegistries() {
        let publicOnly = Set(KnownRegistry.builtIn.filter(\.anonymousPullWorks).map(\.id))
        #expect(publicOnly == ["mcr.microsoft.com", "public.ecr.aws", "registry.k8s.io",
                               "registry.access.redhat.com"])

        // A narrower set: registries with no account system *at all*. ECR Public is public and
        // still takes a sign-in (it raises your rate limit), which is why these are two flags
        // and not one. The rows in this set must offer no Sign In control.
        let noAccounts = Set(KnownRegistry.builtIn.filter { !$0.hasAccounts }.map(\.id))
        #expect(noAccounts == ["mcr.microsoft.com", "registry.k8s.io",
                               "registry.access.redhat.com"])

        // The registries with both tiers must say in their own words that public images need no
        // sign-in, because the status column cannot: for them "not signed in" is the truth.
        for id in ["docker.io", "ghcr.io", "quay.io", "registry.gitlab.com"] {
            let registry = KnownRegistry.builtIn.first { $0.id == id }
            let hint = registry?.credentialHint ?? ""
            #expect(hint.lowercased().contains("without signing in"),
                    Comment(rawValue: "\(id) never mentions that public images are anonymous"))
        }
    }

    /// GitHub's own documentation: selecting `write:packages` in the UI also selects `repo`,
    /// which is full control of private repositories. Flotilla has no `push` in its allowlist at
    /// all, so that scope buys nothing and costs a great deal.
    @Test("the GHCR hint warns about the scope GitHub adds behind your back")
    func ghcrScopeWarning() throws {
        let hint = try #require(KnownRegistry.builtIn.first { $0.id == "ghcr.io" }?.credentialHint)
        #expect(hint.contains("read:packages"))
        #expect(hint.contains("write:packages"))
        #expect(hint.contains("repo"))
    }
}

/// Docker Hub is stored under a different host than the one you sign in to, which produced a
/// visible bug: the Docker Hub row read "Not signed in" while a duplicate row appeared at the
/// bottom marked "not in your list", for the same account.
extension RegistryTests {
    @Test("Docker Hub's three spellings are one registry")
    func dockerHubAliases() {
        for spelling in ["docker.io", "registry-1.docker.io", "index.docker.io",
                         "REGISTRY-1.DOCKER.IO"] {
            #expect(KnownRegistry.canonicalHost(spelling) == "docker.io",
                    Comment(rawValue: "\(spelling) did not canonicalise"))
        }
    }

    /// Only Docker Hub. `gcr.io` and `us.gcr.io` are genuinely different registries and folding
    /// them would merge two real rows into one.
    @Test("nothing else is aliased")
    func nothingElseIsAliased() {
        for host in ["ghcr.io", "quay.io", "gcr.io", "us.gcr.io", "registry.k8s.io",
                     "localhost:5001", "myteam.azurecr.io"] {
            #expect(KnownRegistry.canonicalHost(host) == host.lowercased(),
                    Comment(rawValue: "\(host) was rewritten"))
        }
    }

    /// The catalogue lists `docker.io`, so a login filed under `registry-1.docker.io` has to
    /// land on that row rather than making a second one.
    @Test("a Docker Hub login matches the catalogue row")
    func dockerHubLoginMatchesItsRow() {
        let login = RegistryLogin(id: "registry-1.docker.io", name: "registry-1.docker.io",
                                  username: "someone")
        let dockerHub = KnownRegistry.builtIn.first { $0.id == "docker.io" }
        #expect(dockerHub != nil)
        #expect(KnownRegistry.canonicalHost(login.id)
                == KnownRegistry.canonicalHost(dockerHub?.id ?? ""))
    }
}

/// The account names real registries issue.
///
/// `--username` shipped as `.identifier`, and measured against this list that refused **half**
/// of them — Red Hat's pipe, Quay's plus, Harbor's dollar, Google's leading underscore, and any
/// email address. The Sign In form would have refused a valid account at the allowlist rather
/// than at the field, which is the worst place for it.
extension RegistryCredentialTests {
    @Test("every account name a real registry issues is accepted")
    func realUsernamesAreAccepted() {
        let names = [
            "12345678|flotilla",                        // Red Hat registry service account
            "myorg+buildbot",                           // Quay robot account
            "robot$ci", "robot$myproject+ci",           // Harbor robot accounts
            "00000000-0000-0000-0000-000000000000",     // Azure `az acr login` token
            "_json_key", "_json_key_base64",            // Google Artifact Registry key login
            "oauth2accesstoken",                        // Google access-token login
            "AWS",                                      // Amazon ECR
            "gitlab-ci-token",                          // GitLab CI
            "melonfleet",                               // an ordinary account
            "kamal@example.com",                        // registries that take an email
        ]
        for name in names {
            #expect(Allowlist.accepts(name, as: .registryUsername),
                    Comment(rawValue: "refused \(name)"))
        }
    }

    /// Widening the shape must not have widened what can change the command's meaning.
    @Test("a username still cannot look like a flag or carry structure")
    func usernameStaysNarrow() {
        for bad in ["--username", "-u", "has space", "a/b", "a:b", "a\"b", "a\\b", "", "a b"] {
            #expect(!Allowlist.accepts(bad, as: .registryUsername),
                    Comment(rawValue: "accepted \(bad)"))
        }
    }

    /// A registry username is the user's own identity and is often an email address, so it is
    /// classified free-form and the audit line redacts it — while the **registry**, which is what
    /// an auditor needs, stays visible as the operand.
    @Test("the audit line hides the account and keeps the registry")
    func auditRedactsTheAccountOnly() throws {
        let validated = try Allowlist.validated(
            ["registry", "login", "--username", "12345678|flotilla",
             "--password-stdin", "registry.redhat.io"])
        #expect(!validated.auditDescription.contains("12345678"))
        #expect(validated.auditDescription.contains("registry.redhat.io"))
        // And the argv actually sent is untouched.
        #expect(validated.arguments.contains("12345678|flotilla"))
    }
}

/// Completing an unqualified reference against the chosen registry — the behaviour that turns
/// `defaultRegistryDomain` from a stored value nothing read into a setting that does something.
@Suite("Image reference hosts")
struct ImageReferenceHostTests {

    /// The rule is not "does it contain a slash": `owner/app` is a Docker Hub reference with no
    /// host, and treating the first segment as one would make every namespaced image unpullable.
    @Test("a first segment is a host only when it looks like one")
    func hostDetection() {
        for withHost in ["ghcr.io/owner/app", "localhost:5000/app", "registry.example.com/x",
                         "192.168.1.5:5000/app", "quay.io/prometheus/busybox"] {
            #expect(ImageReferenceHost.hasRegistryHost(withHost),
                    Comment(rawValue: "missed the host in \(withHost)"))
        }
        for without in ["nginx", "nginx:alpine", "owner/app", "library/nginx:latest",
                        "myteam/app:1.2.3", "alpine@sha256:abc"] {
            #expect(!ImageReferenceHost.hasRegistryHost(without),
                    Comment(rawValue: "invented a host in \(without)"))
        }
    }

    /// Docker Hub is left entirely alone. The CLI completes `nginx` to
    /// `docker.io/library/nginx:latest` — including the `library/` namespace that only Docker Hub
    /// has — and prefixing `docker.io/nginx` ourselves would name an image that does not exist.
    @Test("Docker Hub references are never rewritten")
    func dockerHubIsLeftAlone() {
        for spelling in ["docker.io", "registry-1.docker.io", "index.docker.io"] {
            #expect(ImageReferenceHost.qualify("nginx", with: spelling) == "nginx")
            #expect(ImageReferenceHost.qualify("owner/app:1", with: spelling) == "owner/app:1")
        }
    }

    /// Everywhere else the prefix is exactly the host — no namespace insertion, because no other
    /// registry has Docker Hub's implicit one.
    @Test("another registry prefixes the host and nothing more")
    func otherRegistriesArePrefixed() {
        #expect(ImageReferenceHost.qualify("owner/app:1.2", with: "ghcr.io")
                == "ghcr.io/owner/app:1.2")
        #expect(ImageReferenceHost.qualify("app", with: "registry.internal:5000")
                == "registry.internal:5000/app")
        // Case-folded, like every other host in this app.
        #expect(ImageReferenceHost.qualify("app", with: "GHCR.IO") == "ghcr.io/app")
    }

    /// A reference that already names a registry is authoritative. Overriding it would silently
    /// pull a different image than the one written down.
    @Test("an explicit host always wins")
    func explicitHostWins() {
        #expect(ImageReferenceHost.qualify("quay.io/prometheus/busybox", with: "ghcr.io")
                == "quay.io/prometheus/busybox")
        #expect(ImageReferenceHost.qualify("localhost:5000/app", with: "ghcr.io")
                == "localhost:5000/app")
    }

    @Test("empty inputs change nothing")
    func emptyInputs() {
        #expect(ImageReferenceHost.qualify("", with: "ghcr.io") == "")
        #expect(ImageReferenceHost.qualify("nginx", with: "") == "nginx")
        #expect(ImageReferenceHost.resolvedHost("", default: "ghcr.io") == nil)
    }

    /// What the preview says the pull will actually contact.
    @Test("the resolved host is what will really be fetched from")
    func resolvedHost() {
        #expect(ImageReferenceHost.resolvedHost("nginx", default: "docker.io") == "docker.io")
        #expect(ImageReferenceHost.resolvedHost("nginx", default: "ghcr.io") == "ghcr.io")
        #expect(ImageReferenceHost.resolvedHost("quay.io/x/y", default: "ghcr.io") == "quay.io")
        // A host-less reference under a Docker Hub default still resolves to Docker Hub, even
        // though the string was not rewritten.
        #expect(ImageReferenceHost.resolvedHost("owner/app", default: "docker.io") == "docker.io")
    }

    /// Whatever `qualify` produces must be something the allowlist will actually accept, or the
    /// form would build a command the executor refuses.
    @Test("a qualified reference is still a valid image reference")
    func qualifiedReferencesStayValid() {
        for (reference, registry) in [("nginx", "ghcr.io"), ("owner/app:1.2", "ghcr.io"),
                                      ("app", "registry.internal:5000"), ("nginx", "docker.io")] {
            let qualified = ImageReferenceHost.qualify(reference, with: registry)
            #expect(Allowlist.accepts(qualified, as: .imageReference),
                    Comment(rawValue: "allowlist refuses \(qualified)"))
        }
    }
}

/// Removing and putting back.
///
/// A built-in is code, so it cannot be deleted — it is hidden, and Add offers it back by name.
/// The first version simply refused to remove one, which is defensible and was wrong for the
/// person using it: a list of ten registries where you use two is a list you stop reading.
extension RegistryTests {
    @Test("a built-in is hidden rather than deleted, and comes back")
    func hidingAndRestoring() throws {
        var book = RegistryBook()
        #expect(book.all.contains { $0.id == "quay.io" })
        #expect(book.restorable.isEmpty)

        try book.remove(host: "quay.io")
        #expect(!book.all.contains { $0.id == "quay.io" })
        #expect(book.restorable.map(\.id) == ["quay.io"])

        try book.restore(host: "quay.io")
        #expect(book.all.contains { $0.id == "quay.io" })
        #expect(book.restorable.isEmpty)
    }

    /// Typing a removed built-in's host is a sensible way to ask for it back, and must not
    /// create a user-added row that shadows the real one with worse guidance.
    @Test("adding a hidden built-in's host restores the built-in")
    func addingAHiddenHostRestoresIt() throws {
        var book = RegistryBook()
        try book.remove(host: "ghcr.io")
        let restored = try book.add(host: "GHCR.io", name: "My GitHub")
        #expect(!restored.isUserAdded)
        #expect(restored.name == "GitHub Container Registry")
        #expect(book.userAdded.isEmpty)
        #expect(book.restorable.isEmpty)
    }

    /// Docker Hub's three spellings are one registry here too — removing it by any of them
    /// hides the one row, and it does not come back under a second name.
    @Test("hiding follows the canonical host")
    func hidingIsCanonical() throws {
        var book = RegistryBook()
        try book.remove(host: "registry-1.docker.io")
        #expect(!book.all.contains { $0.id == "docker.io" })
        #expect(throws: RegistryBook.RegistryError.duplicate("ghcr.io")) {
            try book.add(host: "ghcr.io", name: "x")
        }
        try book.restore(host: "index.docker.io")
        #expect(book.all.contains { $0.id == "docker.io" })
    }

    @Test("a user's own registry is deleted, not hidden")
    func userAddedIsDeleted() throws {
        var book = RegistryBook()
        try book.add(host: "registry.internal:5000", name: "Mine")
        try book.remove(host: "registry.internal:5000")
        #expect(book.userAdded.isEmpty)
        // Not restorable — there is no built-in behind it, so it has to be typed again.
        #expect(book.restorable.isEmpty)
        #expect(throws: RegistryBook.RegistryError.notUserAdded("nothing.example")) {
            try book.remove(host: "nothing.example")
        }
    }

    /// Amazon's "Popular registries" panel lists Datadog, NGINX, Ubuntu, Python and the rest.
    /// Those are publishers **inside** `public.ecr.aws`, not registries, and must never become
    /// rows — proven by fetching their manifests from that one host. Chainguard is the exception
    /// and runs its own.
    @Test("Chainguard is a registry; the other ECR publishers are not")
    func chainguardIsItsOwnRegistry() {
        #expect(KnownRegistry.builtIn.contains { $0.id == "cgr.dev" })
        #expect(RegistryKind.inferred(fromHost: "cgr.dev") == .chainguard)
        for publisher in ["datadog", "nginx", "ubuntu", "python", "chainguard"] {
            #expect(!KnownRegistry.builtIn.contains { $0.id == publisher },
                    Comment(rawValue: "\(publisher) is a namespace, not a registry"))
        }
    }
}
