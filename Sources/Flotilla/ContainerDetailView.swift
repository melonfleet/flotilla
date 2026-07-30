import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import FlotillaCore

/// Detail sheet for one container: Overview, Logs, and Inspect.
///
/// Live streaming and `exec` are Phase 4 (`PHASE1-UI.md`). Logs is a repeated bounded fetch
/// (`cli.logs(id, lines:, bootLog:)`), not a subscription — even "Follow" below is just that
/// fetch on a timer.
struct ContainerDetailView: View {
    let model: AppModel
    let container: Container

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        case inspect = "Inspect"
        var id: Self { self }
    }

    @State private var tab: Tab = .overview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            switch tab {
            case .overview: overview
            case .logs: LogsTab(model: model, containerID: container.id)
            case .inspect: InspectTab(model: model, container: container)
            }
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id).font(.headline)
                Text(container.configuration.image.reference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding(12)
    }

    private var overview: some View {
        Form {
            // `Navigation.swift` declares a top-level `Section` that shadows SwiftUI's —
            // must be spelled out here.
            SwiftUI.Section("Overview") {
                LabeledContent("State", value: container.status.state.capitalized)
                LabeledContent("Image", value: container.configuration.image.reference)
                LabeledContent("ID", value: container.id)
                LabeledContent("IP", value: container.ipv4 ?? "—")
                LabeledContent("Network", value: container.status.networks?.first?.network ?? "—")
                LabeledContent("Created", value: Self.createdLabel(container.configuration.creationDate))
                // One row per mapping rather than the table's comma-joined summary — the
                // detail pane has the space, and a container publishing several ports is
                // exactly where a single truncated line is least useful.
                if container.publishedPorts.isEmpty {
                    LabeledContent("Ports", value: "None published")
                } else {
                    LabeledContent("Ports") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(container.publishedPorts, id: \.self) { port in
                                Text(port.displayText).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `creationDate` is an ISO-8601 string from `container`, not a `Date` — parse it here
    /// for display only.
    private static func createdLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One already-tagged, already-coloured line ready for display — shared by the Logs and
/// Inspect tabs so both get the same search/highlight/wrap behaviour from one place.
private struct DisplayLine: Identifiable {
    let id: Int
    let text: String
    let color: Color
}

/// The scrollable, monospaced line list both tabs render into. `.textSelection(.enabled)`
/// on the container is what stands in for a bespoke "copy selection" — native drag-select
/// plus Cmd-C — rather than hand-rolling row selection state; that assumption is called out
/// in the report since it can't be verified without a macOS build.
private struct LineListView: View {
    let lines: [DisplayLine]
    let search: String
    let wrap: Bool

    var body: some View {
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    highlighted(line.text, color: line.color)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: !wrap, vertical: false)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                }
            }
            .padding(12)
        }
        .textSelection(.enabled)
    }

    /// Built as one `AttributedString` rather than by `Text` + `Text` concatenation, which
    /// is deprecated in macOS 26. It also fixes a limitation of the original: concatenating
    /// three pieces could only ever bold the **first** match on a line, so a line containing
    /// the search term twice highlighted one and quietly ignored the rest. This marks every
    /// occurrence.
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

/// Logs tab: bounded fetch, boot-log toggle, search+highlight, timestamps, wrap, capped
/// retention, Follow (a timer, not a stream), Copy and Save. Owns its own loading/error
/// state rather than the shared `AppModel.actionError` alert — a failed reload here is
/// local to this tab and shouldn't pop a modal over the rest of the app.
private struct LogsTab: View {
    let model: AppModel
    let containerID: String

    @State private var chunk: LogChunk?
    @State private var loading = false
    @State private var error: String?
    /// When this `chunk` was fetched. `LogLine.receivedAt` exists on the model, but
    /// `ContainerCLI.logs` never actually passes a value for it — every line comes back
    /// `nil` today, so a Timestamps toggle built only on `line.receivedAt` would show
    /// `--:--:--` forever. This is the fallback: one client-side stamp per fetch, used
    /// only when a line has no timestamp of its own.
    @State private var fetchedAt: Date?

    @State private var bootLog = false
    @State private var search = ""
    @State private var showTimestamps: Bool
    @State private var wrap = true
    @State private var follow = false
    @State private var followTask: Task<Void, Never>?

    /// Repeated bounded fetch while Follow is on — real streaming is Phase 4. Not a
    /// settings-registry value: there is no dedicated log-follow interval today, and
    /// adding one means editing `FlotillaCore`, which is the core owner's this round.
    private static let followIntervalSeconds: Int = 3

    init(model: AppModel, containerID: String) {
        self.model = model
        self.containerID = containerID
        _showTimestamps = State(initialValue: model.settingsStore[SettingsKeys.logShowTimestamps])
    }

    /// `logTailLines`/`logBufferLineCap` already exist in the settings registry (the core owner's),
    /// so the log viewer's request size and retention cap come from there rather than
    /// hardcoded numbers.
    private var requestedLines: Int { model.settingsStore[SettingsKeys.logTailLines] }
    private var lineCap: Int { model.settingsStore[SettingsKeys.logBufferLineCap] }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            statusBar
            content
        }
        .task { await load() }
        .onChange(of: bootLog) { _, _ in Task { await load() } }
        .onChange(of: follow) { _, isOn in
            followTask?.cancel()
            guard isOn else { followTask = nil; return }
            followTask = Task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(Self.followIntervalSeconds))
                }
            }
        }
        .onDisappear {
            followTask?.cancel()
            followTask = nil
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Boot Log", isOn: $bootLog)
                Spacer()
                Toggle("Timestamps", isOn: $showTimestamps)
                Toggle("Wrap", isOn: $wrap)
                Toggle("Follow", isOn: $follow)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(loading || follow)
                Button {
                    copyAll()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(displayLines.isEmpty)
                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(displayLines.isEmpty)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let chunk {
            HStack(spacing: 8) {
                // Never let the boot log and the process log be confused for each other.
                Label(
                    chunk.isBootLog ? "Boot log (micro-VM)" : "Container logs",
                    systemImage: chunk.isBootLog ? "shippingbox" : "text.alignleft"
                )
                .font(.caption.bold())
                if chunk.truncated {
                    Text("Showing the most recent \(chunk.requestedLines) — older lines exist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if displayLines.count < chunk.lines.count {
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
        if loading && chunk == nil {
            ProgressView("Loading logs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView(
                "Couldn't load logs",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if !displayLines.isEmpty {
            LineListView(lines: displayLines, search: search, wrap: wrap)
        } else {
            ContentUnavailableView(
                "No log output",
                systemImage: "doc.text",
                description: Text("This container hasn't produced any output yet.")
            )
        }
    }

    private var matchCount: Int { LineListView.matchCount(displayLines, search: search) }

    /// Retained lines, capped at `logBufferLineCap`. `chunk.lines` is already bounded by
    /// `-n`/`logTailLines`, so today this is a no-op safety net — it only bites if a user
    /// raises `logTailLines` in Settings past the buffer cap. That's the "cap what you
    /// retain" the brief asked for, stated rather than left implicit.
    private var displayLines: [DisplayLine] {
        guard let chunk else { return [] }
        return chunk.lines.suffix(lineCap).map { line in
            let text = showTimestamps ? "\(Self.timeLabel(line.receivedAt ?? fetchedAt))  \(line.text)" : line.text
            return DisplayLine(id: line.id, text: text, color: line.stream == .stderr ? .red : .primary)
        }
    }

    private static func timeLabel(_ date: Date?) -> String {
        guard let date else { return "--:--:--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            chunk = try await model.fetchLogs(for: containerID, lines: requestedLines, bootLog: bootLog)
            fetchedAt = Date()
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }

    private func copyAll() {
        let text = displayLines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        let kind = chunk?.isBootLog == true ? "boot" : "logs"
        panel.nameFieldStringValue = "\(containerID)-\(kind).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = displayLines.map(\.text).joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Inspect tab: a compact typed summary plus the CLI's own inspect JSON, pretty-printed
/// (`AppModel.fetchInspectJSON`, which wraps the core owner's `rawInspectJSON(_:)` +
/// `JSONPrettyPrinter`), monospaced, natively selectable, and filterable by a cheap
/// line-substring search.
private struct InspectTab: View {
    let model: AppModel
    let container: Container

    @State private var json: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search JSON", text: $search)
                    .textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .padding(12)
            Divider()
            content
        }
        .task { await load() }
    }

    private var summary: some View {
        Form {
            SwiftUI.Section("Summary") {
                LabeledContent("State", value: container.status.state.capitalized)
                LabeledContent("Image", value: container.configuration.image.reference)
                LabeledContent("ID", value: container.id)
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 150)
    }

    @ViewBuilder
    private var content: some View {
        if loading && json == nil {
            ProgressView("Loading inspect JSON…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView(
                "Couldn't inspect this container",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let json {
            LineListView(lines: Self.displayLines(json), search: search, wrap: true)
        }
    }

    private static func displayLines(_ json: String) -> [DisplayLine] {
        json.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            DisplayLine(id: index, text: String(line), color: .primary)
        }
    }

    private var matchCount: Int {
        guard let json, !search.isEmpty else { return 0 }
        return LineListView.matchCount(Self.displayLines(json), search: search)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            json = try await model.fetchInspectJSON(for: container.id)
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }
}
