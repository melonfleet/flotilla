import Foundation

/// The sidebar's content, per the Phase 1 UI navigation contract.
///
/// Deliberately named `Section` per the contract even though `SwiftUI` also exports a
/// `Section` view builder — a top-level type in this module shadows the imported one,
/// so any file that needs the SwiftUI grouping type inside a `Form`/`List` must spell it
/// `SwiftUI.Section` explicitly. The CLI owner codes against this enum as-is; do not edit it here
/// without updating that agreement.
enum Section: String, CaseIterable, Identifiable, Hashable {
    // Dashboard first: it is the overview you land on, and every other section is a
    // drill-down from something it shows.
    // No `groups`: groups are rows in Containers since 5 October (to-do item 4), the way Docker
    // Desktop lists a Compose stack, rather than a section of their own.
    // `registries` sits under Images (the owner, 5 October): it is where images come from, and
    // it moved out of Settings because it is something you manage, not something you set once.
    // `dns` sits under Networks (6 October): a local domain is how containers are found by name,
    // which is a networking question — and the competitor that prompted it files it there too.
    // `overview` replaced `dashboard` and `hosts` arrived on 6 October (the owner's fleet
    // redesign): Overview is fleet numbers only; each host's page — the old dashboard — is under
    // Hosts.
    case overview, activity, logs, containers, images, registries, volumes, networks, dns,
         machines, clusters, hosts, settings, notifications

    var id: Self { self }

    /// The glyph for a group, wherever one is drawn — a group row, a group card. Kept from the
    /// retired Groups section. Not a `square.stack.3d.*`: Images already uses that family, and a
    /// group of containers is not a stack of layers. Verified present, per the
    /// `ellipsis.vertical` incident.
    static let groupSymbol = "rectangle.3.group"

    var title: String {
        switch self {
        case .overview: "Overview"
        case .hosts: "Hosts"
        case .activity: "Activity"
        case .logs: "Logs"
        case .containers: "Containers"
        case .images: "Images"
        case .registries: "Registries"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .dns: "DNS"
        case .machines: "Machines"
        case .clusters: "Kubernetes"
        case .settings: "Settings"
        case .notifications: "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        // Verified present, per the `ellipsis.vertical` incident.
        case .overview: "square.grid.2x2"
        case .hosts: "desktopcomputer"
        // Verified to exist before use, per the `ellipsis.vertical` incident.
        case .logs: "text.alignleft"
        case .activity: "clock.arrow.circlepath"
        case .containers: "shippingbox"
        // Verified present, per the `ellipsis.vertical` incident.
        case .images: "square.stack.3d.down.right"
        // The glyph the Settings tab used, so nobody has to relearn it.
        case .registries: "shippingbox.and.arrow.backward"
        case .volumes: "cylinder.split.1x2"
        case .networks: "network"
        // A name pointing the way. Verified present, per the `ellipsis.vertical` incident.
        case .dns: "signpost.right.and.left"
        case .machines: "server.rack"
        case .clusters: "circle.hexagongrid"
        case .settings: "gearshape"
        // The bell in the window bar (the owner, 10 October), not a sidebar row.
        case .notifications: "bell"
        }
    }
}
