import SwiftUI
import Charts
import FlotillaCore

/// The landing screen: everything at a glance, and a way into whatever needs attention.
///
/// Added because the owner saw Orchard's dashboard — the market leader per
/// `research/COMPETITORS.md` — and wanted one. It goes first among the gap work for a
/// deliberate reason: it introduces **no new CLI surface, no allowlist grammar and no
/// security cost**. Every figure here is already fetched for some other screen, so this is
/// presentation rather than capability, and it can ship without touching the wire boundary
/// that Phase 2 depends on.
///
/// The house rule applies throughout: **a figure we have not measured renders as an em dash,
/// never as a zero.** An unsampled container is not an idle one, and a dashboard that reports
/// 0% while something is pinned is worse than one that admits it does not know yet.
struct DashboardView: View {
    let model: AppModel
    /// Set to navigate the sidebar — the panels are drill-downs, not decoration. A tile that
    /// shows you a problem and then cannot take you to it is a poster.
    let go: (Section) -> Void

    @State private var diskUsage: SystemDiskUsage?
    @State private var diskFailure: String?
    @State private var range: Range = .fiveMinutes

    /// The window the charts show. **24h is deliberately absent.** At a 5s poll that is 17,280
    /// points per container, lost on every restart, and it would need downsampling to
    /// per-minute averages to be honest — a different design, not a fourth button. Offering it
    /// now would give a 24h tab that silently showed one hour.
    enum Range: String, CaseIterable, Identifiable {
        case fiveMinutes = "5m", fifteenMinutes = "15m", oneHour = "1h"
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .fiveMinutes: 300
            case .fifteenMinutes: 900
            case .oneHour: 3_600
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if case .unavailable(let reason) = model.state {
                    runtimeBanner(reason)
                } else if case .failed(let reason) = model.state {
                    runtimeBanner(reason)
                }

                hostsStrip
                pressureSection
                resourceRows
                attentionPanel
                utilisationPanel
            }
            .padding(14)
        }
        .navigationTitle("")
        .task {
            await model.refresh()
            await model.refreshMachines()      // the strip counts them; nothing else fetches here
            await loadDiskUsage()
        }
    }

    // MARK: Runtime

    /// Shown above everything when the runtime is unusable, because in that state every number
    /// below is stale and a dashboard full of confident figures would be lying.
    private func runtimeBanner(_ reason: String) -> some View {
        // A stopped service is not a fault, so it must not be dressed as one: warning colour,
        // "not running" wording, and a button that fixes it. The red triangle stays for the
        // states where something really is wrong.
        let stopped: Bool = if case .serviceStopped = model.preflight { true } else { false }
        return HStack(spacing: 10) {
            Image(systemName: stopped ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(stopped ? Theme.warning : Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.startingRuntime
                     ? "Starting the container runtime…"
                     : stopped ? "The container runtime isn't running"
                               : "The container runtime is not available")
                    .font(.headline)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.startingRuntime {
                ProgressView().controlSize(.small)
            } else if stopped {
                // Named for what it does. `container system start` takes several seconds, which
                // is why the spinner above exists rather than a button that looks inert.
                Button("Start") { Task { await model.startRuntime() } }
                    .buttonStyle(.borderedProminent)
            }
            Button("Retry") { Task { await model.reload() } }
                .disabled(model.startingRuntime)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((stopped ? Theme.warning : Theme.danger).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Tiles

    // MARK: Hosts
    //
    // The dashboard leads with *hosts* rather than with a grid of resource cards. That is the
    // one structural thing Flotilla has that a single-machine container GUI does not: it is
    // built to manage a fleet, and the layout should say so from the first row rather than
    // reading as a re-skin of somebody else's panel.

    private var hostsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hosts").font(.headline)

            VStack(spacing: 0) {
                thisMacRow
                Divider().padding(.leading, 34)
                // Not a disabled "add a host" button. A control that drives nothing is the
                // failure this project keeps re-learning, and a greyed row invites a click
                // that cannot succeed. A sentence is honest and costs nothing.
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13)).foregroundStyle(.tertiary).frame(width: 24)
                    Text("Pairing with remote Macs over mTLS arrives in Phase 2.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    /// Identity and reachability, and nothing that another panel already says.
    ///
    /// The first version carried CPU, Memory and Running on the right — all three duplicated
    /// from Pressure and Resources directly below, which made the top of the dashboard read
    /// twice. It also had a chevron that went to Containers while the row itself said
    /// "4 containers · 2 machines": a link that satisfies half its own sentence is worse than
    /// no link, so the row is not a button at all now. Same call as the sidebar's host row,
    /// which is deliberately `selectionDisabled` for the same reason.
    ///
    /// What is left is the thing only this row knows: whether the host is reachable, and what
    /// it is carrying. In Phase 2 that becomes a list, and the per-host split starts earning
    /// its place — Pressure will only ever describe one host at a time.
    private var thisMacRow: some View {
        HStack(spacing: 10) {
            Circle().fill(hostDot).frame(width: 8, height: 8).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.hostLabel).font(.system(size: 13, weight: .medium))
                Text(hostSubtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var hostDot: Color {
        switch model.state {
        case .loaded: Theme.online
        case .unavailable, .failed: Theme.danger
        case .idle, .loading: .secondary
        }
    }

    private var hostSubtitle: String {
        switch model.state {
        case .loaded:
            var parts = ["\(model.running.count) of \(model.containers.count) containers running"]
            if model.machinesState == .loaded {
                let running = model.machines.filter { MachinesView.isRunning($0) }.count
                parts.append("\(running) of \(model.machines.count) machines running")
            }
            return parts.joined(separator: " · ")
        case .unavailable(let reason), .failed(let reason): return reason
        case .idle, .loading: return "Checking the container runtime…"
        }
    }

    // MARK: Resources
    //
    // No "Reclaimable" row. It promised "freed by pruning unused images, volumes and
    // containers" and its chevron went to Images alone — it could only ever deliver a third of
    // its own sentence. The honest options were a real prune-everything screen or nothing, and
    // nothing is right until that screen exists: each section already prunes its own kind.
    //
    // Rows, not a grid of four big cards. The cards gave equal visual weight to four numbers
    // that are mostly reference figures, and they had no room for **Machines** — which the
    // dashboard did not mention at all, despite Machines being a whole section of the app.
    // A row list scales to five entries without any of them shouting.

    private var resourceRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resources").font(.headline)
            VStack(spacing: 0) {
                resourceRow("Containers", systemImage: "shippingbox", target: .containers,
                            detail: model.state == .loaded
                                ? "\(model.running.count) running of \(model.containers.count)" : nil,
                            size: diskUsage.map { byteLabel($0.containers.sizeInBytes) })
                Divider().padding(.leading, 34)
                resourceRow("Images", systemImage: "square.stack.3d.up", target: .images,
                            detail: diskUsage.map { "\($0.images.active) in use of \($0.images.total)" },
                            size: diskUsage.map { byteLabel($0.images.sizeInBytes) })
                Divider().padding(.leading, 34)
                resourceRow("Volumes", systemImage: "cylinder.split.1x2", target: .volumes,
                            detail: diskUsage.map { "\($0.volumes.active) in use of \($0.volumes.total)" },
                            size: diskUsage.map { byteLabel($0.volumes.sizeInBytes) })
                Divider().padding(.leading, 34)
                resourceRow("Machines", systemImage: "server.rack", target: .machines,
                            detail: machinesDetail, size: nil)
            }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var machinesDetail: String? {
        guard model.machinesState == .loaded else { return nil }
        let running = model.machines.filter { MachinesView.isRunning($0) }.count
        return "\(running) running of \(model.machines.count)"
    }

    private func resourceRow(_ title: String, systemImage: String, target: Section,
                             detail: String?, size: String?, tint: Color? = nil) -> some View {
        Button { go(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    // `nil` renders nothing rather than a zero: an unvisited section and an
                    // empty one must not look the same. Same rule as the sidebar counts.
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let size {
                    Text(size)
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(tint ?? .primary)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Stat row

    // MARK: System charts

    /// Four time-series charts with one range selector, as in Orchard's.
    ///
    /// **CPU and memory here are the MACHINE's**, read from the kernel by `HostMetricsSampler`
    /// — not summed container usage. That distinction is the whole point of the labels: host
    /// CPU answers "is my Mac struggling", the utilisation table below answers "which container
    /// is doing it". Network is likewise whole-machine and says so, because it includes the
    /// runtime's own vmnet interfaces.
    /// **One** chart, not a 2×2 grid of four.
    ///
    /// CPU and memory share it because they are both genuinely percentages of the same host, so
    /// one 0–100 axis carries them honestly and you can see the two move against each other —
    /// which is the actual question ("is this Mac under strain?"). Network and disk are
    /// *rates*, in bytes per second: laying them on a percentage axis would be a lie, and giving
    /// each an equal-sized card implies they matter equally. They get compact rate rows beneath
    /// instead, with their own units.
    private var pressureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pressure").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            VStack(spacing: 0) {
                pressureChart
                Divider()
                rateRow("Network", systemImage: "arrow.up.arrow.down",
                        down: model.hostMetrics.latest?.networkRxBytesPerSecond,
                        up: model.hostMetrics.latest?.networkTxBytesPerSecond,
                        note: "whole machine, includes the runtime's own interfaces")
                Divider()
                // Whole-machine disk, from IOKit's `IOBlockStorageDriver` counters — the row the
                // caption below used to promise. It sits above the container row for the same
                // reason Network does: this panel reads top-down from the machine to the
                // containers, and the host figure is the one that answers "is the disk busy".
                rateRow("Disk", systemImage: "internaldrive",
                        down: model.hostMetrics.latest?.diskReadBytesPerSecond,
                        up: model.hostMetrics.latest?.diskWriteBytesPerSecond,
                        downLabel: "R", upLabel: "W",
                        note: "whole machine, includes the runtime's own disk images")
                Divider()
                rateRow("Container disk", systemImage: "shippingbox",
                        down: aggregatedContainerPoints.last?.read,
                        up: aggregatedContainerPoints.last?.write,
                        downLabel: "R", upLabel: "W",
                        // Two honest cautions rather than the old "not yet built" note. Buffered
                        // writes inside a guest do not reach its block layer until they are
                        // flushed, so a container can be writing hard and still read 0 here —
                        // measured: a `dd` of 300 MB moved the counter only once `sync` ran.
                        note: "containers only, and only once the guest flushes to its block device")
            }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var pressureChart: some View {
        let samples = hostSamples
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legendDot(Theme.rind, "CPU",
                          model.hostMetrics.latest?.cpuPercent.map { String(format: "%.0f%%", $0) })
                legendDot(Theme.accent, "Memory", memoryPercentLabel)
                Spacer()
                Text("\(ProcessInfo.processInfo.processorCount) cores · \(model.hostLabel)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            // One flattened array with an explicit series name, not two `ForEach`es each
            // setting a flat `foregroundStyle`. Swift Charts derives series identity from the
            // plottable data, so two loops over the same x-values with no series dimension are
            // liable to be joined into a single path — the legend would say two lines and the
            // plot would draw one.
            Chart(pressurePoints, id: \.id) { point in
                LineMark(x: .value("Time", point.date),
                         y: .value("Percent", point.percent),
                         series: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["CPU": Theme.rind, "Memory": Theme.accent])
            .chartLegend(.hidden)      // the header row above already names both, with values
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
            .frame(height: 150)
        }
        .padding(12)
    }

    /// Both series in one array. `id` is the pair, so two points sharing a timestamp stay
    /// distinct rows rather than colliding.
    private struct PressurePoint: Identifiable {
        let id: String
        let date: Date
        let percent: Double
        let series: String
    }

    private var pressurePoints: [PressurePoint] {
        var points: [PressurePoint] = []
        for sample in hostSamples {
            if let cpu = sample.cpuPercent {
                points.append(PressurePoint(id: "cpu-\(sample.date.timeIntervalSince1970)",
                                            date: sample.date, percent: cpu, series: "CPU"))
            }
            if sample.memoryTotalBytes > 0 {
                let percent = Double(sample.memoryUsedBytes)
                    / Double(sample.memoryTotalBytes) * 100
                points.append(PressurePoint(id: "mem-\(sample.date.timeIntervalSince1970)",
                                            date: sample.date, percent: percent, series: "Memory"))
            }
        }
        return points
    }

    private var memoryPercentLabel: String? {
        guard let latest = model.hostMetrics.latest, latest.memoryTotalBytes > 0 else { return nil }
        return String(format: "%.0f%%",
                      Double(latest.memoryUsedBytes) / Double(latest.memoryTotalBytes) * 100)
    }

    private func legendDot(_ colour: Color, _ label: String, _ value: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    private func rateRow(_ title: String, systemImage: String,
                         down: Double?, up: Double?,
                         downLabel: String = "↓", upLabel: String = "↑",
                         note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(note).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(downLabel) \(rateLabel(down))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.info)
            Text("\(upLabel) \(rateLabel(up))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.accentText)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var hostSamples: [HostMetricsSampler.Sample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return model.hostMetrics.history.filter { $0.date >= cutoff }
    }

    /// Container rates summed per timestamp. Points where nothing was measurable are dropped
    /// rather than zeroed — the chart then shows a gap, which is the truth.
    private var aggregatedContainerPoints: [(date: Date, read: Double?, write: Double?)] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        var byDate: [Date: (read: Double, write: Double, count: Int)] = [:]
        for container in model.containers {
            for point in model.statsHistory(for: container.id) where point.date >= cutoff {
                guard let read = point.blockReadBytesPerSecond,
                      let write = point.blockWriteBytesPerSecond else { continue }
                var entry = byDate[point.date] ?? (0, 0, 0)
                entry.read += read
                entry.write += write
                entry.count += 1
                byDate[point.date] = entry
            }
        }
        return byDate.keys.sorted().map { (date: $0, read: byDate[$0]?.read, write: byDate[$0]?.write) }
    }

    private func rateLabel(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return String(format: "%.1f KB/s", bytesPerSecond / 1024)
    }

    // MARK: Utilisation

    /// The per-container table from Orchard's dashboard. Every column is backed by a field
    /// `ContainerStats` was already decoding and `StatsSampler` was throwing away.
    private var utilisationPanel: some View {
        panel("Container utilisation", systemImage: "chart.bar") {
            if model.running.isEmpty {
                Text("No running containers.").font(.caption).foregroundStyle(.secondary)
            } else {
                SwiftUI.Table(model.running) {
                    TableColumn("Container") { container in
                        Button(container.id) { go(.containers) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accentText)
                    }
                    TableColumn("CPU") { container in
                        Text(model.cpuLabel(for: container.id)).monospacedDigit()
                    }
                    TableColumn("Memory") { container in
                        let point = model.statsHistory(for: container.id).last
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.memoryLabel(for: container.id)).monospacedDigit()
                            if let used = point?.memoryUsageBytes,
                               let limit = point?.memoryLimitBytes, limit > 0 {
                                Text(String(format: "%.1f%%", Double(used) / Double(limit) * 100))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    TableColumn("Network I/O") { container in
                        let point = model.statsHistory(for: container.id).last
                        VStack(alignment: .leading, spacing: 1) {
                            Text("↓ " + rateLabel(point?.networkRxBytesPerSecond))
                                .font(.caption).monospacedDigit()
                            Text("↑ " + rateLabel(point?.networkTxBytesPerSecond))
                                .font(.caption).monospacedDigit()
                        }
                    }
                    TableColumn("Block I/O") { container in
                        let point = model.statsHistory(for: container.id).last
                        VStack(alignment: .leading, spacing: 1) {
                            Text("R " + rateLabel(point?.blockReadBytesPerSecond))
                                .font(.caption).monospacedDigit()
                            Text("W " + rateLabel(point?.blockWriteBytesPerSecond))
                                .font(.caption).monospacedDigit()
                        }
                    }
                    TableColumn("PIDs") { container in
                        // `numProcesses`, decoded since day one and never shown until now.
                        Text(model.statsHistory(for: container.id).last?.processCount
                                .map(String.init) ?? "—")
                            .monospacedDigit()
                    }
                }
                .frame(minHeight: 160)
            }
        }
    }

    // MARK: Panels

    /// Containers that need a human. Absent entirely when nothing is wrong — an always-present
    /// "0 problems" panel trains you to stop reading it.
    @ViewBuilder
    private var attentionPanel: some View {
        let troubled = model.containers.filter(Self.needsAttention)
        if !troubled.isEmpty {
            panel("Needs attention", systemImage: "exclamationmark.triangle") {
                ForEach(troubled) { container in
                    HStack(spacing: 8) {
                        Circle().fill(container.stateColor).frame(width: 7, height: 7)
                        Text(container.id).font(.system(size: 12, weight: .medium))
                        Text(container.status.state.lowercased())
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { go(.containers) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Theme.accentText)
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    /// A tile is a card that is also a link. `target` is where it drills down to, so every
    /// number on this screen leads somewhere.
    private func tile<Content: View>(_ title: String, systemImage: String, target: Section,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button { go(target) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).font(.system(size: 11))
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
                content()
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }

    private func panel<Content: View>(_ title: String, systemImage: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).kerning(0.5)
            }
            .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12).monospacedDigit())
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Derived

    /// Same rule as the menu-bar popover: failure, not idleness. `exited (0)` finished; a clean
    /// stop is not a problem and must not cry wolf.
    private static func needsAttention(_ container: Container) -> Bool {
        let state = container.status.state.lowercased()
        if state.contains("restart") || state.contains("dead") || state.contains("fail") {
            return true
        }
        guard state.contains("exit") else { return false }
        return !state.contains("(0)") && !state.contains(" 0")
    }

    private func loadDiskUsage() async {
        do {
            diskUsage = try await model.fetchSystemDiskUsage()
            diskFailure = nil
        } catch {
            diskUsage = nil
            diskFailure = "Could not measure disk usage: \(error)"
        }
    }
}
