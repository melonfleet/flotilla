import SwiftUI
import FlotillaCore

/// View state for the Logs section, owned by `MainWindowView` for the reason every other
/// section's state is: the detail views are destroyed and recreated on each sidebar change, so
/// a filter held as `@State` inside `LogsView` would reset the moment you visited Containers
/// and came back — and losing a filter you just set is worse on this screen than on any other,
/// because it is the one you arrive at *with a question already in mind*.
@Observable
final class LogsUIState {

    /// Which log a source is asked for. **Not** stdout-versus-stderr, which would be a filter
    /// that drives nothing: `container logs` has exactly one switch here — `--boot` for the VM
    /// boot log instead of the process output — and no `--timestamps` at all.
    enum Scope: String, CaseIterable, Identifiable {
        case stdio = "Output", boot = "Boot"
        var id: Self { self }
        var isBoot: Bool { self == .boot }

        /// Verified to exist before use, per the `ellipsis.vertical` incident.
        var systemImage: String { self == .boot ? "power" : "text.alignleft" }
        var accessibilityLabel: String {
            self == .boot ? "Boot log" : "Process output"
        }
    }

    /// Which kinds of source to fetch from. Containers and machines both answer `logs`, through
    /// different subcommands, and mixing them is the whole point of an aggregated view.
    enum Sources: String, CaseIterable, Identifiable {
        case all = "All", containers = "Containers", machines = "Machines"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .all: "square.stack.3d.up"
            case .containers: ActivityKind.container.systemImage
            case .machines: ActivityKind.machine.systemImage
            }
        }
    }

    var scope: Scope = .stdio
    var sources: Sources = .all

    /// Free-text filter, applied to the line and to its source name.
    var search = ""

    /// Only these sources, when the user has narrowed to specific ones. Empty means "every
    /// source in `sources`" rather than "none" — an empty set that meant nothing would make the
    /// screen go blank the first time someone opened the menu and closed it again.
    var only: Set<String> = []

    /// How many lines to ask each source for.
    ///
    /// **Bounded on purpose, and there is no "all".** `container logs` with no `-n` "will print
    /// all of the logs" (its own help), which on a busy container is an unbounded read into
    /// memory — and the 47-spec audit flagged exactly that as a wire-boundary hazard. A ceiling
    /// the user picks is honest; an unbounded fetch behind a friendly button is not.
    var lineLimit = 200
    static let lineLimits = [100, 200, 500, 1000]

    /// Whether the section is streaming rather than fetching.
    ///
    /// Lives here with the filters rather than as `@State` in the view for the same reason they
    /// do: the section view is rebuilt on every sidebar change, so a tail held locally would
    /// stop the moment you looked at Containers — and silently, which is the worst way for a
    /// live view to stop.
    var live = false

    /// The most sources this section will follow at once.
    ///
    /// A judgement, not a measurement, and worth stating as one. Each followed source is its own
    /// `container logs --follow` process with a reader thread pair, so the cost is linear in
    /// sources; and the source tag is a fixed 128pt column, which stops being scannable at about
    /// this many distinct names anyway. Above the ceiling Live is refused with a reason rather
    /// than quietly following a subset — a live view that silently omits sources is worse than
    /// one that will not start.
    ///
    /// Raise it if someone has a real fleet and the processes turn out to be cheap; the number
    /// is here, once, so that is a one-line change.
    static let maxLiveSources = 8
}
