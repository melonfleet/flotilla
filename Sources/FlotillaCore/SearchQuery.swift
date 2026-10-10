import Foundation

/// What a search field holds, read as a small grammar (Phase 1 leftover, research/FEATURES.md):
/// `is:running` or `is:stopped`, `image:nginx`, `host:mini`, `tag:prod`, and any other words.
/// Every part must match — `is:running image:postgres db` is running Postgres containers with
/// "db" somewhere in them. Matching is case-insensitive and by substring, as plain search was.
///
/// A word the grammar does not know — `foo:bar`, or `is:` with a value it does not take — is
/// searched for as written, so nothing typed is silently dropped.
public struct SearchQuery: Sendable, Equatable {
    public enum State: String, Sendable, CaseIterable { case running, stopped }

    public var state: State?
    public var images: [String] = []
    public var hosts: [String] = []
    public var tags: [String] = []
    /// Plain words; each must appear in at least one of the fields searched.
    public var terms: [String] = []

    public init(state: State? = nil, images: [String] = [], hosts: [String] = [], tags: [String] = [],
                terms: [String] = []) {
        self.state = state; self.images = images; self.hosts = hosts; self.tags = tags; self.terms = terms
    }

    public var isEmpty: Bool {
        state == nil && images.isEmpty && hosts.isEmpty && tags.isEmpty && terms.isEmpty
    }

    /// The grammar, for a tooltip beside the field.
    public static let help = "Type words to search, or narrow with is:running, is:stopped, image:nginx, host:mini, tag:prod. Quote a value with spaces: host:\"Mac mini\"."

    public static func parse(_ text: String) -> SearchQuery {
        var query = SearchQuery()
        for token in tokens(text) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                query.terms.append(token); continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            guard !value.isEmpty else { query.terms.append(token); continue }
            switch key {
            case "is":
                if let state = State(rawValue: value.lowercased()) { query.state = state }
                else { query.terms.append(token) }
            case "image": query.images.append(value)
            case "host": query.hosts.append(value)
            case "tag": query.tags.append(value)
            default: query.terms.append(token)
            }
        }
        return query
    }

    /// Whether every plain word appears in at least one of `fields`.
    public func termsMatch(_ fields: [String]) -> Bool {
        terms.allSatisfy { term in fields.contains { Self.contains($0, term) } }
    }

    /// Whether every value of one key (`images`, `hosts`, `tags`) appears in at least one of
    /// `fields`. No values is a match.
    public static func all(_ values: [String], in fields: [String]) -> Bool {
        values.allSatisfy { value in fields.contains { contains($0, value) } }
    }

    public static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Words split on spaces, with double quotes keeping a value's spaces: `host:"Mac mini"`.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
