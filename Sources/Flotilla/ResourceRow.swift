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
/// **The checkbox is the selection, too** (Kamal, 17 October). It leads the row, before the state
/// mark, and toggles this row in the same `Set` the `List` selects into — so ticking adds a row
/// without clearing the others, ⌘-click and ⌘A tick boxes, and the two can never disagree. A row
/// that cannot be acted on in bulk (a built-in network, This Mac) keeps a disabled box, so the
/// column still lines up, and says why on hover.
///
/// **A labelled container for VoiceOver, never a flattened element.** The row is announced as
/// `summary`, and the controls inside it — the checkbox ("Select web"), the title, the chips'
/// links, the icon buttons and the `⋮` menu — stay in the accessibility tree. That is deliberate:
/// the `⋮` menu is the same builder the right-click menu uses, so VoiceOver is offered exactly what
/// the pointer is, in the same order, with the same disabled items and the same confirmations; and
/// the checkbox is the same toggle the pointer ticks, so a VoiceOver user selects for the bulk bar
/// the same way. This used to be `.accessibilityElement(children: .ignore)` with a hand-written
/// `.accessibilityActions` list in each section, and the five lists drifted from their menus
/// (Hosts lost This Mac's runtime controls, Rename, Connect and Remove Access; Registries lost
/// Browse, Copy and Tags). `Scripts/check-row-accessibility.sh` holds the line.
struct ResourceRow<Leading: View, Chips: View, Metrics: View, Actions: View>: View {
    let title: String
    /// Opens the row's page. `nil` makes the title plain text, for a row that has no page.
    var opens: (() -> Void)?
    var openHelp: String?
    /// The second line. One line, truncating at the tail.
    let detail: String
    var detailHelp: String?
    var selected: Bool
    /// The leading checkbox: this row's membership of the list's selection.
    let check: RowCheck
    /// Extra leading space, for a row nested under another (a group's member).
    var indent: CGFloat = 0
    /// What VoiceOver reads for the whole row.
    let summary: String
    /// Whether the figures column is held open when `metrics` is empty. Containers keep it so the
    /// buttons line up between running and stopped rows; a section that never has figures says
    /// `false` rather than spend 88pt of its minimum width on nothing.
    var reservesMetrics = true
    /// Whether a title with no page (`opens == nil`) is drawn dimmed. A group member that does not
    /// exist yet should look unavailable; a cluster, which simply has no page, should not.
    var dimsPlainTitle = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var chips: Chips
    @ViewBuilder var metrics: Metrics
    @ViewBuilder var actions: Actions

    /// The figures column's width, when `reservesMetrics` holds it open: then it is reserved even
    /// on a row with no figures, so the actions line up down the list instead of stepping sideways
    /// between running and stopped rows. A section that says `reservesMetrics: false` gets no
    /// column at all — its metrics, if any, take their own width, and nothing is reserved.
    ///
    /// Wide enough for "Mem 12.34 GB", and for "CPU 100%" with its sparkline beside it — the
    /// figures are labelled, so they are longer than the bare numbers they replaced.
    static var metricsWidth: CGFloat { 112 }

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Outside the indent, so a group member's box sits in the same column as everyone
            // else's and under the toolbar's select-all.
            RowCheckbox(check: check, name: title)
            content
                .padding(.leading, indent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // The hover wash `MenuRowStyle` uses, and not over a selected row: the accent fill is
        // already the row's highlight, and two layers of it read as a different selection.
        .background(hovering && !selected ? Theme.accent.opacity(0.08) : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    private var content: some View {
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
                    // `summary` already says it.
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if reservesMetrics {
                    metrics
                        .frame(width: Self.metricsWidth, alignment: .trailing)
                } else {
                    metrics
                }
            }
            // The figures are in `summary` too.
            .accessibilityHidden(true)

            actions
                .fixedSize()
                .layoutPriority(3)
        }
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
                .foregroundStyle(dimsPlainTitle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1).truncationMode(.middle)
                .help(openHelp ?? title)
        }
    }
}

/// A small labelled capsule on a row's first line — the kind, a host.
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
///
/// **A sparkline beside the top figure** when the caller has a history — a running container's CPU
/// from `StatsSampler`, the line the Cards view drew before it was scrapped (Q56, 17 October). It
/// sits to the left of "CPU n%", so the figures keep their right edge, and it is decorative to
/// VoiceOver: the figure beside it already says the number.
struct ResourceFigures: View {
    let top: String
    let bottom: String
    var topLabel = "CPU"
    var bottomLabel = "Mem"
    /// Oldest first, `nil` a gap — `Sparkline`'s rules. Empty draws nothing and takes no room.
    var history: [Double?] = []
    var help: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                if history.count > 1 {
                    Sparkline(values: history, maximum: nil)
                        .frame(width: 28, height: 10)
                }
                figure(topLabel, top)
            }
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

/// The leading slot of a two-line row, at Containers' width.
///
/// Containers keeps a 16pt disclosure gutter on every row so a group's caret and a container's
/// dot share one column, which puts its names 32pt in. Every other section uses the same slot,
/// with the mark at the same trailing edge, so a name starts at the same x on every list and
/// switching sections does not move the column your eye is on.
struct RowLeadingMark<Mark: View>: View {
    @ViewBuilder var mark: Mark

    var body: some View {
        mark
            .frame(width: 30, alignment: .trailing)
            .frame(width: 32, alignment: .leading)
    }
}

/// A row's mark for a section with no lifecycle — volumes, networks, images: the section's own
/// sidebar glyph. Not a state (there is none to show), so it is the same on every row and stays
/// quiet in `.tertiary`; it is what gives the two lines a hanging indent.
struct RowKindGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
