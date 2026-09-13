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
    /// Whether pulling public images from it needs no credentials at all. Drives the status
    /// column's third state: "not signed in" and "no sign-in needed" are different facts, and
    /// showing the first for `mcr.microsoft.com` would send people looking for an account they
    /// do not need.
    public let anonymousPullWorks: Bool
    /// True for the one registry a bare `alpine:latest` resolves to.
    public let isImplicitDefault: Bool
    /// Whether the user added this themselves, as opposed to it being in the built-in catalogue.
    public let isUserAdded: Bool

    public init(id: String, name: String, summary: String,
                anonymousPullWorks: Bool = false,
                isImplicitDefault: Bool = false,
                isUserAdded: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.anonymousPullWorks = anonymousPullWorks
        self.isImplicitDefault = isImplicitDefault
        self.isUserAdded = isUserAdded
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
                      isImplicitDefault: true),
        KnownRegistry(id: "ghcr.io", name: "GitHub Container Registry",
                      summary: "Images published from GitHub repositories. Apple's own builder image lives here."),
        KnownRegistry(id: "quay.io", name: "Quay",
                      summary: "Red Hat's public registry."),
        KnownRegistry(id: "mcr.microsoft.com", name: "Microsoft Artifact Registry",
                      summary: "Microsoft's official images. Public images need no account.",
                      anonymousPullWorks: true),
        KnownRegistry(id: "public.ecr.aws", name: "Amazon ECR Public",
                      summary: "Amazon's public gallery. Private ECR is per-account — add it below.",
                      anonymousPullWorks: true),
        KnownRegistry(id: "registry.k8s.io", name: "Kubernetes",
                      summary: "Official Kubernetes images. Public, no account.",
                      anonymousPullWorks: true),
        KnownRegistry(id: "registry.gitlab.com", name: "GitLab Container Registry",
                      summary: "Images published from GitLab projects."),
        KnownRegistry(id: "registry.redhat.io", name: "Red Hat Registry",
                      summary: "Red Hat's authenticated registry; needs a Red Hat account."),
    ]
}

/// The catalogue: the built-in registries plus whatever the user has added.
///
/// Pure, in the core, and tested, for the reason `TagBook` gives — the app target has no test
/// target, and "may a user add a host that is already built in" is not a question to answer by
/// trying it.
public struct RegistryBook: Sendable, Equatable {
    /// Registries the user added themselves, in the order they added them.
    public private(set) var userAdded: [KnownRegistry]

    public init(userAdded: [KnownRegistry] = []) {
        self.userAdded = userAdded
    }

    /// Everything the screen lists, built-ins first.
    public var all: [KnownRegistry] { KnownRegistry.builtIn + userAdded }

    public func registry(id: String) -> KnownRegistry? { all.first { $0.id == id } }

    public enum RegistryError: Error, Equatable, CustomStringConvertible {
        case emptyHost
        case invalidHost(String)
        case duplicate(String)
        case builtIn(String)
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
            case .builtIn(let host):
                "‘\(host)’ is built in and can’t be removed."
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
        guard !all.contains(where: { $0.id == host }) else { throw RegistryError.duplicate(host) }
        return host
    }

    @discardableResult
    public mutating func add(host rawHost: String, name rawName: String,
                             summary: String = "") throws -> KnownRegistry {
        let host = try normalised(host: rawHost)
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Falls back to the host rather than refusing: the name is for recognising the row, and
        // for a self-hosted registry the host *is* how you recognise it. Only a name that is
        // nothing but whitespace when one was typed is an error.
        let name = trimmed.isEmpty ? host : trimmed
        let registry = KnownRegistry(id: host, name: name,
                                     summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                     isUserAdded: true)
        userAdded.append(registry)
        return registry
    }

    /// Removes one of the user's own registries from the list.
    ///
    /// **Does not sign out.** Removing a row and destroying a credential are different
    /// decisions, and doing both behind one button is how someone loses a login they meant to
    /// keep. The screen offers Sign Out separately, and a removed registry that still has a
    /// login reappears in the table — as a login, which is the truth.
    public mutating func remove(host: String) throws {
        guard userAdded.contains(where: { $0.id == host }) else {
            throw KnownRegistry.builtIn.contains(where: { $0.id == host })
                ? RegistryError.builtIn(host)
                : RegistryError.notUserAdded(host)
        }
        userAdded.removeAll { $0.id == host }
    }
}
