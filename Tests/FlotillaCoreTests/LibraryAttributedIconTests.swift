import Foundation
import Testing
@testable import FlotillaCore

/// `attributedIcon` (Redis, 23 October): a logo that may appear only with its owner's attribution,
/// kept out of `icon` so beta 5, which can't show the attribution, never draws it.
@Suite struct LibraryAttributedIconTests {
    private static let attribution = "Redis is a registered trademark of Redis Ltd. Any rights therein are reserved to Redis Ltd."
    private static let redisSHA = String(repeating: "a", count: 64)
    private static let plainSHA = String(repeating: "b", count: 64)

    private static func json(attributedIcon: String = #"{"icon": {"file": "icons/redis.png", "sha256": "\#(redisSHA)", "bytes": 4096}, "attribution": "\#(attribution)"}"#,
                             icon: String? = nil) -> String {
        #"""
        {"schema": 2, "version": "2026.10.23.1", "entries": [{"id": "redis", "title": "Redis",
         "summary": "", "categories": ["Databases"], "kind": "container",
         "tested": {"date": "2026-10-20", "macs": 1},
         "container": {"image": "docker.io/library/redis:8.10.2", "name": "redis", "ports": ["6379:6379"],
          "env": [], "secretEnv": [], "command": [],
          "volumes": [{"suffix": "data", "path": "/data", "volumeOwner": {"uid": 999, "gid": 999}}]},
         \#(icon.map { #""icon": \#($0), "# } ?? "")"attributedIcon": \#(attributedIcon)}]}
        """#
    }

    private static func decode(_ text: String) throws -> SuggestionLibrary {
        try JSONDecoder().decode(SuggestionLibrary.self, from: Data(text.utf8))
    }

    private static let validIcon = LibraryIcon(file: "icons/redis.png", sha256: redisSHA, bytes: 4096)

    @Test func itDecodesAndPassesTheChecks() throws {
        let (checked, dropped) = try Self.decode(Self.json()).checked()
        #expect(dropped.isEmpty, "\(dropped)")
        let entry = try #require(checked.entries.first)
        #expect(entry.icon == nil)
        #expect(entry.attributedIcon == LibraryAttributedIcon(icon: Self.validIcon, attribution: Self.attribution))
        // Round-trips, as the cache and the built-in copy do.
        let again = try JSONDecoder().decode(SuggestionLibrary.self, from: JSONEncoder().encode(checked))
        #expect(again == checked)
    }

    @Test func itIsValidatedLikeArtworkAttribution() throws {
        #expect(LibraryAttributedIcon(icon: Self.validIcon, attribution: Self.attribution).problem() == nil)
        #expect(LibraryAttributedIcon(icon: Self.validIcon, attribution: String(repeating: "a", count: 300)).problem() == nil)
        for bad in ["", String(repeating: "a", count: 301), "Bad\u{202E}text", "Two\nlines", "Cafe\u{301}"] {
            #expect(LibraryAttributedIcon(icon: Self.validIcon, attribution: bad).problem() != nil, "\(bad)")
        }
        for icon in [LibraryIcon(file: "../redis.png", sha256: Self.redisSHA, bytes: 1),
                     LibraryIcon(file: "icons/redis.png", sha256: "ABC", bytes: 1),
                     LibraryIcon(file: "icons/redis.png", sha256: Self.redisSHA, bytes: LibraryIcon.maxBytes + 1)] {
            #expect(LibraryAttributedIcon(icon: icon, attribution: Self.attribution).problem() != nil)
        }

        // A bad one drops only the decoration, and is named; the entry and its plain icon stay.
        let plain = #"{"file": "icons/redis-plain.png", "sha256": "\#(Self.plainSHA)", "bytes": 10}"#
        for malformed in [#"{"icon": {"file": "icons/redis.png", "sha256": "\#(Self.redisSHA)", "bytes": 4096}}"#,
                          #"{"icon": {"file": "icons/redis.png", "sha256": "\#(Self.redisSHA)", "bytes": 4096}, "attribution": ""}"#,
                          #"{"icon": "icons/redis.png", "attribution": "Redis"}"#,
                          #""icons/redis.png""#, "42", "[]"] {
            let (checked, dropped) = try Self.decode(Self.json(attributedIcon: malformed, icon: plain)).checked()
            #expect(dropped.map(\.id) == ["redis"], "\(malformed)")
            #expect(dropped.first?.problem.hasPrefix("Attributed icon ignored: ") == true)
            #expect(checked.entries.first?.attributedIcon == nil)
            #expect(checked.entries.first?.icon?.sha256 == Self.plainSHA)
        }
        // null is absent, as for any optional.
        let (none, dropped) = try Self.decode(Self.json(attributedIcon: "null")).checked()
        #expect(dropped.isEmpty)
        #expect(none.entries.first?.attributedIcon == nil)
    }

    @Test func itIsPreferredOverIconWhereverALogoIsPicked() throws {
        let plain = #"{"file": "icons/redis-plain.png", "sha256": "\#(Self.plainSHA)", "bytes": 10}"#
        let library = try Self.decode(Self.json(icon: plain)).checked().library
        let redisBytes = Data("redis".utf8), plainBytes = Data("plain".utf8)
        let both = [Self.redisSHA: redisBytes, Self.plainSHA: plainBytes]

        let entry = try #require(library.entries.first)
        #expect(entry.logo(in: both)?.data == redisBytes)
        #expect(entry.logo(in: both)?.attribution == Self.attribution)
        // The images and containers that run it get the same logo, through the image match.
        let byImage = try #require(library.entry(forImage: "redis:8.2"))
        #expect(byImage.logo(in: both)?.data == redisBytes)
        #expect(library.entry(forGroup: ContainerGroup(name: "cache", members: [GroupMember(name: "cache", image: "redis")]))?
            .logo(in: both)?.data == redisBytes)
        // Not fetched yet: the plain icon, which owes nothing.
        #expect(entry.logo(in: [Self.plainSHA: plainBytes])?.data == plainBytes)
        #expect(entry.logo(in: [Self.plainSHA: plainBytes])?.attribution == nil)
        #expect(entry.logo(in: [:]) == nil)

        // Attributions are owed only for what is drawn, once each.
        #expect(library.logoAttributions(icons: both) == [Self.attribution])
        #expect(library.logoAttributions(icons: [Self.plainSHA: plainBytes]).isEmpty)
        var twice = library
        var copy = entry
        copy.id = "redis-two"
        twice.entries.append(copy)
        #expect(twice.logoAttributions(icons: both) == [Self.attribution])
    }

    /// Beta 5's `LibraryEntry` was synthesized `Codable` without this key. Decoding with exactly its
    /// keys stands in for that build: the entry still reads, still passes, and has no icon to draw.
    @Test func aBeta5ReaderSeesNoIcon() throws {
        struct Beta5Library: Decodable {
            var schema: Int
            var version: String
            var entries: [Beta5Entry]
            var artwork: [LibraryArtwork]?
        }
        struct Beta5Entry: Decodable {
            var id: String
            var title: String
            var summary: String
            var categories: [String]
            var kind: LibraryEntry.Kind
            var licenceNote: String?
            var tested: LibraryEntry.Tested?
            var container: LibraryContainer?
            var stack: LibraryStack?
            var icon: LibraryIcon?
        }
        let old = try JSONDecoder().decode(Beta5Library.self, from: Data(Self.json().utf8))
        let entry = try #require(old.entries.first)
        #expect(entry.icon == nil)
        // Its checks are the ones this build runs on the same fields; none of them reads the new key.
        let asBeta5 = SuggestionLibrary(schema: old.schema, version: old.version, entries: old.entries.map {
            LibraryEntry(id: $0.id, title: $0.title, summary: $0.summary, categories: $0.categories, kind: $0.kind,
                         licenceNote: $0.licenceNote, tested: $0.tested, container: $0.container, stack: $0.stack,
                         icon: $0.icon)
        })
        let (checked, dropped) = asBeta5.checked()
        #expect(dropped.isEmpty, "\(dropped)")
        #expect(checked.entries.first?.logo(in: [Self.redisSHA: Data("redis".utf8)]) == nil)
    }
}
