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

    /// The display popover — wrapping and the timestamp column, the two things Docker Desktop's
    /// own log screen puts behind an overflow menu. Same idea, same place: they change how the
    /// feed is drawn rather than what is in it, so they do not belong beside the filters.
    @State private var showingDisplay = false
    /// Set when an export fails. A save that silently does nothing is the failure shape this app
    /// keeps finding; `try?` on the write would have been exactly that.
    @State private var exportError: String?

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
            // **Select all, in the same place every other section puts it** — first in the
            // leading cluster, before the controls that change what you are looking at. It is
            // what makes the selection worth having: the export button reads the selection, and
            // "select these two hundred lines" with no select-all means dragging through them.
            //
            // Scoped to what is *visible*, like every other section's: it unions the feed's own
            // ids rather than setting a flag, so a line filtered away is never silently exported
            // because a box was ticked before the filter moved.
            Toggle("", isOn: Binding(get: { allVisibleSelected },
                                     set: { on in
                                         if on { ui.selection.formUnion(visibleIDs) }
                                         else { ui.selection.subtract(visibleIDs) }
                                     }))
                .labelsHidden()
                .disabled(feed.isEmpty)
                .accessibilityLabel(allVisibleSelected ? "Deselect all lines" : "Select all lines")
                .help(allVisibleSelected
                      ? "Deselect all"
                      : "Select all \(visibleIDs.count) line\(visibleIDs.count == 1 ? "" : "s")")

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
            // How the feed is *drawn* — wrapping, and whether the Received column shows.
            // Beside the other two popovers rather than in the trailing cluster, because those
            // are the things you do to the feed and these are things you do to the view of it.
            // `gearshape`, the owner's call. It was `textformat` (Aa), which named the *kind*
            // of thing behind the button rather than what it is — and the two switches in there
            // are not both about type: wrapping is, the timestamp column is not. A gear says
            // "options for this view", which is what it actually holds.
            //
            // Not confusable with the window bar's own Settings gear: that one lives in the
            // title bar at the far right of the window, on a coloured ground, and this sits in
            // the section's control band with the section's other controls. It is also distinct
            // from everything beside it here — neither the scope picker's `text.alignleft`, the
            // Lines list nor the Sources filter reads as a gear, which is what the previous
            // choice was avoiding.
            IconActionButton(systemImage: "gearshape", label: "Display",
                             help: displayHelp,
                             active: ui.wrapLines || ui.showTimestamps) {
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

    private var displayHelp: String {
        var on: [String] = []
        if ui.wrapLines { on.append("wrapping") }
        if ui.showTimestamps { on.append("timestamps") }
        return on.isEmpty ? "How the feed is shown" : "Showing " + on.joined(separator: " and ")
    }

    private var displayPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Wrap lines", isOn: Binding(get: { ui.wrapLines },
                                               set: { ui.wrapLines = $0 }))
            Text("Off, a long message stays on one line and can be opened row by row with the "
                 + "chevron.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

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
            // **A `Table`, matching every other section.**
            //
            // It was a `LazyVStack` of hand-drawn rows, which is what a log *reads* like and not
            // what this screen is for: you come here to find the lines that matter among two
            // hundred that do not, take them somewhere else, and jump to whatever produced them.
            // None of that is reachable from a stack of `Text` — no selection, so nothing to
            // export; no columns, so nothing to hide; and a fixed source tag rather than a way
            // in. Docker Desktop's log screen is a table for exactly these reasons and the owner
            // asked for the same shape here.
            //
            // **No `sortOrder`, and that is the one place this deliberately differs from the
            // other tables.** Every other section sorts because its rows are independent things.
            // These are not: within a source, a log line's position *is* its meaning, and the
            // only clock available is when we read it (see `AggregatedLogLine.receivedAt`). A
            // clickable "Received" header on a fetched feed would reorder two hundred lines that
            // all share one timestamp, by nothing, and look authoritative doing it. The source
            // filter is what answers "just show me this one"; the search field answers the rest.
            VStack(spacing: 0) {
                // Failures above the table rather than mixed into it. A source that could not be
                // read is not a log line — it has no message, no position and nothing to select
                // — and a row that renders half the columns as blanks is how a table stops being
                // readable. They stay visible under any filter, for the reason `filtered` gives:
                // hiding why a source is missing is how you conclude a log is empty when it is
                // broken.
                if !failures.isEmpty { failureBand }

                ScrollViewReader { proxy in
                    SwiftUI.Table(feed,
                                  selection: Binding(get: { ui.selection },
                                                     set: { ui.selection = $0 }),
                                  columnCustomization: Binding(
                                      get: { ui.columnCustomization },
                                      set: { ui.columnCustomization = $0 })) {
                        TableColumn("") { line in
                            selectionToggle(for: line.id)
                        }
                        .width(min: 28, ideal: 30, max: 34)

                        // Present only when asked for, rather than always-present-and-hideable
                        // through the column menu. The reason to leave it out is not "I have
                        // enough columns" — it is that on a fetched feed every value in it is
                        // the same, so it is a column that means something in one mode and
                        // repeats itself in the other. The Display popover is where that is
                        // explained, so that is where it is switched.
                        if ui.showTimestamps {
                            TableColumn("Received") { line in
                                Text(line.receivedAt.map(Self.timestamp) ?? "\u{2014}")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .help("When Flotilla received this line. `container logs` "
                                          + "has no timestamps of its own.")
                            }
                            // Sized for the whole `2026-09-13 12:04:50`, not the time
                            // alone — a date column that truncates to `2026-09-13 12:0…` is
                            // worse than no column.
                            .width(min: 140, ideal: 156, max: 190)
                        }

                        TableColumn("Object") { line in
                            sourceButton(line.source, kind: line.kind,
                                         selected: ui.selection.contains(line.id))
                        }
                        // Capped. `width(min:ideal:)` leaves the maximum unbounded, and with
                        // only three or four columns the table handed Object every spare point
                        // — measured at ~830pt for names eight characters long, with the
                        // messages squeezed into the right-hand third. The message is what this
                        // screen is for, so it is the column that takes the slack.
                        .width(min: 110, ideal: 168, max: 260)
                        .customizationID("object")
                        // The only column carrying a `customizationID`, which is what the
                        // customization binding actually persists: this is the one whose width
                        // people drag, because source names vary from `web` to
                        // `probe-alpine-latest`. Message has none because it is the screen's
                        // whole purpose, and Received is switched from the Display popover
                        // rather than the header menu — for the reason that popover explains.

                        TableColumn("Message") { line in
                            messageCell(line)
                        }
                    }
                    // Follows the tail while Live is on, as the `LazyVStack` did. Without it the
                    // stream works and does not look like it: lines arrive below the fold and the
                    // screen sits still while five children push output into it.
                    .onChange(of: feed.last?.id) { _, newest in
                        guard ui.live, let newest else { return }
                        // No animation: a tail that eases to each new line lags behind the output
                        // and makes the text unreadable while it moves.
                        proxy.scrollTo(newest, anchor: .bottom)
                    }
                    .onChange(of: ui.live) { _, isOn in
                        if isOn, let newest = feed.last?.id {
                            proxy.scrollTo(newest, anchor: .bottom)
                        }
                    }
                }
                .contextMenu(forSelectionType: AggregatedLogLine.ID.self) { ids in
                    lineMenu(for: ids)
                } primaryAction: { ids in
                    // Double-click opens the row, the way it opens a detail elsewhere. Only when
                    // the activation names exactly one line: with several selected, `first` is an
                    // arbitrary member of a `Set`.
                    guard ids.count == 1, let id = ids.first else { return }
                    toggleExpanded(id)
                }
            }
        }
    }

    /// Sources that could not be read, above the feed.
    private var failureBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(failures) { chunk in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                    sourceButton(chunk.source, kind: chunk.kind)
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

    /// The message, and the control that opens it.
    ///
    /// Three states, and they compose: truncated to one line; wrapped, because the toolbar says
    /// so; or wrapped because *this* row was opened. The per-row chevron exists because the
    /// global toggle is the wrong tool for the usual case — one stack trace among two hundred
    /// ordinary lines — and turning wrapping on for all of them pushes everything else off the
    /// screen to read one.
    ///
    /// **The chevron appears only when there is something behind it, and that is measured rather
    /// than guessed.** The first attempt tested `text.count > 96`, which is wrong in both
    /// directions: the Message column is resizable, so the same line overflows at one width and
    /// fits at another. `ViewThatFits` asks the layout system the actual question — it takes the
    /// first child that fits, so a line that fits whole renders with no chevron at all, and one
    /// that does not falls through to the truncated form with the control beside it. Resizing
    /// the column re-evaluates it.
    @ViewBuilder
    private func messageCell(_ line: AggregatedLogLine) -> some View {
        if ui.wrapLines {
            // Everything is already shown, so a chevron here would be a control whose two
            // states look identical.
            messageText(line, wrapped: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if ui.expanded.contains(line.id) {
            HStack(alignment: .top, spacing: 6) {
                messageText(line, wrapped: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                expandButton(line, expanded: true)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                // Fits whole: no control, because there is nothing to reveal.
                //
                // `fixedSize()` and **no** `maxWidth: .infinity` — that combination is what
                // makes this measure anything at all. The first version put the greedy frame
                // inside `messageText`, so this candidate always reported that it fitted and
                // the chevron never appeared on any row, including visibly truncated ones.
                // Measured on the `Starting Squid Cache version 6.13 for aarch64-…` line,
                // which is where it showed.
                messageText(line, wrapped: false).fixedSize()
                HStack(alignment: .top, spacing: 6) {
                    messageText(line, wrapped: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    expandButton(line, expanded: false)
                }
            }
        }
    }

    /// The text alone, with no opinion about width — the caller supplies that, because the
    /// `ViewThatFits` candidates need opposite answers: one intrinsic, one greedy.
    private func messageText(_ line: AggregatedLogLine, wrapped: Bool) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            // `stderr` here is the *CLI's* stderr, not the container's own: `container logs`
            // writes program output to stdout, so a line arriving on stderr is the runtime
            // complaining. Tinted rather than filtered — offering a "stderr" filter would
            // imply a split the CLI does not make.
            //
            // The tint drops on a selected row. Amber `#E5A100` on the accent fill `#EE7B4D` is
            // two neighbouring oranges, so the one line you deliberately clicked would be the
            // hardest to read; `.primary` inverts with the selection and stays legible. The
            // distinction is not lost — deselect, or read the Stream column in the CSV.
            .foregroundStyle(line.stream == .stderr && !ui.selection.contains(line.id)
                             ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .lineLimit(wrapped ? nil : 1)
            .fixedSize(horizontal: false, vertical: wrapped)
    }

    private func expandButton(_ line: AggregatedLogLine, expanded: Bool) -> some View {
        Button {
            toggleExpanded(line.id)
        } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(expanded ? "Collapse this message" : "Show the whole message")
        .help(expanded ? "Collapse" : "Show the whole message")
    }

    private func toggleExpanded(_ id: AggregatedLogLine.ID) {
        if ui.expanded.contains(id) { ui.expanded.remove(id) } else { ui.expanded.insert(id) }
    }

    /// Same checkbox column every other section's table leads with. Plain `Table` selection hides
    /// multi-select behind a modifier key; the box makes it visible.
    private func selectionToggle(for id: AggregatedLogLine.ID) -> some View {
        Toggle("", isOn: Binding(
            get: { ui.selection.contains(id) },
            set: { on in
                if on { ui.selection.insert(id) } else { ui.selection.remove(id) }
            }))
            .labelsHidden()
            .accessibilityLabel("Select this line")
    }

    /// `2026-09-13 12:04:50`, fixed, 24-hour, no AM/PM and no locale.
    ///
    /// The owner's call, and it is the right format for this column. `.formatted(date:time:)`
    /// follows the user's region — it was rendering `12:04:50 PM` here — which is fine for
    /// "Updated …" in a toolbar and wrong for a log: the date matters because the feed can carry
    /// lines read minutes or hours apart, AM/PM costs three characters and orders nothing, and a
    /// twelve-hour clock is the one that makes 12:04 ambiguous.
    ///
    /// Sortable as text, too, which is the other reason ISO-style ordering is worth the width.
    /// `en_US_POSIX` and an explicit Gregorian calendar because a *fixed* format must not be
    /// reinterpreted by whatever calendar or numbering system the Mac is set to — a Buddhist or
    /// Hijri calendar would print a different year, and eastern Arabic numerals different digits.
    ///
    /// Not a relative time: two lines four seconds apart is the distinction this column exists to
    /// draw, and "just now" for both would erase it.
    private static func timestamp(_ date: Date) -> String {
        // One literal, not three concatenated: `Date.FormatString` is built by string
        // *interpolation*, so `+` between pieces is a `String` and does not type-check.
        date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 timeZone: .current,
                                 calendar: Calendar(identifier: .gregorian)))
    }

    /// The row menu. Same shape as every other table's: what you can do with the rows, then Copy,
    /// and nothing that is only reachable here.
    @ViewBuilder
    private func lineMenu(for ids: Set<AggregatedLogLine.ID>) -> some View {
        let lines = feed.filter { ids.contains($0.id) }
        let sources = Set(lines.map { "\($0.kind.rawValue)/\($0.source)" })

        // Only when the selection is about one source. "Open Logs" with three sources selected
        // has no single answer, and picking one of them arbitrarily is how the containers detail
        // used to open the wrong row.
        if sources.count == 1, let first = lines.first {
            Button("Open \(first.source) Logs") { openSource(first.source, kind: first.kind) }
        }
        Button(lines.count == 1 ? "Show Whole Message" : "Show Whole Messages") {
            for line in lines { ui.expanded.insert(line.id) }
        }
        .disabled(lines.isEmpty || ui.wrapLines)
        Divider()
        Button(lines.count == 1 ? "Copy Line" : "Copy \(lines.count) Lines") {
            Clipboard.copy(lines.map(\.text).joined(separator: "\n"))
        }
        .disabled(lines.isEmpty)
        Button("Copy with Source") {
            Clipboard.copy(lines.map { "\($0.source)\t\($0.text)" }.joined(separator: "\n"))
        }
        .disabled(lines.isEmpty)
        Divider()
        Button("Export \(lines.count) Line\(lines.count == 1 ? "" : "s") as CSV\u{2026}") {
            exportCSV(lines)
        }
        .disabled(lines.isEmpty)
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
    private func sourceButton(_ source: String, kind: ActivityKind,
                              selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 9))
                // Tertiary is nearly invisible on the accent fill; on a selected row the glyph
                // follows the text rather than staying a wash.
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Button(source) { openSource(source, kind: kind) }
                .buttonStyle(.link)
                // **`rowName(selected:)`, not `accentText`.** A selected row is filled with the
                // accent, so an accent-coloured link on it is the one piece of text that stays
                // the colour of its own background and vanishes — while still being clickable,
                // which is the worst version of the problem. Every other table's Name column has
                // taken this argument since `.link` was found to hardcode the system blue; the
                // Logs table was new and did not inherit it.
                .foregroundStyle(Theme.rowName(selected: selected))
                .lineLimit(1)
                .truncationMode(.head)
            // The subject's own tags, so a feed mixing five containers is readable by colour.
            // This is the whole argument for tagging reaching Logs: you are not tagging log
            // lines, you are recognising which of your things is talking.
            TagPillRow(tags: model.tags.tags(on: kind, source), compact: true, limit: 1)
        }
        .help("Open \(source)\u{2019}s own Logs tab "
              + "(\(kind == .machine ? "machine" : "container"))")
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
                                                       text: item.text, receivedAt: item.at))
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

    // MARK: Export

    /// What Export would write: the selected lines, or everything on screen when nothing is
    /// selected.
    ///
    /// Intersected with the feed, never taken from the selection set alone. Filtering does not
    /// clear a table's selection, so a line you selected and then filtered away is still in
    /// `ui.selection` — and exporting a row the user cannot see is the same mistake the bulk
    /// delete bars guard against with their own `actionable`.
    private var exportRows: [AggregatedLogLine] {
        let selected = feed.filter { ui.selection.contains($0.id) }
        return selected.isEmpty ? feed : selected
    }

    /// The lines currently on screen. The same set `exportRows` falls back to, named separately
    /// because select-all and export ask the same question for different reasons.
    private var visibleIDs: Set<AggregatedLogLine.ID> { Set(feed.map(\.id)) }

    private var allVisibleSelected: Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: ui.selection)
    }

    private var exportHelp: String {
        let count = exportRows.count
        guard count > 0 else { return "Nothing to export" }
        let selected = feed.contains { ui.selection.contains($0.id) }
        return selected
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
            header: ["Received", "Kind", "Object", "Stream", "Message"],
            rows: lines.map { line in
                [line.receivedAt.map { $0.formatted(.iso8601) } ?? "",
                 line.kind.rawValue,
                 line.source,
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
        /// Recorded when the line **arrived**, not when the tick drained it. A drain can carry
        /// a hundred lines written over the preceding 120 ms, and stamping them all with the
        /// drain's own clock would flatten that into one instant — which is precisely the
        /// fabricated ordering this screen refuses to produce on a fetch.
        let at: Date
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
            pending.append(Item(source: source, kind: kind, stream: stream, text: text,
                                at: Date()))
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
