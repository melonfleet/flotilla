import Foundation

/// One row of the Registries section: a registry in your list, a login, or both.
///
/// Both halves are kept because they answer different questions. The list entry says what the
/// registry *is*; the login says whether this Mac has credentials for it. A row can have either
/// alone — a registry you have never signed in to, or a login to something not in the list — and
/// the table has to show both or it is lying about one of them.
///
/// In the core since the section moved out of Settings (5 October), so the merge and the facts it
/// derives are pinned by tests the app target cannot have.
public struct RegistryRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let known: KnownRegistry?
    public let login: RegistryLogin?

    public init(id: String, known: KnownRegistry?, login: RegistryLogin?) {
        self.id = id
        self.known = known
        self.login = login
    }

    public var name: String { known?.name ?? id }
    public var summary: String {
        known?.summary
            ?? "Signed in from the command line; not in your list. Add it to keep it here."
    }
    public var isUserAdded: Bool { known?.isUserAdded ?? false }
    /// In your list, as opposed to being here only because this Mac holds a login for it.
    public var isListed: Bool { known != nil }
    public var isSignedIn: Bool { login != nil }
    public var username: String? { login?.username }

    /// The host the credential is filed under, which is what a sign-out has to name. Usually the
    /// row's own id; for Docker Hub it is `registry-1.docker.io`.
    public var credentialHost: String { login?.id ?? id }

    /// Where to create the token this registry wants as a password, if there is such a page.
    public var tokenURL: URL? { known?.tokenURL.flatMap(URL.init(string:)) }
    public var browseURL: URL? { known?.browseURL.flatMap(URL.init(string:)) }

    /// How much this registry needs a sign-in. A login with no list entry is someone's own
    /// registry signed in to from a terminal, so it is treated as `required`, the same default a
    /// hand-added one gets.
    public var signInNeed: SignInNeed { known?.signInNeed ?? .required }

    /// Whether this registry is reached over plain HTTP.
    public var usesHTTP: Bool { known?.usesHTTP ?? false }

    /// Whether this Mac can sign in to it at all.
    ///
    /// **Not over HTTP, since `container` 1.5.0.** The runtime's registry client refuses to send a
    /// credential to a registry that challenges for one over a non-HTTPS connection —
    /// "refusing insecure credential exchange" (`apple/containerization`,
    /// `RegistryClient.swift`), with no exemption, not even for `localhost`. Measured on
    /// 5 October against a local `registry:2` with a correct password; the same sign-in worked on
    /// 1.4.1, which is how `Fixtures/registries.json` was captured. So an HTTP registry gets no
    /// Sign In, rather than one that can only fail.
    public var canSignIn: Bool { signInNeed != .notNeeded && !usesHTTP }

    /// Why there is no Sign In, when the registry has accounts but this Mac cannot use them.
    public var signInUnavailableReason: String? {
        guard signInNeed != .notNeeded, usesHTTP else { return nil }
        return KnownRegistry.httpSignInRefusal
    }

    /// What to put in the two fields. The catalogue's own wording where there is one; otherwise
    /// the cloud-CLI recipe, matched on the host — which is how a per-account registry the
    /// catalogue cannot list still gets useful instructions.
    public var credentialHint: String? {
        known?.credentialHint ?? KnownRegistry.cloudCredentialHint(forHost: id)
    }

    /// The registry family's name, for the Type column.
    public var kindTitle: String { (known?.kind ?? RegistryKind.inferred(fromHost: id)).name }

    /// What the status column says. Three states, not two: "not signed in" and "nothing to sign
    /// in to" are different facts, and showing the first for `mcr.microsoft.com` would send
    /// someone looking for an account they do not need.
    public var statusText: String {
        if let username, !username.isEmpty { return "Signed in as \(username)" }
        if isSignedIn { return "Signed in" }
        if signInUnavailableReason != nil { return "Can't sign in over HTTP" }
        return canSignIn ? "Not signed in" : "No account"
    }

    // Sort keys for the table.
    public var nameSortKey: String { name.lowercased() }
    public var hostSortKey: String { id.lowercased() }
    public var signInSortKey: Int { signInNeed.sortRank }
    public var statusSortKey: String { isSignedIn ? "0" + (username ?? "") : (canSignIn ? "1" : "2") }
    public var kindSortKey: String { kindTitle.lowercased() }
}

extension RegistryBook {
    /// Your list, then any login this Mac holds that is not in it, de-duplicated by host.
    ///
    /// The second set is what stops this being a pretty list that disagrees with the machine: a
    /// registry you signed in to with `container registry login` in a terminal appears, marked as
    /// not being in your list, rather than being invisible.
    ///
    /// Keyed on the **canonical** host, not the stored one. `docker.io` signs in and comes back as
    /// `registry-1.docker.io`; matching by exact string left the Docker Hub row saying "Not signed
    /// in" and added a duplicate row for the same account. See `KnownRegistry.canonicalHost`.
    public func rows(logins: [RegistryLogin]) -> [RegistryRow] {
        let byHost = Dictionary(logins.map { (KnownRegistry.canonicalHost($0.id), $0) },
                                uniquingKeysWith: { first, _ in first })
        var rows = all.map {
            RegistryRow(id: $0.id, known: $0, login: byHost[KnownRegistry.canonicalHost($0.id)])
        }
        var listed = Set(rows.map { KnownRegistry.canonicalHost($0.id) })
        for login in logins where !listed.contains(KnownRegistry.canonicalHost(login.id)) {
            listed.insert(KnownRegistry.canonicalHost(login.id))
            rows.append(RegistryRow(id: login.id, known: nil, login: login))
        }
        return rows
    }
}
