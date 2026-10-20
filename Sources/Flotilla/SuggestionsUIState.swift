import SwiftUI
import FlotillaCore

/// Owned by MainWindowView: browsing survives forms and trips to other sidebar sections.
@Observable
final class SuggestionsUIState {
    var tab: SuggestionTab = .all
    var query = ""
    var category: String?
    var selection = Set<String>()
    var host: HostRef = .local
    let pane = PaneState()
}

extension SuggestionTab {
    var systemImage: String {
        switch self {
        case .all: "sparkles"
        case .apps: Section.containers.systemImage
        case .stacks: Section.groupSymbol
        case .volumes: Section.volumes.systemImage
        case .networks: Section.networks.systemImage
        case .domains: Section.dns.systemImage
        case .machines: Section.machines.systemImage
        case .clusters: Section.clusters.systemImage
        }
    }
}
