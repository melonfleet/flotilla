import SwiftUI
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

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if case .unavailable(let reason) = model.state {
                    runtimeBanner(reason)
                } else if case .failed(let reason) = model.state {
                    runtimeBanner(reason)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    containersTile
                    resourceTile
                    storageTile
                    hostTile
                }
                attentionPanel
                activityPanel
            }
            .padding(14)
        }
        .navigationTitle("")
        .task {
            await model.refresh()
            await loadDiskUsage()
        }
    }

    // MARK: Runtime

    /// Shown above everything when the runtime is unusable, because in that state every number
    /// below is stale and a dashboard full of confident figures would be lying.
    private func runtimeBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("The container runtime is not available").font(.headline)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Retry") { Task { await model.reload() } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Tiles

    private var containersTile: some View {
        tile("Containers", systemImage: "shippingbox", target: .containers) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                bigNumber(model.state == .loaded ? "\(model.running.count)" : "—", "running")
                bigNumber(model.state == .loaded ? "\(model.stopped.count)" : "—", "stopped")
                Spacer()
            }
            if model.state == .loaded {
                // Proportion of a known total, so a plain bar rather than a ProgressView —
                // which styles itself as an operation in progress.
                meter(fraction: model.containers.isEmpty
                      ? 0 : Double(model.running.count) / Double(model.containers.count),
                      tint: Theme.online)
                Text("\(model.containers.count) total on \(model.hostLabel)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var resourceTile: some View {
        tile("Resource use", systemImage: "cpu", target: .containers) {
            let cpus = model.running.compactMap { model.cpuPercent(for: $0.id) }
            let bytes = model.running.compactMap { model.memoryBytes(for: $0.id) }

            row("CPU, all containers",
                cpus.isEmpty ? "—" : String(format: "%.0f%%", cpus.reduce(0, +)))
            row("Memory, all containers",
                bytes.isEmpty ? "—"
                : ByteCountFormatter.string(fromByteCount: bytes.reduce(0, +), countStyle: .file))
            row("Busiest", busiest)

            // Real history only. A flat line at zero reads as a quiet machine rather than an
            // unmeasured one.
            let history = aggregateHistory
            if history.contains(where: { $0 != nil }) {
                Sparkline(values: history, maximum: nil).frame(height: 30).padding(.top, 2)
            }
        }
    }

    private var storageTile: some View {
        tile("Storage", systemImage: "internaldrive", target: .images) {
            if let usage = diskUsage {
                row("Images", byteLabel(usage.images.sizeInBytes))
                row("Containers", byteLabel(usage.containers.sizeInBytes))
                row("Volumes", byteLabel(usage.volumes.sizeInBytes))
                let reclaimable = usage.images.reclaimable + usage.containers.reclaimable
                    + usage.volumes.reclaimable
                // Only offered when there is something to reclaim: a Prune button that would
                // free nothing is a control that does nothing.
                if reclaimable > 0 {
                    Divider().padding(.vertical, 1)
                    HStack {
                        Text("Reclaimable").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(byteLabel(reclaimable))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.warning)
                    }
                }
            } else if let diskFailure {
                Text(diskFailure).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Measuring…").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var hostTile: some View {
        tile("This Mac", systemImage: "laptopcomputer", target: .settings) {
            HStack(spacing: 6) {
                Circle().fill(hostDotColor).frame(width: 7, height: 7)
                Text(hostStateLabel).font(.system(size: 13, weight: .medium))
            }
            row("Host", model.hostName)
            row("Mode", "Client")
            // Says what is true now rather than what is planned, matching the sidebar footer.
            row("Paired hosts", "None · Phase 2")
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

    /// State changes across **every** container, newest first — the same observed-transition
    /// log the detail view shows per container, aggregated. Says plainly that it starts at
    /// launch, because a timeline implying completeness would be a lie of omission.
    private var activityPanel: some View {
        panel("Recent activity", systemImage: "clock") {
            let recent = model.containers
                .flatMap { container in model.events(for: container.id).map { (container.id, $0) } }
                .sorted { $0.1.date > $1.1.date }
                .prefix(8)

            if recent.isEmpty {
                Text("Nothing has changed since Flotilla started. State changes appear here as "
                     + "they happen; history from before launch is not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Circle().fill(entry.1.isFailure ? Theme.danger : Theme.online)
                            .frame(width: 6, height: 6)
                        Text(entry.0).font(.system(size: 12, weight: .medium))
                        Text(entry.1.summary).font(.system(size: 12))
                        Text(entry.1.detail).font(.system(size: 12)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(entry.1.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
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

    private func bigNumber(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 26, weight: .light)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12).monospacedDigit())
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func meter(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Derived

    private var busiest: String {
        let ranked = model.running.compactMap { container -> (String, Double)? in
            guard let cpu = model.cpuPercent(for: container.id) else { return nil }
            return (container.id, cpu)
        }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first else { return "—" }
        return String(format: "%@ · %.0f%%", top.0, top.1)
    }

    /// Summed across containers per sample, so the sparkline shows total load over time rather
    /// than one arbitrary container's. `nil` where nothing was sampled, which `Sparkline`
    /// already renders as a gap rather than a zero.
    private var aggregateHistory: [Double?] {
        let histories = model.running.map { model.cpuHistory(for: $0.id) }
        guard let width = histories.map(\.count).max(), width > 0 else { return [] }
        return (0..<width).map { index in
            let samples = histories.compactMap { history -> Double? in
                guard index < history.count else { return nil }
                return history[index]
            }
            return samples.isEmpty ? nil : samples.reduce(0, +)
        }
    }

    private var hostDotColor: Color {
        switch model.state {
        case .loaded: Theme.online
        case .unavailable, .failed: Theme.danger
        case .idle, .loading: .secondary
        }
    }

    private var hostStateLabel: String {
        switch model.state {
        case .loaded: "Runtime ready"
        case .unavailable, .failed: "Runtime unavailable"
        case .idle, .loading: "Checking…"
        }
    }

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
