import SwiftUI
import FlotillaCore

/// The Logs section: one place that answers "what has everything been saying", instead of
/// visiting each container's detail tab in turn.
///
/// **Grouped by source, never interleaved into one stream** — see `aggregatedLogs`. `container
/// logs` has no `--timestamps`, so the only clock available is the moment *we* read the chunk,
/// which is the same for every line in it. A single merged column ordered by that would look
/// authoritative and mean nothing. Each source keeps its own block, in its own order, labelled.
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

            Picker("", selection: Binding(get: { ui.sources }, set: { ui.sources = $0 })) {
                ForEach(LogsUIState.Sources.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            .help("Which kinds of source to read from")

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
            ContentUnavailableView("The container runtime isn't available",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("Logs come from `container logs`, which needs the runtime."))
        } else if chunks.isEmpty {
            // Says *why* it is empty. Only running sources can answer `logs`, and "nothing is
            // running" is a different fact from "nothing has been logged".
            ContentUnavailableView("Nothing to read",
                                   systemImage: "text.alignleft",
                                   description: Text("Only running containers and machines can return logs."))
        } else if filtered.allSatisfy({ $0.lines.isEmpty && $0.failure == nil }) && !ui.search.isEmpty {
            ContentUnavailableView.search(text: ui.search)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(filtered) { chunk in
                        sourceBlock(chunk)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func sourceBlock(_ chunk: AggregatedLogChunk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: chunk.kind.systemImage)
                    .foregroundStyle(.secondary)
                Text(chunk.source)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                if chunk.truncated {
                    // Per source, not one banner for the screen: which log was clipped matters.
                    Text("tail of \(ui.lineLimit)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Older lines exist. Raise the line count to read further back.")
                }
                Spacer()
                Text(chunk.kind == .machine ? "machine" : "container")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if let failure = chunk.failure {
                // Shown, not dropped. A source that cannot be read is a fact worth seeing, and
                // silently omitting it makes "quiet" and "broken" identical.
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            } else if chunk.lines.isEmpty {
                Text("No output.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chunk.lines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            // `stderr` here is the *CLI's* stderr, not the container's own —
                            // `container logs` writes program output to stdout, so a line
                            // arriving on stderr is the runtime complaining. Tinted rather than
                            // filtered, because it is a different kind of information and
                            // offering it as a "stderr" filter would imply a split the CLI does
                            // not make.
                            .foregroundStyle(line.stream == .stderr ? Theme.warning : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            }
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

    private func load() async {
        loading = true
        defer { loading = false }
        chunks = await model.aggregatedLogs(scope: ui.scope, sources: ui.sources,
                                           only: ui.only, lines: ui.lineLimit)
        updated = Date()
    }
}
