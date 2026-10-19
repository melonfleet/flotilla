import SwiftUI
import AppKit
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
    /// Fetched chunks to show instead of asking the runtime — the seam the 10,000-line scroll test
    /// uses, since no real container writes that on demand. Nil in the app. When it is set, Live
    /// follows two made-up sources that write `simulatedLines` between them instead of starting
    /// `container logs --follow`, so the real tail loop — inbox, cap, rebuild, follow — is what runs.
    var preloaded: [AggregatedLogChunk]?
    var simulatedLines = 0

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
    /// Bumped whenever the tail should be pinned to the bottom; see `TailPinner`.
    @State private var pinTail = 0

    /// What the list shows, built once per change of its inputs rather than on every pass through
    /// `body`. Logs can hold thousands of lines, and a computed `feed` re-filtered, re-lowercased
    /// and re-flattened all of them each time anything — a selection, a hover — touched the view.
    @State private var feed: [AggregatedLogLine] = []
    /// Line id → position in `feed`: what turns a selection back into lines without scanning.
    @State private var feedIndex: [String: Int] = [:]
    @State private var failures: [AggregatedLogChunk] = []

    /// The display popover — wrapping and the timestamp column, the two things Docker Desktop's
    /// own log screen puts behind an overflow menu. Same idea, same place: they change how the
    /// feed is drawn rather than what is in it, so they do not belong beside the filters.
    @State private var showingDisplay = false
    /// Set when an export fails. A save that silently does nothing is the failure shape this app
    /// keeps finding; `try?` on the write would have been exactly that.
    @State private var exportError: String?

    var body: some View {
        // Rows and a page, like every list (Q58), but opening on the rows alone (`PaneMode`): a
        // feed is read top to bottom, and a line's page is something you open over it.
        SplitPanes("logs", item: shownLine?.id, clearing: { ui.selection = [] }) {
            listPane
        } detail: {
            detailPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ui.search) { _, _ in rebuildFeed() }
        // Fetched on arrival and on every filter change, **not on a timer**. Polling every few
        // seconds would be a 200-line read per source forever, for a screen nobody may be
        // looking at. When you do want movement you say so, and then it is a `--follow` child
        // per source that pushes — which is both cheaper than polling and actually live.
        .task(id: fetchKey) { await refetchOrRestream() }
        .onChange(of: ui.live) { _, isOn in
            liveTask?.cancel()
            liveTask = nil
            rebuildFeed()
            if isOn {
                liveTask = Task { await tail() }
            } else {
                Task { await load() }
            }
        }
        .alert("Couldn\u{2019}t save the CSV", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
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
        let sources = model.logSources().map(\.key).sorted()
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
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search log lines…",
                       matches: feed.count,
                       updated: updated,
                       leading: {
            PaneModeButton()

            // **Select all, in the same place every other section puts it** — first in the
            // leading cluster, before the controls that change what you are looking at. Scoped to
            // what is *visible*: the selection is kept inside the feed (`rebuildFeed`), so "every
            // line selected" is a count, not a scan of ten thousand ids.
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { ui.selection = Set(feedIndex.keys) }
                                         else { ui.selection = [] }
                                     }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(feed.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all lines" : "Select all lines")
                .help(allVisibleSelected
                      ? "Deselect all"
                      : "Select all \(feed.count) line\(feed.count == 1 ? "" : "s")")

            IconSegmentedPicker(title: "Log", selection: Binding(get: { ui.scope }, set: { ui.scope = $0 }),
                                options: LogsUIState.Scope.allCases,
                                label: \.rawValue, systemImage: \.systemImage, help: \.accessibilityLabel)

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
            // How the feed is *drawn* — wrapping, and whether the Received column shows.
            // Beside the other two popovers rather than in the trailing cluster, because those
            // are the things you do to the feed and these are things you do to the view of it.
            // `slider.horizontal.3` — sliders rather than a cog, the owner's call and matched to
            // a reference they supplied, so this does not read as a second copy of the app's own
            // Settings gear.
            //
            // Three rails, not two: SF Symbols has no bare `slider.horizontal.2`, only boxed and
            // decorated variants (`.square`, `.gobackward`), which would make this the only
            // glyph in the band inside a container. Checked before use, per the
            // `ellipsis.vertical` incident.
            //
            // One thing to know if this is ever revisited: rendered at the toolbar's own 13pt,
            // this makes the band four stacks of horizontal lines in a row — `text.alignleft`,
            // `list.bullet`, `line.3.horizontal.decrease`, then this. The knobs carry the
            // distinction and the Sources filter is one control away, so it holds; but
            // `slider.vertical.3` is the same idea turned ninety degrees if it ever stops
            // holding.
            IconActionButton(systemImage: "slider.horizontal.3", label: "Display",
                             help: displayHelp,
                             active: ui.showTimestamps) {
                showingDisplay.toggle()
            }
            .popover(isPresented: $showingDisplay, arrowEdge: .bottom) { displayPopover }
        }, trailing: {
            // Exports what you selected, or everything you can see. Named in the tooltip both
            // ways round, because "Export 12 selected lines" and "Export all 847 lines" are
            // different enough actions that the button has to say which one it is about to do.
            ToolbarIconButton(systemImage: "arrow.down.document", label: "Export CSV",
                              help: exportHelp, disabled: exportRows.isEmpty) {
                exportCSV()
            }
            // **Live sits beside Refresh, and they are the same axis** — once, or continuously —
            // exactly as they are in the detail Logs tabs, so the control you reach for is in the
            // same place whichever log screen you are on.
            ToolbarIconButton(systemImage: "dot.radiowaves.left.and.right", label: "Live",
                              help: liveHelp, active: ui.live, disabled: !canGoLive) {
                ui.live.toggle()
            }
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh",
                              help: ui.live ? "Not needed while Live is on" : "Refresh",
                              disabled: ui.live) {
                Task { await load() }
            }
        })
    }

    /// Sources the tail would follow: the same set a fetch would read, so Live and Refresh never
    /// disagree about what "selected" means — on every Mac since D2, through each host's follow.
    /// A host whose Flotilla predates streams appears as a failed row saying so.
    private var liveTargets: [LogSource] { selectedSources }

    /// The sources the kind and source filters leave, on every Mac.
    private var selectedSources: [LogSource] {
        var targets = availableSources
        if ui.sources == .containers { targets = targets.filter { $0.kind != .machine } }
        if ui.sources == .machines { targets = targets.filter { $0.kind == .machine } }
        if !ui.only.isEmpty { targets = targets.filter { ui.only.contains($0.key) } }
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
        let shown = !ui.only.isEmpty
            ? (ui.only.count == 1 ? "\(ui.only.first ?? "one source") only" : Plural.count(ui.only.count, "source") + " shown")
            : ui.sources == .all ? "all shown" : "\(ui.sources.rawValue) only"
        return "Choose which sources to show — \(shown)"
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
                ForEach(availableSources, id: \.key) { source in
                    Toggle(isOn: Binding(
                        get: { ui.only.contains(source.key) },
                        set: { on in
                            if on { ui.only.insert(source.key) } else { ui.only.remove(source.key) }
                        }
                    )) {
                        Label(source.label, systemImage: source.kind.systemImage)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 200)
    }

    private var displayHelp: String {
        ui.showTimestamps ? "Display options — timestamps on" : "Display options"
    }

    private var displayPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show timestamps", isOn: Binding(get: { ui.showTimestamps },
                                                    set: { ui.showTimestamps = $0 }))
            // The whole reason this is off by default, said where the control is rather than
            // only in a docstring nobody reading the screen will find.
            // Plain prose, no backticks and no asterisks. `Text` parses Markdown only in a
            // string *literal*; this is built with `+`, so the syntax rendered on screen as
            // literal punctuation — measured, not assumed.
            Text("Apple\u{2019}s container CLI does not timestamp log lines, so this is when "
                 + "Flotilla received the line: genuine per line while streaming, and one "
                 + "shared read time per source when fetched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A line\u{2019}s whole message is on its page: choose it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var limitPopover: some View {
        Picker("Lines", selection: Binding(get: { ui.lineLimit }, set: { ui.lineLimit = $0 })) {
            ForEach(LogsUIState.lineLimits, id: \.self) { Text("\($0) lines").tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .padding(14)
    }

    // MARK: Panes

    /// The one line whose page is open: exactly one selected. Two or more open no page — there is no
    /// one page to show — and the bulk bar under the list is how they are acted on.
    private var shownLine: AggregatedLogLine? {
        guard ui.selection.count == 1, let id = ui.selection.first, let at = feedIndex[id],
              feed.indices.contains(at) else { return nil }
        return feed[at]
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            toolbar
            bulkBar
            Divider()
            content
                // The same surface the detail Logs tabs and the JSON inspector sit on.
                .background(Theme.raisedSurface)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let line = shownLine {
            LogLineDetailView(line: line,
                              open: { openSource(line.source, kind: line.kind) },
                              copy: { Clipboard.copy(line.text) })
                .id(line.id)
        } else if ui.selection.count > 1 {
            ContentUnavailableView("\(ui.selection.count) lines selected", systemImage: "text.alignleft",
                                   description: Text("Copy or export them from the bar under the list."))
        } else {
            PaneEmptyState(title: "Choose a line", systemImage: "text.alignleft",
                           description: "The whole message and where it came from show here.")
        }
    }

    /// From two lines, as every section's is: one line is its page. Copy and Export act on the
    /// selection, and are the same two things the right-click offers it.
    @ViewBuilder
    private var bulkBar: some View {
        if ui.selection.count > 1 {
            BulkActionBar(title: "\(ui.selection.count) lines selected") {
                Button("Copy \(ui.selection.count) Lines") { copyLines(selectedLines) }
                Button("Export\u{2026}") { exportCSV(selectedLines) }
            }
        }
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
        } else if preloaded == nil, !model.runtimeUsable {
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
            // **Rows, matching every other section** (Q56) — and, as before, **no sort**. Every
            // other list sorts because its rows are independent things. These are not: within a
            // source, a log line's position *is* its meaning, and the only clock available is when
            // we read it (see `AggregatedLogLine.receivedAt`). A sortable time would reorder two
            // hundred lines that all share one timestamp, by nothing, and look authoritative doing
            // it. The source filter answers "just show me this one"; the search box the rest.
            VStack(spacing: 0) {
                // Failures above the list rather than mixed into it. A source that could not be
                // read is not a log line — it has no message, no position and nothing to select.
                // They stay visible under any filter, for the reason `filtered` gives: hiding why
                // a source is missing is how you conclude a log is empty when it is broken.
                if !failures.isEmpty { failureBand }
                feedList
            }
        }
    }

    /// A lazy `List`: only the rows on screen are built, so ten thousand lines cost what a screenful
    /// does. Nothing here walks `feed` — the rows come from it, and everything else asks `feedIndex`.
    private var feedList: some View {
        List(feed, selection: selectionBinding) { line in
            row(line)
                // The row paints its own padding, so its hover wash and the list's selection
                // fill reach the same edges.
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On the List, not on a row: this one hands back every selected id.
        .contextMenu(forSelectionType: String.self) { ids in
            rowContextMenu(for: ids)
        }
        // Follows the tail while Live is on. Without it the stream works and does not look
        // like it: lines arrive below the fold and the screen sits still while five children
        // push output into it.
        //
        // **Not `ScrollViewProxy.scrollTo(id)`.** That has to find the row among the rest and size the
        // rows above it, so every tick cost more than the last: measured with a simulated tail, 4,000
        // lines took 2s to arrive without it and never finished in 16s with it (about 2,000 in).
        // `ScrollPosition.scrollTo(edge:)` is cheap but a `List` ignores it. So `TailPinner` moves the
        // list's own scroll view to the end of its document.
        .background(TailPinner(trigger: pinTail, live: ui.live))
        .onChange(of: feed.last?.id) { _, newest in
            guard ui.live, newest != nil else { return }
            // No animation: a tail that eases to each new line lags behind the output
            // and makes the text unreadable while it moves.
            pinTail += 1
        }
        .onChange(of: ui.live) { _, isOn in
            if isOn { pinTail += 1 }
        }
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { ui.selection }, set: { ui.selection = $0 })
    }

    /// Sources that could not be read, above the feed.
    private var failureBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(failures) { chunk in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                    sourceButton(chunk.source, name: chunk.host.isLocal ? chunk.name : "\(chunk.name) on \(chunk.hostName)",
                                 kind: chunk.kind)
                        .frame(width: 150, alignment: .leading)
                    Text(chunk.failure ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
            Divider()
        }
        .background(Theme.danger.opacity(0.07))
    }

    // MARK: Rows

    /// One line, on the shared row: the source and the time over the message.
    ///
    /// ```
    /// 📦 web  [Error] [mac-mini]                              12:04:50
    ///    GET /health 500 internal error …
    /// ```
    /// The time is on the trailing end of the first line, where Notifications and every other row
    /// keep theirs, and only when Show timestamps is on (see `LogsUIState.showTimestamps`). The
    /// message is the second line, cut to the row: the whole of it is the page's.
    ///
    /// The stream is the mark. A line on stderr — the runtime complaining, since `container logs`
    /// writes program output to stdout — gets the warning dot; the rest carry the plain kind glyph.
    private func row(_ line: AggregatedLogLine) -> some View {
        let level = LogLevel.of(line.text)
        return ResourceRow(
            title: line.name,
            titleHelp: line.host.isLocal ? line.name : "\(line.name) on \(line.hostName)",
            trailingText: ui.showTimestamps ? line.receivedAt.map(LogTimestamp.clock) : nil,
            detail: Self.preview(line),
            selected: ui.selection.contains(line.id),
            check: RowCheck(line.id, in: selectionBinding),
            summary: Self.summary(line, level: level),
            leading: {
                RowLeadingMark {
                    switch line.stream {
                    case .stdout:
                        RowKindGlyph(systemImage: line.kind.systemImage)
                    case .stderr:
                        RowTypeMark(systemImage: line.kind.systemImage, kind: "stderr") {
                            Circle().fill(Theme.warning)
                        }
                    case .notice:
                        RowTypeMark(systemImage: line.kind.systemImage, kind: "Flotilla notice") {
                            Circle().fill(.secondary)
                        }
                    }
                }
            },
            chips: {
                if let level { LogLevelChip(level: level) }
                if !line.host.isLocal {
                    HostCell(name: line.hostName, staleSince: nil)
                        .chipStyle()
                        .fixedSize()
                }
                // The subject's own tags, so a feed mixing five containers is readable by colour.
                TagPillRow(tags: model.tags.tags(on: line.kind, line.source), compact: true, limit: 1)
            },
            actions: {
                RowOverflowMenu(label: "More actions for this line from \(line.name)", help: "More actions for this line") {
                    menu(for: line)
                }
            })
    }

    /// The message as a row shows it: one line, and not more than a screen of it. A single
    /// 100 KB line would otherwise be shaped in full on every layout pass to be cut to 400pt.
    private static func preview(_ line: AggregatedLogLine) -> String {
        let text = line.text.count > 400 ? String(line.text.prefix(400)) : line.text
        return line.stream == .notice ? "[Flotilla] \(text)" : text
    }

    private static func summary(_ line: AggregatedLogLine, level: LogLevel?) -> String {
        [line.name, level?.title, line.host.isLocal ? nil : "on \(line.hostName)",
         line.stream == .stderr ? "stderr" : nil, String(line.text.prefix(120))]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// What the `⋮` and a right-click on a row offer. On a row inside a selection of several they
    /// act on the selection — the way every list's right-click does.
    @ViewBuilder
    private func menu(for line: AggregatedLogLine) -> some View {
        let chosen = ui.selection.count > 1 && ui.selection.contains(line.id)
        let count = chosen ? ui.selection.count : 1
        if !chosen {
            Button("Open \(line.name) Logs") { openSource(line.source, kind: line.kind) }
            Divider()
        }
        Button(count == 1 ? "Copy Line" : "Copy \(count) Lines") {
            copyLines(chosen ? selectedLines : [line])
        }
        Button("Copy with Source") {
            copyLines(chosen ? selectedLines : [line], withSource: true)
        }
        Divider()
        Button("Export \(count) Line\(count == 1 ? "" : "s") as CSV\u{2026}") {
            exportCSV(chosen ? selectedLines : [line])
        }
    }

    /// The list's right-click: one row's menu, or what a selection of several can do.
    @ViewBuilder
    private func rowContextMenu(for ids: Set<String>) -> some View {
        let lines = self.lines(for: ids)
        if ids.count == 1, let line = lines.first {
            menu(for: line)
        } else if !lines.isEmpty {
            Button("Copy \(lines.count) Lines") { copyLines(lines) }
            Button("Copy with Source") { copyLines(lines, withSource: true) }
            Divider()
            Button("Export \(lines.count) Lines as CSV\u{2026}") { exportCSV(lines) }
        }
    }

    private func copyLines(_ lines: [AggregatedLogLine], withSource: Bool = false) {
        guard !lines.isEmpty else { return }
        Clipboard.copy(lines.map {
            withSource ? ($0.host.isLocal ? $0.name : "\($0.name) on \($0.hostName)") + "\t" + $0.text : $0.text
        }.joined(separator: "\n"))
    }

    /// Clicking a source takes you to that container's or machine's own Logs tab.
    ///
    /// The owner asked for it and it closes a real gap: the source was a label, so the aggregated
    /// feed could tell you *which* container was shouting and then leave you to find it. It is
    /// the one navigation this screen owes, because the aggregated view is deliberately capped
    /// at N lines per source and the per-source tab is where you go for more.
    private func openSource(_ source: String, kind: ActivityKind) {
        model.requestDetail(kind: kind, subject: source, tab: "Logs")
    }

    /// The source, as the way in rather than as a label.
    ///
    /// Truncates from the head: container ids share prefixes far more often than suffixes, so
    /// keeping the end is what keeps two of them distinguishable.
    private func sourceButton(_ source: String, name: String, kind: ActivityKind,
                              selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 9))
                // Tertiary is nearly invisible on the accent fill; on a selected row the glyph
                // follows the text rather than staying a wash.
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Button(name) { openSource(source, kind: kind) }
                .buttonStyle(.link)
                // **`rowName(selected:)`, not `accentText`.** A selected row is filled with the
                // accent, so an accent-coloured link on it is the one piece of text that stays
                // the colour of its own background and vanishes — while still being clickable,
                // which is the worst version of the problem. Every other table's Name column has
                // taken this argument since it was first made; the Logs table was new and did not
                // inherit it. It still holds with the system link colour and the system accent,
                // which are both blue by default.
                .foregroundStyle(Theme.rowName(selected: selected))
                .lineLimit(1)
                .truncationMode(.head)
            // The subject's own tags, so a feed mixing five containers is readable by colour.
            // This is the whole argument for tagging reaching Logs: you are not tagging log
            // lines, you are recognising which of your things is talking.
            TagPillRow(tags: model.tags.tags(on: kind, source), compact: true, limit: 1)
        }
        .help("Open \(name)\u{2019}s own Logs tab "
              + "(\(kind == .machine ? "machine" : "container"))")
    }

    /// Rebuilds what the list shows from the fetched chunks or the live lines, under the current
    /// search. Called when those change — a load, a tick of the tail, a keystroke — and not from
    /// `body`, so a selection or a hover costs nothing.
    ///
    /// Order is each source's own order, with sources in the stable order `aggregatedLogs` returns
    /// — containers alphabetically, then machines. Explicitly **not** time-ordered; see the note on
    /// this view. Live lines are already one list in arrival order.
    ///
    /// Also keeps the selection inside the feed: a line filtered away or trimmed off the live
    /// buffer is no longer selected, so the page, the box counts and Export agree.
    private func rebuildFeed() {
        let lines = ui.live ? filteredLiveLines : filtered.flatMap(\.lines)
        var index = [String: Int](minimumCapacity: lines.count)
        for (position, line) in lines.enumerated() { index[line.id] = position }
        feed = lines
        feedIndex = index
        failures = ui.live ? liveFailures : filtered.filter { $0.failure != nil }
        if !ui.selection.isEmpty, !ui.selection.allSatisfy({ index[$0] != nil }) {
            ui.selection = ui.selection.filter { index[$0] != nil }
        }
    }

    /// The same free-text rule the fetched feed uses, applied line by line — there are no
    /// per-source chunks to match a name against while streaming, so a search that names a
    /// source matches on the line's own `source` field instead.
    private var filteredLiveLines: [AggregatedLogLine] {
        let needle = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return liveLines }
        return liveLines.filter {
            $0.text.lowercased().contains(needle) || $0.source.lowercased().contains(needle)
                || $0.hostName.lowercased().contains(needle)
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
            if chunk.source.lowercased().contains(needle)
                || (!chunk.host.isLocal && chunk.hostName.lowercased().contains(needle)) { return chunk }
            let hits = chunk.lines.filter { $0.text.lowercased().contains(needle) }
            guard !hits.isEmpty else { return nil }
            return AggregatedLogChunk(source: chunk.source, kind: chunk.kind, lines: hits,
                                      truncated: chunk.truncated, failure: nil,
                                      host: chunk.host, hostName: chunk.hostName)
        }
    }

    /// Running containers and machines, in the order the feed uses.
    private var availableSources: [LogSource] { model.logSources() }

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
        let targets = preloaded == nil ? liveTargets
            : (0..<2).map { LogSource(key: "sim-\($0)", kind: .container, host: .local, hostName: "") }
        guard !targets.isEmpty else { ui.live = false; return }

        liveLines = []
        liveFailures = []
        chunks = []
        rebuildFeed()
        loading = true

        let inbox = LiveAggregateInbox(cap: model.settingsStore[SettingsKeys.logBufferLineCap])
        let boot = ui.scope.isBoot
        let requested = ui.lineLimit
        var readers: [Task<Void, Never>] = []
        for target in targets {
            let events = preloaded != nil ? simulatedEvents(count: simulatedLines / targets.count)
                : target.kind == .machine
                ? model.liveMachineLogs(target.key, lines: requested, boot: boot)
                : model.liveContainerLogs(target.name, lines: requested, bootLog: boot, host: target.host)
            // Off the main actor: this used to hop to it for every line, and a window busy drawing the
            // tail gave each hop a whole run-loop turn — a few dozen lines a second however fast the
            // container wrote. The inbox is locked instead, and the tick below drains it.
            readers.append(Task.detached {
                for await event in events { inbox.accept(event, from: target) }
                inbox.close(target.key, kind: target.kind)
            })
        }
        defer { readers.forEach { $0.cancel() } }

        let cap = model.settingsStore[SettingsKeys.logBufferLineCap]
        var nextIndex: [String: Int] = [:]

        while !Task.isCancelled {
            let (batch, ended, finished) = inbox.snapshot(targets: targets.count)
            if !batch.isEmpty {
                loading = false
                for item in batch {
                    let key = "\(item.kind.rawValue)/\(item.source)"
                    let index = nextIndex[key, default: 0]
                    nextIndex[key] = index + 1
                    liveLines.append(AggregatedLogLine(source: item.source, kind: item.kind,
                                                       index: index, stream: item.stream,
                                                       text: item.text, receivedAt: item.at,
                                                       host: item.host, hostName: item.hostName))
                }
                // One cap across the whole feed, not per source: this is one list and what
                // matters is how much of it is in memory.
                if liveLines.count > cap { liveLines.removeFirst(liveLines.count - cap) }
                updated = Date()
                rebuildFeed()
            }

            if !ended.isEmpty {
                loading = false
                liveFailures.append(contentsOf: ended)
                updated = Date()
                rebuildFeed()
            }

            if finished {
                loading = false
                ui.live = false
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        loading = false
    }

    /// Lines arriving in bursts of 25 every 10ms, then silence, the way a quiet container is — the scroll test's stand-in for a child.
    private func simulatedEvents(count: Int) -> AsyncStream<LiveLogEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                var sent = 0
                while sent < count, !Task.isCancelled {
                    for _ in 0..<min(25, count - sent) {
                        continuation.yield(.line(.stdout, "GET /items/\(sent) 200 \(sent % 90)ms"))
                        sent += 1
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                // Open and quiet, like a container that has said all it will for now.
                try? await Task.sleep(for: .seconds(120))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Export

    /// The lines of `ids`, in feed order. Ids that are no longer in the feed are dropped.
    private func lines(for ids: Set<String>) -> [AggregatedLogLine] {
        ids.compactMap { feedIndex[$0] }.sorted().map { feed[$0] }
    }

    private var selectedLines: [AggregatedLogLine] { lines(for: ui.selection) }

    /// What Export would write: the selected lines, or everything on screen when nothing is
    /// selected. The selection is kept inside the feed, so this never writes a line the user
    /// cannot see.
    private var exportRows: [AggregatedLogLine] {
        ui.selection.isEmpty ? feed : selectedLines
    }

    private var allVisibleSelected: Bool {
        !feed.isEmpty && ui.selection.count == feed.count
    }

    private var exportHelp: String {
        let count = exportRows.count
        guard count > 0 else { return "Nothing to export" }
        return !ui.selection.isEmpty
            ? "Save the \(count) selected line\(count == 1 ? "" : "s") as CSV"
            : "Save all \(count) line\(count == 1 ? "" : "s") as CSV"
    }

    private func exportCSV() { exportCSV(exportRows) }

    /// Writes the given lines as CSV.
    ///
    /// **Five columns, including two the table does not show.** `Received` and `Object` and
    /// `Message` are the table; `Kind` and `Stream` are not, and they are here because an export
    /// is read without the app beside it. `Kind` is what makes `web` unambiguous once the rows
    /// have left the screen — a container and a machine can share a name — and `Stream` carries
    /// the stdout/stderr split that the table encodes as a colour, which a CSV cannot.
    ///
    /// The escaping, including the leading-apostrophe defence against spreadsheet formulas, is
    /// `CSVWriter`'s and is tested there. A log line is attacker-influenced text by definition.
    private func exportCSV(_ lines: [AggregatedLogLine]) {
        guard !lines.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportFilename(scope: ui.scope)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document = CSVWriter.document(
            header: ["Received", "Host", "Kind", "Object", "Stream", "Message"],
            rows: lines.map { line in
                [line.receivedAt.map { $0.formatted(.iso8601) } ?? "",
                 line.hostName,
                 line.kind.rawValue,
                 line.name,
                 line.stream.rawValue,
                 line.text]
            })

        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Surfaced, not swallowed. `try?` here would make a failed save — a read-only
            // volume, a full disk — indistinguishable from a successful one.
            exportError = error.localizedDescription
        }
    }

    /// `flotilla-logs-2026-09-13-142233.csv`. Sortable, unambiguous, and safe on every
    /// filesystem: no colons, which macOS shows as slashes, and no spaces.
    private static func exportFilename(scope: LogsUIState.Scope) -> String {
        let stamp = Date().formatted(
            .verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                      locale: Locale(identifier: "en_US_POSIX"),
                      timeZone: .current,
                      calendar: Calendar(identifier: .gregorian)))
        return "flotilla-\(scope.isBoot ? "boot-" : "")logs-\(stamp).csv"
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
        if let preloaded {
            chunks = preloaded
            rebuildFeed()
            updated = Date()
            return
        }
        if model.machines.isEmpty { await model.refreshMachines() }
        chunks = await model.aggregatedLogs(scope: ui.scope, sources: ui.sources,
                                           only: ui.only, lines: ui.lineLimit)
        rebuildFeed()
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
/// Written from the readers' own tasks and drained by the tick on the main actor, so every access
/// is under one lock. Deliberately plain and *not* observed state — one state write per line is
/// exactly what the tick exists to avoid.
final class LiveAggregateInbox: @unchecked Sendable {
    struct Item {
        let source: String
        let kind: ActivityKind
        let stream: LogLine.Stream
        let text: String
        let host: HostRef
        let hostName: String
        /// Recorded when the line **arrived**, not when the tick drained it. A drain can carry
        /// a hundred lines written over the preceding 120 ms, and stamping them all with the
        /// drain's own clock would flatten that into one instant — which is precisely the
        /// fabricated ordering this screen refuses to produce on a fetch.
        let at: Date
    }

    private let lock = NSLock()
    private var pending: [Item] = []
    /// Ends not yet shown. Drained like lines are, so an ended source appears in the same tick
    /// as the lines it wrote just before ending rather than a frame later.
    private var endedPending: [AggregatedLogChunk] = []
    /// Sources whose stream has terminated, by `kind/source` key. A `Set` because a stream that
    /// both fails and then closes must not be counted twice — that would end the tail early
    /// while other children were still running.
    private var closed: Set<String> = []

    /// No more than the feed keeps: anything older would be trimmed on the next tick anyway.
    private let cap: Int
    init(cap: Int) { self.cap = max(1, cap) }

    func accept(_ event: LiveLogEvent, from target: LogSource) {
        let source = target.key, kind = target.kind
        lock.withLock {
            switch event {
            case .line(let stream, let text):
                pending.append(Item(source: source, kind: kind, stream: stream, text: text,
                                    host: target.host, hostName: target.hostName, at: Date()))
                if pending.count > cap { pending.removeFirst(pending.count - cap) }
            case .ended(let end):
                // A clean end is not a failure. The container exited or was stopped, which is a fact
                // worth a row — but tinting it like a broken source would cry wolf every time
                // someone stops something while watching.
                if end.ok { closeLocked(source, kind: kind) }
                else { noteLocked(source, kind: kind, end.reason ?? "stream ended (exit \(end.exitCode))") }
            case .failed(let reason):
                noteLocked(source, kind: kind, reason)
            }
        }
    }

    func close(_ source: String, kind: ActivityKind) {
        lock.withLock { closeLocked(source, kind: kind) }
    }

    private func closeLocked(_ source: String, kind: ActivityKind) {
        closed.insert("\(kind.rawValue)/\(source)")
    }

    private func noteLocked(_ source: String, kind: ActivityKind, _ reason: String) {
        endedPending.append(AggregatedLogChunk(source: source, kind: kind, lines: [],
                                               truncated: false, failure: reason))
        closeLocked(source, kind: kind)
    }

    /// Lines, ends and the closed count taken under one hold of the lock. Reading them in three
    /// calls let a reader append its last line or failure and close between the drain and the
    /// closed check, so the loop saw "everything closed" without ever having consumed it.
    /// `finished` is true only when every one of `targets` was closed *as of this same snapshot*,
    /// so nothing can arrive after it.
    func snapshot(targets: Int) -> (items: [Item], ended: [AggregatedLogChunk], finished: Bool) {
        lock.withLock {
            defer { pending.removeAll(keepingCapacity: true); endedPending.removeAll(keepingCapacity: true) }
            return (pending, endedPending, closed.count >= targets)
        }
    }
}

/// Scrolls the `List` it is the background of to its last row each time `trigger` changes.
///
/// A SwiftUI `List` on macOS is an `NSTableView`, and this is the cheap way to the bottom of it: the
/// clip view moved to the end of the document, with no row to look up. Found through the hosting view's tree
/// rather than held, because SwiftUI gives no handle to the table.
private struct TailPinner: NSViewRepresentable {
    let trigger: Int
    /// Whether the tail is still being followed. Read again when a delayed scroll fires.
    let live: Bool

    final class Coordinator {
        var seen = 0
        var live = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.live = live
        guard coordinator.seen != trigger else { return }
        coordinator.seen = trigger
        let generation = trigger
        // After this update's rows exist, or the end is the one before the newest — and again a beat
        // later and again after that: the document's height is an estimate until the rows near the
        // end have been drawn, so the first landing is a few rows short of the real bottom.
        for delay in [0.0, 0.08, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view, weak coordinator] in
                // Live may have been switched off, or a newer trigger issued, since this was
                // queued; a stale callback must not drag a list the user has since scrolled.
                guard let coordinator, coordinator.live, coordinator.seen == generation else { return }
                guard let root = view?.window?.contentView, let table = Self.table(near: view, in: root),
                      let scroll = table.enclosingScrollView else { return }
                // The clip view to the document's end, not `scrollRowToVisible`: that sizes every
                // row above the target, so it costs more with every line the tail adds.
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, table.frame.height - clip.bounds.height)))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    /// The table that shares an ancestor with this view: the nearest one, so a window with another
    /// list in it (the sidebar's) is not the one scrolled.
    private static func table(near view: NSView?, in root: NSView) -> NSTableView? {
        var ancestor = view?.superview
        while let current = ancestor {
            var queue = [current]
            while let candidate = queue.popLast() {
                if let table = candidate as? NSTableView { return table }
                queue.append(contentsOf: candidate.subviews)
            }
            if current === root { break }
            ancestor = current.superview
        }
        return nil
    }
}
