import SwiftUI
import FlotillaCore

// The pieces a group is drawn with, now that groups are rows in the Containers list (5 October,
// to-do item 4) rather than a section of their own. Moved here from the retired `GroupsView`.

/// Which group the form is editing, or that it is making a new one.
enum GroupFormTarget: Identifiable, Hashable {
    case new
    case existing(String)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let groupID): groupID
        }
    }
}

/// A group's state as a dot, in the column every other row puts its state dot in.
///
/// **Partly running is a half-filled dot, not an amber one** (the owner, 5 October). Amber is the
/// colour for "needs attention", and a group with two of three services up is not necessarily a
/// problem: it may be stopped on purpose. Green, grey and a half of the green say "all", "none"
/// and "some" without borrowing a colour that means something else. The count goes beside it,
/// because "some of it is running" is not actionable and "2/3" is.
struct GroupStateDot: View {
    let state: GroupState

    var body: some View {
        HStack(spacing: 4) {
            dot
            if case .partial(let running, let total) = state {
                Text("\(running)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(state.title) — \(state.explanation)")
        .accessibilityLabel(state.title)
    }

    /// Half-filled only when **some** members are running. `GroupState.partial` also covers
    /// "none running, but only some exist" (`partial(running: 0, …)`), and drawing that half green
    /// claimed something was up when nothing was — seen on screen, 5 October. Nothing running is
    /// grey, whatever the reason.
    @ViewBuilder
    private var dot: some View {
        if case .partial(let running, _) = state, running > 0 {
            HalfDot(color: Theme.online)
        } else {
            Circle().fill(state.tint).frame(width: 8, height: 8)
        }
    }
}

/// An 8pt dot, outlined, with its left half filled.
private struct HalfDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.2)
            Circle().fill(color)
                .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
        }
        .frame(width: 8, height: 8)
    }
}

/// A member's state, read from its container rather than from the group.
///
/// A container that does not exist yet is a hollow ring, not a grey dot: "stopped" and "never
/// created" are different answers to "why is this not running".
struct ServiceStateDot: View {
    let container: Container?

    var body: some View {
        Group {
            if let container {
                Circle()
                    .fill(container.stateColor)
                    .frame(width: 8, height: 8)
                    .help(container.status.state.capitalized)
                    .accessibilityLabel(container.status.state.capitalized)
            } else {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1)
                    .frame(width: 8, height: 8)
                    .help("Not created yet")
                    .accessibilityLabel("Not created")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How a group's state is *drawn*. In the app target, not beside `GroupState` in `FlotillaCore`,
/// for the reason `ActivityKind` gives: the Foundation-only core has no business knowing SF
/// Symbol names or colours.
extension GroupState {
    var title: String {
        switch self {
        case .empty: "No services"
        case .notCreated: "Not created"
        case .stopped: "Stopped"
        case .partial(let running, let total): "\(running) of \(total) running"
        case .running: "Running"
        }
    }

    /// The dot's colour. A partly running group draws a *half* of the green instead — see
    /// `GroupStateDot` — so it never takes the warning amber.
    var tint: Color {
        switch self {
        case .empty, .notCreated, .stopped: .secondary
        case .partial(let running, _): running > 0 ? Theme.online : .secondary
        case .running: Theme.online
        }
    }

    /// "Not created" is the one state a user will misread, so it explains itself.
    var explanation: String {
        switch self {
        case .empty: "This group has no services in it yet."
        case .notCreated: "None of these containers exists on this Mac yet. Starting the group creates them."
        case .stopped: "Every container exists and none is running."
        case .partial: "Some of this group is running and some is not."
        case .running: "Every service in this group is running."
        }
    }

    /// Sorts with containers' own state rank (`Container.sortRank`: running 0, stopped 1) scaled
    /// up, so a running group sits with running containers and a stopped one with stopped ones.
    var sortRank: Int {
        switch self {
        case .running: 0
        // Partly running sorts between running and stopped; nothing running sorts as stopped.
        case .partial(let running, _): running > 0 ? 1 : 2
        case .stopped: 2
        case .notCreated: 3
        case .empty: 4
        }
    }
}

/// A group in the Cards view: its state, its tags, and a chip per member (the owner, 5 October).
///
/// Chips rather than nested cards, because a card that grows to hold three more cards reflows the
/// whole grid each time it opens. A chip says enough at a glance — the member's state and its name
/// — and clicking it opens that container, the thing you want once you are looking at one service.
struct GroupCard<Actions: View>: View {
    let group: ContainerGroup
    let state: GroupState
    let members: [ContainerListing.Member]
    var tags: [Tag] = []
    let onEdit: () -> Void
    let onOpenMember: (String) -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Section.groupSymbol)
                    .foregroundStyle(.secondary)
                Button(group.name, action: onEdit)
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.link)
                    .lineLimit(1)
                    .help("Edit \(group.name)")
                Spacer(minLength: 0)
                GroupStateDot(state: state).fixedSize()
            }

            Text(state.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !tags.isEmpty {
                TagPillRow(tags: tags, limit: 4)
            }

            if members.isEmpty {
                Text("No services yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                FlowChips(members: members, onOpen: onOpenMember)
            }

            Divider()
            actions
        }
        // The app's one card surface, the same as the container cards beside it and every other
        // section's (the owner, 5 October: one card style, not two).
        .cardSurface()
    }
}

/// The member chips, wrapping onto as many lines as they need.
private struct FlowChips: View {
    let members: [ContainerListing.Member]
    let onOpen: (String) -> Void

    var body: some View {
        WrappingLayout(spacing: 5) {
            ForEach(members, id: \.member.id) { member in
                chip(member)
            }
        }
    }

    @ViewBuilder
    private func chip(_ member: ContainerListing.Member) -> some View {
        let label = HStack(spacing: 4) {
            ServiceStateDot(container: member.container).fixedSize()
            Text(member.member.name).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())

        if member.container != nil {
            Button { onOpen(member.member.name) } label: { label }
                .buttonStyle(.plain)
                .help("Open \(member.member.name)")
        } else {
            label
                .foregroundStyle(.secondary)
                .help("Not created yet — starting the group creates it")
        }
    }
}

/// Lays children out left to right, wrapping when a line is full.
private struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row { var y: CGFloat; var height: CGFloat; var width: CGFloat; var items: [(index: Int, x: CGFloat, size: CGSize)] }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, width: 0, items: [])
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = current.items.isEmpty ? 0 : current.width + spacing
            if !current.items.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing, height: 0, width: 0, items: [])
            }
            let start = current.items.isEmpty ? 0 : current.width + spacing
            current.items.append((index, start, size))
            current.width = start + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
