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
        case processes = "Processes"
        case logs = "Logs"
        case inspect = "Inspect"
        case configuration = "Configuration"
        var id: Self { self }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            // The label was rendering as a literal "Tab" beside the control. A segmented
            // picker of tab names does not need to be told it is tabs.
            .labelsHidden()
            .padding(12)

            // Each tab fills the remaining height. Without this the `VStack` sizes itself to
            // whichever tab is showing and centres the lot inside the fixed sheet frame, so a
            // short tab — Logs with no output, most obviously — left a large empty band above
            // the title and below the content.
            Group {
                switch tab {
                case .overview: overview
                case .processes: ProcessesTab(model: model, container: container)
                case .logs: LogsTab(model: model, containerID: container.id)
                case .inspect: InspectTab(model: model, container: container)
                case .configuration: ConfigurationTab(model: model, container: container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // No frame here: the presenting `ModalCard` sizes the sheet. This carried
        // `minWidth/minHeight` back when detail was a resizable window, and leaving it would
        // fight the sheet's fixed frame.
        //
        // The header the title bar used to supply is now `ModalCard`'s, so this view no longer
        // draws a name of its own — see `header`, which keeps only the image reference.
    }

    /// The image reference only. The container's **name** is the modal's title, and printing it
    /// again immediately beneath would be the "Flotilla Flotilla" mistake in miniature.
    private var header: some View {
        HStack {
            Text(container.configuration.image.reference)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

// MARK: - Processes

/// One parsed `ps -o pid,comm,args` row.
private struct ProcessRow: Identifiable {
    let id: Int
    let pid: String
    let command: String
    let arguments: String
}

/// Parses `container exec <id> -- ps -o pid,comm,args` output into rows, or reports that it
/// couldn't so the caller can fall back to the raw text instead of guessing.
///
/// The real output repeats the header word `COMMAND` for both the `comm` and `args`
/// columns:
/// ```
/// PID   COMMAND          COMMAND
///     1 sh               sh -c while true; do i=0; ...
///     5 ps               ps -o pid,comm,args
/// ```
/// Splitting on whitespace is only safe for the first two fields — PID and `comm` never
/// contain spaces — everything after that is `args` verbatim, including its own internal
/// spaces, and must be taken as one remainder rather than tokenized further.
private enum ProcessParse {
    /// `nil` means "couldn't make sense of this" — no header, or a body line that isn't at
    /// least three whitespace-separated fields. An empty (non-nil) array means a real,
    /// recognised header with no process rows under it, which is a different and equally
    /// honest outcome ("no processes"), not a parse failure.
    static func parse(_ raw: String) -> [ProcessRow]? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first, isHeader(header) else { return nil }
        let body = lines.dropFirst()
        guard !body.isEmpty else { return [] }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(body.count)
        for (index, line) in body.enumerated() {
            guard let fields = splitFields(line) else { return nil }
            rows.append(ProcessRow(id: index, pid: fields.pid, command: fields.command, arguments: fields.arguments))
        }
        return rows
    }

    private static func isHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("PID")
    }

    private static func splitFields(_ line: String) -> (pid: String, command: String, arguments: String)? {
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var remainder = Substring(trimmed)
        guard let pidEnd = remainder.firstIndex(where: isSpace) else { return nil }
        let pid = String(remainder[remainder.startIndex..<pidEnd])
        remainder = remainder[pidEnd...].drop(while: isSpace)

        // No third field means a process with a command but no arguments. Return it with
        // empty arguments rather than nil: dropping the row would hide a running process,
        // and a process list that silently omits entries is worse than an ugly one.
        guard let commandEnd = remainder.firstIndex(where: isSpace) else {
            return (pid, String(remainder), "")
        }
        let command = String(remainder[remainder.startIndex..<commandEnd])
        remainder = remainder[commandEnd...].drop(while: isSpace)

        return (pid, command, String(remainder))
    }
}

/// What is actually running inside a running container — `container exec <id> ps -o
/// pid,comm,args`. No `--`: the real CLI takes the separator as the program name and fails,
/// so the allowlist accepts it on input and strips it from the executed argv (see
/// `ContainerCLI.processes(_:)`). No auto-poll: this shells into the container on every
/// call, which is not something to do on a timer without being asked — only the Logs tab's
/// explicit "Follow" toggle earns that, and even that is a fixed-interval fetch, not a
/// stream.
private struct ProcessesTab: View {
    let model: AppModel
    let container: Container

    @State private var rows: [ProcessRow]?
    @State private var rawOutput: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .task {
            guard container.isRunning else { return }
            await load()
        }
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(loading || !container.isRunning)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if !container.isRunning {
            ContentUnavailableView(
                "Not running",
                systemImage: "pause.circle",
                description: Text("Only a running container has processes to list.")
            )
        } else if loading && rows == nil && rawOutput == nil {
            ProgressView("Loading processes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView(
                "Couldn't list processes",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let rows {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No processes",
                    systemImage: "list.bullet",
                    description: Text("The container reported no running processes.")
                )
            } else {
                Table(rows) {
                    TableColumn("PID") { row in
                        Text(row.pid).monospacedDigit()
                    }
                    .width(60)
                    TableColumn("Command") { row in
                        Text(row.command).font(.system(.body, design: .monospaced))
                    }
                    .width(160)
                    TableColumn("Arguments") { row in
                        Text(row.arguments).font(.system(.body, design: .monospaced))
                    }
                }
            }
        } else if let rawOutput {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't parse process output — showing it as text.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                LineListView(lines: Self.rawLines(rawOutput), search: "", wrap: true)
            }
        }
    }

    private static func rawLines(_ text: String) -> [DisplayLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            DisplayLine(id: index, text: String(line), color: .primary)
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let raw = try await model.fetchProcesses(for: container.id)
            if let parsed = ProcessParse.parse(raw) {
                rows = parsed
                rawOutput = nil
            } else {
                rows = nil
                rawOutput = raw
            }
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }
}

// MARK: - Configuration (rendered YAML)

/// A hand-rolled JSON→YAML renderer. `Foundation` has no YAML encoder, and this can't be
/// built or run on this machine to catch a subtle emitter bug before it ships — so every
/// string scalar, key and value alike, is double-quoted and escaped unconditionally rather
/// than emitted plain when it "looks safe."
///
/// That is the deliberate choice the brief calls out explicitly: *valid but ugly* over
/// *pretty but wrong*. A plain-scalar emitter has to get right, all at once, that `no`,
/// `true`, `~`, `0755`, a leading `-`, an embedded `: `, a leading `#`, an empty string, and
/// leading/trailing whitespace all corrupt meaning if left unquoted — one missed case is a
/// silent data-corruption bug in a view whose whole job is to be trustworthy about what the
/// container is configured to do. Double-quoting everything sidesteps all of those cases
/// simultaneously. Its known cost: the output is noisier than a hand-written YAML file, and
/// numeric formatting comes from `NSNumber.stringValue`, which is not guaranteed to
/// reproduce unusual source literals (e.g. a float written in scientific notation) exactly.
///
/// Object keys are sorted so the rendering is stable between refreshes rather than
/// reshuffling with whatever order `JSONSerialization` happens to hand back.
private enum ConfigurationYAML {
    static func render(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return lines(for: root, indent: 0).joined(separator: "\n")
    }

    private static func lines(for value: Any, indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        if let dict = value as? [String: Any] {
            guard !dict.isEmpty else { return ["\(pad){}"] }
            var out: [String] = []
            for (key, v) in dict.sorted(by: { $0.key < $1.key }) {
                appendEntry(prefix: "\(pad)\(quoted(key)):", value: v, indent: indent, into: &out)
            }
            return out
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return ["\(pad)[]"] }
            var out: [String] = []
            for item in array {
                appendEntry(prefix: "\(pad)-", value: item, indent: indent, into: &out)
            }
            return out
        }
        return ["\(pad)\(scalar(value))"]
    }

    /// Appends a `key:` (or `-`) entry, plus whatever follows it: inline for a scalar or an
    /// empty container, or on further-indented lines below for a non-empty nested one — as
    /// `key:` / `-` alone on their own line, which is plain valid YAML and needs no special
    /// handling of where a nested mapping's first field lands relative to its dash.
    private static func appendEntry(prefix: String, value: Any, indent: Int, into out: inout [String]) {
        let childIndent = indent + 1
        if let dict = value as? [String: Any] {
            if dict.isEmpty {
                out.append("\(prefix) {}")
            } else {
                out.append(prefix)
                out.append(contentsOf: lines(for: value, indent: childIndent))
            }
            return
        }
        if let array = value as? [Any] {
            if array.isEmpty {
                out.append("\(prefix) []")
            } else {
                out.append(prefix)
                out.append(contentsOf: lines(for: value, indent: childIndent))
            }
            return
        }
        out.append("\(prefix) \(scalar(value))")
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let number as NSNumber:
            // `JSONSerialization` bridges JSON booleans to `NSNumber` on Apple platforms;
            // `CFGetTypeID` is the standard way to tell an `NSNumber` holding a real `Bool`
            // apart from one holding a numeric value that happens to be 0 or 1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let string as String:
            return quoted(string)
        default:
            return quoted(String(describing: value))
        }
    }

    /// Double-quoted YAML scalar escaping: backslash, double quote, and the common control
    /// characters get named escapes; anything else below `0x20` — a raw newline would
    /// otherwise break a plain scalar, which is exactly the case the brief calls out — gets
    /// a `\xNN` escape so the result stays valid on one logical line.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// Configuration tab: the container's inspect JSON, rendered as YAML by `ConfigurationYAML`.
/// Apple's `container` has no YAML anywhere — no compose file, no YAML config, TOML for
/// system config and JSON per-container — so this is a rendering, not a file on disk, and
/// says so on screen rather than letting the YAML syntax imply otherwise.
private struct ConfigurationTab: View {
    let model: AppModel
    let container: Container

    @State private var yaml: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            Divider()
            controls
            Divider()
            content
        }
        .task { await load() }
    }

    /// Why this view is read-only, stated here so it is not mistaken for unfinished work:
    /// **Apple's `container` has no command that mutates an existing container.** There is no
    /// `container update`, and no pause/resume/set — the lifecycle is create, start, stop,
    /// kill, delete. An editable configuration pane would therefore let someone type changes
    /// that could never be applied, which is worse than not offering the field.
    ///
    /// The real "edit" is to recreate: the review's portability review recommends a `Duplicate…`
    /// action that pre-fills the run sheet from this container's configuration, which is the
    /// honest shape of the same intent. See `research/DOCKER-PORTABILITY.md`.
    private var caption: some View {
        Label(
            "Read-only. Apple's `container` has no YAML config file, and no command to change "
                + "an existing container's settings — to change one, recreate it.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(loading)
            Button {
                copyAll()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(yaml == nil)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if loading && yaml == nil {
            ProgressView("Rendering configuration…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView(
                "Couldn't render configuration",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let yaml {
            LineListView(lines: Self.displayLines(yaml), search: "", wrap: true)
        }
    }

    private static func displayLines(_ text: String) -> [DisplayLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            DisplayLine(id: index, text: String(line), color: .primary)
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let json = try await model.fetchInspectJSON(for: container.id)
            if let rendered = ConfigurationYAML.render(fromJSON: json) {
                yaml = rendered
            } else {
                error = "Couldn't parse the container's configuration JSON."
            }
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }

    private func copyAll() {
        guard let yaml else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(yaml, forType: .string)
    }
}
