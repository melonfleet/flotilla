import SwiftUI
import AppKit
import FlotillaCore

/// What a `LogViewer` is reading.
///
/// The two log screens used to be two views. The container's had search, timestamps, wrap, a
/// retention cap, Copy and Save; the machine's had a reload button and a segmented control, and
/// nothing else — same job, a fifth of the affordances, and no way to find a line in five hundred.
/// One view with a source parameter is the fix, and the parameter is small because the difference
/// really is small: which command to run, and what to call the thing being read.
enum LogViewerSource: Equatable {
    case container(String)
    case machine(String)

    var id: String {
        switch self {
        case .container(let id), .machine(let id): id
        }
    }

    /// What the status bar calls the non-boot log. Both sources have a boot log as well, and
    /// conflating the two is the one mistake this screen must never make.
    var streamLabel: String {
        switch self {
        case .container: "Container logs"
        case .machine: "Machine logs"
        }
    }

    var streamIcon: String { "text.alignleft" }

    /// A machine *is* the micro-VM, so its boot log needs no parenthetical; a container's boot
    /// log is the VM underneath it, which is worth saying.
    var bootLabel: String {
        switch self {
        case .container: "Boot log (micro-VM)"
        case .machine: "Boot log (VM)"
        }
    }

    var emptyDescription: String {
        switch self {
        case .container: "This container hasn't produced any output yet."
        case .machine: "This machine hasn't produced any output yet."
        }
    }

    func fetch(_ model: AppModel, lines: Int, boot: Bool) async throws -> LogChunk {
        switch self {
        case .container(let id): try await model.fetchLogs(for: id, lines: lines, bootLog: boot)
        case .machine(let id): try await model.machineLogs(for: id, lines: lines, boot: boot)
        }
    }

    func live(_ model: AppModel, lines: Int, boot: Bool) -> AsyncStream<LiveLogEvent> {
        switch self {
        case .container(let id): model.liveContainerLogs(id, lines: lines, bootLog: boot)
        case .machine(let id): model.liveMachineLogs(id, lines: lines, boot: boot)
        }
    }
}

/// The log screen for containers and machines both: bounded fetch, boot-log toggle,
/// search + highlight, timestamps, wrap, capped retention, a **live tail**, Copy and Save.
///
/// Owns its own loading and error state rather than the shared `AppModel.actionError` alert — a
/// failed reload here is local to this tab and should not pop a modal over the rest of the app.
///
/// **Live is a real stream, not a faster poll.** It used to be a three-second refetch of the last
/// N lines, which re-rendered the whole buffer on a timer, could not show a line sooner than three
/// seconds after it was written, and silently doubled the work when two tabs were open. This runs
/// `container logs --follow` and appends what arrives, the way Console does — see
/// `ContainerHost.stream`.
struct LogViewer: View {
    let model: AppModel
    let source: LogViewerSource

    @State private var lines: [LogLine] = []
    @State private var nextIndex = 0
    @State private var loading = false
    @State private var error: String?
    /// When the bounded fetch happened. `container logs` has no `--timestamps`, so a line's own
    /// `receivedAt` is nil for everything that arrived in a chunk; this is the fallback stamp.
    /// Live lines carry a real one, because we were there when they arrived.
    @State private var fetchedAt: Date?
    /// True when the CLI said there are older lines than the ones shown.
    @State private var truncated = false

    @State private var bootLog = false
    @State private var search = ""
    @State private var showTimestamps: Bool
    @State private var live = false
    @State private var showingOptions = false
    @State private var liveTask: Task<Void, Never>?

    init(model: AppModel, source: LogViewerSource) {
        self.model = model
        self.source = source
        _showTimestamps = State(initialValue: model.settingsStore[SettingsKeys.logShowTimestamps])
    }

    private var requestedLines: Int { model.settingsStore[SettingsKeys.logTailLines] }
    private var lineCap: Int { model.settingsStore[SettingsKeys.logBufferLineCap] }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusBar
            content
                .background(Theme.raisedSurface)
        }
        .task { await load() }
        .onChange(of: bootLog) { _, _ in restart() }
        .onChange(of: live) { _, isOn in
            liveTask?.cancel()
            liveTask = nil
            if isOn {
                liveTask = Task { await tail() }
            } else {
                Task { await load() }
            }
        }
        .onDisappear {
            liveTask?.cancel()
            liveTask = nil
        }
    }

    // MARK: Chrome

    /// One band, ordered the way the list toolbars are ordered: the actions in a glass cluster,
    /// then the control that changes what you are looking at, then the field you search it with.
    ///
    /// The cluster is the same `ActionCluster` the Containers and Machines toolbars use, so these
    /// buttons sit on the same surface and react the same way as every other action group in the
    /// app — they were bare glyphs on the band, which is why they looked like a different kind of
    /// control from the ones two bands above them.
    ///
    /// Within the cluster: **Copy, Save, Reload, Live**. Copy and Save do the same thing to the
    /// same text and belong together; Reload and Live are the same axis — once, or continuously —
    /// and sit at the end, where the lists put Refresh. The Inspect band next door is Copy then
    /// Reload, the same relative order minus the two it has no use for.
    private var controls: some View {
        HStack(spacing: 12) {
            ActionCluster {
                IconActionButton(systemImage: "doc.on.doc", label: "Copy",
                                 help: "Copy every line shown",
                                 disabled: displayLines.isEmpty) {
                    copyAll()
                }
                IconActionButton(systemImage: "square.and.arrow.down", label: "Save…",
                                 help: "Save every line shown to a file",
                                 disabled: displayLines.isEmpty) {
                    save()
                }
                Divider().frame(height: 14)
                IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                 help: live ? "Not needed while Live is on" : "Fetch the most recent lines again",
                                 busy: loading && !live, disabled: live) {
                    Task { await load() }
                }
                // **Not in the popover with the other options.** Live is the only one that changes
                // what the app is *doing* rather than what the panel shows, it has to be visible
                // while it is running, and stopping it has to be one click rather than one to open
                // a popover and another to find the switch. Console keeps its equivalent on the
                // toolbar for the same reason.
                IconActionButton(systemImage: "dot.radiowaves.left.and.right", label: "Live",
                                 help: live ? "Stop streaming" : "Stream new lines as they are written",
                                 active: live) {
                    live.toggle()
                }
            }

            // Beside the search field, where every list puts its filter.
            IconActionButton(systemImage: "line.3.horizontal.decrease", label: "Options",
                             help: optionsHelp, active: bootLog) {
                showingOptions.toggle()
            }
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) { optionsPopover }

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                // The same 200 as the Inspect tab's filter. It used to take every point left over,
                // which made one search field on a detail screen four times the width of the
                // other for no reason either of them could give.
                .frame(maxWidth: 200)
            if !search.isEmpty {
                Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var optionsHelp: String {
        bootLog ? "Showing the boot log" : "What to show"
    }

    /// Checkboxes in a popover, laid out like the lists' Columns popover — same width, same
    /// spacing, same control — so the two read as the same mechanism in different places.
    private var optionsPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Boot Log", isOn: $bootLog)
            Divider().padding(.vertical, 6)
            Toggle("Timestamps", isOn: $showTimestamps)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 190)
    }

    @ViewBuilder
    private var statusBar: some View {
        if !lines.isEmpty || live {
            HStack(spacing: 8) {
                Label(bootLog ? source.bootLabel : source.streamLabel,
                      systemImage: bootLog ? "shippingbox" : source.streamIcon)
                    .font(.caption.bold())
                if live {
                    // A dot, because "Live" on a toggle says what was asked for and this says
                    // what is happening — they come apart when the child exits on its own.
                    HStack(spacing: 4) {
                        Circle().fill(Theme.online).frame(width: 6, height: 6)
                        Text("Streaming").font(.caption)
                    }
                } else if truncated {
                    Text("Showing the most recent \(requestedLines) — older lines exist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if lines.count >= lineCap {
                    Text("Capped at \(lineCap) retained.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && lines.isEmpty {
            ProgressView(live ? "Waiting for output…" : "Loading logs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, lines.isEmpty {
            ContentUnavailableView("Couldn't load logs",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if !displayLines.isEmpty {
            LineListView(lines: displayLines, search: search, followTail: live)
        } else {
            ContentUnavailableView("No log output",
                                   systemImage: "doc.text",
                                   description: Text(source.emptyDescription))
        }
    }

    // MARK: Lines

    private var matchCount: Int { LineListView.matchCount(displayLines, search: search) }

    /// Retained lines, capped at `logBufferLineCap`. The cap matters for the live tail in a way
    /// it never did for a bounded fetch: a chatty container will otherwise grow this array for
    /// as long as the tab is open.
    private var displayLines: [DisplayLine] {
        lines.suffix(lineCap).map { line in
            let text = showTimestamps
                ? "\(Self.timeLabel(line.receivedAt ?? fetchedAt))  \(line.text)"
                : line.text
            return DisplayLine(id: line.index, text: text,
                               color: line.stream == .stderr ? Theme.danger : .primary)
        }
    }

    private static func timeLabel(_ date: Date?) -> String {
        guard let date else { return "--:--:--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    // MARK: Loading

    /// Re-run whichever mode is on. Switching between the boot log and the stream log is a
    /// different command either way, so Live has to be restarted rather than left pointed at
    /// the old one.
    private func restart() {
        if live {
            liveTask?.cancel()
            liveTask = Task { await tail() }
        } else {
            Task { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let chunk = try await source.fetch(model, lines: requestedLines, boot: bootLog)
            lines = chunk.lines
            nextIndex = (chunk.lines.last?.index ?? -1) + 1
            truncated = chunk.truncated
            fetchedAt = Date()
        } catch {
            self.error = String(describing: error)
            lines = []
        }
        loading = false
    }

    /// The live tail.
    ///
    /// Lines are drained into a buffer and published on a tick rather than one state write per
    /// line: a container writing a thousand lines a second would otherwise ask SwiftUI to rebuild
    /// the list a thousand times a second, and nobody can read that anyway. 120 ms is under the
    /// threshold where a tail stops feeling immediate and far above the cost of a diff.
    @MainActor
    private func tail() async {
        lines = []
        nextIndex = 0
        truncated = false
        error = nil
        loading = true

        let inbox = LiveInbox()
        let events = source.live(model, lines: requestedLines, boot: bootLog)
        let reader = Task { @MainActor in
            for await event in events { inbox.accept(event) }
            inbox.close()
        }
        defer { reader.cancel() }

        while !Task.isCancelled {
            let batch = inbox.drain()
            if !batch.isEmpty {
                loading = false
                for (stream, text) in batch {
                    lines.append(LogLine(index: nextIndex, stream: stream, text: text,
                                         receivedAt: Date()))
                    nextIndex += 1
                }
                if lines.count > lineCap { lines.removeFirst(lines.count - lineCap) }
            }
            if let stop = inbox.stop {
                loading = false
                // The child ended by itself: the container exited, or the CLI refused. Either
                // way Live is no longer true, and a toggle left on would be a lie.
                if let message = stop { error = message }
                live = false
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    // MARK: Export

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayLines.map(\.text).joined(separator: "\n"),
                                       forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(source.id)-\(bootLog ? "boot" : "logs").txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? displayLines.map(\.text).joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Collects live events between ticks.
///
/// Main-actor isolated and deliberately plain: the `AsyncStream` is already consumed on the main
/// actor, so the only thing needed here is a place to put lines that is *not* observed state.
@MainActor
private final class LiveInbox {
    private var pending: [(LogLine.Stream, String)] = []
    /// Set once the tail is over. The outer `Optional` is "has it stopped"; the inner one is
    /// "with a failure" — a clean end and a failed end are different, and both are ends.
    private(set) var stop: String??

    func accept(_ event: LiveLogEvent) {
        switch event {
        case .line(let stream, let text):
            pending.append((stream, text))
        case .ended(let end):
            stop = end.ok ? .some(nil) : .some("The log stream stopped (exit \(end.exitCode)).")
        case .failed(let message):
            stop = .some(message)
        }
    }

    /// The stream's own end — reached when the child exits without saying so through `onEnd`.
    func close() { if stop == nil { stop = .some(nil) } }

    func drain() -> [(LogLine.Stream, String)] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

/// One already-tagged, already-coloured line ready for display — shared by the log viewer, the
/// Inspect tabs and `InspectSheet`, so all of them get the same search/highlight/wrap behaviour
/// from one place.
struct DisplayLine: Identifiable {
    let id: Int
    let text: String
    let color: Color
}

/// The scrollable, monospaced line list those screens render into. `.textSelection(.enabled)`
/// stands in for a bespoke "copy selection" — native drag-select plus Cmd-C — rather than
/// hand-rolling row selection state.
struct LineListView: View {
    let lines: [DisplayLine]
    let search: String
    /// Keep the newest line in view as lines arrive. Off for a static document, where yanking
    /// the scroll position to the bottom would fight the reader.
    var followTail: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            // **Always wrapped, always left-aligned.** There used to be a Wrap toggle, and with
            // it off the text was *centred* and looked shrunken — a two-axis `ScrollView` centres
            // content narrower than its viewport, the same fault the JSON view had. That is
            // fixable, but nobody wanted the mode: the other two callers both passed `wrap: true`,
            // and a log reads like Console's, down the left edge. So the mode went rather than
            // being repaired into something no one asked for.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        highlighted(line.text, color: line.color)
                            .font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: lines.last?.id) { _, newest in
                guard followTail, let newest else { return }
                // No animation: a tail that eases to each new line lags behind the output and
                // makes the text unreadable while it moves.
                proxy.scrollTo(newest, anchor: .bottom)
            }
            .onChange(of: followTail) { _, isOn in
                if isOn, let newest = lines.last?.id { proxy.scrollTo(newest, anchor: .bottom) }
            }
        }
    }

    /// Built as one `AttributedString` rather than by `Text` + `Text` concatenation, which is
    /// deprecated in macOS 26. It also fixes a limitation of the original: concatenating three
    /// pieces could only ever bold the **first** match on a line, so a line containing the search
    /// term twice highlighted one and quietly ignored the rest. This marks every occurrence.
    private func highlighted(_ text: String, color: Color) -> Text {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color

        guard !search.isEmpty else { return Text(attributed) }

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let found = attributed[searchStart...].range(of: search, options: .caseInsensitive) {
            attributed[found].inlinePresentationIntent = .stronglyEmphasized
            // Advance past this hit; without this a zero-width or repeated match loops forever.
            searchStart = found.upperBound > searchStart
                ? found.upperBound
                : attributed.index(afterCharacter: searchStart)
        }
        return Text(attributed)
    }

    static func matchCount(_ lines: [DisplayLine], search: String) -> Int {
        guard !search.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + ($1.text.localizedCaseInsensitiveContains(search) ? 1 : 0) }
    }
}
