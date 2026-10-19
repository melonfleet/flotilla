import SwiftUI
import FlotillaCore

/// The Tasks drawer (Q63, Kamal, 19 October): rises from the bottom of the window, just above the
/// status bar, when a job starts, and sinks into the status bar's Tasks item when minimised.
///
/// It replaced a centred sheet. That sheet was modal, so watching a forty-second pull meant not
/// using the window for forty seconds, and its Hide orphaned the job's output. The drawer is not
/// modal: the page above it stays live, and minimising it changes nothing about the job.
struct TaskDrawer: View {
    let tasks: TaskCenter
    @State private var expanded: Set<UUID> = []
    @FocusState private var focused: Bool

    static let height: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: Self.height)
        .background(Theme.raisedSurface, in: shape)
        .overlay(shape.strokeBorder(Theme.hairline))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.18), radius: 10, y: -2)
        .padding(.horizontal, 12)
        // A click anywhere in it gives it focus, so Esc minimises without hunting for the button.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand { tasks.minimise() }
        // Asked for — the status item, ⌥⌘T — it takes focus, so Esc puts it away again. Risen
        // because a job started, it does not: the user may be typing in the form that started it.
        .onAppear { if tasks.board.drawer == .list { focused = true } }
        .onChange(of: tasks.board.drawer) { _, drawer in if drawer == .list { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks")
        .accessibilityHint("Press Escape to minimise into the status bar")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
    }

    // MARK: -

    private var header: some View {
        HStack(spacing: 8) {
            switch tasks.board.drawer {
            case .task(let id):
                Button {
                    tasks.showList()
                } label: {
                    Label("All Tasks", systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("All tasks")
                .accessibilityLabel("Show all tasks")
                Text(tasks.board.entry(id)?.title ?? "Task")
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            default:
                Text("Tasks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            if tasks.board.drawer == .list, tasks.board.hasFinished {
                Button("Clear Finished") { tasks.clearFinished() }
                    .controlSize(.small)
            }
            Button {
                tasks.minimise()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Minimise into the status bar (Esc). Tasks keep running.")
            .accessibilityLabel("Minimise tasks")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tasks.board.drawer {
        case .task(let id):
            if let progress = tasks.progress(id) {
                TaskDetailView(progress: progress, fillsHeight: true)
                    .padding(14)
            }
        default:
            let ordered = tasks.board.ordered
            if ordered.isEmpty {
                Text("No tasks this session.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ordered) { entry in
                            row(entry)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: TaskBoard.Entry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        TaskStateMark(state: entry.state)
                        Text(entry.title).lineLimit(1)
                        Text(Self.stateText(entry.state))
                            .foregroundStyle(entry.state.isFailure ? Theme.danger : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.finishedAt ?? entry.startedAt, style: .time)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.title), \(Self.stateText(entry.state))")
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the task's steps and output")
                if entry.state.isFinished {
                    Button("Clear") { tasks.clear(entry.id) }
                        .controlSize(.small)
                        .accessibilityLabel("Clear \(entry.title)")
                }
            }
            .font(.system(size: 12))
            if isOpen, let progress = tasks.progress(entry.id) {
                TaskDetailView(progress: progress, fillsHeight: false)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    static func stateText(_ state: TaskBoard.State) -> String {
        switch state {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        }
    }
}

/// A task's command, steps, output and outcome — what the centred progress panel used to show,
/// in the drawer now. Selectable, because this is where a command reports a path or a line to
/// run, and a panel that shows you a command you cannot copy has made you retype it.
struct TaskDetailView: View {
    let progress: OperationProgress
    /// In the drawer's single-task view the output takes the room left; in a list row it is fixed.
    let fillsHeight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let reason) = progress.outcome {
                // First, so a drawer that turned to a failure opens on the reason.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }

            Text(progress.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

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
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 60, maxHeight: fillsHeight ? .infinity : 120)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                    // Follows the output, for the same reason the live log tail does: a feed that
                    // arrives below the fold is indistinguishable from one that stopped.
                    .onChange(of: progress.output.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo(progress.output.count - 1, anchor: .bottom) }
                }
            } else if fillsHeight {
                Spacer(minLength: 0)
            }

            if case .succeeded(let summary) = progress.outcome {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
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
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Running, done or failed, as a symbol.
private struct TaskStateMark: View {
    let state: TaskBoard.State

    var body: some View {
        Group {
            switch state {
            case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.online)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The status bar's Tasks item: always there, beside the Helper. A spinner, a count and the newest
/// line while anything runs; red until looked at after a failure; "<title> finished" briefly after
/// a success; otherwise just "Tasks". A click opens the drawer on the task list.
struct TasksStatusItem: View {
    let tasks: TaskCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let headline = tasks.headline
        Button {
            tasks.toggleList()
        } label: {
            HStack(spacing: 4) {
                symbol(headline)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                if case .running(let count, _) = headline {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Text(headline.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tint(headline) ?? .secondary)
            }
            .font(.system(size: 11))
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The line can be anything a command printed; it gives way before the version does.
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .help(help(headline))
        .accessibilityLabel(label(headline))
        .accessibilityHint(tasks.board.drawer == .list ? "Hides the task list" : "Shows the task list")
    }

    @ViewBuilder
    private func symbol(_ headline: TaskBoard.Headline) -> some View {
        switch headline {
        case .running:
            if reduceMotion {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .finished:
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.online)
        case .quiet:
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
        }
    }

    private func tint(_ headline: TaskBoard.Headline) -> Color? {
        if case .failed = headline { return Theme.danger }
        return nil
    }

    private func label(_ headline: TaskBoard.Headline) -> String {
        switch headline {
        case .quiet: "Tasks"
        case .running(let count, let line): "Tasks, \(count) running: \(line)"
        case .failed(let title): "Tasks: \(title) failed"
        case .finished(let title): "Tasks: \(title) finished"
        }
    }

    private func help(_ headline: TaskBoard.Headline) -> String {
        switch headline {
        case .quiet: "Tasks this session"
        default: headline.text
        }
    }
}
