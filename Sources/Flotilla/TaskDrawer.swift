import SwiftUI
import FlotillaCore

/// The Tasks drawer (Q63, Kamal, 19 October): rises on the right of the content area, above the
/// status bar's Tasks item, when a job starts, and sinks into that item when minimised.
///
/// It replaced a centred sheet. That sheet was modal, so watching a forty-second pull meant not
/// using the window for forty seconds, and its Hide orphaned the job's output. The drawer is not
/// modal: the page beside it stays live, and minimising it changes nothing about the job.
///
/// **One list, collapsed rows.** Every job is a row — caret, title, progress, and a line saying where
/// it started, its state and its current step. The caret is the only way into the detail (steps and
/// live output). The drawer's height follows its rows, to half the content area, and then the list
/// scrolls.
struct TaskDrawer: View {
    let tasks: TaskCenter
    /// The content area the drawer sits in (right of the sidebar, below the window bar).
    let bounds: CGSize
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0

    /// Rows must stay readable; below this the drawer takes the whole content width instead.
    static let minimumWidth: CGFloat = 420
    private static let headerHeight: CGFloat = 38

    /// Half the content area's width, never narrower than a row needs, never wider than the area.
    var width: CGFloat { TaskBoard.drawerWidth(in: bounds.width, minimum: Self.minimumWidth) }
    /// About half the window's height, then the list scrolls.
    private var maxListHeight: CGFloat { max(120, bounds.height * 0.5 - Self.headerHeight) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: width)
        .background(Theme.raisedSurface, in: shape)
        .overlay(shape.strokeBorder(Theme.hairline))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.18), radius: 10, y: -2)
        // A click anywhere in it gives it focus, so Esc minimises without hunting for the button.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand { tasks.minimise() }
        // Asked for — the status item, ⌥⌘T — it takes focus, so Esc puts it away again. Risen
        // because a job started, it does not: the user may be typing in the form that started it.
        .onAppear { if tasks.board.highlighted == nil { focused = true } }
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
            Text("Tasks")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if tasks.board.hasFinished {
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
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var list: some View {
        if tasks.board.entries.isEmpty {
            Text("No tasks this session.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Elapsed times tick once a second while anything runs.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tasks.board.rows(at: timeline.date)) { row in
                                TaskRowView(tasks: tasks, row: row)
                                    .id(row.id)
                                Divider()
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // Follows the rows: one task is a short drawer, more make it taller, to the cap.
                .frame(height: min(max(listHeight, 48), maxListHeight))
                .onChange(of: tasks.board.revealed) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    tasks.clearReveal()
                }
                .onAppear {
                    if let id = tasks.board.revealed {
                        proxy.scrollTo(id, anchor: .center)
                        tasks.clearReveal()
                    }
                }
            }
        }
    }
}

/// One job: collapsed by default, opened by its caret alone.
private struct TaskRowView: View {
    let tasks: TaskCenter
    let row: TaskBoard.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    tasks.toggleExpanded(row.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")
                .accessibilityHint("Shows the task's steps and output")

                TaskStateMark(state: row.state).padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        progress
                    }
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(row.state.isFailure ? Theme.danger : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                actions
            }
            .font(.system(size: 12))
            if row.isExpanded, let progress = tasks.progress(row.id) {
                TaskDetailView(progress: progress)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(background)
        .animation(.easeOut(duration: 0.4), value: row.isHighlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(row.stateText)\(row.fraction.map { ", \(Int($0 * 100)) percent" } ?? "")")
    }

    /// A percentage and a bar where the job reports one, otherwise the time it has been going.
    @ViewBuilder
    private var progress: some View {
        if let fraction = row.fraction {
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 64)
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        } else {
            Text(row.elapsedText).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// "Images · Running · [1/2] Fetching 42%" — where, state, and the step it is on (or, for a
    /// failure, why).
    private var secondary: String {
        var parts = [row.origin, row.stateText]
        if row.fraction != nil { parts.append(row.elapsedText) }
        if let step = row.step { parts.append(step) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if row.offersCancel {
                Button("Cancel") { tasks.cancel(row.id) }
                    .controlSize(.small)
                    .help("Stop it. Whatever it has fetched or built so far stays.")
                    .accessibilityLabel("Cancel \(row.title)")
            } else if row.isCancelling {
                Text("Cancelling…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if row.offersRetry {
                Button("Retry") { tasks.retry(row.id) }
                    .controlSize(.small)
                    .help("Run it again as a new task")
                    .accessibilityLabel("Retry \(row.title)")
            }
            if row.state.isFinished {
                Button("Clear") { tasks.clear(row.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Clear \(row.title)")
            }
        }
    }

    /// Lit briefly when it is the job that just started; red-tinted when it failed.
    @ViewBuilder
    private var background: some View {
        if row.isHighlighted {
            Color.accentColor.opacity(0.14)
        } else if row.state.isFailure {
            Theme.danger.opacity(0.07)
        } else {
            Color.clear
        }
    }
}

/// A task's command, steps, output and outcome — what the centred progress panel used to show,
/// in the drawer now. Selectable, because this is where a command reports a path or a line to
/// run, and a panel that shows you a command you cannot copy has made you retype it.
struct TaskDetailView: View {
    let progress: OperationProgress

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
                    .frame(minHeight: 60, maxHeight: 120)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                    // Follows the output, for the same reason the live log tail does: a feed that
                    // arrives below the fold is indistinguishable from one that stopped.
                    .onChange(of: progress.output.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo(progress.output.count - 1, anchor: .bottom) }
                }
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
            case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// The status bar's Tasks item: always there, alone at the right edge. A spinner, a count and the newest
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
                Spacer(minLength: 0)
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
        .frame(maxWidth: 320, alignment: .trailing)
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
