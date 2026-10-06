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

// MARK: Machines

public struct MachineSuggestion: ResourceSuggestion, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let baseName: String
    public let image: String
    public let cpus: Int
    public let memoryGB: Int
    /// What PID 1 is — the thing Apple requires of a machine image, and what tells them apart.
    public let initSystem: String

    public var details: [(String, String)] {
        [("Image", image.replacingOccurrences(of: "docker.io/library/", with: "")
                       .replacingOccurrences(of: "docker.io/", with: "")),
         ("Resources", "\(cpus) CPUs, \(memoryGB) GB memory"),
         ("Init", initSystem)]
    }

    /// Each **booted and logged in to** on container 1.5.0 before shipping (6 October): created,
    /// booted, `/etc/os-release` read, a login shell opened as the Mac's user, stopped and booted
    /// again. Stock Ubuntu and Debian are absent because they cannot be machines — Apple needs
    /// `/sbin/init` in the image (`research/MACHINES-SPEC.md`). AlmaLinux is pinned to a dated
    /// build; Iris's research named older ones, and these are the newest. Written as the machine
    /// form's own verified list writes them, so the form recognises them as verified.
    public static let catalogue: [MachineSuggestion] = [
        MachineSuggestion(id: "alpine", title: "Alpine",
                          summary: "A small, quick shell or build box.",
                          baseName: "alpine-box", image: "alpine:3.22",
                          cpus: 2, memoryGB: 2, initSystem: "BusyBox init"),
        MachineSuggestion(id: "alma9", title: "AlmaLinux 9",
                          summary: "A stable, RHEL-compatible development VM.",
                          baseName: "alma9-dev",
                          image: "almalinux/9-init:9.8-20261002",
                          cpus: 4, memoryGB: 4, initSystem: "systemd"),
        MachineSuggestion(id: "alma10", title: "AlmaLinux 10",
                          summary: "The current RHEL-compatible generation.",
                          baseName: "alma10-dev",
                          image: "almalinux/10-init:10.2-20261002",
                          cpus: 4, memoryGB: 4, initSystem: "systemd"),
    ]
}

// MARK: DNS domains

public struct DNSSuggestion: ResourceSuggestion, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    /// The domain itself. Not moved to `-2` like other names: a domain that exists is the same
    /// domain, and the form says so.
    public let baseName: String
    /// Set for a host alias.
    public let hostAddress: String?

    public var details: [(String, String)] {
        [("Kind", hostAddress == nil ? "Container names" : "Host alias"),
         ("Example", hostAddress.map { "\(baseName) → this Mac, via \($0)" } ?? "web.\(baseName)"),
         ("Safe because", hostAddress == nil
             ? "reserved — never a real internet domain"
             : "an address reserved for examples")]   // Apple's documented one (RFC 5737)
    }

    /// The owner's choice, 6 October. Container-name domains are alternatives — the runtime
    /// names containers under one domain at a time.
    public static let catalogue: [DNSSuggestion] = [
        DNSSuggestion(id: "test", title: "test",
                      summary: "Container names like web.test.",
                      baseName: "test", hostAddress: nil),     // RFC 6761
        DNSSuggestion(id: "internal", title: "internal",
                      summary: "Container names like web.internal.",
                      baseName: "internal", hostAddress: nil), // ICANN, for private use, 2024
        DNSSuggestion(id: "host", title: "host.container.internal",
                      summary: "Reach a service on this Mac from a container.",
                      baseName: "host.container.internal", hostAddress: "203.0.113.113"),
    ]
}
