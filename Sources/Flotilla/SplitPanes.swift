import SwiftUI

/// The list-left, page-right split every list in the app is drawn in (Q58, 17 October): the nine
/// row sections — Containers, Machines, Images, Volumes, Networks, Hosts, Registries, DNS and
/// Clusters — and the three screens that had it first, Suggestions, the Docker Hub browser and
/// Notifications.
///
/// Kamal: "consider a split view, something similar to the Mail app … the divider can be slid left
/// and right to resize the two panes." One definition, so the twelve cannot drift in width, divider
/// or behaviour.
///
/// **One pane has a width; the other takes the rest.** In a row section that is the list — Mail's
/// message list keeps its width as the window grows, and the page gets the room. The three older
/// screens remember their *detail* pane instead, because their list is a gallery that reflows and
/// their detail is a fixed-measure description; each keeps the 400pt it had. Either way the width
/// is remembered **per screen, across launches**, in `UserDefaults` under `paneWidth.<key>`. It is a
/// window layout, like the sidebar's rail, not a setting an administrator would seed or lock, so it
/// is not in the settings registry.
///
/// **Too narrow for both, the page wins** (row sections only). With the labelled sidebar the
/// window's 700pt minimum leaves the content about 480pt, which cannot hold a 260pt list beside a
/// 360pt page. Rather than raise the minimum — on a 13-inch display the window would then be wider
/// than half the screen — the split folds into one pane: the list while nothing is chosen, the page
/// once something is, with the expand button in the page's header bringing the list back. That is
/// the same button that widens the page in a wide window, so it means one thing everywhere: "the
/// list, or not".
///
/// **Every pane is bounded.** Both are given the whole height and an exact width; neither sizes the
/// window (`CLAUDE.md`, "one unbounded child can scroll the whole window").
struct SplitPanes<Primary: View, Detail: View>: View {
    /// Which pane has the remembered width.
    enum Sizing { case list, detail }

    private let sizing: Sizing
    private let defaultWidth: CGFloat
    private let minPrimary: CGFloat
    private let minDetail: CGFloat
    /// The section's expand and narrow-window state, or nil for a screen with neither.
    private let pane: PaneState?
    /// What the page is showing, or nil when it is an empty state or a selection summary — which
    /// are never widened over the list, since they say nothing without it.
    private let item: AnyHashable?
    private let primary: Primary
    private let detail: Detail

    @AppStorage private var storedWidth: Double
    /// The width while a drag is in progress; written to `storedWidth` when it ends, so a drag is
    /// one write rather than one per frame.
    @State private var dragWidth: CGFloat?
    /// A form inside the page asked for the whole width — Add Service, inside a group's page.
    @State private var formWantsFullWidth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A row section's split: the list on the left at its remembered width, the selected item's
    /// page on the right.
    init(list key: String, pane: PaneState, showing item: AnyHashable?,
         @ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.init(key, sizing: .list, defaultWidth: 340, minPrimary: 260, minDetail: 360,
                  pane: pane, item: item, primary: primary, detail: detail)
    }

    /// Suggestions, the Docker Hub browser and Notifications: a flexible list at least 240 wide and
    /// a detail pane of at least 260, 400 until it is dragged.
    init(_ key: String, sizing: Sizing = .detail, defaultWidth: CGFloat = 400,
         minPrimary: CGFloat = 240, minDetail: CGFloat = 260,
         pane: PaneState? = nil, item: AnyHashable? = nil,
         @ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.sizing = sizing
        self.defaultWidth = defaultWidth
        self.minPrimary = minPrimary
        self.minDetail = minDetail
        self.pane = pane
        self.item = item
        self.primary = primary()
        self.detail = detail()
        _storedWidth = AppStorage(wrappedValue: Double(defaultWidth), "paneWidth.\(key)")
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let layout = arrangement(total)
            HStack(spacing: 0) {
                if layout.showsList {
                    primary
                        .frame(width: layout.listOnly ? total : sizedWidth(total, for: .list))
                        .frame(maxHeight: .infinity)
                }
                if layout.showsList, !layout.listOnly {
                    divider(total)
                }
                if !layout.listOnly {
                    detail
                        .frame(width: layout.full ? total : sizedWidth(total, for: .detail))
                        .frame(maxHeight: .infinity)
                        .environment(\.paneLayout, pane.map { pane in
                            PaneLayout(isFull: layout.full, isCompact: layout.compact) {
                                if layout.compact { pane.compactShowsList = true } else { pane.expanded.toggle() }
                            }
                        })
                }
            }
            .coordinateSpace(.named(Self.space))
            .onPreferenceChange(PaneWantsFullWidth.self) { formWantsFullWidth = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: layout.full)
        }
        // A newly chosen item is shown, in a narrow window, rather than left behind the list.
        .onChange(of: item) { _, chosen in if chosen != nil { pane?.compactShowsList = false } }
    }

    // MARK: Layout

    private struct Arrangement {
        /// Too narrow for both panes.
        var compact: Bool
        /// The page covers the list.
        var full: Bool
        /// Only the list, at the whole width.
        var listOnly: Bool
        var showsList: Bool { !full }
    }

    private func arrangement(_ total: CGFloat) -> Arrangement {
        guard let pane else { return Arrangement(compact: false, full: false, listOnly: false) }
        let compact = total < minPrimary + minDetail + 1
        guard item != nil else {
            // Nothing to widen: the list, beside an empty page if there is room for one.
            return Arrangement(compact: compact, full: false, listOnly: compact)
        }
        if formWantsFullWidth { return Arrangement(compact: compact, full: true, listOnly: false) }
        if compact {
            return pane.compactShowsList
                ? Arrangement(compact: true, full: false, listOnly: true)
                : Arrangement(compact: true, full: true, listOnly: false)
        }
        return Arrangement(compact: false, full: pane.expanded, listOnly: false)
    }

    /// The width of `side` with the window at `total`: the remembered pane's own width, held inside
    /// both minimums, and the other pane's the remainder.
    private func sizedWidth(_ total: CGFloat, for side: Sizing) -> CGFloat {
        let remembered = rememberedWidth(total)
        return side == sizing ? remembered : max(0, total - remembered - 1)
    }

    private func rememberedWidth(_ total: CGFloat) -> CGFloat {
        clamped(dragWidth ?? CGFloat(storedWidth), in: total)
    }

    /// `wanted`, held inside both panes' minimums at a total width of `total`.
    private func clamped(_ wanted: CGFloat, in total: CGFloat) -> CGFloat {
        let (own, other) = sizing == .list ? (minPrimary, minDetail) : (minDetail, minPrimary)
        // The other pane's minimum first: when even that cannot fit, this pane gives way to it.
        return max(min(wanted, total - other - 1), min(own, total))
    }

    // MARK: The divider

    private static var space: String { "SplitPanes" }

    /// The system's hairline, with a 9pt grip centred on it that takes the drag and shows the
    /// column-resize pointer — Mail's divider, which is a line you can grab rather than a bar.
    private func divider(_ total: CGFloat) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { drag in
                                dragWidth = sizing == .list ? drag.location.x : total - drag.location.x
                            }
                            .onEnded { _ in
                                storedWidth = Double(rememberedWidth(total))
                                dragWidth = nil
                            })
            }
            // Over both panes, so the grip's halves are not under the page's first control.
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(sizing == .list ? "List width" : "Detail width")
            .accessibilityValue("\(Int(rememberedWidth(total))) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 24 : -24
                storedWidth = Double(clamped(rememberedWidth(total) + step, in: total))
            }
    }
}

// MARK: - Pane state

/// A row section's expand button and narrow-window state, for the session.
///
/// Held by the section's UI state (`ContainersUIState`, `MachinesUIState`, `ResourceUIState`), which
/// `MainWindowView` owns, so a widened page is still widened after a visit to another section and
/// back. Not persisted: the next launch opens on the split, which is the layout to come back to.
@Observable
final class PaneState {
    /// The expand button: the page widened over the list, to the whole content width.
    var expanded = false
    /// In a window too narrow for both panes, whether the list is showing instead of the page.
    var compactShowsList = false

    /// Brings the page forward where a narrow window had the list over it — a double-click or
    /// Return on the row that is already selected, which changes no selection to do it.
    func reveal() { compactShowsList = false }
}

/// What the page's header needs to draw its expand button.
struct PaneLayout {
    /// The page covers the list — widened, or alone in a narrow window.
    let isFull: Bool
    /// The window is too narrow for both, so the button can only swap them.
    let isCompact: Bool
    let toggle: () -> Void
}

/// Where the page is in its list, and how to step: what the header's ↑ ↓ need. Set by the section
/// on its page, so a form shown there (a registry, a domain, a group) gets the same stepper as a
/// detail page without each form knowing which section it is in.
struct PaneStep {
    /// "container" — used in "Previous container" and "3 of 12 containers".
    let singular: String
    let plural: String
    /// Position in the list as shown, or nil when the page's item is not in it.
    let index: Int?
    let count: Int
    let previous: () -> Void
    let next: () -> Void
}

/// Computed defaults, not stored ones: neither type is `Sendable`, and a stored static would have to be.
private struct PaneLayoutKey: EnvironmentKey { static var defaultValue: PaneLayout? { nil } }
private struct PaneStepKey: EnvironmentKey { static var defaultValue: PaneStep? { nil } }

extension EnvironmentValues {
    /// Set by `SplitPanes` on a row section's page; nil anywhere else, which is how a header knows
    /// it is not in a split and keeps its Back button.
    var paneLayout: PaneLayout? {
        get { self[PaneLayoutKey.self] }
        set { self[PaneLayoutKey.self] = newValue }
    }
    var paneStep: PaneStep? {
        get { self[PaneStepKey.self] }
        set { self[PaneStepKey.self] = newValue }
    }
}

/// A form inside a page that needs the whole width while it is on screen. Add Service, inside a
/// group's page, is the one: it is a form, and forms are full width (Q58).
struct PaneWantsFullWidth: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// Leaves the split: no stepper, no expand button, and Back where a form expects one. For a
    /// form that is opened from inside a page and must not behave as the page itself.
    func outsideSplitPane() -> some View {
        environment(\.paneLayout, nil)
            .environment(\.paneStep, nil)
            .preference(key: PaneWantsFullWidth.self, value: true)
    }
}

// MARK: - The page's other two states

/// The page with nothing chosen — the shape Suggestions and Notifications already use.
struct PaneEmptyState: View {
    /// "Choose a container".
    let title: String
    let systemImage: String
    /// "Its state, logs and settings show here."
    let description: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The page with two or more rows ticked: how many, which, and the bulk bar's actions — the same
/// builder, so the two cannot offer different things. Mail's "3 messages selected".
struct SelectionSummaryPane<Actions: View>: View {
    /// "3 containers selected".
    let title: String
    let systemImage: String
    /// The selected rows' names, in list order.
    let names: [String]
    @ViewBuilder var actions: Actions

    /// Beyond this, "and 12 more": the names say what you selected, not a second copy of the list.
    private let shown = 12

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
            VStack(spacing: 3) {
                ForEach(Array(names.prefix(shown).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if names.count > shown {
                    Text("and \(names.count - shown) more")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            ActionCluster { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
