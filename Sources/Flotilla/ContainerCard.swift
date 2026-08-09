import SwiftUI
import Foundation
import FlotillaCore

/// One container, as a card — the counterpart to `ContainersView.rowActions` for the card
/// presentation. The owner's feedback on the previous pass was blunt and correct: the card had no
/// action buttons and no usage information at all, just a dot, a name, an image and a host.
/// This is the fix, built to the mockup's row + inspector content: state, name, image, ports,
/// CPU, memory, started/created, and a sparkline.
///
/// Deliberately self-contained: it takes its data and its actions as plain values and
/// closures rather than an `AppModel`, so it can be dropped into a grid, previewed on its
/// own, and so every action still flows through the one model call site wires up.
struct ContainerCard: View {
    let container: Container
    /// `nil` means "not measured yet" — never render this as 0%. A container we have not
    /// sampled is unknown, not idle, and painting a false zero claims a measurement that was
    /// never taken.
    let cpuPercent: Double?
    let memoryBytes: Int64?
    /// Oldest → newest. May be empty or shorter than the sparkline's width.
    let history: [Double?]
    let isBusy: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onDetails: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            portsRow
            metricsRow
            Sparkline(values: history, maximum: nil)
                .frame(height: 28)
            actionCluster
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { onDetails() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                // `stateColor`, not a local `.green`/`.secondary` pair: the table and the
                // cards were each picking their own, so the same container had two greens.
                // It also distinguishes "exited (137)" from "stopped", which one bool cannot.
                .fill(container.stateColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                // The name is the way in, exactly as it is in the table. It was plain text
                // here, so the only route to detail from a card was a `⋯` menu with a single
                // item in it — a second control for something the name should already do.
                Button(action: onDetails) {
                    Text(container.id)
                        .font(.headline)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                // `.link` hardcodes the system blue and ignores the scene tint, so the one
                // brand-coloured thing on the card came out stock-macOS blue.
                .foregroundStyle(Theme.accentText)
                .help("Open \(container.id)")
                Text(ContainerImage.shortReference(container.imageReference))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(container.imageReference)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(container.status.state.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.startedOrCreatedLabel(for: container))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // An em dash, not an absent row: "publishes nothing" and "we couldn't read this" must
    // not look the same, matching the table's Ports column.
    private var portsRow: some View {
        Text(container.portSummary ?? "—")
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(container.portSummary == nil ? .tertiary : .secondary)
            .help(container.portSummary ?? "No published ports")
    }

    private var metricsRow: some View {
        HStack(spacing: 16) {
            metric(label: "CPU", value: Self.cpuLabel(cpuPercent))
            metric(label: "Memory", value: Self.memoryLabel(memoryBytes))
            Spacer()
        }
    }

    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Mirrors `ContainersView.rowActions` deliberately and closely: Start/Stop swap and never
    /// both show, icon buttons are always visible rather than hover-revealed and carry both
    /// `accessibilityLabel` and `help`, and Delete sits last behind a divider, disabled rather
    /// than absent while busy.
    ///
    /// The cluster is left-aligned and tight — play, `⋯`, bin together — rather than throwing
    /// the bin to the far edge with a `Spacer`. The two views should read as the same controls
    /// in a different container, and a trash can floating alone across the card did not.
    private var actionCluster: some View {
        HStack(spacing: 2) {
            if container.isRunning {
                actionButton("stop.fill", "Stop", help: "Stop \(container.id)", action: onStop)
                actionButton("arrow.clockwise", "Restart", help: "Restart \(container.id)", action: onRestart)
            } else {
                actionButton("play.fill", "Start", help: "Start \(container.id)", action: onStart)
                // Holds the cluster's width steady as containers start and stop, so the
                // buttons don't shuffle sideways under the pointer — same trick as the table.
                actionButton("arrow.clockwise", "Restart", help: "", action: {}).hidden()
            }

            // The same overflow menu as the table row, from the same definition. It briefly
            // held only "Details…" here, which is why Copy was missing from cards entirely —
            // the toggle quietly cost you a feature.
            Menu {
                Button("Details…", action: onDetails)
                Divider()
                CopyMenu.forContainer(container)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(container.id)")
            .disabled(isBusy)

            Divider().frame(height: 14)

            actionButton("trash", "Delete", help: "Delete \(container.id)", destructive: true, action: onDelete)

            Spacer()
        }
    }

    private func actionButton(
        _ symbol: String, _ label: String, help: String,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        // The cards must not offer less feedback than the rows — a presentation toggle that
        // changes how responsive the app feels is the same trap as one that changes what you
        // can do. `isBusy` drives the spinner here too.
        IconActionButton(systemImage: symbol, label: label, help: help,
                         busy: isBusy, destructive: destructive, action: action)
    }

    /// "Started 2 days ago" while running, "Created 2 days ago" once stopped — the single
    /// started/created line the card contract asks for. `creationDate` and `startedDate`
    /// are both ISO-8601 *strings* from the CLI, not `Date`, so this parses for display only
    /// and never stores the parsed value.
    private static func startedOrCreatedLabel(for container: Container) -> String {
        if container.isRunning, RelativeDate.parse(container.status.startedDate) != nil {
            return RelativeDate.relative(container.status.startedDate, prefix: "Started")
        }
        return RelativeDate.relative(container.configuration.creationDate, prefix: "Created")
    }

    private static func cpuLabel(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return String(format: "%.0f%%", percent)
    }

    private static func memoryLabel(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
