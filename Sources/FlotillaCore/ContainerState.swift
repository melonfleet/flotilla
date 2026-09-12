import Foundation

/// The states Apple's `container` actually reports for a container, and the one question the UI
/// asks of them.
///
/// This exists because five places in the app classified a container by matching its state
/// string against `exit`, `dead`, `fail`, `restart` and `(0)` — Docker's vocabulary. Apple's
/// runtime produces none of those, so every one of those rules was unreachable: the "Needs
/// attention" panel on the dashboard and in the menu-bar popover could never render, `stateColor`
/// could never return its danger or warning tint, and `ContainerEvent.isFailure` was always
/// false. Nothing looked broken, because the absence of a panel looks exactly like the absence of
/// a problem.
///
/// **The vocabulary is measured, not assumed** (2026-09-12, `container` 1.4.1):
///
/// - `container ls -a --format json` reported `running` and `stopped` and nothing else.
/// - A container run as `sh -c 'exit 3'` ends `stopped`. So does one killed with
///   `container kill`. A clean exit, a non-zero exit and a SIGKILL are indistinguishable.
/// - `container inspect` returns a `status` object with exactly three keys — `networks`,
///   `startedDate`, `state`. **There is no exit code anywhere in the payload.**
/// - A container whose command does not exist never becomes a record at all: `run` fails and
///   leaves nothing to list.
/// - The runtime's own enum, read out of `/usr/local/bin/container` as a contiguous
///   `RawValue`/`AllCases` block: `unknown`, `stopped`, `running`, `stopping`.
///
/// So Flotilla cannot report that a container *failed*, and must not pretend to. What it can
/// report is `unknown` — the runtime saying it does not know, which is the one listed state that
/// genuinely wants a person. That is rare, and rare is the point: the panels it feeds are absent
/// when empty, on the principle that an always-present "0 problems" panel trains you to stop
/// reading it.
///
/// `other` carries anything unrecognised through rather than failing to decode, and deliberately
/// does **not** count as needing attention — a future release adding a benign state must not
/// light up every row. `ContainerStateTests` pins the four known cases, so a `container` release
/// that widens the vocabulary arrives as a failing test rather than as silence.
public enum ContainerState: Sendable, Equatable, Hashable {
    case running
    /// In the middle of coming down. Transient, and the only state that is legitimately
    /// "in progress" — which is what the warning tint is for.
    case stopping
    case stopped
    /// The runtime cannot say. The one listed state that means something is wrong.
    case unknown
    /// A state this build has not seen. Carried verbatim so nothing is lost or mis-decoded.
    case other(String)

    /// Case-insensitive, because the wire type is a free-form string and matching on exact
    /// casing is the kind of assumption this file exists to stop making.
    public init(_ raw: String) {
        switch raw.lowercased() {
        case "running": self = .running
        case "stopping": self = .stopping
        case "stopped": self = .stopped
        case "unknown": self = .unknown
        default: self = .other(raw)
        }
    }

    /// The runtime's own spelling, so a display path can show exactly what was reported.
    public var rawValue: String {
        switch self {
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .unknown: "unknown"
        case .other(let raw): raw
        }
    }

    /// The four states this build knows about — the vocabulary read from the runtime.
    public static let known: [ContainerState] = [.running, .stopping, .stopped, .unknown]

    public var isRunning: Bool { self == .running }

    /// Whether a person should look at this container.
    ///
    /// Only `unknown`. A stopped container is not a problem — most of them were stopped on
    /// purpose, and the runtime gives no way to tell the rest apart. Claiming otherwise is how
    /// a panel cries wolf; claiming it with a rule that cannot match is how one stays silent
    /// forever.
    public var needsAttention: Bool { self == .unknown }
}

/// The states Apple's `container` reports for a **machine** — the Linux micro-VM, not a
/// container. A separate type because it is a separate vocabulary: it has `starting`, which
/// containers do not, and the two must not be allowed to borrow each other's cases.
///
/// Measured the same way and with the same result on the question that matters: **there is no
/// failure state here either.** `MachinesView.stateColor` tested `status.contains("error")` and
/// `contains("fail")`, which nothing produces, so its danger branch was as unreachable as the
/// container one — the sixth copy of the same mistake, found while fixing the other five.
///
/// Evidence (2026-09-12, `container` 1.4.1):
///
/// - `container machine ls --format json` reported `running` and `stopped` on this Mac, and both
///   captured fixtures carry only those two.
/// - The runtime's VM status enum, read out of `/usr/local/bin/container` in a block whose
///   neighbours are unambiguously the VM domain — `kernel`, `initialFilesystem`, `bootLog`,
///   `rosetta`, `nestedVirtualization`, then `create`/`freeze`/`thaw`/`trim`: `starting`,
///   `running`, `stopped`, `stopping`, `unknown`.
///
/// **`starting` and `stopping` were not observed directly.** A `machine start` on this Mac did
/// not boot the machine (it needs the interactive path `MachinesView` uses), so the two
/// transitional cases rest on the binary and on the existing code having already believed in
/// them — the amber-for-transitional rule predates this and was itself written after a real bug
/// where `contains("stopp")` painted resting machines amber. They are carried here rather than
/// dropped because a state that exists and is unhandled is worse than one that is handled and
/// rare.
public enum MachineState: Sendable, Equatable, Hashable {
    case starting
    case running
    case stopping
    case stopped
    /// The runtime cannot say — the one state that wants a person.
    case unknown
    case other(String)

    public init(_ raw: String) {
        switch raw.lowercased() {
        case "starting": self = .starting
        case "running": self = .running
        case "stopping": self = .stopping
        case "stopped": self = .stopped
        case "unknown": self = .unknown
        default: self = .other(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .unknown: "unknown"
        case .other(let raw): raw
        }
    }

    public static let known: [MachineState] = [.starting, .running, .stopping, .stopped, .unknown]

    public var isRunning: Bool { self == .running }

    /// Something is moving and will settle. This is what the amber tint is for, and the only
    /// thing it is for — a resting `stopped` machine took it once, which is the bug that made
    /// the dot's colour load-bearing in the first place.
    public var isTransitional: Bool { self == .starting || self == .stopping }

    public var needsAttention: Bool { self == .unknown }
}
