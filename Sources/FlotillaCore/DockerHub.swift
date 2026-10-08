import Foundation

/// Searching Docker Hub for the Images ▸ Browse page (PLAN.md ▸ Registry browser, the owner,
/// 7–8 October). URLs and decoding only — the app makes the request, and only when the owner opens
/// the page or types a search, so the no-phone-home promise holds.
///
/// `container` has no search command, so this is Docker Hub's own HTTP API:
///
/// - **Search** is `/api/search/v4`, what hub.docker.com's own search uses. It ranks the official
///   `redis` above look-alikes (the older `/v2/search/repositories` put `mcp/redis` first) and says
///   which architectures each image has, which matters on Apple silicon. It is not a documented,
///   versioned API, so a decoding failure says so rather than showing an empty list.
/// - **Tags** are `/v2/namespaces/{ns}/repositories/{repo}/tags`, from Docker's published Hub API.
///
/// Everything decoded here is untrusted text from the internet: shown, never executed. A result
/// becomes a pull only through the Pull form, which validates the reference like a typed one.
public enum DockerHub {
    public static let host = "hub.docker.com"
    /// The registry an unqualified reference pulls from.
    public static let registryDomain = "docker.io"
    /// Longer than any real search; a pasted essay is cut, not sent.
    public static let maxQueryLength = 100

    // MARK: URLs

    /// A search, or with an empty query the Docker Official Images by popularity — what the page
    /// shows before anything is typed.
    public static func searchURL(query: String, from: Int = 0, size: Int = 25) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/search/v4"
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQueryLength))
        var items = [URLQueryItem(name: "query", value: trimmed),
                     URLQueryItem(name: "from", value: String(max(0, from))),
                     URLQueryItem(name: "size", value: String(min(max(1, size), 100)))]
        if trimmed.isEmpty { items.append(URLQueryItem(name: "badges", value: "official")) }
        components.queryItems = items
        return components.url!
    }

    /// The newest tags of `repository` (`library/redis`, `grafana/grafana`), or nil for a name that
    /// is not a plain `namespace/name` — nothing from a result reaches a URL path unchecked.
    public static func tagsURL(repository: String, page: Int = 1, size: Int = 25) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(isPathSafe) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v2/namespaces/\(parts[0])/repositories/\(parts[1])/tags"
        components.queryItems = [URLQueryItem(name: "page", value: String(max(1, page))),
                                 URLQueryItem(name: "page_size", value: String(min(max(1, size), 100))),
                                 URLQueryItem(name: "ordering", value: "last_updated")]
        return components.url
    }

    /// One tag by name — how `latest` is found when it is not among the newest page of tags.
    public static func tagURL(repository: String, tag: String) -> URL? {
        guard let list = tagsURL(repository: repository),
              (try? JSONDecoder().decode(Tag.self, from: Data(#"{"name":\#(String(reflecting: tag))}"#.utf8)))?.isUsable == true
        else { return nil }
        var components = URLComponents(url: list, resolvingAgainstBaseURL: false)
        components?.path += "/" + tag
        components?.queryItems = nil
        return components?.url
    }

    /// Docker Hub's own rules for a namespace or repository name: lowercase letters, digits and
    /// `._-`, starting with a letter or digit.
    static func isPathSafe(_ part: String) -> Bool {
        guard let first = part.unicodeScalars.first, part.count <= 255 else { return false }
        let lowerOrDigit: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        return lowerOrDigit(first) && part.unicodeScalars.allSatisfy { lowerOrDigit($0) || "._-".unicodeScalars.contains($0) }
    }

    // MARK: Search results

    public struct SearchPage: Decodable, Sendable {
        public let total: Int
        public let results: [Repository]
    }

    public struct Repository: Decodable, Sendable, Identifiable, Hashable {
        /// `library/redis`, `grafana/grafana`.
        public let id: String
        public let name: String
        /// `image` is something `docker.io` serves. Others — `dhi` (Docker Hardened Images, a
        /// separate subscription registry), `mcp`, `extension`, `plugin` — are not pulled this way.
        public let type: String
        /// `official`, `verified_publisher`, `open_source`, `hardened`, or none.
        public let badge: String?
        public let shortDescription: String?
        /// Rounded by Docker Hub: `1B+`, `10M+`.
        public let pullCount: String?
        public let starCount: Int?
        public let architectures: [String]
        public let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name, type, badge, architectures
            case shortDescription = "short_description", pullCount = "pull_count"
            case starCount = "star_count", updatedAt = "updated_at"
        }

        private struct Architecture: Decodable { let name: String }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            badge = try c.decodeIfPresent(String.self, forKey: .badge)
            shortDescription = try c.decodeIfPresent(String.self, forKey: .shortDescription)
            pullCount = try c.decodeIfPresent(String.self, forKey: .pullCount)
            starCount = try c.decodeIfPresent(Int.self, forKey: .starCount)
            architectures = (try c.decodeIfPresent([Architecture].self, forKey: .architectures) ?? []).map(\.name)
            updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        }

        /// Pullable from `docker.io` by name.
        public var isPullable: Bool { type == "image" && DockerHub.tagsURL(repository: id) != nil }

        /// What a pull names: `redis` for an official image, `grafana/grafana` otherwise.
        public var reference: String { id.hasPrefix("library/") ? String(id.dropFirst("library/".count)) : id }

        /// Whether it has a build Apple silicon runs natively. `false` still pulls — `container`
        /// can run amd64 under Rosetta — but the page says so.
        public var hasARM64: Bool { architectures.contains("arm64") }

        public var badgeLabel: String? {
            switch badge {
            case "official": "Docker Official Image"
            case "verified_publisher": "Verified Publisher"
            case "open_source": "Sponsored OSS"
            default: nil
            }
        }
    }

    // MARK: Tags

    public struct TagPage: Decodable, Sendable {
        public let count: Int
        public let next: String?
        public let results: [Tag]
    }

    public struct Tag: Decodable, Sendable, Identifiable, Hashable {
        public let name: String
        public let lastUpdated: String?
        public let fullSize: Int64?
        public let platforms: [Platform]
        public var id: String { name }

        public struct Platform: Decodable, Sendable, Hashable {
            public let os: String?
            public let architecture: String?
            public let variant: String?
        }

        enum CodingKeys: String, CodingKey {
            case name, images
            case lastUpdated = "last_updated", fullSize = "full_size"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated)
            fullSize = try c.decodeIfPresent(Int64.self, forKey: .fullSize)
            platforms = try c.decodeIfPresent([Platform].self, forKey: .images) ?? []
        }

        /// A `linux/arm64` image — what runs natively on Apple silicon.
        public var hasLinuxARM64: Bool {
            platforms.contains { $0.os == "linux" && $0.architecture == "arm64" }
        }

        /// Only names a pull can use: the tag grammar's characters, nothing a shell or URL would
        /// read as more.
        public var isUsable: Bool {
            guard let first = name.unicodeScalars.first, name.count <= 128 else { return false }
            let word: (Unicode.Scalar) -> Bool = {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
            }
            return word(first) && name.unicodeScalars.allSatisfy { word($0) || $0 == "." || $0 == "-" }
        }
    }

    /// `2026-10-07T21:06:32.281021Z` → a date. Docker Hub writes six fractional digits, which not
    /// every ISO 8601 parser takes, so they are dropped: a second is precise enough for "3 days ago".
    public static func date(_ text: String?) -> Date? {
        guard var text else { return nil }
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            text.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
