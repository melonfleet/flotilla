import Foundation
import Testing
@testable import FlotillaCore

// The Registries section (5 October): registries moved out of Settings into the sidebar, each
// saying whether signing in is optional or required, and the Add form refusing to add a required
// one until you have signed in. These pin the facts the section shows.

@Suite("Registries section")
struct RegistrySectionTests {

    private func catalogued(_ host: String) throws -> KnownRegistry {
        try #require(KnownRegistry.catalogue.first { $0.id == host })
    }

    // MARK: How much a registry needs a sign-in

    @Test("public-image registries say sign-in is optional, not required")
    func publicRegistriesAreOptional() throws {
        // The trap this type exists for: `anonymousPullWorks` is false for these, because they
        // have private tiers too. Read as "optional", they would all have said "required".
        for host in ["docker.io", "ghcr.io", "quay.io", "registry.gitlab.com", "cgr.dev",
                     "public.ecr.aws"] {
            #expect(try catalogued(host).signInNeed == .optional,
                    Comment(rawValue: host))
        }
    }

    @Test("a registry with no accounts needs no sign-in")
    func accountlessRegistriesNeedNone() throws {
        for host in ["mcr.microsoft.com", "registry.k8s.io", "registry.access.redhat.com"] {
            #expect(try catalogued(host).signInNeed == .notNeeded, Comment(rawValue: host))
        }
    }

    @Test("Red Hat's authenticated registry is the one that requires a sign-in")
    func redHatRequires() throws {
        #expect(try catalogued("registry.redhat.io").signInNeed == .required)
        #expect(KnownRegistry.catalogue.filter { $0.signInNeed == .required }.map(\.id)
                == ["registry.redhat.io"])
    }

    @Test("a hand-added registry is required unless the user says otherwise")
    func handAddedDefaultsToRequired() throws {
        var book = RegistryBook()
        let unanswered = try book.add(host: "registry.internal:5000", name: "")
        #expect(unanswered.signInNeed == .required)
        let optional = try book.add(host: "mirror.internal", name: "", signInRequired: false)
        #expect(optional.signInNeed == .optional)
    }

    @Test("no accounts wins over a stored answer")
    func noAccountsWins() {
        let odd = KnownRegistry(id: "example.com", name: "x", summary: "",
                                hasAccounts: false, signInRequired: true)
        #expect(odd.signInNeed == .notNeeded)
    }

    @Test("the column sorts required first")
    func sortOrder() {
        #expect(SignInNeed.allCases.sorted { $0.sortRank < $1.sortRank }
                == [.required, .optional, .notNeeded])
    }

    // MARK: The rows

    @Test("a Docker Hub login lands on the Docker Hub row, not a second one")
    func dockerHubLoginMerges() {
        let login = RegistryLogin(id: "registry-1.docker.io", name: "registry-1.docker.io",
                                  username: "someone")
        let rows = RegistryBook.starter.rows(logins: [login])
        #expect(rows.map(\.id) == ["docker.io", "ghcr.io"])
        let hub = rows[0]
        #expect(hub.isSignedIn)
        #expect(hub.statusText == "Signed in as someone")
        // Sign-out must name where the credential is filed, not the row.
        #expect(hub.credentialHost == "registry-1.docker.io")
    }

    @Test("a login to a registry not in the list still shows, marked as such")
    func unlistedLoginShows() {
        let login = RegistryLogin(id: "localhost:5001", name: "localhost:5001",
                                  username: "fixture-user")
        let rows = RegistryBook.starter.rows(logins: [login])
        let extra = rows.last
        #expect(rows.count == 3)
        #expect(extra?.id == "localhost:5001")
        #expect(extra?.isListed == false)
        #expect(extra?.signInNeed == .required)
    }

    @Test("two spellings of one unlisted host make one row")
    func unlistedDuplicatesCollapse() {
        let a = RegistryLogin(id: "index.docker.io", name: "index.docker.io")
        let b = RegistryLogin(id: "registry-1.docker.io", name: "registry-1.docker.io")
        // An empty list, so both are "unlisted": they are still one registry.
        #expect(RegistryBook().rows(logins: [a, b]).count == 1)
    }

    @Test("the status says 'No account' where there is nothing to sign in to")
    func statusWording() throws {
        let book = RegistryBook(registries: [try catalogued("mcr.microsoft.com"),
                                             try catalogued("ghcr.io")])
        let rows = book.rows(logins: [])
        #expect(rows[0].statusText == "No account")
        #expect(!rows[0].canSignIn)
        #expect(rows[1].statusText == "Not signed in")
    }

    @Test("an HTTP registry cannot be signed in to, and says why")
    func httpRegistriesHaveNoSignIn() throws {
        // container 1.5.0 refuses a credential challenge over plain HTTP, even on localhost
        // (measured 5 October with a correct password). A Sign In there could only fail.
        var book = RegistryBook()
        try book.add(host: "localhost:5001", name: "", usesHTTP: true)
        try book.add(host: "registry.internal", name: "")
        let rows = book.rows(logins: [])
        let http = try #require(rows.first { $0.id == "localhost:5001" })
        let https = try #require(rows.first { $0.id == "registry.internal" })
        #expect(!http.canSignIn)
        #expect(http.signInUnavailableReason == KnownRegistry.httpSignInRefusal)
        #expect(http.statusText == "Can't sign in over HTTP")
        #expect(https.canSignIn)
        #expect(https.signInUnavailableReason == nil)
    }

    @Test("registries are their own activity and tag kind")
    func registryKind() {
        let subject = TagSubject(kind: .registry, id: "ghcr.io")
        #expect(subject.storageKey == "registry/ghcr.io")
        #expect(TagSubject(storageKey: "registry/ghcr.io") == subject)
    }
}
