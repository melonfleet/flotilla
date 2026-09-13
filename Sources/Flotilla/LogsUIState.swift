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

    // MARK: Presentation

    /// Whether a long message wraps onto as many lines as it needs, or stays on one and is
    /// truncated.
    ///
    /// **Off by default**, which is the opposite of what reading prose would want and right for
    /// this screen: a log is scanned far more often than it is read, and one line per event is
    /// what makes two hundred of them scannable. A single 900-character stack trace with wrapping
    /// on pushes everything else off the screen. Turning it on is one click, and a single row can
    /// be expanded without turning it on for everything.
    var wrapLines = false

    /// Rows the user has opened to see the whole message. Ids, so an expansion survives the feed
    /// being refetched — the line keeps its `source#index` identity across a reload of the same
    /// window of output.
    var expanded: Set<String> = []

    /// Selected rows, for copy and for "export just these".
    ///
    /// Held here rather than as view `@State` for the same reason every other filter is: this
    /// section is rebuilt on each sidebar change, and a selection you made in order to export it
    /// must survive looking something up.
    var selection: Set<String> = []

    /// Which columns the feed table is showing, and how wide.
    ///
    /// Same mechanism every other section's table uses, for the same reason: a column you hid
    /// must stay hidden when you come back from looking something up.
    var columnCustomization = TableColumnCustomization<AggregatedLogLine>()

    /// Whether the Received column is showing.
    ///
    /// **Off by default, and the default is the honest one.** `container logs` has no
    /// `--timestamps`, so there is no time in the data; the column shows when *Flotilla* received
    /// the line, which is real per-line information while streaming and one identical value per
    /// source while fetching. A column of two hundred identical timestamps, on by default, would
    /// read as the container's own clock and be believed. Off by default, with a header that says
    /// what it is, it is a tool for the case where it means something.
    var showTimestamps = false

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
