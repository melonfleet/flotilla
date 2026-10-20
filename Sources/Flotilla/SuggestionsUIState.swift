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

    /// The list's scroll position, as the first row at least half in view: Use replaces the list
    /// with a form, and the list drawn on return starts at the top (Kyle, 20 October, round 2).
    /// Not observed — it changes on every scroll step and is read only when the list is drawn.
    @ObservationIgnored private(set) var scrollAnchor: String?
    /// The middle of each row on screen, in the list's own scroll coordinates. A macOS `List` does
    /// not report `onScrollVisibilityChange` faithfully (measured: rows never leave), and `onAppear`
    /// runs a couple of rows early, so the anchor is read from row geometry instead.
    @ObservationIgnored private var rowMiddles: [String: CGFloat] = [:]

    func rowMoved(_ id: String, middle: CGFloat) {
        rowMiddles[id] = middle
        scrollAnchor = rowMiddles.filter { $0.value >= 0 }.min { $0.value < $1.value }?.key
    }

    /// Off screen, or the list is going: forget the row without moving the anchor, so tearing the
    /// list down for a form does not lose the place it is meant to keep.
    func rowGone(_ id: String) { rowMiddles[id] = nil }
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
