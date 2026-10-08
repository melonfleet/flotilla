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
    private(set) var outcome: Outcome?

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
        return step.id
    }

    func finish(_ id: UUID, detail: String? = nil, failed: Bool = false) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = failed ? .failed : .done
        steps[index].detail = detail
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
    }

    func note(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        output.append(trimmed)
        // The panel is a progress report, not a log viewer. A build can emit thousands of lines
        // and the last few are the ones that matter.
        if output.count > 400 { output.removeFirst(output.count - 400) }
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

/// The progress panel, over the window.
///
/// Modal, and deliberately so — this is one of the two shapes `ModalCard` is still for: a dialog
/// you acknowledge, not a form you fill in. It dismisses itself on success, because the point is
/// to bridge the gap until the list is correct rather than to add a click; a failure stays up,
/// because that is the one case with something to read.
struct OperationProgressView: View {
    let progress: OperationProgress
    let dismiss: () -> Void

    var body: some View {
        // `onClose` is wired even while running, because a modal with no way out is a trap if
        // something hangs — but the panel does not pretend the work stopped: dismissing hides the
        // report, and the operation it describes carries on in its own task.
        ModalCard(title: progress.title, onClose: dismiss) {
            VStack(alignment: .leading, spacing: 12) {
                Text(progress.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(progress.steps) { step in
                        stepRow(step)
                    }
                }

                if !progress.output.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(progress.output.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        // Selectable, because this is where a command reports
                                        // a path or a line to run. Writing a kubeconfig puts
                                        // both here, and a panel that shows you a command you
                                        // cannot copy has made you retype it.
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 120)
                        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                        .textSelection(.enabled)
                        // Follows the output, for the same reason the live log tail does: a feed
                        // that arrives below the fold is indistinguishable from one that stopped.
                        .onChange(of: progress.output.count) { _, count in
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }

                if case .failed(let reason) = progress.outcome {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    if progress.outcome == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(progress.outcome?.isFailure == true ? "Close" : "Done",
                               action: dismiss)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(width: 460)
            .padding(16)
        }
    }

    private func stepRow(_ step: OperationProgress.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch step.state {
                case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
                case .done: Image(systemName: "checkmark").foregroundStyle(Theme.online)
                case .failed: Image(systemName: "xmark").foregroundStyle(Theme.danger)
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 14)

            Text(step.title).font(.system(size: 12))
            if let detail = step.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
