import SwiftUI

/// The Host column's cell, the same in every fleet table (PLAN.md Phase C): which Mac the row is
/// on, and — when that Mac has stopped answering — a marker saying how old the row is. A host that
/// drops keeps its rows rather than emptying the table.
struct HostCell: View {
    let name: String
    let staleSince: Date?

    var body: some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary).lineLimit(1)
            if let staleSince {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(Theme.warning)
                    .help("As of \(staleSince.formatted(.relative(presentation: .named))) — \(name) isn’t answering")
            }
        }
    }
}
