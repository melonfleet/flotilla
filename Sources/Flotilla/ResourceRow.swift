import SwiftUI

/// The two-line list row that replaces the table (Q56), written for Containers first and shaped
/// so every row section takes it with no change here.
///
/// ```
/// ☐ ●  web  [Container] [tag] [mac-mini]                ■ ▸ ⋮ | 🗑
///         nginx:latest · 8080→80 · 192.168.64.3 (default)
/// ```
///
/// Checkbox · state mark · name and chips over the second line · actions. A section supplies what
/// is genuinely its own — the mark, the chips, the second line and the actions — and this owns the
/// part that must not drift between sections: the padding, the hover wash, the truncation rules and
/// the accessibility shape.
///
/// **No live figures** (Q58, 17 October). CPU over memory, with a sparkline, sat between the text
/// and the buttons for a day; Kamal: "keeping the CPU and the memory in the new view is not worth
/// the hassle". A container's page shows them, beside the list, for the one you chose.
///
/// **Height comes from the content.** No row height is written down anywhere: two lines of text
/// and the vertical padding make the row, so a larger text size makes taller rows rather than
/// clipped ones.
///
/// **What truncates, and what never does.** The name has priority over the chips, the chips over
/// the second line; the actions never give way. At the list's minimum width the second line is
/// what shortens, so the buttons can never sit on top of text.
///
/// **Selection is the list's own** (the accent fill, ⌘-click, ⇧-click, ⌘A, arrow keys), and since
/// the split (Q58) **selecting is showing**: a click anywhere on the row, the name included, selects
/// it and its page opens beside the list. The name used to be a link that opened a slide-in page;
/// a link would now take the click away from the selection, so it is plain text. This only has to
/// know whether it is selected, to not paint its hover wash over the fill.
///
/// **The checkbox is the selection, too** (Kamal, 17 October). It leads the row, before the state
/// mark, and toggles this row in the same `Set` the `List` selects into — so ticking adds a row
/// without clearing the others, ⌘-click and ⌘A tick boxes, and the two can never disagree. A row
/// that cannot be acted on in bulk (a built-in network, This Mac) keeps a disabled box, so the
/// column still lines up, and says why on hover.
///
/// **A labelled container for VoiceOver, never a flattened element.** The row is announced as
/// `summary`, and the controls inside it — the checkbox ("Select web"), the chips' links, the icon
/// buttons and the `⋮` menu — stay in the accessibility tree. That is deliberate: the `⋮` menu is
/// the same builder the right-click menu uses, so VoiceOver is offered exactly what the pointer is,
/// in the same order, with the same disabled items and the same confirmations; and the checkbox is
/// the same toggle the pointer ticks, so a VoiceOver user selects for the bulk bar the same way.
/// This used to be `.accessibilityElement(children: .ignore)` with a hand-written
/// `.accessibilityActions` list in each section, and the five lists drifted from their menus
/// (Hosts lost This Mac's runtime controls, Rename, Connect and Remove Access; Registries lost
/// Browse, Copy and Tags). `Scripts/check-row-accessibility.sh` holds the line.
struct ResourceRow<Leading: View, Chips: View, Actions: View>: View {
    let title: String
    /// The name's tooltip, when there is more to say than the name.
    var titleHelp: String?
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
    /// Draws the name dimmed: a group member that does not exist yet should look unavailable.
    var dimsTitle = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var chips: Chips
    @ViewBuilder var actions: Actions

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

            actions
                .fixedSize()
                .layoutPriority(3)
        }
    }

    /// Plain text in `.primary`, which the list turns white on its accent fill by itself.
    private var name: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dimsTitle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1).truncationMode(.middle)
            .help(titleHelp ?? title)
            // `summary` already names the row.
            .accessibilityHidden(true)
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
