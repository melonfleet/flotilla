import Foundation

/// One state change Flotilla **observed** — not a history it was told about.
///
/// The distinction matters enough to be in the type's name and in the UI: these are transitions
/// the poll loop saw between one refresh and the next. Anything that happened before the app
/// launched, or between polls in a way that resolved itself, is not here and cannot be.
struct ContainerEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let from: String
    let to: String

    /// Plain language, because "running → stopped" makes the reader do the translation.
    var summary: String {
        switch to.lowercased() {
        case "running": from.lowercased() == "stopped" ? "Started" : "Running"
        case "stopped": "Stopped"
        default: to.capitalized
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
