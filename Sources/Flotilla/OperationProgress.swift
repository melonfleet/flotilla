import SwiftUI
import FlotillaCore

/// One long-running thing the app is doing on the user's behalf, and what it has done so far.
///
/// **This exists because of what the redesign quietly removed.** Creating a container, machine,
/// volume or network used to report itself; once the forms became embedded screens that return
/// to their list on save, the report went with them. What is left is a table that does not have
/// the new row in it yet — `container run` takes seconds, the poll that would notice takes more —
/// so the honest reading of that screen is "nothing happened", and the user goes looking for a
/// bug that is not there.
///
/// The fix is not a spinner. A spinner says *something* is happening; this says **what**, step by
/// step, with the command it ran so the whole thing is reproducible in a terminal, and it stays
/// up until the new item is actually in the list — which is the specific gap being closed.
/// `@MainActor` because every field feeds a view directly and the callers that write to it —
/// a pull's progress callback, a build's output — arrive from the runner's own thread and hop
/// here. Marking it keeps that hop explicit rather than leaving it to be remembered.
@MainActor
@Observable
final class OperationProgress: Identifiable {
    let id = UUID()
    /// "Run a container", "Pull an image" — a sentence about intent, not a command name.
    let title: String
    /// The argv, exactly as it will run. Shown so the panel is not opaque and so a failure is
    /// something the user can reproduce and paste to someone else.
    let command: String
    let startedAt = Date()

    private(set) var steps: [Step] = []
    /// Whatever the command actually said. Empty for commands that say nothing, which is most of
    /// them when they succeed.
    private(set) var output: [String] = []
    private(set) var outcome: Outcome? { didSet { onChange?() } }

    /// Set by `TaskCenter`, so the status bar's line and the task's state follow this object by
    /// identity. Before the Tasks drawer (Q63) the model reached a running job only through a
    /// single "active" slot, and hiding the panel emptied the slot: the job ran on, and its
    /// updates went nowhere.
    @ObservationIgnored var onChange: (() -> Void)?

    /// The newest thing this task said, for the status bar: its last output line, or else a
    /// running step and its detail.
    var latestLine: String? {
        if let last = output.last { return last }
        guard let step = steps.last(where: { $0.state == .running }) else { return nil }
        return step.detail.map { "\(step.title) — \($0)" } ?? step.title
    }

    enum Outcome: Equatable {
        case succeeded(String)
        case failed(String)

        var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    struct Step: Identifiable {
        let id = UUID()
        let title: String
        var state: State = .running
        /// What this step found — a count, a name, the CLI's own complaint.
        var detail: String?

        enum State { case running, done, failed }
    }

    init(title: String, command: String) {
        self.title = title
        self.command = command
    }

    /// Begins a step and returns its id, so the caller can finish exactly the one it started
    /// rather than "the last one" — which goes wrong the moment two steps overlap.
    @discardableResult
    func begin(_ title: String) -> UUID {
        let step = Step(title: title)
        steps.append(step)
        onChange?()
        return step.id
    }

    func finish(_ id: UUID, detail: String? = nil, failed: Bool = false) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = failed ? .failed : .done
        steps[index].detail = detail
        onChange?()
    }

    /// Updates a running step's detail, leaving it running.
    ///
    /// `finish` also sets a detail, but it marks the step done — right for a step that has
    /// produced its answer, wrong for one that is still working. A cluster create runs for
    /// minutes and the CLI reports itself the whole way; without this the panel could only show
    /// a spinner, which is indistinguishable from a hang. That is exactly how it looked.
    func update(_ id: UUID, detail: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].detail = detail
        onChange?()
    }

    func note(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        output.append(trimmed)
        // The panel is a progress report, not a log viewer. A build can emit thousands of lines
        // and the last few are the ones that matter.
        if output.count > 400 { output.removeFirst(output.count - 400) }
        onChange?()
    }

    func succeed(_ summary: String) {
        markRemainingStepsDone()
        outcome = .succeeded(summary)
    }

    func fail(_ reason: String) {
        if let index = steps.lastIndex(where: { $0.state == .running }) {
            steps[index].state = .failed
        }
        outcome = .failed(reason)
    }

    private func markRemainingStepsDone() {
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = .done
        }
    }
}

