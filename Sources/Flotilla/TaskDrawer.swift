import SwiftUI
import FlotillaCore

/// The Tasks drawer (Q63, Kamal, 19 October): rises on the right of the content area, above the
/// status bar's Tasks item, when a job starts, and sinks into that item when minimised.
///
/// It replaced a centred sheet. That sheet was modal, so watching a forty-second pull meant not
/// using the window for forty seconds, and its Hide orphaned the job's output. The drawer is not
/// modal: the page beside it stays live, and minimising it changes nothing about the job.
///
/// **Compact rows, like Claude Code's background tasks** (round 3). Each job is one line — caret,
/// the kind's symbol, the title, its percentage or elapsed time, and icon buttons — and a failure
/// adds a second line with the reason. The caret is the only way into the detail (steps and live
/// output). Finished jobs fold into one "N finished" line that opens onto them, so the drawer stays
/// as short as what is running. Its height follows the rows, to half the content area (less when
/// Greta is above it), and then the list scrolls. It is an overlay: nothing beneath it moves, which
/// is why every form's commit is in its header (Q64, Q65).
struct TaskDrawer: View {
    let tasks: TaskCenter
    /// For a finished Run's Stop: the container lists it reads and the Stop it calls.
    let model: AppModel
    /// The content area the drawer sits in (right of the sidebar, below the window bar).
    let bounds: CGSize
    /// Height already spoken for above the drawer — Greta's overlay, when she is open — so the two
    /// together never outgrow the window.
    var reservedAbove: CGFloat = 0
    @FocusState private var focused: Bool
    @State private var listHeight: CGFloat = 0

    /// Rows must stay readable; below this the drawer takes the whole content width instead.
    static let minimumWidth: CGFloat = 420
    static let headerHeight: CGFloat = 34

    /// Half the content area's width, never narrower than a row needs, never wider than the area.
    var width: CGFloat { TaskBoard.drawerWidth(in: bounds.width, minimum: Self.minimumWidth) }
    /// About half the window's height, then the list scrolls; less when Greta needs the rest.
    private var maxListHeight: CGFloat {
        let half = bounds.height * 0.5
        let room = bounds.height - reservedAbove
        return max(56, min(half, room) - Self.headerHeight)
    }

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
        // Asked for — the status item, ⌥⌘T, a notice — it takes focus, so Esc puts it away again.
        // Risen because a job started, it does not: the user may be typing in the form that started
        // it. The board says which (`openedByUser`); the highlight cannot, since a reopen during a new
        // row's highlight is still a reopen.
        .onAppear { if tasks.board.openedByUser { focused = true } }
        .onChange(of: tasks.board.openedByUser) { _, asked in if asked { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks")
        .accessibilityHint("Press Escape to minimise into the status bar")
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
    }

    // MARK: -

    private var header: some View {
        HStack(spacing: 4) {
            Text("Tasks")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if tasks.board.hasFinished {
                TaskIconButton(systemImage: "xmark.circle", label: "Clear finished",
                               help: "Clear finished") { tasks.clearFinished() }
            }
            TaskIconButton(systemImage: "chevron.down", label: "Minimise tasks",
                           help: "Minimise into the status bar (Esc). Tasks keep running.") { tasks.minimise() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private var list: some View {
        if tasks.board.entries.isEmpty {
            Text("No tasks this session.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Elapsed times tick once a second while anything runs.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(tasks.board.runningRows(at: timeline.date)) { row in
                                TaskRowView(tasks: tasks, model: model, row: row).id(row.id)
                            }
                            if tasks.board.hasFinished {
                                FinishedFold(tasks: tasks)
                                if tasks.board.finishedExpanded {
                                    ForEach(tasks.board.finishedRows(at: timeline.date)) { row in
                                        TaskRowView(tasks: tasks, model: model, row: row).id(row.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // Follows the rows: one task is a short drawer, more make it taller, to the cap.
                .frame(height: min(max(listHeight, 32), maxListHeight))
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

/// "N finished": the finished jobs, folded into one line until it is opened. A failure among them is
/// named on the line, in red, so folding never hides one.
private struct FinishedFold: View {
    let tasks: TaskCenter

    var body: some View {
        let count = tasks.board.finishedCount
        let failed = tasks.board.failedCount
        Button {
            tasks.toggleFinished()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(tasks.board.finishedExpanded ? 90 : 0))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("\(count) finished")
                if failed > 0 {
                    Text("· \(failed) failed").foregroundStyle(Theme.danger)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) finished\(failed > 0 ? ", \(failed) failed" : "")")
        .accessibilityHint(tasks.board.finishedExpanded ? "Hides the finished tasks" : "Shows the finished tasks")
    }
}

/// One job, one line: opened by its caret alone.
private struct TaskRowView: View {
    let tasks: TaskCenter
    let model: AppModel
    let row: TaskBoard.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    tasks.toggleExpanded(row.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")
                .accessibilityHint("Shows the task's steps and output")

                TaskKindMark(kind: row.kind, state: row.state)

                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.state == .running ? .primary : .secondary)
                Spacer(minLength: 6)
                Text(figure)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                actions
            }
            .frame(minHeight: 22)
            // The step it is on, where it started and its state: one hover away, not a second line.
            .help(secondary)

            if case .failed = row.state, let reason = row.step {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 44)
            }
            if row.isExpanded, let progress = tasks.progress(row.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let fraction = row.fraction { ProgressView(value: fraction) }
                    TaskDetailView(progress: progress)
                }
                .padding(.leading, 44)
                .padding(.bottom, 4)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(background)
        .animation(.easeOut(duration: 0.4), value: row.isHighlighted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(row.stateText)\(row.fraction.map { ", \(Int($0 * 100)) percent" } ?? "")")
    }

    /// The percentage where the job reports one, otherwise how long it has been going (or took).
    private var figure: String {
        if let fraction = row.fraction { return "\(Int(fraction * 100))%" }
        return row.elapsedText
    }

    /// "Images · Running · [1/2] Fetching 42%" — where, state, and the step it is on (or, for a
    /// failure, why).
    private var secondary: String {
        var parts = [row.origin, row.stateText]
        if row.fraction != nil { parts.append(row.elapsedText) }
        if let step = row.step { parts.append(step) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Icons only (Kamal, round 3), each with a tooltip and a spoken label: Stop where the job can
    /// be stopped, Retry once its guards have let go, Clear when it is over.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 0) {
            if row.offersCancel {
                TaskIconButton(systemImage: "stop.circle", label: "Stop \(row.title)",
                               help: "Stop. Whatever it has fetched or built so far stays.") { tasks.cancel(row.id) }
            } else if row.isCancelling {
                ProgressView().controlSize(.small).scaleEffect(0.5)
                    .frame(width: 22, height: 22)
                    .help("Stopping…")
                    .accessibilityLabel("Stopping \(row.title)")
            }
            if let made = row.stopTarget(isRunning: { model.container($0).map(AppModel.isRunning) ?? false }),
               let container = model.container(made) {
                containerStop(made, container)
            }
            if row.offersRetry, tasks.canRetry(row.id) {
                TaskIconButton(systemImage: "arrow.clockwise", label: "Retry \(row.title)",
                               help: "Run it again as a new task") { tasks.retry(row.id) }
            }
            if row.state.isFinished {
                TaskIconButton(systemImage: "xmark", label: "Clear \(row.title)",
                               help: "Clear from the list") { tasks.clear(row.id) }
            }
        }
    }

    /// A finished Run whose container is running: the container's own Stop (Kamal, 19 October) —
    /// the call and busy guard the Containers row uses, on the container's host. `stop.fill`, the
    /// Containers list's glyph, so it cannot be mistaken for the task's Cancel (`stop.circle`).
    @ViewBuilder
    private func containerStop(_ made: TaskBoard.TaskContainer, _ container: Container) -> some View {
        if model.isBusy(made.host.rowID(made.id), kind: .container) {
            ProgressView().controlSize(.small).scaleEffect(0.5)
                .frame(width: 22, height: 22)
                .help("Stopping \(made.id)…")
                .accessibilityLabel("Stopping \(made.id)")
        } else {
            TaskIconButton(systemImage: "stop.fill", label: "Stop \(made.id)", help: "Stop \(made.id)") {
                Task { await model.perform(.stop, on: container, host: made.host) }
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

/// A small borderless symbol button for the drawer: no text buttons there (Kamal, round 3).
private struct TaskIconButton: View {
    let systemImage: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The job's kind as a symbol, with its outcome as a small badge once it is over.
private struct TaskKindMark: View {
    let kind: TaskKind
    let state: TaskBoard.State

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: 12))
            .foregroundStyle(state.isFailure ? Theme.danger : .secondary)
            .frame(width: 18, height: 16)
            .overlay(alignment: .bottomTrailing) { badge.offset(x: 3, y: 3) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .running: EmptyView()
        case .succeeded: Image(systemName: "checkmark.circle.fill").badgeStyle().foregroundStyle(Theme.online)
        case .failed: Image(systemName: "exclamationmark.circle.fill").badgeStyle().foregroundStyle(Theme.danger)
        case .cancelled: Image(systemName: "minus.circle.fill").badgeStyle().foregroundStyle(.secondary)
        }
    }
}

private extension Image {
    func badgeStyle() -> some View {
        font(.system(size: 8, weight: .bold))
            .background(Circle().fill(Theme.raisedSurface).padding(-1))
    }
}

extension TaskKind {
    /// The kind's symbol in the drawer's rows. Each is checked to exist (an unknown name draws
    /// nothing at all).
    var systemImage: String {
        switch self {
        case .pullImage: "arrow.down.circle"
        case .pullImageToHosts: "square.and.arrow.down.on.square"
        case .buildImage: "hammer"
        case .sendImage: "paperplane"
        case .createVolume: "externaldrive.badge.plus"
        case .createNetwork: "network"
        case .pushDefinition: "square.and.arrow.up.on.square"
        case .runContainer: "shippingbox"
        case .createStack: "square.stack.3d.up"
        case .createCluster, .recreateCluster, .clusterAction: "circle.hexagongrid"
        case .createMachine: "plus.rectangle.on.folder"
        case .importConfiguration: "square.and.arrow.down"
        case .groupAction: "square.stack"
        case .dnsSetup: "globe"
        case .unclassified: "gearshape"
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

/// The status bar's Tasks item: always there, alone at the right edge, and short (Kamal, round 3).
/// "Tasks · 2 · 31%" while anything runs — a spinner, the count, and the newest job's percentage or
/// elapsed time; "Tasks · Failed" in red until looked at after a failure; "Tasks · Done" briefly
/// after a success; otherwise just "Tasks". The full line is the drawer row's, and the tooltip's.
/// A click opens the drawer on the task list.
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
                if case .running = headline {
                    // Ticks once a second while a job runs, since its elapsed time may be the figure.
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        caption(headline, at: timeline.date)
                    }
                } else {
                    caption(headline, at: tasks.now)
                }
            }
            .font(.system(size: 11))
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help(headline))
        .accessibilityLabel(label(headline))
        .accessibilityHint(tasks.board.drawer == .list ? "Hides the task list" : "Shows the task list")
    }

    private func caption(_ headline: TaskBoard.Headline, at now: Date) -> some View {
        Text(text(headline, at: now))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(tint(headline) ?? .secondary)
    }

    private func text(_ headline: TaskBoard.Headline, at now: Date) -> String {
        switch headline {
        // Quiet still says what the session did: "Tasks · 7 finished" (Kamal, 19 October).
        case .quiet: finished == 0 ? "Tasks" : "Tasks · \(finished) finished"
        case .running(let count, _):
            ["Tasks", "\(count)", tasks.board.leadingFigure(at: now)].compactMap { $0 }.joined(separator: " · ")
        case .failed: "Tasks · Failed"
        case .finished: "Tasks · Done"
        }
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

    /// Finished tasks still in this session's list.
    private var finished: Int { tasks.board.finishedCount }

    private func label(_ headline: TaskBoard.Headline) -> String {
        switch headline {
        case .quiet: finished == 0 ? "Tasks" : "Tasks, \(finished) finished"
        case .running(let count, let line): "Tasks, \(count) running: \(line)"
        case .failed(let title): "Tasks: \(title) failed"
        case .finished(let title): "Tasks: \(title) finished"
        }
    }

    private func help(_ headline: TaskBoard.Headline) -> String {
        switch headline {
        case .quiet: "Tasks this session"
        case .running(let count, let line): count == 1 ? line : "\(count) running. Newest: \(line)"
        default: headline.text
        }
    }
}
