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
    /// The "2/3" beside a partly running group's dot. Off in a two-line row, where the second line
    /// says it in words and a fixed-width state mark must not change width with the state.
    var showsCount = true

    var body: some View {
        HStack(spacing: 4) {
            dot
            if showsCount, case .partial(let running, let total) = state {
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
        case .notCreated: "None of these containers exists yet. Starting the group creates them."
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
