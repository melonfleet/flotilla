import SwiftUI

/// The two-line list row that replaces the table (Q56), written for Containers first and shaped
/// so Machines, Images, Volumes and Networks can take it with no change here.
///
/// ```
/// ● ▸  web  [Container] [tag] [mac-mini]            2.1%    ■ ▸ ⋮ | 🗑
///      nginx:latest · 8080→80 · 192.168.64.3 (default)  120 MB
/// ```
///
/// A section supplies what is genuinely its own — the state mark, the chips, the second line, the
/// figures and the actions — and this owns the part that must not drift between sections: the
/// metrics, the padding, the hover wash, the truncation rules and the accessibility shape.
///
/// **Height comes from the content.** No row height is written down anywhere: two lines of text
/// and the vertical padding make the row, so a larger text size makes taller rows rather than
/// clipped ones.
///
/// **What truncates, and what never does.** The name has priority over the chips, the chips over
/// the second line; the metrics and the actions never give way. At the window's minimum width the
/// second line is what shortens, so the buttons can never sit on top of text.
///
/// **Selection is the list's own** (the accent fill, ⌘-click, ⇧-click, ⌘A, arrow keys); this only
/// has to know whether it is selected, to swap the link-blue name for `.primary` and to not paint
/// its hover wash over the fill.
///
/// **One element for VoiceOver.** The row reads as `summary` and the actions it carries are
/// exposed as custom actions by whoever places it (`.accessibilityActions`) — the buttons inside
/// are hidden from the accessibility tree, so every one of them must have an action there.
struct ResourceRow<Leading: View, Chips: View, Metrics: View, Actions: View>: View {
    let title: String
    /// Opens the row's page. `nil` makes the title plain text, for a row that has no page.
    var opens: (() -> Void)?
    var openHelp: String?
    /// The second line. One line, truncating at the tail.
    let detail: String
    var detailHelp: String?
    var selected: Bool
    /// Extra leading space, for a row nested under another (a group's member).
    var indent: CGFloat = 0
    /// What VoiceOver reads for the whole row.
    let summary: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var chips: Chips
    @ViewBuilder var metrics: Metrics
    @ViewBuilder var actions: Actions

    /// Reserved even when a row has no figures, so the actions line up down the list instead of
    /// stepping sideways between running and stopped rows.
    ///
    /// Wide enough for "Mem 1.33 GB" — the figures are labelled, so they are longer than the
    /// bare numbers they replaced.
    static var metricsWidth: CGFloat { 88 }

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    name
                        .layoutPriority(2)
                    chips
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detailHelp ?? detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            metrics
                .frame(width: Self.metricsWidth, alignment: .trailing)

            actions
                .fixedSize()
                .layoutPriority(3)
        }
        .padding(.leading, indent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // The hover wash `MenuRowStyle` uses, and not over a selected row: the accent fill is
        // already the row's highlight, and two layers of it read as a different selection.
        .background(hovering && !selected ? Theme.accent.opacity(0.08) : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    @ViewBuilder
    private var name: some View {
        if let opens {
            Button(action: opens) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            // A selected row is filled with the accent, and link blue on that vanishes — see
            // `Theme.rowName`.
            .foregroundStyle(Theme.rowName(selected: selected))
            .help(openHelp ?? "Open \(title)")
        } else {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(openHelp ?? title)
        }
    }
}

/// A small labelled capsule on a row's first line — the kind, a host. The shape `ResourceCard`'s
/// badge has, so a row and a card carry the same chip.
struct ResourceChip: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .chipStyle()
        .fixedSize()
    }
}

extension View {
    /// The capsule behind a chip: caption2, secondary ink, the quaternary fill.
    func chipStyle() -> some View {
        self
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

/// Two small labelled figures stacked in a row's metrics slot — "CPU 11%" over "Mem 1.33 GB" for
/// a container. Monospaced digits so the column does not shimmer as the numbers change, and
/// right-aligned so the figures' right edges line up down the list.
///
/// VoiceOver reads one phrase, "CPU 11 percent, memory 1.33 gigabytes", rather than four
/// fragments.
struct ResourceFigures: View {
    let top: String
    let bottom: String
    var topLabel = "CPU"
    var bottomLabel = "Mem"
    var help: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            figure(topLabel, top)
            figure(bottomLabel, bottom)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(topLabel) \(Self.spoken(top)), \(bottomLabel == "Mem" ? "memory" : bottomLabel) \(Self.spoken(bottom))")
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// "11%" → "11 percent", "1.33 GB" → "1.33 gigabytes".
    static func spoken(_ figure: String) -> String {
        figure
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: " GB", with: " gigabytes")
            .replacingOccurrences(of: " MB", with: " megabytes")
            .replacingOccurrences(of: " KB", with: " kilobytes")
    }
}
