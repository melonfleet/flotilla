import Foundation

extension SuggestionLibrary {
    /// Repository identity for artwork matching, independent of a pulled tag or digest.
    /// Only the registry is case insensitive; repository paths keep their spelling.
    public static func imageRepository(_ reference: String) -> String {
        var repository = String(reference.prefix { $0 != "@" })
        if let colon = repository.lastIndex(of: ":"),
           repository.lastIndex(of: "/").map({ colon > $0 }) ?? true {
            repository = String(repository[..<colon])
        }
        var parts = repository.split(separator: "/").map(String.init)
        guard let first = parts.first else { return "" }
        let explicitRegistry = parts.count > 1
            && (first.contains(".") || first.contains(":") || first.lowercased() == "localhost")
        if explicitRegistry {
            parts[0] = first.lowercased()
            // Docker's legacy name for its own registry (distribution/reference normalize.go).
            if parts[0] == "index.docker.io" { parts[0] = "docker.io" }
        } else {
            parts.insert("docker.io", at: 0)
        }
        if parts[0] == "docker.io", parts.count == 2 { parts.insert("library", at: 1) }
        return parts.joined(separator: "/")
    }

    /// Prefer an entry dedicated to this container over a stack that happens to pull it. With no
    /// dedicated entry, a stack's logo is used only when it is the one stack pulling the image: a
    /// database several stacks share is none of theirs, so it doesn't wear Gitea's logo.
    public func entry(forImage image: String) -> LibraryEntry? {
        let repository = Self.imageRepository(image)
        let matches = entries.filter { $0.images.contains { Self.imageRepository($0) == repository } }
        if let dedicated = matches.first(where: { $0.kind == .container && $0.images.count == 1 }) { return dedicated }
        return matches.count == 1 ? matches.first : nil
    }

    /// The library *container* whose ports, variables and volumes an image on this Mac may start
    /// from: the repository match `entry(forImage:)` makes for artwork, **and** the same major
    /// version on both sides (`GroupMembers.majorVersion`). A recipe is operational, not
    /// decorative: PostgreSQL 18 keeps its data at `/var/lib/postgresql` and 17 at
    /// `/var/lib/postgresql/data`, and 18's entrypoint refuses the older mount (Kyle and Iris,
    /// 20 October). `latest`, no tag, or only a digest names no version, so it inherits nothing.
    /// Logos keep matching by repository alone.
    public func recipe(forImage image: String) -> LibraryEntry? {
        guard let entry = entry(forImage: image), entry.kind == .container, let container = entry.container,
              let mine = GroupMembers.majorVersion(of: image),
              mine == GroupMembers.majorVersion(of: container.image) else { return nil }
        return entry
    }

    /// The entry covering the most distinct member repositories; on a tie, the one pulling fewest
    /// images the group doesn't have, so a lone Grafana is Grafana rather than a stack with it.
    /// Library order breaks any remaining tie.
    public func entry(forGroup group: ContainerGroup) -> LibraryEntry? {
        let members = Set(group.members.map { Self.imageRepository($0.image) })
        var best: LibraryEntry?
        var coverage = 0
        var extra = Int.max
        for entry in entries {
            let images = Set(entry.images.map(Self.imageRepository))
            let count = members.intersection(images).count
            let surplus = images.subtracting(members).count
            if count > coverage || (count == coverage && count > 0 && surplus < extra) {
                best = entry; coverage = count; extra = surplus
            }
        }
        return best ?? group.members.first.flatMap { entry(forImage: $0.image) }
    }
}
