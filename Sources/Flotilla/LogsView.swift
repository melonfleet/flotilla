import SwiftUI
import FlotillaCore

/// The Logs section: one place that answers "what has everything been saying", instead of
/// visiting each container's detail tab in turn.
///
/// **One continuous feed, with the source as a field on every line.** It was per-source blocks
/// first, which read well with two containers and turned into a scrolling exercise with five —
/// the owner's call, and he is right: the thing you want is usually one stream you can filter, not a
/// tour of every source in turn.
///
/// What has *not* changed is what the data can support. `container logs` has no `--timestamps`
/// (captured help confirms it), so the only clock available is the moment *we* read a chunk,
/// which is identical for every line in it. So **a fetched** feed is not chronological across
/// sources and does not pretend to be: lines keep their source's own order, sources follow a
/// stable order, and the toolbar says so. Sorting this by a fabricated time would look
/// authoritative and order lines by nothing at all. The per-source filter is what actually
/// answers "just show me this one".
///
/// **Live is the exception, and it is a real one.** While streaming, every line is appended as
/// it arrives from a `--follow` child, so arrival order across sources is genuine ordering — not
/// a timestamp we invented, but the sequence in which the runtime actually handed us the lines.
/// It is that ordering to within one 120 ms drain tick, which is the same bound the detail
/// viewer's tail carries. So the interleaving this view refuses to fake when fetching is exactly
/// what it earns when streaming.
struct LogsView: View {
    let model: AppModel
    /// Owned by `MainWindowView` — see `LogsUIState`.
    let ui: LogsUIState

    @State private var chunks: [AggregatedLogChunk] = []
    @State private var loading = false
    @State private var updated: Date?
    @State private var showingSources = false
    @State private var showingLimit = false

    /// Lines that arrived from the live tail, newest last, already interleaved by arrival.
    @State private var liveLines: [AggregatedLogLine] = []
    /// Sources the tail could not start or that ended by themselves, held per source and shown
    /// the same way a failed fetch is — a stream that died must not just stop producing lines.
    @State private var liveFailures: [AggregatedLogChunk] = []
    @State private var liveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                // The same surface the detail Logs tabs and the JSON inspector sit on. This
                // panel had no background at all, so it took the window's, and the one screen in
                // the app whose whole job is reading log text was the one that did not look like
                // the log surface everywhere else.
                .background(Theme.raisedSurface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Fetched on arrival and on every filter change, **not on a timer**. Polling every few
        // seconds would be a 200-line read per source forever, for a screen nobody may be
        // looking at. When you do want movement you say so, and then it is a `--follow` child
        // per source that pushes — which is both cheaper than polling and actually live.
        .task(id: fetchKey) { await refetchOrRestream() }
        .onChange(of: ui.live) { _, isOn in
            liveTask?.cancel()
            liveTask = nil
            if isOn {
                liveTask = Task { await tail() }
            } else {
                Task { await load() }
            }
        }
        .onDisappear {
            // The tail must not outlive the screen. `AsyncStream.onTermination` cancels the
            // child, so cancelling here is what stops N `container logs --follow` processes.
            liveTask?.cancel()
            liveTask = nil
        }
    }

    /// One entry point for "the inputs changed", because live and fetched need opposite things
    /// from it: a fetch re-reads, a tail has to be torn down and started again against the new
    /// source set. Calling `load()` unconditionally here would have overwritten the live feed
    /// with a static one every time a filter moved, while the children kept running.
    private func refetchOrRestream() async {
        if ui.live {
            liveTask?.cancel()
            liveTask = Task { await tail() }
        } else {
            await load()
        }
    }

    /// Everything a fetch depends on. Changing any of it re-runs `.task`, which is what makes
    /// the filters live without a manual refresh.
    ///
    /// **The source inventory is part of the key, and that is not an optimisation.** Without it
    /// this screen fetched exactly once on appear — which on a cold launch is *before* the first
    /// container list has arrived, so it asked zero sources, drew "Nothing to read" over five
    /// running containers, and had no reason to ever try again. Keying on the ids also means
    /// starting or stopping something refreshes the logs on its own, which is the behaviour you
    /// would want anyway.
    private var fetchKey: String {
        let sources = (model.running.map(\.id)
                       + model.machines.filter { MachinesView.isRunning($0) }.map(\.id)).sorted()
        return "\(ui.scope.rawValue)|\(ui.sources.rawValue)|\(ui.lineLimit)"
            + "|\(ui.only.sorted().joined(separator: ","))|\(sources.joined(separator: ","))"
    }

    /// The same control band every other section wears, and the same *idiom* inside it: an
    /// icon-only segmented picker, then `IconActionButton`s that open popovers.
    ///
    /// It was four worded controls — a segmented Output/Boot, an All/Containers/Machines picker, a
    /// named-source menu and a "200 lines" picker — which pushed the search field halfway across
    /// the window while every other section starts it near the left. The owner's standing rule applies
    /// too: *"we don't want to use a lot of words instead of icons just so that it makes it more
    /// universal and more easier to read for everyone, especially the people that can't read words
    /// or English."* The words move to `help` and `accessibilityLabel`, where they still reach
    /// anyone who needs them.
    ///
    /// The two source controls collapsed into **one** filter, which is also what the other
    /// sections have: kind and name are both "which sources", and splitting them across two
    /// controls made the reader hold a two-part rule in their head.
    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search log lines…",
                       updated: updated,
                       leading: {
            Picker("Log", selection: Binding(get: { ui.scope }, set: { ui.scope = $0 })) {
                ForEach(LogsUIState.Scope.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(option.accessibilityLabel)
                        .help(option.accessibilityLabel)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // **Order matches every other section: the filter sits closest to the search
            // field.** The owner's rule, and it is the right one — filter and search are the two
            // controls that narrow what you are looking at, so they belong together, with the
            // "how do I want to look at this" controls further left.
            // A list, not `#`: the hash reads as "number" in the abstract, and what this control
            // sets is how many *lines* come back. The owner's call.
            IconActionButton(systemImage: "list.bullet", label: "Lines",
                             help: "Read the last \(ui.lineLimit) lines from each source") {
                showingLimit.toggle()
            }
            .popover(isPresented: $showingLimit, arrowEdge: .bottom) { limitPopover }

            // Filled when narrowed, hollow when not — the same signal `ResourceListControls`
            // gives, so "a filter is on" reads identically on every screen.
            IconActionButton(systemImage: "line.3.horizontal.decrease",
                             label: "Sources", help: sourceFilterHelp,
                             active: isFiltered) {
                showingSources.toggle()
            }
            .popover(isPresented: $showingSources, arrowEdge: .bottom) { sourcesPopover }
        }, trailing: {
            // **Live sits beside Refresh, and they are the same axis** — once, or continuously —
            // exactly as they are in the detail Logs tabs, so the control you reach for is in the
            // same place whichever log screen you are on.
            ToolbarIconButton(systemImage: "dot.radiowaves.left.and.right", label: "Live",
                              help: liveHelp, active: ui.live, disabled: !canGoLive) {
                ui.live.toggle()
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh",
                              disabled: ui.live) {
                Task { await load() }
            }
        })
    }

    /// Sources the tail would follow: the same set a fetch would read, so Live and Refresh never
    /// disagree about what "selected" means.
    private var liveTargets: [(String, ActivityKind)] {
        var targets = availableSources
        if ui.sources == .containers { targets = targets.filter { $0.1 != .machine } }
        if ui.sources == .machines { targets = targets.filter { $0.1 == .machine } }
        if !ui.only.isEmpty { targets = targets.filter { ui.only.contains($0.0) } }
        return targets
    }

    /// Refused rather than degraded above the ceiling — see `LogsUIState.maxLiveSources`. A live
    /// view that silently follows eight of your twenty containers is a view that lies by
    /// omission, and the fix the user needs is the source filter, which the help names.
    private var canGoLive: Bool {
        !liveTargets.isEmpty && liveTargets.count <= LogsUIState.maxLiveSources
    }

    private var liveHelp: String {
        if liveTargets.isEmpty { return "Nothing running to stream" }
        if liveTargets.count > LogsUIState.maxLiveSources {
            return "Too many sources to stream (\(liveTargets.count) selected, "
                + "\(LogsUIState.maxLiveSources) at a time) — narrow them with the filter"
        }
        return ui.live
            ? "Stop streaming"
            : "Stream new lines from \(liveTargets.count) source"
                + (liveTargets.count == 1 ? "" : "s") + " as they are written"
    }

    private var isFiltered: Bool { ui.sources != .all || !ui.only.isEmpty }

    private var sourceFilterHelp: String {
        if !ui.only.isEmpty {
            return ui.only.count == 1
                ? "Showing \(ui.only.first ?? "one source") only"
                : "Showing \(ui.only.count) sources"
        }
        return ui.sources == .all ? "All sources" : "\(ui.sources.rawValue) only"
    }

    /// Kinds first, then the individual sources that are actually running — the only ones `logs`
    /// can answer for, so a stopped container never appears as a control that cannot work.
    private var sourcesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: Binding(get: { ui.sources }, set: { ui.sources = $0 })) {
                ForEach(LogsUIState.Sources.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if !availableSources.isEmpty {
                Divider()
                Toggle("All sources", isOn: Binding(get: { ui.only.isEmpty },
                                                    set: { if $0 { ui.only.removeAll() } }))
                ForEach(availableSources, id: \.0) { source, kind in
                    Toggle(isOn: Binding(
                        get: { ui.only.contains(source) },
                        set: { on in
                            if on { ui.only.insert(source) } else { ui.only.remove(source) }
                        }
                    )) {
                        Label(source, systemImage: kind.systemImage)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 200)
    }

    private var limitPopover: some View {
        Picker("Lines", selection: Binding(get: { ui.lineLimit }, set: { ui.lineLimit = $0 })) {
            ForEach(LogsUIState.lineLimits, id: \.self) { Text("\($0) lines").tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .padding(14)
    }

    private var content: some View {
        // Fills the pane in every branch, for the reason `LogViewer.content` records: an empty
        // state that sizes to its own message turns the log surface into a floating card.
        logContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var logContent: some View {
        if loading && chunks.isEmpty && liveLines.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.runtimeUsable {
            ContentUnavailableView("The container runtime isn\u{2019}t available",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("Logs come from `container logs`, which needs the runtime."))
        } else if chunks.isEmpty && liveLines.isEmpty && liveFailures.isEmpty {
            if ui.live {
                // Streaming with nothing said yet is not the same as nothing to read: the
                // children are attached and waiting, and a "Nothing to read" here would read as
                // a failure every time you turned Live on against quiet containers.
                ContentUnavailableView("Waiting for output",
                                       systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Streaming \(liveTargets.count) source"
                                            + (liveTargets.count == 1 ? "" : "s")
                                            + ". Lines appear as they are written."))
            } else {
                ContentUnavailableView("Nothing to read",
                                       systemImage: "text.alignleft",
                                       description: Text("Only running containers and machines can return logs."))
            }
        } else if feed.isEmpty && failures.isEmpty {
            if ui.search.isEmpty {
                ContentUnavailableView("No output",
                                       systemImage: "text.alignleft",
                                       description: Text("The selected sources have not logged anything."))
            } else {
                ContentUnavailableView.search(text: ui.search)
            }
        } else {
            // **Follows the tail while Live is on**, the way `LineListView` does for the detail
            // tabs. Without it the stream worked and did not look like it: lines were arriving
            // and landing below the fold, so the screen sat perfectly still while five children
            // pushed output into it — indistinguishable from a feed that is not connected.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Failures first and compact — a source that cannot be read is a fact worth
                        // seeing, and it must not be silently absent from a feed that otherwise
                        // looks complete.
                        ForEach(failures) { chunk in
                            HStack(alignment: .top, spacing: 8) {
                                sourceTag(chunk.source, kind: chunk.kind)
                                Text(chunk.failure ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.danger)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }

                        ForEach(feed) { line in
                            HStack(alignment: .top, spacing: 8) {
                                sourceTag(line.source, kind: line.kind)
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    // `stderr` here is the *CLI's* stderr, not the container's own:
                                    // `container logs` writes program output to stdout, so a line
                                    // arriving on stderr is the runtime complaining. Tinted rather
                                    // than filtered — offering a "stderr" filter would imply a split
                                    // the CLI does not make.
                                    .foregroundStyle(line.stream == .stderr ? Theme.warning : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: feed.last?.id) { _, newest in
                    guard ui.live, let newest else { return }
                    // No animation: a tail that eases to each new line lags behind the output and
                    // makes the text unreadable while it moves. Same call the detail tail makes.
                    proxy.scrollTo(newest, anchor: .bottom)
                }
                .onChange(of: ui.live) { _, isOn in
                    if isOn, let newest = feed.last?.id { proxy.scrollTo(newest, anchor: .bottom) }
                }
            }
        }
    }

    /// The source name as a field on the line, fixed-width so the text column still lines up.
    ///
    /// Truncates from the head rather than the tail: container ids share prefixes far more often
    /// than suffixes, so keeping the end is what keeps two of them distinguishable.
    private func sourceTag(_ source: String, kind: ActivityKind) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(source)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.accentText)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(width: 128, alignment: .leading)
        .help("\(source) \u{2014} \(kind == .machine ? "machine" : "container")")
    }

    /// Every line from every selected source, in one list.
    ///
    /// Order is each source's own order, with sources in the stable order `aggregatedLogs`
    /// returns — containers alphabetically, then machines. Explicitly **not** time-ordered; see
    /// the note on this view.
    private var feed: [AggregatedLogLine] {
        // Live lines are already one interleaved list in arrival order; fetched ones are still
        // per-source chunks that get flattened in the stable order `aggregatedLogs` returns.
        ui.live ? filteredLiveLines : filtered.flatMap(\.lines)
    }

    private var failures: [AggregatedLogChunk] {
        ui.live ? liveFailures : filtered.filter { $0.failure != nil }
    }

    /// The same free-text rule the fetched feed uses, applied line by line — there are no
    /// per-source chunks to match a name against while streaming, so a search that names a
    /// source matches on the line's own `source` field instead.
    private var filteredLiveLines: [AggregatedLogLine] {
        let needle = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return liveLines }
        return liveLines.filter {
            $0.text.lowercased().contains(needle) || $0.source.lowercased().contains(needle)
        }
    }

    /// The free-text filter, applied per source: a chunk survives if its name matches — so you
    /// can type a container's name to isolate it — or if any of its lines do, in which case only
    /// the matching lines remain. A failure row always survives, because hiding the reason a
    /// source is missing while filtering is how you conclude a log is empty when it is broken.
    private var filtered: [AggregatedLogChunk] {
        let needle = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return chunks }
        return chunks.compactMap { chunk in
            if chunk.failure != nil { return chunk }
            if chunk.source.lowercased().contains(needle) { return chunk }
            let hits = chunk.lines.filter { $0.text.lowercased().contains(needle) }
            guard !hits.isEmpty else { return nil }
            return AggregatedLogChunk(source: chunk.source, kind: chunk.kind, lines: hits,
                                      truncated: chunk.truncated, failure: nil)
        }
    }

    /// Running containers and machines, in the order the feed uses.
    private var availableSources: [(String, ActivityKind)] {
        model.running.map { ($0.id, ActivityKind.container) }
            + model.machines.filter { MachinesView.isRunning($0) }.map { ($0.id, ActivityKind.machine) }
    }

    /// The live tail, across every selected source at once.
    ///
    /// Shaped like `LogViewer.tail` and for the same reasons — lines drained into a buffer and
    /// published on a 120 ms tick rather than one state write per line, because a source writing
    /// a thousand lines a second would otherwise ask SwiftUI to rebuild the list a thousand
    /// times a second, and nobody can read that anyway.
    ///
    /// What is different here is that there are **N children, not one**, and they end
    /// independently: a container you stop mid-stream takes its own tail down and leaves the
    /// others running. So an end is recorded per source and shown as a row, and Live only turns
    /// itself off when every source has finished — otherwise stopping one container would
    /// silently kill the whole view.
    @MainActor
    private func tail() async {
        let targets = liveTargets
        guard !targets.isEmpty else { ui.live = false; return }

        liveLines = []
        liveFailures = []
        chunks = []
        loading = true

        let inbox = LiveAggregateInbox()
        let boot = ui.scope.isBoot
        let requested = ui.lineLimit
        var readers: [Task<Void, Never>] = []
        for (id, kind) in targets {
            let events = kind == .machine
                ? model.liveMachineLogs(id, lines: requested, boot: boot)
                : model.liveContainerLogs(id, lines: requested, bootLog: boot)
            readers.append(Task { @MainActor in
                for await event in events { inbox.accept(event, from: id, kind: kind) }
                inbox.close(id, kind: kind)
            })
        }
        defer { readers.forEach { $0.cancel() } }

        let cap = model.settingsStore[SettingsKeys.logBufferLineCap]
        var nextIndex: [String: Int] = [:]

        while !Task.isCancelled {
            let batch = inbox.drain()
            if !batch.isEmpty {
                loading = false
                for item in batch {
                    let key = "\(item.kind.rawValue)/\(item.source)"
                    let index = nextIndex[key, default: 0]
                    nextIndex[key] = index + 1
                    liveLines.append(AggregatedLogLine(source: item.source, kind: item.kind,
                                                       index: index, stream: item.stream,
                                                       text: item.text))
                }
                // One cap across the whole feed, not per source: this is one list and what
                // matters is how much of it is in memory.
                if liveLines.count > cap { liveLines.removeFirst(liveLines.count - cap) }
                updated = Date()
            }

            let ended = inbox.takeEnded()
            if !ended.isEmpty {
                loading = false
                liveFailures.append(contentsOf: ended)
                updated = Date()
            }

            if inbox.closedCount >= targets.count {
                loading = false
                ui.live = false
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        loading = false
    }

    private func load() async {
        liveLines = []
        liveFailures = []
        loading = true
        defer { loading = false }

        // **Load the machine list first if it is empty.** Machines refresh on every *sixth* poll
        // tick (~30s), so on a cold launch this screen would otherwise ask only the containers
        // and show no machine lines at all — which is exactly what the owner saw, and it looked like
        // "machines have no logs" rather than "we have not looked yet". Machine logs do work:
        // verified against the live CLI, both the stdio log and `--boot`.
        if model.machines.isEmpty { await model.refreshMachines() }
        chunks = await model.aggregatedLogs(scope: ui.scope, sources: ui.sources,
                                           only: ui.only, lines: ui.lineLimit)
        updated = Date()
    }
}

/// Collects live events from several sources between drain ticks.
///
/// The aggregate counterpart of `LogViewer`'s `LiveInbox`, and deliberately a separate type
/// rather than a generalisation of it: this one has to keep the source on every line and count
/// the children that have finished, and folding both shapes into one box would make the simple
/// case carry the complicated case's bookkeeping.
///
/// Main-actor isolated and deliberately plain: the streams are already consumed on the main
/// actor, so all this needs to be is a place to put lines that is *not* observed state — one
/// state write per line is exactly what the tick exists to avoid.
@MainActor
private final class LiveAggregateInbox {
    struct Item {
        let source: String
        let kind: ActivityKind
        let stream: LogLine.Stream
        let text: String
    }

    private var pending: [Item] = []
    /// Ends not yet shown. Drained like lines are, so an ended source appears in the same tick
    /// as the lines it wrote just before ending rather than a frame later.
    private var endedPending: [AggregatedLogChunk] = []
    /// Sources whose stream has terminated, by `kind/source` key. A `Set` because a stream that
    /// both fails and then closes must not be counted twice — that would end the tail early
    /// while other children were still running.
    private var closed: Set<String> = []

    var closedCount: Int { closed.count }

    func accept(_ event: LiveLogEvent, from source: String, kind: ActivityKind) {
        switch event {
        case .line(let stream, let text):
            pending.append(Item(source: source, kind: kind, stream: stream, text: text))
        case .ended(let end):
            // A clean end is not a failure. The container exited or was stopped, which is a fact
            // worth a row — but tinting it like a broken source would cry wolf every time
            // someone stops something while watching.
            guard !end.ok else { return close(source, kind: kind) }
            note(source, kind: kind, "stream ended (exit \(end.exitCode))")
        case .failed(let reason):
            note(source, kind: kind, reason)
        }
    }

    func close(_ source: String, kind: ActivityKind) {
        closed.insert("\(kind.rawValue)/\(source)")
    }

    private func note(_ source: String, kind: ActivityKind, _ reason: String) {
        endedPending.append(AggregatedLogChunk(source: source, kind: kind, lines: [],
                                               truncated: false, failure: reason))
        close(source, kind: kind)
    }

    func drain() -> [Item] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    func takeEnded() -> [AggregatedLogChunk] {
        defer { endedPending.removeAll(keepingCapacity: true) }
        return endedPending
    }
}
