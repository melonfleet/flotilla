import Foundation

/// The resource a feed entry belongs to.
///
/// Deliberately not derived from the model types: a volume that has been *deleted* still needs an
/// entry, and by then there is no `ContainerVolume` left to ask.
enum ActivityKind: String, CaseIterable, Identifiable, Hashable {
    case container, machine, image, volume, network
    var id: Self { self }

    var title: String {
        switch self {
        case .container: "Containers"
        case .machine: "Machines"
        case .image: "Images"
        case .volume: "Volumes"
        case .network: "Networks"
        }
    }

    /// The same glyph the sidebar uses for that section, so the feed reads as a view *onto* the
    /// sections rather than as a separate inventory.
    var systemImage: String {
        switch self {
        case .container: "shippingbox"
        case .machine: "server.rack"
        case .image: "square.stack.3d.up"
        case .volume: "cylinder.split.1x2"
        case .network: "network"
        }
    }

    /// Where a feed row should take you when clicked.
    var section: Section {
        switch self {
        case .container: .containers
        case .machine: .machines
        case .image: .images
        case .volume: .volumes
        case .network: .networks
        }
    }
}

/// Something that happened to a container or machine — either a transition Flotilla observed,
/// or an action it performed.
///
/// It used to be observations only, and that had a hole: **a restart never appeared in the
/// activity strip.** The poll loop compares one refresh with the next, and a restart of a
/// running thing ends where it began, so there is no change to see. Start and stop each leave a
/// lasting state, which is why those two did show up. Waiting for a faster poll would not fix
/// it either — the stop and the start can both land between two polls.
///
/// So an action that has no net state change has to be recorded by whoever performs it. `action`
/// is set in that case and left nil for an observed transition, which keeps the two
/// distinguishable rather than dressing one up as the other.
///
/// Observations still matter and are still recorded: they are the only way a change made outside
/// Flotilla — someone running `container stop` in a terminal — reaches the strip at all.
struct ContainerEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let from: String
    let to: String

    /// Which kind of thing this happened to, and which one.
    ///
    /// Added so a single feed can carry every resource kind. There used to be two separate
    /// dictionaries — containers and machines — and images, volumes and networks recorded
    /// nothing at all, so there was no place to ask "what has changed on this Mac?". Three more
    /// dictionaries would have made that worse; one flat log answers it directly and the
    /// per-subject lists the detail views want are a filter over it.
    var kind: ActivityKind = .container
    var subject: String = ""

    /// Set when this records an action Flotilla performed; nil for an observed transition.
    var action: String?

    /// Plain language, because "running → stopped" makes the reader do the translation.
    var summary: String {
        if let action { return action }
        switch to.lowercased() {
        case "running": return from.lowercased() == "stopped" ? "Started" : "Running"
        case "stopped": return "Stopped"
        default: return to.capitalized
        }
    }

    var detail: String { "from \(from.lowercased())" }

    /// Failure is not the same as a clean stop and must not look like one.
    var isFailure: Bool {
        let state = to.lowercased()
        return state.contains("exit") && !state.contains("(0)")
            || state.contains("dead") || state.contains("fail")
    }
}
