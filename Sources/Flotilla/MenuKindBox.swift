import SwiftUI

/// A stacked summary box in the menu-bar popover, which expands **in place** on hover.
///
/// Third design, and the reason for it matters. A `Menu` per kind reduced its label to a plain
/// title, so the counts and graph were silently dropped. A `.popover` per kind rendered properly
/// but could not work either: **macOS presents one popover per window**, so once the containers
/// popover had been presented the machines one silently failed to appear — which is why Machines
/// "still does nothing" after two attempts at fixing the hover logic. The hover arbitration was
/// not the fault the second time; the second popover was never going to open.
///
/// Expanding inline dissolves that whole class of problem: no second window to present, no
/// positioning to get wrong, and no beak — which the owner had separately asked to remove. The cost
/// is that the list is not detached, so the popover grows downwards instead of spilling
/// sideways. If a true pop-out is wanted later it needs a hand-positioned `NSPanel`, which also
/// means re-implementing click-outside-to-dismiss and screen-edge flipping.
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
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded {
                Divider().padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) { items }
                    .padding(.top, 4)
                    .transition(.opacity)
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
        .animation(.easeOut(duration: 0.12), value: expanded)
    }

    private var summary: some View {
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
                // Points down when open, right when closed — a disclosure, because that is now
                // what it is.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(expanded ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.tertiary))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
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

            // **One fixed height whichever is drawn.**
            //
            // The sparkline appeared only once a sample had arrived, and the bar is 4pt against
            // its 18pt — so the box grew the first time it had data, which happened to coincide
            // with the first hover and read as the box resizing when pointed at. Reserving the
            // height means the content can change without the layout moving.
            ZStack {
                if let history, history.contains(where: { $0 != nil }) {
                    // The shared `Sparkline`, not a second implementation. It already enforces
                    // the rules that matter here — a `nil` is a gap rather than a zero, and a
                    // single sample draws nothing instead of implying a trend.
                    Sparkline(values: history, maximum: nil)
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
            .frame(height: 18)
        }
        // **Content only.** No padding, no fill, no border and above all NO `.onHover` — the
        // enclosing `body` owns all of that.
        //
        // A second `.onHover` here is what made the expanded box unusable. The summary is only
        // the *top* of the box, so moving the pointer down into the rows leaves the summary's
        // hit region and fired `hoverChanged(false)` for this kind. The parent keys its state on
        // the kind, not on which subview reported, so that one event emptied `hoverOrder` and
        // started the close timer — the box collapsed exactly as the pointer arrived at the
        // Start/Stop buttons, which is why the menu could not be used to control anything.
        //
        // The chrome was duplicated too, so the box was drawing its fill and border twice.
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
