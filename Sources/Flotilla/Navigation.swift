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
    case dashboard, activity, logs, containers, images, volumes, networks, machines, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .activity: "Activity"
        case .logs: "Logs"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .machines: "Machines"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.bottom.50percent"
        // Verified to exist before use, per the `ellipsis.vertical` incident.
        case .logs: "text.alignleft"
        case .activity: "clock.arrow.circlepath"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.down.right"
        case .volumes: "cylinder.split.1x2"
        case .networks: "network"
        case .machines: "server.rack"
        case .settings: "gearshape"
        }
    }
}
