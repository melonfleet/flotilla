import Foundation
import Testing
@testable import FlotillaCore

// Against real Docker Hub answers, captured 8 October 2026 with `curl -A Flotilla` from the URLs
// `DockerHub` builds (Fixtures/dockerhub): `redis`, the empty-query official browse, a search with
// no results, and library/redis's newest tags.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures/dockerhub"))
    return try Data(contentsOf: url)
}

@Suite struct DockerHubTests {
    @Test func searchRanksTheOfficialImageAndSaysWhatRunsHere() throws {
        let page = try JSONDecoder().decode(DockerHub.SearchPage.self, from: fixture("search-v4-redis"))
        #expect(page.total > 0)
        let redis = try #require(page.results.first { $0.id == "library/redis" })
        #expect(redis.isPullable)
        #expect(redis.reference == "redis")
        #expect(redis.badgeLabel == "Docker Official Image")
        #expect(redis.hasARM64)
        #expect(redis.pullCount == "1B+")
        // Docker Hardened Images and MCP listings are in the results, and are not pulled from docker.io.
        let others = page.results.filter { $0.type != "image" }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { !$0.isPullable })
    }

    @Test func emptyQueryBrowsesOfficialImages() throws {
        let page = try JSONDecoder().decode(DockerHub.SearchPage.self, from: fixture("search-v4-official"))
        #expect(!page.results.isEmpty)
        #expect(page.results.allSatisfy { $0.badge == "official" && $0.id.hasPrefix("library/") })
    }

    @Test func noResultsDecodesAsEmpty() throws {
        let page = try JSONDecoder().decode(DockerHub.SearchPage.self, from: fixture("search-v4-empty"))
        #expect(page.total == 0 && page.results.isEmpty)
    }

    @Test func tagsDecodeWithPlatformsAndDates() throws {
        let page = try JSONDecoder().decode(DockerHub.TagPage.self, from: fixture("tags-library-redis"))
        let latest = try #require(page.results.first { $0.name == "latest" })
        #expect(latest.hasLinuxARM64)
        #expect(latest.isUsable)
        #expect((latest.fullSize ?? 0) > 0)
        #expect(DockerHub.date(latest.lastUpdated) != nil)
        #expect(page.next != nil)
    }

    @Test func urlsCarryOnlyTheSearchAndRefuseOddNames() throws {
        let search = DockerHub.searchURL(query: "  redis & co ", from: 25)
        #expect(search.host == "hub.docker.com")
        let items = URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "query" }?.value == "redis & co")
        #expect(items.first { $0.name == "from" }?.value == "25")
        #expect(!items.contains { $0.name == "badges" })
        let browse = URLComponents(url: DockerHub.searchURL(query: ""), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(browse.first { $0.name == "badges" }?.value == "official")
        #expect(DockerHub.searchURL(query: String(repeating: "a", count: 500)).absoluteString.count < 300)

        #expect(DockerHub.tagsURL(repository: "library/redis")?.path == "/v2/namespaces/library/repositories/redis/tags")
        #expect(DockerHub.tagURL(repository: "library/nginx", tag: "latest")?.absoluteString
                == "https://hub.docker.com/v2/namespaces/library/repositories/nginx/tags/latest")
        #expect(DockerHub.tagURL(repository: "library/nginx", tag: "../x") == nil)
        for bad in ["redis", "a/b/c", "../etc", "Library/Redis", "a/b?x=1", "a/-b", "", "/"] {
            #expect(DockerHub.tagsURL(repository: bad) == nil, "\(bad)")
        }
    }

    @Test func tagNamesAreChecked() throws {
        func tag(_ name: String) throws -> DockerHub.Tag {
            try JSONDecoder().decode(DockerHub.Tag.self, from: Data(#"{"name":\#(String(reflecting: name))}"#.utf8))
        }
        #expect(try tag("8.8.3-trixie").isUsable)
        #expect(try !tag("-x").isUsable)
        #expect(try !tag("a b").isUsable)
        #expect(try !tag("a;rm").isUsable)
    }
}
