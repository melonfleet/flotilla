import Foundation

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
