import Foundation

// Suggestions for Volumes, Networks and Clusters (DECISIONS Q28, slice 4): Iris's "include" lists,
// decided with the owner on 6 October. Each is one create command, so a suggestion does not get a
// form of its own — it **opens the section's own create form, filled in**, where the name and
// every value can still be changed. One form per thing, as everywhere else.

/// The card a suggestion shows, the same shape for every section.
public protocol ResourceSuggestion: Identifiable, Sendable where ID == String {
    var title: String { get }
    var summary: String { get }
    /// The name it would take; `uniqueName` moves it past anything already there.
    var baseName: String { get }
    /// Label/value lines for the card.
    var details: [(String, String)] { get }
}

public enum ResourceSuggestions {
    /// `base`, or `base-2`, `base-3`… past every name in `taken`.
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

// Summaries are one line on a card, so they stay short; the details rows carry the rest.

// MARK: Volumes

public struct VolumeSuggestion: ResourceSuggestion, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let baseName: String
    /// `-s`: a ceiling, not an allocation — Apple's volumes are sparse.
    public let size: String
    /// Where the image expects it. Shown, because a volume mounted at the wrong path stores nothing.
    public let mountPath: String

    /// Where an older version of the same image expects it, if that differs.
    public var olderMountPath: String? = nil

    public var details: [(String, String)] {
        // Every card carries the row, so the three are the same shape (the owner's card rule).
        [("Size", "up to \(size), allocated as used"), ("Mount at", mountPath),
         ("Older versions", olderMountPath ?? "same path")]
    }

    public static let catalogue: [VolumeSuggestion] = [
        VolumeSuggestion(id: "postgres", title: "PostgreSQL data",
                         summary: "For PostgreSQL 18 and later.",
                         baseName: "postgres-data", size: "10G", mountPath: "/var/lib/postgresql",
                         olderMountPath: "/var/lib/postgresql/data"),
        VolumeSuggestion(id: "mysql", title: "MySQL or MariaDB data",
                         summary: "For a MySQL or MariaDB container.",
                         baseName: "mysql-data", size: "10G", mountPath: "/var/lib/mysql"),
        VolumeSuggestion(id: "mongo", title: "MongoDB data",
                         summary: "For a MongoDB container.",
                         baseName: "mongo-data", size: "10G", mountPath: "/data/db"),
    ]
}

// MARK: Networks

public struct NetworkSuggestion: ResourceSuggestion, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let baseName: String
    /// `--internal`: Apple calls it host-only, so the card does too.
    public let hostOnly: Bool

    public var details: [(String, String)] {
        [("Reaches", hostOnly ? "this Mac only — host-only" : "this Mac and the internet")]
    }

    public static let catalogue: [NetworkSuggestion] = [
        NetworkSuggestion(id: "app", title: "Application network",
                          summary: "For one application's containers.",
                          baseName: "app", hostOnly: false),
        NetworkSuggestion(id: "frontend", title: "Frontend tier",
                          summary: "For web and API containers.",
                          baseName: "frontend", hostOnly: false),
        NetworkSuggestion(id: "backend", title: "Host-only backend",
                          summary: "For databases and caches.",
                          baseName: "backend", hostOnly: true),
    ]
}

// MARK: Clusters

public struct ClusterSuggestion: ResourceSuggestion, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let baseName: String
    public let cpus: Int
    public let memory: String
    /// Pinned by tag **and** digest — kind recommends the digest, and 1.5 needs the tag.
    public let nodeImage: String
    /// `--rm`: removed when it stops.
    public let disposable: Bool

    public var details: [(String, String)] {
        [("Resources", "\(cpus) CPUs, \(memory)B memory"),
         ("Kubernetes", Self.kubernetesVersion(nodeImage) ?? "—"),
         ("When stopped", disposable ? "removed" : "kept")]
    }

    static func kubernetesVersion(_ image: String) -> String? {
        guard let tag = image.split(separator: ":").dropFirst().first?.split(separator: "@").first
        else { return nil }
        return String(tag.dropFirst(tag.hasPrefix("v") ? 1 : 0))
    }

    /// The node image `container` 1.5.0 uses by default — the kind release it was built against.
    public static let nodeImage135 =
        "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"

    public static let catalogue: [ClusterSuggestion] = [
        ClusterSuggestion(id: "starter", title: "Starter",
                          summary: "For learning, manifests and a few small services.",
                          baseName: "k8s-starter", cpus: 2, memory: "2G",
                          nodeImage: nodeImage135, disposable: false),
        ClusterSuggestion(id: "standard", title: "Standard",
                          summary: "For several workloads at once.",
                          baseName: "k8s-dev", cpus: 4, memory: "8G",
                          nodeImage: nodeImage135, disposable: false),
        ClusterSuggestion(id: "disposable", title: "Disposable",
                          summary: "For a quick test.",
                          baseName: "k8s-test", cpus: 2, memory: "2G",
                          nodeImage: nodeImage135, disposable: true),
    ]
}
