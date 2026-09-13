import Foundation

/// One registry this Mac holds credentials for, as `container registry list --format json`
/// reports it.
///
/// **The field names came from the real CLI, not from the table header.** `container registry
/// list` prints columns headed `HOSTNAME  USERNAME  MODIFIED  CREATED`, and the JSON calls them
/// `name`/`id`, `username`, `modificationDate`, `creationDate` — so a decoder written from the
/// human-readable output would have decoded nothing and shown an empty table on a Mac with
/// logins in it. Captured to `Fixtures/registries.json` on 2026-09-13 against 1.4.1, from a
/// throwaway local registry, which is the only way to see a populated one.
public struct RegistryLogin: Codable, Sendable, Equatable, Identifiable {
    /// The server, `host[:port]`. `id` and `name` are the same string in every observed record;
    /// `id` is kept as the identity because that is what the other list commands use.
    public let id: String
    public let name: String
    public let username: String?
    public let creationDate: String?
    public let modificationDate: String?
    public let labels: [String: String]?

    public init(id: String, name: String, username: String? = nil,
                creationDate: String? = nil, modificationDate: String? = nil,
                labels: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.labels = labels
    }
}

/// A registry the Registries screen offers by name.
///
/// **This is a catalogue, not a capability list, and the distinction is the whole design.**
/// Apple's `container` has no notion of a supported registry: it will pull from anything that
/// speaks the OCI distribution API, and the only thing that decides where an image comes from is
/// the reference you write — `ghcr.io/apple/container-builder-shim/builder:0.13.1` is already in
/// the user's own config. So this list cannot be, and must never claim to be, "the registries
/// that work". It is the list you do not have to remember the hostname of.
///
/// That is why there are no rows for Amazon ECR, Azure Container Registry, Google Artifact
/// Registry or Harbor, all of which are entirely usable: their hostnames are **per account** —
/// `<account>.dkr.ecr.<region>.amazonaws.com` — so a built-in row for them would be a row whose
/// host cannot be used, which is a placeholder control. They are what **Add Registry…** is for,
/// and the form's help names their shapes.
public struct KnownRegistry: Sendable, Equatable, Identifiable, Codable {
    /// The server, and the identity. Two registries cannot share a host.
    public let id: String
    /// What people call it: "GitHub Container Registry", not `ghcr.io`.
    public let name: String
    /// One line on what it is for, shown under the name.
    public let summary: String
    /// Whether this registry hosts **only** public content, so there is never anything to sign
    /// in for.
    ///
    /// The first wording of this was "whether pulling public images needs no credentials", and
    /// that is a different and much wider claim — GitHub's own documentation says "you can also
    /// access public container images anonymously", and an anonymous token fetch against
    /// `ghcr.io/apple/container-builder-shim` returns the manifest with a 200. By that rule
    /// almost every registry here would qualify and the flag would say nothing.
    ///
    /// What it actually marks is registries with no private tier at all: Microsoft's, ECR
    /// **Public**, and Kubernetes'. Those get "No sign-in needed" in the status column, which is
    /// a different fact from "not signed in" — showing the latter would send someone looking for
    /// an account that does not exist. Where a registry has both tiers, the sign-in sheet says
    /// so in its own words instead.
    public let anonymousPullWorks: Bool
    /// True for the one registry a bare `alpine:latest` resolves to.
    public let isImplicitDefault: Bool
    /// Whether this registry has accounts to sign in to **at all**.
    ///
    /// Orthogonal to `anonymousPullWorks`, and the two together are what the research made
    /// necessary. Microsoft's registry and `registry.k8s.io` have no sign-in of any kind — there
    /// is no account, no token page, no credential. Offering "Sign In…" on those is a control
    /// that cannot work, which is precisely what this app keeps deleting.
    ///
    /// Amazon ECR **Public** is the case that forced the second flag: it is public-only *and*
    /// has a sign-in, because authenticating raises your pull rate limit. So "public" and
    /// "no account exists" are not the same fact and cannot share a boolean.
    public let hasAccounts: Bool

    /// Whether the user added this themselves, as opposed to it being in the built-in catalogue.
    public let isUserAdded: Bool

    /// Which family this registry belongs to. The credential guidance and the token link come
    /// from here rather than being repeated per row — a self-hosted Harbor and the Harbor in
    /// somebody's catalogue authenticate identically, and two copies of that text would drift.
    public let kind: RegistryKind

    /// Whether this registry is reached over plain HTTP.
    ///
    /// **Remembered per registry, unlike the Pull form's one-off switch**, and the difference is
    /// deliberate. That one resets every time because choosing plaintext for a public registry
    /// by accident is the failure worth preventing. This one is a property *of a specific
    /// registry the user added*: a development registry with no TLS today will not have any
    /// tomorrow, and making someone re-assert it on every sign-in is how they stop reading the
    /// warning. Built-in registries are all HTTPS and cannot set it.
    public let usesHTTP: Bool

    /// Where, in a browser, you create the token this registry wants as a password.
    ///
    /// **This is as close to a browser sign-in as the runtime allows**, and it is worth being
    /// exact about why. `container registry login` takes a username and a password on stdin and
    /// nothing else — no device code, no OAuth grant, no callback (checked against the binary and
    /// the leaf help on 1.4.1). The OCI distribution spec has no interactive grant either; its
    /// auth is a bearer token fetched with HTTP Basic. So a browser flow that ended in a working
    /// `container` credential is not something Flotilla can build.
    ///
    /// What *is* true, and what the owner's question was really about, is that on almost every
    /// registry here the thing you type is **not your account password** — it is a token you
    /// create in a browser. Taking you to that page is the useful half, and the sign-in sheet
    /// does exactly that.
    ///
    /// `nil` where no such page exists: the anonymous registries need no credential at all, and
    /// a "Create a token…" button on one would be a control that leads nowhere.
    ///
    /// Every URL here was checked to resolve before it shipped. The ones that answer `302` do so
    /// by redirecting to *their own* sign-in with a `returnTo` back to the same path, which is
    /// what proves the path exists.
    private let ownTokenURL: String?
    /// The family's token page, unless this row names its own — and **nothing at all** when
    /// this registry has no accounts.
    ///
    /// That last guard is not belt-and-braces: `registry.access.redhat.com` has no sign-in and
    /// is nonetheless of kind `.redHat`, so without it the row inherited Red Hat's service-account
    /// page and would have offered "Create a token…" for a registry that takes no credential.
    /// Caught by the test that pins the two sets against each other.
    public var tokenURL: String? { hasAccounts ? (ownTokenURL ?? kind.tokenURL) : nil }

    /// Where to browse or search this registry's images, if it has such a page.
    ///
    /// Backs the Pull form's browse link, which the owner asked to follow the chosen registry
    /// rather than always saying "Browse Docker Hub". `nil` where no such page exists —
    /// `registry.k8s.io` genuinely has none, only a repository README.
    public let browseURL: String?

    /// What to put in the two fields. Defaults to the family's wording — see `RegistryKind` —
    /// and is overridden only where a specific host differs from its family.
    ///
    /// **Plain prose, no backticks and no asterisks.** These reach the view as a `String`
    /// variable, and SwiftUI's `Text` parses Markdown only in a string *literal* — so the syntax
    /// renders on screen as literal punctuation. Measured on the Registries pane, whose footer
    /// showed `**any**` and the backticks verbatim; the same trap the Logs display popover fell
    /// into. A command that needs to stand out is separated by a blank line, and the view renders
    /// that tail monospaced. Shown in the sign-in sheet,
    /// because "username and password" is wrong for most of them — GHCR wants a GitHub username
    /// and a `read:packages` token, and someone typing their GitHub password will simply fail.
    private let ownCredentialHint: String?
    /// The family's wording, unless this row names its own. Nil where there is no account —
    /// see `tokenURL`.
    public var credentialHint: String? {
        hasAccounts ? (ownCredentialHint ?? kind.credentialHint) : nil
    }

    public init(id: String, name: String, summary: String,
                anonymousPullWorks: Bool = false,
                hasAccounts: Bool = true,
                isImplicitDefault: Bool = false,
                isUserAdded: Bool = false,
                kind: RegistryKind? = nil,
                usesHTTP: Bool = false,
                tokenURL: String? = nil,
                browseURL: String? = nil,
                credentialHint: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.anonymousPullWorks = anonymousPullWorks
        self.hasAccounts = hasAccounts
        self.isImplicitDefault = isImplicitDefault
        self.isUserAdded = isUserAdded
        // Inferred from the host when the caller does not say, so a registry restored from a
        // plist written before kinds existed still gets the right guidance.
        self.kind = kind ?? RegistryKind.inferred(fromHost: id)
        self.usesHTTP = usesHTTP
        self.ownTokenURL = tokenURL
        self.browseURL = browseURL
        self.ownCredentialHint = credentialHint
    }

    /// The registries offered out of the box.
    ///
    /// Every one has a **single, real, account-independent hostname** — that is the entry
    /// requirement, for the reason the type's own note gives. Ordered by how often they turn up
    /// rather than alphabetically, with the implicit default first because it is the one that
    /// answers "where did `alpine:latest` come from".
    public static let builtIn: [KnownRegistry] = [
        KnownRegistry(id: "docker.io", name: "Docker Hub",
                      summary: "Where an image reference with no host comes from, such as `alpine:latest`.",
                      isImplicitDefault: true,
                      // Straight to the create form, not the list. Verified to exist (302 to
                      // Docker's own login with a returnTo back to this path).
                      tokenURL: "https://app.docker.com/settings/personal-access-tokens/create",
                      browseURL: "https://hub.docker.com/search"),
        KnownRegistry(id: "ghcr.io", name: "GitHub Container Registry",
                      summary: "Images published from GitHub repositories. Apple's own builder image lives here.",
                      // The `scopes` and `description` parameters pre-fill GitHub's own form, so
                      // the page opens with the right scope already ticked.
                      tokenURL: "https://github.com/settings/tokens/new?scopes=read:packages&description=Flotilla",
                      browseURL: "https://github.com/search?type=registrypackages"),
        KnownRegistry(id: "quay.io", name: "Quay",
                      summary: "Red Hat's public registry.",
                      tokenURL: "https://docs.quay.io/glossary/robot-accounts.html",
                      browseURL: "https://quay.io/search"),
        // No accounts at all: Microsoft's public distribution endpoint. Measured — `/v2/`
        // answers 200 rather than 401, so there is not even a token step. Do not confuse it
        // with Azure Container Registry, which is a different product on a different host.
        KnownRegistry(id: "mcr.microsoft.com", name: "Microsoft Artifact Registry",
                      summary: "Microsoft's official images. There is no account and no sign-in.",
                      anonymousPullWorks: true, hasAccounts: false,
                      browseURL: "https://mcr.microsoft.com/en-us/catalog"),
        // Public-only **and** has a sign-in: authenticating raises the pull rate limit. This is
        // the row that proved `anonymousPullWorks` and `hasAccounts` are different questions.
        KnownRegistry(id: "public.ecr.aws", name: "Amazon ECR Public",
                      summary: "Amazon's public gallery. Private ECR is per-account — add it below.",
                      anonymousPullWorks: true,
                      browseURL: "https://gallery.ecr.aws/"),
        KnownRegistry(id: "registry.k8s.io", name: "Kubernetes",
                      summary: "Official Kubernetes images. There is no account and no sign-in.",
                      anonymousPullWorks: true, hasAccounts: false),
        // Chainguard's **own** registry, and the one real addition from Amazon's "Popular
        // registries" panel — everything else on it (Datadog, NGINX, Ubuntu, Python, Lambda…)
        // is a publisher *inside* `public.ecr.aws`, which is already a row. Proven: an anonymous
        // manifest fetch for `chainguard/static` returns 200 on both hosts.
        KnownRegistry(id: "cgr.dev", name: "Chainguard",
                      summary: "Minimal, low-CVE base images. The free tier is public; the "
                        + "rest needs a Chainguard account.",
                      browseURL: "https://images.chainguard.dev/"),
        KnownRegistry(id: "registry.gitlab.com", name: "GitLab Container Registry",
                      summary: "Images published from GitLab projects.",
                      // The `legacy/new` form takes a `scopes` parameter, so this opens with
                      // `read_registry` already ticked — the same trick as the GitHub link.
                      tokenURL: "https://gitlab.com/-/user_settings/personal_access_tokens/legacy/new?scopes=read_registry",
                      browseURL: "https://gitlab.com/explore/projects"),
        KnownRegistry(id: "registry.redhat.io", name: "Red Hat Registry",
                      summary: "Red Hat's authenticated registry; needs a Red Hat account.",
                      tokenURL: "https://access.redhat.com/terms-based-registry/",
                      browseURL: "https://catalog.redhat.com/en/software/containers/explore",
                      credentialHint: "A registry service account — its username looks like "
                        + "12345678|name, and its token is the password. Everything here is "
                        + "behind a subscription; registry.access.redhat.com carries the "
                        + "unauthenticated images."),
        // Red Hat's **unauthenticated** sibling, and a genuinely separate host and credential.
        // Measured: an anonymous manifest fetch for `ubi9/ubi` returns 200, where the same
        // request to `registry.redhat.io` returns 401. Worth a row precisely because someone
        // who cannot get a Red Hat subscription can still pull the UBI images from here.
        KnownRegistry(id: "registry.access.redhat.com", name: "Red Hat (no sign-in)",
                      summary: "Red Hat's freely available images, including UBI. No account.",
                      anonymousPullWorks: true, hasAccounts: false),
    ]

    /// The host a registry's credential is actually **stored** under, which is not always the
    /// host you signed in to.
    ///
    /// **Measured, after it produced a visible bug.** Signing in to `docker.io` through this app
    /// put a row in `container registry list` under `registry-1.docker.io` — Docker Hub's real
    /// endpoint, which the CLI resolves `docker.io` to before storing. Matching logins to
    /// catalogue rows by exact string then did the obvious wrong thing: the Docker Hub row kept
    /// saying "Not signed in" while a second row appeared at the bottom marked "not in your
    /// list", for the same account, on the same registry. GHCR has no such rewrite, which is why
    /// it looked right and Docker Hub did not.
    ///
    /// `index.docker.io` is included because it is the third spelling of the same registry — it
    /// is what Docker's own credential store uses — and a user who signed in from a terminal may
    /// have it. Nothing else is aliased: `us.gcr.io` and `gcr.io` are genuinely different hosts
    /// and folding them would merge two real registries into one row.
    public static func canonicalHost(_ host: String) -> String {
        let host = host.lowercased()
        switch host {
        case "registry-1.docker.io", "index.docker.io", "docker.io":
            return "docker.io"
        default:
            return host
        }
    }

    /// How a registry whose credential comes from a **cloud CLI** is authenticated.
    ///
    /// Amazon ECR, Azure Container Registry and Google Artifact Registry do have browser sign-in
    /// — through `aws`, `az` and `gcloud`, against the vendor's own identity system, not against
    /// the registry. What comes out the other end is a short-lived token, and that token is what
    /// goes in the password field here. A username-and-password form for these is not wrong so
    /// much as incomplete, so the sheet prints the command that produces the password.
    ///
    /// Matched on the host, because these are the per-account registries that can never be
    /// catalogue rows. Returns nil for everything else rather than guessing.
    public static func cloudCredentialHint(forHost host: String) -> String? {
        let host = host.lowercased()
        if host.hasSuffix(".amazonaws.com"), host.contains(".dkr.ecr.") {
            let region = host.split(separator: ".").dropFirst(3).first.map(String.init) ?? "<region>"
            return "Amazon ECR issues a short-lived token. The username is AWS; for the password "
                + "run:\n\naws ecr get-login-password --region \(region)"
        }
        if host.hasSuffix(".azurecr.io") {
            let name = host.split(separator: ".").first.map(String.init) ?? "<registry>"
            return "Azure issues a short-lived token. Run:\n\n"
                + "az acr login --name \(name) --expose-token\n\n"
                + "Use 00000000-0000-0000-0000-000000000000 as the username and the "
                + "accessToken it prints as the password."
        }
        if host.hasSuffix("-docker.pkg.dev") || host == "gcr.io" || host.hasSuffix(".gcr.io") {
            return "Google issues a short-lived token. The username is oauth2accesstoken; for the "
                + "password run:\n\ngcloud auth print-access-token"
        }
        return nil
    }
}

/// The catalogue: the built-in registries plus whatever the user has added.
///
/// Pure, in the core, and tested, for the reason `TagBook` gives — the app target has no test
/// target, and "may a user add a host that is already built in" is not a question to answer by
/// trying it.
public struct RegistryBook: Sendable, Equatable {
    /// Registries the user added themselves, in the order they added them.
    public private(set) var userAdded: [KnownRegistry]

    /// Built-in registries the user has removed from the list.
    ///
    /// **Hidden rather than deleted, because a built-in is code and cannot be deleted.** The
    /// first version simply refused to remove one, which is defensible and was wrong for the
    /// person using it: a list of nine registries where you use two is a list you stop reading.
    /// So Remove hides, Add restores, and the set of hidden ones is exactly what the Add form
    /// offers back — which is also what finally made that picker's contents meaningful.
    ///
    /// Stored as hosts rather than indices so a future reordering of the catalogue cannot
    /// silently hide a different registry than the one that was removed.
    public private(set) var hidden: Set<String>

    public init(userAdded: [KnownRegistry] = [], hidden: Set<String> = []) {
        self.userAdded = userAdded
        self.hidden = hidden
    }

    /// Everything the screen lists, built-ins first and minus whatever was removed.
    public var all: [KnownRegistry] {
        KnownRegistry.builtIn.filter { !hidden.contains(KnownRegistry.canonicalHost($0.id)) }
            + userAdded
    }

    /// Built-ins the user has removed, in catalogue order — what Add offers to put back.
    public var restorable: [KnownRegistry] {
        KnownRegistry.builtIn.filter { hidden.contains(KnownRegistry.canonicalHost($0.id)) }
    }

    public func registry(id: String) -> KnownRegistry? { all.first { $0.id == id } }

    public enum RegistryError: Error, Equatable, CustomStringConvertible {
        case emptyHost
        case invalidHost(String)
        case duplicate(String)
        case notUserAdded(String)
        case emptyName

        public var description: String {
            switch self {
            case .emptyHost:
                "Enter the registry's server name."
            case .invalidHost(let host):
                "‘\(host)’ isn’t a registry server. " + ValueShape.registryHost.rule
            case .duplicate(let host):
                "‘\(host)’ is already in the list."
            case .notUserAdded(let host):
                "‘\(host)’ isn’t one of your own registries."
            case .emptyName:
                "Give the registry a name, so you can recognise it in the list."
            }
        }
    }

    /// Validates a proposed host without throwing, so the Add form can say why it is refusing
    /// **before** the button is pressed — this app's standing rule after the network form.
    public func problem(withHost raw: String) -> String? {
        do { _ = try normalised(host: raw); return nil }
        catch let error as RegistryError { return error.description }
        catch { return String(describing: error) }
    }

    /// Trims, lowercases and checks a host.
    ///
    /// Lowercased because a hostname is case-insensitive and the credential store is not
    /// obviously so: `GHCR.io` and `ghcr.io` as two rows would be two rows for one registry, one
    /// of which would never match what `registry list` reports.
    ///
    /// The shape check is `Allowlist`'s own, not a second copy of it. A host this accepts but
    /// the allowlist refuses would be a row whose Sign In button is guaranteed to fail, which is
    /// the "refuses without saying why" shape this app keeps removing.
    private func normalised(host raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { throw RegistryError.emptyHost }
        guard Allowlist.accepts(host, as: .registryHost) else {
            throw RegistryError.invalidHost(host)
        }
        // Against the **visible** list. A built-in the user removed is not a duplicate — typing
        // its host is a perfectly sensible way to ask for it back, and `add` restores it.
        guard !all.contains(where: {
            KnownRegistry.canonicalHost($0.id) == KnownRegistry.canonicalHost(host)
        }) else { throw RegistryError.duplicate(host) }
        return host
    }

    @discardableResult
    public mutating func add(host rawHost: String, name rawName: String,
                             summary: String = "",
                             kind: RegistryKind? = nil,
                             usesHTTP: Bool = false) throws -> KnownRegistry {
        // Typing the host of a removed built-in puts the built-in back, rather than creating a
        // user-added row that shadows it with worse guidance.
        let canonical = KnownRegistry.canonicalHost(
            rawHost.trimmingCharacters(in: .whitespacesAndNewlines))
        if hidden.contains(canonical),
           let builtIn = KnownRegistry.builtIn.first(where: {
               KnownRegistry.canonicalHost($0.id) == canonical
           }) {
            hidden.remove(canonical)
            return builtIn
        }
        let host = try normalised(host: rawHost)
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Falls back to the host rather than refusing: the name is for recognising the row, and
        // for a self-hosted registry the host *is* how you recognise it. Only a name that is
        // nothing but whitespace when one was typed is an error.
        let name = trimmed.isEmpty ? host : trimmed
        let registry = KnownRegistry(id: host, name: name,
                                     summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                     isUserAdded: true, kind: kind, usesHTTP: usesHTTP)
        userAdded.append(registry)
        return registry
    }

    /// Removes a registry from the list.
    ///
    /// **Does not sign out.** Removing a row and destroying a credential are different
    /// decisions, and doing both behind one button is how someone loses a login they meant to
    /// keep. The screen offers Sign Out separately, and a removed registry that still has a
    /// login reappears in the table — as a login, which is the truth.
    ///
    /// A built-in is hidden; one of the user's own is deleted. Both come back the same way,
    /// through Add.
    public mutating func remove(host rawHost: String) throws {
        let host = KnownRegistry.canonicalHost(rawHost)
        if userAdded.contains(where: { KnownRegistry.canonicalHost($0.id) == host }) {
            userAdded.removeAll { KnownRegistry.canonicalHost($0.id) == host }
            return
        }
        guard KnownRegistry.builtIn.contains(where: { KnownRegistry.canonicalHost($0.id) == host })
        else { throw RegistryError.notUserAdded(rawHost) }
        hidden.insert(host)
    }

    /// Puts a removed built-in back.
    public mutating func restore(host rawHost: String) throws {
        let host = KnownRegistry.canonicalHost(rawHost)
        guard hidden.contains(host) else { throw RegistryError.notUserAdded(rawHost) }
        hidden.remove(host)
    }
}
