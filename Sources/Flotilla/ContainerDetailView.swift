import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import FlotillaCore

/// Detail sheet for one container: Overview, Processes, Logs, Terminal, Inspect, Configuration.
///
/// Logs is still a repeated bounded fetch (`cli.logs(id, lines:, bootLog:)`), not a
/// subscription — even "Follow" is that fetch on a timer. Live *streaming* remains Phase 4.
///
/// **Terminal is Phase 4 scope pulled forward deliberately**, at the owner's request and after
/// checking it was possible at all: `container exec` supports `-i/-t` and yields a real PTY.
/// It is gated on `ExecPolicy.interactiveShell`, which the default allowlist does not grant.
struct ContainerDetailView: View {
    let model: AppModel
    let container: Container

    typealias Tab = DetailTab

    @State private var tab: Tab

    /// Seeded from the model so reopening a container returns you to the tab you left it on,
    /// and defaults to Overview the first time you open it this run. See `AppModel.lastDetailTab`.
    init(model: AppModel, container: Container) {
        self.model = model
        self.container = container
        _tab = State(initialValue: model.lastDetailTab[container.id] ?? .overview)
    }


    var body: some View {
        VStack(spacing: 0) {
            tabBar

            // Each tab fills the remaining height. Without this the `VStack` sizes itself to
            // whichever tab is showing and centres the lot inside the fixed sheet frame, so a
            // short tab — Logs with no output, most obviously — left a large empty band above
            // the title and below the content.
            Group {
                switch tab {
                case .overview: overview
                case .processes: ProcessesTab(model: model, container: container)
                case .logs: LogsTab(model: model, containerID: container.id)
                case .terminal: TerminalTab(model: model, container: container)
                case .files: FilesTab(model: model, container: container)
                case .inspect: InspectTab(model: model, container: container)
                case .configuration: ConfigurationTab(model: model, container: container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Remembered for this run only — see `AppModel.lastDetailTab` for why it is not
        // persisted to disk.
        .onChange(of: tab) { _, newTab in model.lastDetailTab[container.id] = newTab }
        // No frame and no header of its own. `ContainersView.detailHeader` supplies the name,
        // state, image, host and uptime above this, so a second header here would repeat them;
        // and now that detail is embedded rather than sheeted, it should take whatever height
        // the window has rather than pin itself to a fixed one.
    }

    /// The mockup's `.tabs` strip, transcribed from `assets/mac.css` rather than eyeballed.
    ///
    /// It replaces a centred segmented `Picker`, which was wrong twice over: no icons, and
    /// centred when the mockup is **left-aligned**. Note this is a different shape from the
    /// Settings strip on purpose — Settings uses chips with the icon stacked above the label,
    /// these are underlined tabs with the icon beside it. Two different jobs, two different
    /// controls, both from the same stylesheet.
    ///
    /// The selected tab is marked by a 2pt accent underline inset 8pt at each end, plus a
    /// heavier weight and full-strength text — three signals, so it does not rely on colour
    /// alone.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { candidate in
                let selected = candidate == tab
                Button { tab = candidate } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.systemImage).font(.system(size: 12))
                        Text(candidate.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(height: 34)
                    .padding(.horizontal, 11)
                    .overlay(alignment: .bottom) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Theme.accent)
                                .frame(height: 2)
                                .padding(.horizontal, 8)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detail sections")
    }

    /// The mockup's overview: a grid of cards rather than one long `Form` of label/value rows.
    ///
    /// The point is that everything is visible at once instead of scrolled through — state,
    /// what it is using, how to reach it, and what it was built from, side by side.
    ///
    /// **What is deliberately absent matters as much as what is here.** The mockup also shows
    /// Network I/O, Block I/O, MAC, MTU, IPv6, working directory, mounts, labels and a Recent
    /// Events timeline. `StatsSampler` measures CPU and memory only, and the container model
    /// carries none of the rest, so every one of those would be a plausible-looking number
    /// with nothing behind it. Fabricated fixtures already cost this project a day; fabricated
    /// *readouts* would be worse, because nothing would ever fail to reveal them. They arrive
    /// when the data does.
    private var overview: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Two fixed columns rather than `.adaptive`, so the four cards are the same
                // width as each other instead of re-flowing to three-up or one-up as the
                // window resizes. `minHeight` then squares them off vertically: without it a
                // card with two rows sat half the height of its neighbour and the grid looked
                // ragged. The cards still grow if their content needs it.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    stateCard
                    resourceCard
                    networkCard
                    imageCard
                }
                // Full width beneath the grid, as in the mockup — a timeline reads badly in a
                // narrow column.
                eventsCard
            }
            .padding(12)
        }
    }

    private var stateCard: some View {
        card("State") {
            HStack(spacing: 6) {
                Circle().fill(container.stateColor).frame(width: 7, height: 7)
                Text(container.status.state.capitalized).font(.system(size: 13, weight: .medium))
            }
            detailRow("Started", RelativeDate.relative(container.status.startedDate, prefix: ""))
            detailRow("Created", RelativeDate.relative(container.configuration.creationDate, prefix: ""))

            // The mockup carries this note and it is true of Apple's runtime, not a limitation
            // of ours: there is no `--restart` and no health check in `container run`, checked
            // against the captured CLI help. Flotilla implements restart policy itself in a
            // later phase, and until it does, saying nothing here would imply the container is
            // being watched when it is not.
            Text("Apple `container` has no native restart policy or health check.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var resourceCard: some View {
        card("Resource use") {
            meter("CPU",
                  value: model.cpuLabel(for: container.id),
                  // Against one core, which is what a per-container percentage means here.
                  fraction: (model.cpuPercent(for: container.id) ?? 0) / 100)
            meter("Memory",
                  value: model.memoryLabel(for: container.id),
                  fraction: memoryFraction)

            if let allocated = container.configuration.resources {
                detailRow("Allocated", Self.allocationLabel(allocated))
            }

            // Real sampled history, or nothing. An empty sparkline drawn flat at zero would
            // read as an idle container rather than an unmeasured one.
            let history = model.cpuHistory(for: container.id)
            if history.contains(where: { $0 != nil }) {
                Sparkline(values: history, maximum: nil).frame(height: 30).padding(.top, 2)
            }
        }
    }

    private var networkCard: some View {
        card("Ports & network") {
            if container.publishedPorts.isEmpty {
                detailRow("Ports", "None published")
            } else {
                ForEach(container.publishedPorts, id: \.self) { port in
                    portRow(port)
                }
            }
            Divider().padding(.vertical, 2)
            detailRow("Network", container.status.networks?.first?.network ?? "—")
            detailRow("Hostname", container.status.networks?.first?.hostname ?? "—")
            detailRow("IPv4", container.ipv4 ?? "—", monospaced: true)
        }
    }

    private var imageCard: some View {
        card("Image") {
            detailRow("Reference", container.configuration.image.reference)
            if let digest = container.configuration.image.descriptor?.digest {
                detailRow("Digest", digest, monospaced: true, truncateMiddle: true)
            }
            if let platform = container.configuration.platform {
                detailRow("Platform", [platform.os, platform.architecture, platform.variant]
                    .compactMap { $0 }.joined(separator: "/"))
            }
            if let size = container.configuration.image.descriptor?.size {
                detailRow("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
    }

    /// One published port, with Copy always and Open only where a browser could plausibly
    /// help.
    ///
    /// the owner clicked Open on a container publishing 8080 and got "empty response". The link was
    /// working correctly — the container was running `sleep` with nothing listening — but the
    /// affordance was overpromising, and the mockup overpromises the same way by offering
    /// "Open in browser" beside Postgres on 5432. **A published port is not necessarily HTTP.**
    ///
    /// So Copy is the primary action, because an address is useful whatever is behind it —
    /// `psql`, `redis-cli`, a browser. Open stays for TCP, since a web server is the common
    /// case and guessing wrong costs one browser tab, but its tooltip now says plainly what it
    /// assumes instead of implying every port answers HTTP.
    @ViewBuilder
    private func portRow(_ port: Container.Configuration.PublishedPort) -> some View {
        let address = "localhost:\(port.hostPort)"
        HStack {
            Text(port.displayText).font(.system(size: 12).monospacedDigit())
            Spacer()
            Button("Copy") { Clipboard.copy(address) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.accentText)
                .help("Copy \(address)")
            // UDP is excluded outright: a browser has nothing to do with it.
            if port.proto?.lowercased() != "udp",
               let url = URL(string: "http://\(address)") {
                Link("Open", destination: url)
                    .font(.caption)
                    // `Link`, like `buttonStyle(.link)`, hardcodes the system blue and ignores
                    // the scene tint.
                    .foregroundStyle(Theme.accentText)
                    .help("Open http://\(address) — assumes this container serves HTTP on "
                          + "port \(port.containerPort). It will not respond if nothing is "
                          + "listening there.")
            }
        }
    }

    /// The mockup's Recent Events, backed by what Flotilla actually watched happen.
    ///
    /// The mockup sources this "from local history (SwiftData)". There is no store, so rather
    /// than fake a history this shows the transitions the poll loop observed **this run**, and
    /// says exactly that. A timeline that starts at app launch but presents itself as complete
    /// would be a lie of omission — the sort this project has already paid for once.
    private var eventsCard: some View {
        card("Recent events") {
            let events = model.events(for: container.id)
            if events.isEmpty {
                Text("Nothing has changed since Flotilla started. State changes appear here as "
                     + "they happen; history from before launch is not recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(events.prefix(8)) { event in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(event.isFailure ? Theme.danger : Theme.online)
                            .frame(width: 6, height: 6)
                        Text(event.summary).font(.system(size: 12, weight: .medium))
                        Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(event.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if events.count > 8 {
                    Text("+ \(events.count - 8) earlier this session")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Card building blocks

    /// The mockup's `.card.pad` with a `.section-title` heading.
    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Squares the grid off. The events card opts out — it is full width and its height
        // follows how much actually happened.
        .frame(minHeight: title == "Recent events" ? 0 : 148, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func detailRow(_ label: String, _ value: String,
                           monospaced: Bool = false, truncateMiddle: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(truncateMiddle ? .middle : .tail)
                .help(value)
        }
    }

    /// A labelled bar. Not a `ProgressView`: this is a level, and the stock indicator styles it
    /// as an operation in progress.
    private func meter(_ label: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 12).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(fraction > 0.85 ? Theme.warning : Theme.online)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .frame(height: 5)
        }
    }

    /// Used over allocated, when both are known. Without an allocation there is no denominator
    /// and the bar stays empty rather than inventing one.
    private var memoryFraction: Double {
        guard let used = model.memoryBytes(for: container.id),
              let limit = container.configuration.resources?.memoryInBytes, limit > 0
        else { return 0 }
        return Double(used) / Double(limit)
    }

    private static func allocationLabel(_ resources: Container.Configuration.Resources) -> String {
        var parts: [String] = []
        if let cpus = resources.cpus { parts.append("\(cpus) CPU\(cpus == 1 ? "" : "s")") }
        if let memory = resources.memoryInBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
/// Inspect tabs, and by `InspectSheet`, so all of them get the same search/highlight/wrap
/// behaviour from one place.
///
/// Internal rather than private for that third caller. `LineListView` below is the reason it has to
/// be: the alternative was a second line type for the volume/network inspector, which is exactly
/// how the container and machine Inspect tabs drifted apart before `InspectTable.swift` pulled the
/// flattening out of here.
struct DisplayLine: Identifiable {
    let id: Int
    let text: String
    let color: Color
}

/// The scrollable, monospaced line list both tabs render into. `.textSelection(.enabled)`
/// on the container is what stands in for a bespoke "copy selection" — native drag-select
/// plus Cmd-C — rather than hand-rolling row selection state; that assumption is called out
/// in the report since it can't be verified without a macOS build.
struct LineListView: View {
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
            return DisplayLine(id: line.id, text: text, color: line.stream == .stderr ? Theme.danger : .primary)
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
    @State private var presentation: InspectPresentation = .json

    /// Narrowed on purpose. The standard set is tuned for a support bundle **leaving the
    /// machine**; this is a panel you read on your own Mac, and applying the strict rules here
    /// rewrote every image digest as `<redacted:fingerprint>` — a digest is 64 hex characters
    /// and so is a certificate fingerprint. A digest is a public content hash and one of the
    /// more useful things in this output, so redacting it removed information and protected
    /// nothing. Mount paths go the same way: they are the point of inspecting.
    ///
    /// Everything that is actually a secret still goes: tokens, certificates, URL credentials
    /// and `KEY=value` secrets.
    private static let redactor = Redactor(excluding: [.fingerprint, .homePath,
                                                       .temporaryPath, .email])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $presentation) {
                    ForEach(InspectPresentation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter keys", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                if !search.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // The mockup shows the command it ran. Worth keeping: it turns an opaque
                // panel into something you can reproduce in a terminal.
                Text("container inspect \(container.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // `IconActionButton` on both detail panels, icon-only. These two tabs disagreed:
                // the machine panel drew Copy JSON icon-only and the container panel drew it with
                // the word, and neither used the shared button, so neither shaded on hover while
                // the toolbar controls above them did. Same control, same tab, two screens.
                IconActionButton(systemImage: "doc.on.doc", label: "Copy JSON",
                                 help: "Copy the inspect output, with secrets redacted",
                                 disabled: json == nil) {
                    // Copies exactly what is displayed — redacted. See `load()`.
                    if let json { Clipboard.copy(json) }
                }

                IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                 help: "Reload", busy: loading) {
                    Task { await load() }
                }
            }
            .padding(12)
            Divider()
            if presentation == .table { tableView } else { content }
            redactionNote
        }
        .task { await load() }
    }

    /// The mockup's Table view. The flattening and the table itself are in
    /// `InspectTable.swift` because the machine Inspect tab needs exactly the same thing —
    /// they used to be private here, which is why that panel shipped JSON-only.
    @ViewBuilder
    private var tableView: some View {
        InspectTableView(json: json, search: search)
    }

    /// Says that what you are reading has been filtered. A redaction the user cannot see is
    /// indistinguishable from a container that had no secrets, and someone debugging a missing
    /// environment variable deserves to know the difference.
    private var redactionNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.caption2)
            Text("Secrets are redacted. Values shown as `<redacted:…>` are present in the "
                 + "container but hidden here and in Copy JSON.")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
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
            // Redacted before it is ever assigned, so nothing unredacted reaches the view, the
            // search index or the clipboard.
            //
            // This is not decoration. `container inspect` includes
            // `configuration.initProcess.environment`, verified against the live CLI — on nginx
            // that is PATH and version strings, on Postgres it is POSTGRES_PASSWORD, and on an
            // application container it is whatever API keys were passed at run time. The panel
            // was rendering all of it in plain text, and the new Copy JSON button would have
            // put it on the clipboard in one click. The mockup shows the same field as
            // `POSTGRES_PASSWORD=••••••`, which is the design telling us this mattered.
            //
            // `Redactor.standard` is the one already trusted for support bundles, so the rules
            // are shared with the surface that has tests behind it rather than reinvented here.
            json = Self.redactor.redact(try await model.fetchInspectJSON(for: container.id))
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

/// Which pane of the container detail is showing.
///
/// Top-level rather than nested in the view because `AppModel` remembers the last one per
/// container, and a model reaching into a view's private nested type would be backwards.
enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case processes = "Processes"
    case logs = "Logs"
    // Between Logs and Inspect, matching the mockup's tab order.
    case terminal = "Terminal"
    // Between Terminal and Inspect, as in the mockup.
    case files = "Files"
    case inspect = "Inspect"
    case configuration = "Configuration"
    var id: Self { self }

    /// The mockup names an icon per tab (`i-info`, `i-doc`, `i-terminal`, `i-braces`).
    /// Processes and Configuration have no counterpart there — that mockup shows Stats and
    /// Files, which the CLI cannot back — so those two are chosen to stay distinguishable
    /// from their neighbours rather than invented to look busy.
    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .processes: "list.bullet.rectangle"
        case .logs: "doc.text"
        case .terminal: "terminal"
        case .files: "folder"
        case .inspect: "curlybraces"
        case .configuration: "doc.plaintext"
        }
    }
}
