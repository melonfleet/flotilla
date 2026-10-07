import SwiftUI
import FlotillaCore

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

/// How a cross-host action names the Macs it touches (PLAN.md Phase C: keep cross-host actions
/// explicit about the hosts affected). `nil` when it touches only This Mac — the wording every
/// dialog had before there were hosts, and still the right amount to say.
enum FleetWording {
    /// "On This Mac, Tahoe-Test-VM and the mini." — each Mac once, in the order first met.
    static func onMacs(_ hosts: [(ref: HostRef, name: String)]) -> String? {
        var seen = Set<HostRef>(), names: [String] = []
        for host in hosts where seen.insert(host.ref).inserted { names.append(host.name) }
        guard seen.contains(where: { !$0.isLocal }) else { return nil }
        let list = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + names.last!
            : names[0]
        return "On \(list)."
    }
}
