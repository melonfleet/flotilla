import Testing
@testable import FlotillaCore

@Suite struct LibraryImageMatchingTests {
    private func container(_ id: String, _ image: String) -> LibraryEntry {
        LibraryEntry(id: id, title: id, summary: "", categories: [], kind: .container,
                     container: LibraryContainer(image: image, name: id))
    }

    private func stack(_ id: String, _ images: [String]) -> LibraryEntry {
        LibraryEntry(id: id, title: id, summary: "", categories: [], kind: .stack,
                     stack: LibraryStack(services: images.enumerated().map {
                         .init(role: "service\($0.offset)", title: "Service", image: $0.element)
                     }))
    }

    private func library(_ entries: [LibraryEntry]) -> SuggestionLibrary {
        SuggestionLibrary(version: "2026.10.18.0", entries: entries)
    }

    private func group(_ images: [String]) -> ContainerGroup {
        ContainerGroup(name: "Site", members: images.enumerated().map {
            GroupMember(name: "service\($0.offset)", image: $0.element)
        })
    }

    @Test(arguments: ["nginx", "nginx:latest", "docker.io/nginx:1.27",
                      "docker.io/library/nginx", "DOCKER.IO/library/nginx:stable",
                      "nginx@sha256:abc", "docker.io/library/nginx:1.27@sha256:abc",
                      "index.docker.io/library/nginx:latest", "index.docker.io/nginx"])
    func dockerHubAliases(_ reference: String) {
        #expect(SuggestionLibrary.imageRepository(reference) == "docker.io/library/nginx")
        #expect(library([container("web", "docker.io/library/nginx:1.27")])
            .entry(forImage: reference)?.id == "web")
    }

    @Test func registriesNamespacesPortsAndCase() {
        let entries = library([container("github", "ghcr.io/owner/app:1"),
                               container("quay", "quay.io/owner/app:2"),
                               container("hub", "owner/app:3"),
                               container("private", "localhost:5000/team/app:4")])
        #expect(entries.entry(forImage: "GHCR.IO/owner/app@sha256:abc")?.id == "github")
        #expect(entries.entry(forImage: "QUAY.IO/owner/app:latest")?.id == "quay")
        #expect(entries.entry(forImage: "docker.io/owner/app@sha256:abc")?.id == "hub")
        #expect(entries.entry(forImage: "LOCALHOST:5000/team/app:latest")?.id == "private")
        #expect(entries.entry(forImage: "ghcr.io/Owner/app:1") == nil)
        #expect(entries.entry(forImage: "localhost:5001/team/app:4") == nil)
        #expect(entries.entry(forImage: "unknown:1") == nil)
        #expect(entries.entry(forImage: "") == nil)
    }

    @Test func dedicatedContainerWinsThenLibraryOrder() {
        let first = stack("site", ["wordpress:6", "mariadb:11"])
        let second = stack("other-site", ["mariadb:10", "other:1"])
        let database = container("database", "docker.io/library/mariadb:11")
        let duplicate = container("duplicate", "mariadb:10")
        #expect(library([first, second, database, duplicate]).entry(forImage: "mariadb")?.id == "database")
        #expect(library([first, second]).entry(forImage: "mariadb")?.id == "site")
        #expect(library([duplicate, database]).entry(forImage: "mariadb")?.id == "duplicate")
    }

    @Test func groupsUseMostDistinctRepositoriesThenLibraryOrder() {
        let entries = library([container("database", "mariadb:11"),
                               stack("wordpress", ["wordpress:6", "mariadb:11"]),
                               stack("duplicate", ["wordpress:7", "mariadb:10"]),
                               stack("larger", ["wordpress:6", "mariadb:11", "redis:7"])])
        // Database first, just as it is in a stack's startup order.
        #expect(entries.entry(forGroup: group(["docker.io/library/mariadb:10", "wordpress@sha256:abc"]))?.id == "wordpress")
        #expect(entries.entry(forGroup: group(["mariadb", "wordpress", "redis"]))?.id == "larger")
        #expect(entries.entry(forGroup: group(["mariadb", "mariadb:10", "mariadb:11"]))?.id == "database")
        #expect(entries.entry(forGroup: group(["unknown", "wordpress"]))?.id == "wordpress")
        #expect(entries.entry(forGroup: group(["mariadb", "unknown"]))?.id == "database")
        #expect(entries.entry(forGroup: group(["unknown"])) == nil)
        #expect(entries.entry(forGroup: group([])) == nil)
    }

    @Test func equalCoveragePrefersTheEntryWithFewestImagesTheGroupLacks() {
        let entries = library([stack("monitoring", ["prom/prometheus:v3", "grafana/grafana:13"]),
                               container("grafana", "grafana/grafana:13")])
        #expect(entries.entry(forGroup: group(["grafana/grafana:12"]))?.id == "grafana")
        #expect(entries.entry(forGroup: group(["grafana/grafana", "prom/prometheus"]))?.id == "monitoring")
    }
}
