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
                .fill(container.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id)
                    .font(.headline)
                    .lineLimit(1)
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

    /// Mirrors `ContainersView.rowActions`: Start/Stop swap and never both show, always
    /// visible rather than hover-revealed, icon buttons carry `accessibilityLabel` and
    /// `help`, and Delete sits last, separated, and disabled (not absent) while busy.
    private var actionCluster: some View {
        HStack(spacing: 4) {
            if container.isRunning {
                actionButton("stop.fill", "Stop", help: "Stop \(container.id)", action: onStop)
                actionButton("arrow.clockwise", "Restart", help: "Restart \(container.id)", action: onRestart)
            } else {
                actionButton("play.fill", "Start", help: "Start \(container.id)", action: onStart)
            }

            Menu {
                Button("Details…", action: onDetails)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(container.id)")
            .disabled(isBusy)

            Spacer()

            Divider().frame(height: 14)

            actionButton("trash", "Delete", help: "Delete \(container.id)", destructive: true, action: onDelete)
        }
    }

    private func actionButton(
        _ symbol: String, _ label: String, help: String,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .disabled(isBusy)
        .help(help)
        .accessibilityLabel(label)
    }

    /// "Started 2 days ago" while running, "Created 2 days ago" once stopped — the single
    /// started/created line the card contract asks for. `creationDate` and `startedDate`
    /// are both ISO-8601 *strings* from the CLI, not `Date`, so this parses for display only
    /// and never stores the parsed value.
    private static func startedOrCreatedLabel(for container: Container) -> String {
        if container.isRunning, let started = container.status.startedDate,
           let date = parseDate(started) {
            return "Started \(date.formatted(.relative(presentation: .named)))"
        }
        if let created = container.configuration.creationDate, let date = parseDate(created) {
            return "Created \(date.formatted(.relative(presentation: .named)))"
        }
        return "—"
    }

    private static func parseDate(_ iso: String) -> Date? {
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return strict.date(from: iso) ?? fractional.date(from: iso)
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
