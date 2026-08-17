import SwiftUI

/// A stacked summary box in the menu-bar popover, which expands on **hover**.
///
/// This replaces a `Menu` per kind, which did not work: a `Menu` reduces its label to a simple
/// title, so the counts, the bar and the graph were all silently dropped and the box rendered as
/// two words. `.menuStyle(.borderlessButton)` also discarded the row padding, which is why the
/// "New…" row sat further left than its neighbours.
///
/// A hover-triggered `popover` gets what a `Menu` could not: the box renders whatever it likes,
/// and it opens by pointing at it — the iStat Menus behaviour the owner asked for. Two delays make
/// that usable rather than twitchy: a short one before opening, so sweeping the pointer across
/// the popover on the way somewhere else does not fire it, and a longer one before closing, so
/// you can travel from the box into the popover without it vanishing under you.
struct MenuKindBox<Items: View>: View {
    let title: String
    let systemImage: String
    let running: Int
    let total: Int
    /// False before the section has ever loaded. Renders an em dash rather than "0 running" —
    /// an unvisited section and an empty one must not look the same.
    let loaded: Bool
    /// One line of real figures. Never invented: see `MenuBarView` for why machines get an
    /// allocation here and containers get measured usage.
    let detail: String
    /// A CPU-percent series, or nil for a kind Flotilla cannot measure.
    var history: [Double?]?

    /// Whether this box is the expanded one. **Owned by the parent**, not here.
    ///
    /// Each box used to keep its own `expanded` flag and its own open/close timers, and the two
    /// fought: opening the containers popover shifted where the pointer counted as being, the
    /// containers box's close timer fired, and the machines box claimed the hover — so pointing
    /// at Containers opened it, closed it, then opened Machines instead. Two independent state
    /// machines racing over one pointer cannot be fixed by tuning their delays. One owner
    /// decides which box is open, and switching is then just a change of value.
    @Binding var expanded: Bool
    /// Reports hover intent upwards; the parent debounces and decides.
    let hoverChanged: (Bool) -> Void

    /// Last, so callers can pass it as a trailing closure.
    @ViewBuilder var items: Items

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if loaded {
                    Text("\(running)/\(total)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Points the way the popover opens, so the affordance and the behaviour agree.
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if loaded {
                HStack(spacing: 8) {
                    pip(running, "running", Theme.online)
                    pip(max(0, total - running), "stopped", .secondary)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }

            if let history, history.contains(where: { $0 != nil }) {
                // The shared `Sparkline`, not a second implementation. It already enforces the
                // rules that matter here — a `nil` is a gap rather than a zero, and a single
                // sample draws nothing instead of implying a trend.
                Sparkline(values: history, maximum: nil)
                    .frame(height: 18)
                    .foregroundStyle(Theme.accent)
            } else {
                // A proportion bar, not a flat line pretending to be a graph.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Theme.online)
                            .frame(width: total > 0
                                   ? CGFloat(running) / CGFloat(total) * geo.size.width : 0)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(boxFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(hovering || expanded ? Theme.accent.opacity(0.55) : Theme.hairline))
        .contentShape(.rect)
        .onHover { inside in
            hovering = inside
            hoverChanged(inside)
        }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeOut(duration: 0.1), value: expanded)
        .popover(isPresented: $expanded, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) { items }
                .padding(.vertical, 6)
                .frame(minWidth: 240)
                // Hovering the popover counts as hovering the box, so travelling into it does
                // not start the close timer.
                .onHover { inside in
                    hovering = inside
                    hoverChanged(inside)
                }
        }
    }

    /// `AnyShapeStyle` because the two branches are different types — a tinted `Color` and the
    /// hierarchical `.quaternary` — and a ternary needs one.
    /// The hover tint was 0.10, which the owner could barely see. 0.24 while pointing and 0.30 while
    /// expanded, so the box that owns the open popover stays visibly the one that owns it.
    private var boxFill: AnyShapeStyle {
        if expanded { return AnyShapeStyle(Theme.accent.opacity(0.30)) }
        if hovering { return AnyShapeStyle(Theme.accent.opacity(0.24)) }
        return AnyShapeStyle(.quaternary.opacity(0.26))
    }

    private func pip(_ value: Int, _ label: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text("\(value) \(label)").font(.system(size: 11)).monospacedDigit()
        }
    }
}
