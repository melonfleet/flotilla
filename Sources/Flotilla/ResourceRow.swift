import SwiftUI

/// The two-line list row that replaces the table (Q56), written for Containers first and shaped
/// so every row section takes it with no change here.
///
/// ```
/// ☐ ▸ 📦• web  [tag] [mac-mini]
///           nginx:latest · 8080→80 · 192.168.64.3 (default)
/// ```
///
/// Checkbox · state mark · name and chips over the second line. A section supplies what is
/// genuinely its own — the mark, the chips, the second line and the actions — and this owns the
/// part that must not drift between sections: the padding, the hover wash, the truncation rules,
/// when the actions show, and the accessibility shape.
///
/// **No live figures** (Q58, 17 October). CPU over memory, with a sparkline, sat between the text
/// and the buttons for a day; Kamal: "keeping the CPU and the memory in the new view is not worth
/// the hassle". A container's page shows them, beside the list, for the one you chose.
///
/// **Height comes from the content.** No row height is written down anywhere: two lines of text
/// and the vertical padding make the row, so a larger text size makes taller rows rather than
/// clipped ones.
///
/// **The name fits first** (Kamal, 17 October, round 2 of the split). At the list's default 340pt
/// the kind chip, the tags and four buttons took the width and the name truncated first — "…",
/// "s…l", a blank name. Now the name is offered the whole line before anything else, and the chips
/// after it are a `ChipLine`, which shows each chip whole or drops it, last first. So the chips
/// give way to the name, and the name truncates (in the middle) only when it alone is wider than
/// the line. The kind chip is gone: the mark says what a row is (`RowTypeMark`).
///
/// **Actions on hover, like Mail** (same decision). A row draws its primary action and `⋮` only
/// while it is hovered or selected, **over** the trailing end of the two lines, which fade out
/// beneath them. Over, not beside: the row's layout does not change when they appear, so nothing
/// moves under the pointer and the name does not re-truncate as you cross it. Delete is not on the
/// row any more — it is in `⋮`, the right-click and the page's header, which has room for every
/// action (`RowActionPlace`). This reverses the table's "always visible, never hover-revealed"
/// rule, and it is safe for the reasons that rule existed:
/// - **Keyboard:** the arrow keys select, and a selected row shows its actions.
/// - **VoiceOver:** while it runs, the actions are always drawn, inline after the text rather than
///   over it, so they are in the tree on every row and nothing is hidden under them. An invisible
///   control is not something to trust to the accessibility tree.
/// - **Nothing is only here:** every action is also in the right-click menu, `⋮` *is* that menu,
///   and the page header beside the list repeats them.
///
/// **Selection is the list's own** (the accent fill, ⌘-click, ⇧-click, ⌘A, arrow keys), and since
/// the split (Q58) **selecting is showing**: a click anywhere on the row, the name included, selects
/// it and its page opens beside the list. The name used to be a link that opened a slide-in page;
/// a link would now take the click away from the selection, so it is plain text.
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
///
/// **The widths, at the default 340pt list** — worked out, since nobody building this can see it.
/// The inset list leaves the row about 320. Out of that: 12 + 12 padding, the checkbox 14 and its
/// 8 gap, the 32pt mark and its 10 gap — 88 — so the two lines get about **232pt**. The name is
/// 13pt medium, about 7pt a character in lowercase, so **33 characters** fit on a row at rest, or
/// up to the first chip that does not. Hovered or selected, the overlay — a 24pt button, 2, a ~20pt
/// `⋮`, and a 14pt fade — covers about 60pt of the end, which leaves **about 24 characters** in
/// view. `build-runner` (12) and `analytics` (9) are whole either way.
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
    /// Each chip a separate view, not one `HStack` of them: `ChipLine` drops them one at a time.
    @ViewBuilder var chips: Chips
    /// The row's primary action and `⋮` — `RowActionPlace.row`. Drawn on hover and selection only.
    @ViewBuilder var actions: Actions

    @State private var hovering = false
    /// The actions' width, so the text fades out exactly where they begin.
    @State private var actionsWidth: CGFloat = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// When the actions are drawn over the row. With VoiceOver they are always drawn, inline.
    private var showsActions: Bool { hovering || selected }

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

            if voiceOver {
                text
                actionSlot
            } else {
                text
                    .mask { fade }
                    .overlay(alignment: .trailing) {
                        actionSlot
                            .opacity(showsActions ? 1 : 0)
                            .allowsHitTesting(showsActions)
                    }
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                name
                    // Offered the whole line first: the chips' minimum is zero, so this takes
                    // its full width whenever it can.
                    .layoutPriority(1)
                ChipLine { chips }
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
    }

    private var actionSlot: some View {
        actions
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
    }

    /// Opaque, then a 14pt fade to clear where the actions begin, while they are showing. The text
    /// is faded rather than painted over, so whatever is behind the row — the accent fill, the
    /// unfocused grey, the hover wash — shows through without this having to know which it is.
    private var fade: some View {
        let hidden = showsActions ? 0.0 : 1.0
        return HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(hidden)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
            Rectangle()
                .opacity(hidden)
                .frame(width: actionsWidth)
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

/// Where a section's actions are being drawn.
///
/// One builder per section serves both, so the page header and the row cannot offer the same
/// action two different ways — but they do not offer the same *number*. The row has room for its
/// primary action and `⋮` (Kamal, 17 October); the header beside the list has room for everything,
/// so it keeps Restart, Tag and the bin.
enum RowActionPlace {
    /// On the row, on hover: the primary action and `⋮`.
    case row
    /// In the page's header: every action, the bin last.
    case header
}

/// The chips after a row's name, each shown whole or not at all.
///
/// An `HStack` would squeeze them — "defa…", "Contai…" — and, worse, a `.fixedSize()` chip in an
/// `HStack` has a minimum as wide as itself, which is what took the name's width at 340pt. This
/// reports a minimum of zero, so the name beside it is offered the line first, and then shows the
/// leading run of chips that fits in what is left: the last chip goes first.
struct ChipLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        DroppingRow(spacing: 4) {
            ForEach(subviews: content) { chip in
                chip
                    // A dropped chip is given no width; clipped, it draws nothing.
                    .frame(minWidth: 0, alignment: .leading)
                    .clipped()
            }
        }
    }
}

/// The layout behind `ChipLine`: its subviews at their ideal widths, left to right, for as long as
/// they fit; the rest at zero width.
struct DroppingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = fitted(proposal.width, subviews)
        let shown = widths.filter { $0 > 0 }
        let height = zip(subviews, widths).filter { $0.1 > 0 }
            .map { $0.0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: shown.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, fitted(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: nil))
            if width > 0 { x += width + spacing }
        }
    }

    /// The ideal width of each subview in the leading run that fits in `available`, and zero for
    /// every one after it — so a chip that does not fit hides the ones after it too, rather than
    /// a shorter one jumping forward into its place. `nil` is "as wide as you like".
    private func fitted(_ available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        var used: CGFloat = 0
        var full = false
        return subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            // Zero height is "nothing to show": `TagPillRow` with no tags is a zero-height
            // `Color.clear`, whose ideal width is a colour's default 10pt rather than zero.
            guard !full, size.width > 0, size.height > 0 else { return 0 }
            let width = size.width
            let next = used + (used > 0 ? spacing : 0) + width
            if let available, next > available + 0.5 { full = true; return 0 }
            used = next
            return width
        }
    }
}

/// A row's mark that says what the row **is** as well as what state it is in: the kind's glyph —
/// the sidebar's, or the detail header's — with the state dot on its lower trailing corner.
///
/// It replaced the "Container" / "Group" text chip (Kamal, 17 October), which cost a row 70pt of its
/// first line to say a word the glyph says in 14. The dot is cut out of the glyph rather than drawn
/// on a ring, so it reads on any background — the accent fill, the hover wash, dark mode — without
/// this having to know which.
struct RowTypeMark<Badge: View>: View {
    let systemImage: String
    /// The kind, for the tooltip: "Group".
    let kind: String
    @ViewBuilder var badge: Badge

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            // The hole the dot sits in: 2pt wider than the dot all round.
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .frame(width: 12, height: 12)
                            .offset(x: 4, y: 4)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                badge
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: 2)
            }
            .help(kind)
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
