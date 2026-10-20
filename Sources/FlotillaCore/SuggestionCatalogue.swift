import Foundation

/// Discovery joins the signed library and the existing compiled presets without changing either
/// format. Namespaced identities keep PostgreSQL the app separate from PostgreSQL the volume.
public enum SuggestionTab: String, CaseIterable, Sendable {
    case all = "All", apps = "Apps", stacks = "Stacks", volumes = "Volumes", networks = "Networks"
    case domains = "Domains", machines = "Machines", clusters = "Clusters"
}

/// The payload is also the handoff: each case opens its existing form, never executes a command.
public enum SuggestionItem: Sendable, Equatable, Identifiable {
    case library(LibraryEntry)
    case volume(VolumeSuggestion)
    case network(NetworkSuggestion)
    case domain(DNSSuggestion)
    case machine(MachineSuggestion)
    case cluster(ClusterSuggestion)

    public var tab: SuggestionTab {
        switch self {
        case .library(let entry): entry.kind == .stack ? .stacks : .apps
        case .volume: .volumes
        case .network: .networks
        case .domain: .domains
        case .machine: .machines
        case .cluster: .clusters
        }
    }

    public var resource: (any ResourceSuggestion)? {
        switch self {
        case .library: nil
        case .volume(let value): value
        case .network(let value): value
        case .domain(let value): value
        case .machine(let value): value
        case .cluster(let value): value
        }
    }

    public var libraryEntry: LibraryEntry? {
        if case .library(let entry) = self { entry } else { nil }
    }

    public var id: String {
        if let entry = libraryEntry { return "library:\(entry.id)" }
        return "\(tab.rawValue.lowercased()):\(resource!.id)"
    }
    public var title: String { libraryEntry?.title ?? resource!.title }
    public var summary: String { libraryEntry?.summary ?? resource!.summary }
    public var details: [(String, String)] { resource?.details ?? [] }

    public var searchText: [String] {
        if let entry = libraryEntry { return entry.searchText + [tab.rawValue] }
        guard let resource else { return [] }
        return [title, summary, tab.rawValue, resource.baseName]
            + details.flatMap { [$0.0, $0.1] }
    }

    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            searchText.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Machines have only a local create path today. Do not silently change a chosen host.
    public func supports(_ host: HostRef) -> Bool { tab != .machines || host.isLocal }
}

public struct SuggestionCatalogue: Sendable {
    public let items: [SuggestionItem]

    public init(library: SuggestionLibrary) {
        items = library.entries.map(SuggestionItem.library)
            + VolumeSuggestion.catalogue.map(SuggestionItem.volume)
            + NetworkSuggestion.catalogue.map(SuggestionItem.network)
            + DNSSuggestion.catalogue.map(SuggestionItem.domain)
            + MachineSuggestion.catalogue.map(SuggestionItem.machine)
            + ClusterSuggestion.catalogue.map(SuggestionItem.cluster)
    }

    public func matching(_ query: String, tab: SuggestionTab = .all, category: String? = nil) -> [SuggestionItem] {
        items.filter {
            (tab == .all || $0.tab == tab) && $0.matches(query)
                && (category == nil || $0.libraryEntry?.categories.contains(category!) == true)
        }
    }

    public func counts(_ query: String, category: String? = nil) -> [SuggestionTab: Int] {
        Dictionary(uniqueKeysWithValues: SuggestionTab.allCases.map {
            ($0, matching(query, tab: $0, category: category).count)
        })
    }

    /// Preserve the existing app/stack review walk. A mixed resource selection is never a batch.
    public static func canUseTogether(_ items: [SuggestionItem], on host: HostRef) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.supports(host) }
            && (items.count == 1 || items.allSatisfy { $0.libraryEntry != nil })
    }
}
