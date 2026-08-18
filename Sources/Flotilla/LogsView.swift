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
/// which is identical for every line in it. So the feed is **not** chronological across sources
/// and does not pretend to be: lines keep their source's own order, sources follow a stable
/// order, and the toolbar says so. Sorting this by a fabricated time would look authoritative
/// and order lines by nothing at all. The per-source filter is what actually answers "just show
/// me this one".
struct LogsView: View {
    let model: AppModel
    /// Owned by `MainWindowView` — see `LogsUIState`.
    let ui: LogsUIState

    @State private var chunks: [AggregatedLogChunk] = []
    @State private var loading = false
    @State private var updated: Date?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Fetched on arrival and on every filter change, not on a timer. Logs are a question you
        // ask, and a 200-line fetch per running source every few seconds is a lot of processes
        // for a screen nobody is watching. Refresh is a button.
        .task(id: fetchKey) { await load() }
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

    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search log lines…",
                       updated: updated,
                       leading: {
            Picker("", selection: Binding(get: { ui.scope }, set: { ui.scope = $0 })) {
                ForEach(LogsUIState.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Process output, or the VM boot log")

            // Kinds, and then individual names — "just this container" is the filter that
            // actually replaces scrolling past four others.
            Picker("", selection: Binding(get: { ui.sources }, set: { ui.sources = $0 })) {
                ForEach(LogsUIState.Sources.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("Which kinds of source to read from")

            Menu {
                Button {
                    ui.only.removeAll()
                } label: {
                    Label("All sources", systemImage: ui.only.isEmpty ? "checkmark" : "")
                }
                Divider()
                // Built from what is actually running, because those are the only sources
                // `logs` can answer for — a menu offering a stopped container would be a
                // control that cannot work.
                ForEach(availableSources, id: \.0) { source, kind in
                    Button {
                        if ui.only.contains(source) { ui.only.remove(source) } else { ui.only.insert(source) }
                    } label: {
                        Label(source, systemImage: ui.only.contains(source)
                              ? "checkmark"
                              : kind.systemImage)
                    }
                }
            } label: {
                Text(sourceFilterLabel)
            }
            .fixedSize()
            .help("Filter to particular containers or machines")

            Picker("", selection: Binding(get: { ui.lineLimit }, set: { ui.lineLimit = $0 })) {
                ForEach(LogsUIState.lineLimits, id: \.self) { Text("\($0) lines").tag($0) }
            }
            .fixedSize()
            .help("Lines to read from the end of each source")
        }, trailing: {
            ToolbarIconButton(systemImage: "arrow.clockwise", label: "Refresh") {
                Task { await load() }
            }
        })
    }

    @ViewBuilder
    private var content: some View {
        if loading && chunks.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.runtimeUsable {
            ContentUnavailableView("The container runtime isn\u{2019}t available",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("Logs come from `container logs`, which needs the runtime."))
        } else if chunks.isEmpty {
            ContentUnavailableView("Nothing to read",
                                   systemImage: "text.alignleft",
                                   description: Text("Only running containers and machines can return logs."))
        } else if feed.isEmpty && failures.isEmpty {
            if ui.search.isEmpty {
                ContentUnavailableView("No output",
                                       systemImage: "text.alignleft",
                                       description: Text("The selected sources have not logged anything."))
            } else {
                ContentUnavailableView.search(text: ui.search)
            }
        } else {
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
        filtered.flatMap(\.lines)
    }

    private var failures: [AggregatedLogChunk] {
        filtered.filter { $0.failure != nil }
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

    private var sourceFilterLabel: String {
        switch ui.only.count {
        case 0: "All sources"
        case 1: ui.only.first ?? "1 source"
        default: "\(ui.only.count) sources"
        }
    }

    private func load() async {
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
