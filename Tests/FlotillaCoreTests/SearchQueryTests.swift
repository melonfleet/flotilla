import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SearchQueryTests {
    @Test func theGrammarsWords() {
        let query = SearchQuery.parse("is:running image:postgres host:\"Mac mini\" tag:prod db")
        #expect(query.state == .running)
        #expect(query.images == ["postgres"] && query.hosts == ["Mac mini"] && query.tags == ["prod"])
        #expect(query.terms == ["db"])
    }

    @Test func wordsItDoesNotKnowAreSearchedAsWritten() {
        let query = SearchQuery.parse("is:paused foo:bar image: :x")
        #expect(query.state == nil)
        #expect(query.terms == ["is:paused", "foo:bar", "image:", ":x"])
        #expect(query.images.isEmpty)
    }

    @Test func plainSearchIsUnchanged() {
        let query = SearchQuery.parse("  web  ")
        #expect(query == SearchQuery(terms: ["web"]))
        #expect(SearchQuery.parse("").isEmpty)
        #expect(query.termsMatch(["storefront-web", "running"]))
        #expect(!query.termsMatch(["db"]))
    }

    @Test func everyPartMustMatch() {
        let query = SearchQuery.parse("db shop")
        #expect(query.termsMatch(["shop-db"]))
        #expect(query.termsMatch(["db", "shop-net"]))
        #expect(!query.termsMatch(["db"]))
        #expect(SearchQuery.all(["POSTGRES"], in: ["docker.io/library/postgres:17"]))
        #expect(!SearchQuery.all(["redis"], in: ["docker.io/library/postgres:17"]))
        #expect(SearchQuery.all([], in: []))
    }

    @Test func keysAndStatesIgnoreCase() {
        let query = SearchQuery.parse("IS:Stopped Image:Alpine")
        #expect(query.state == .stopped && query.images == ["Alpine"])
    }
}
