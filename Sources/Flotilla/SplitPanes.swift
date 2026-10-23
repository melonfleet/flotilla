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
/// their detail is a fixed-measure description. Every split starts with the divider in the centre
/// (Kamal, 17 October) until it is dragged; after that the width
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
/// **Hiding the page asks, like leaving it** (Kyle, 17 October). In the folded split the list
/// replaces the page rather than sitting beside it, so the page — a registry's, a domain's or a
/// group's form among them — leaves the hierarchy and its state with it. "Show the list" therefore
/// goes through `FormGuard.confirmLeaving` and Keep Editing stays on the page. Keeping the page
/// alive behind the list was the alternative, and is worse: a hidden form still owns Return and
/// Escape (`.defaultAction`, `.cancelAction`) and can still hold keyboard focus, so typing or
/// pressing Return in the list would act on a form nobody can see. For the same reason a window
/// widened out of the fold forgets that the list was showing, so narrowing it again shows the page —
/// the rule for a narrow window — rather than hiding a page that may have been edited meanwhile.
///
/// **Two panes, or list only** (Kamal, 18 October). Each screen remembers, under `paneMode.<key>`
/// beside its `paneWidth.<key>`, whether it is the split above or just the rows. In list only the
/// list takes the whole width and a chosen row's page **slides in over the list's trailing edge**,
/// exactly where it would sit in the split — the remembered divider, the same width — rather than
/// beside the list. Over, because beside would squeeze the list and reflow every row to a narrower
/// layout the moment you clicked one, so the row you clicked would move under the pointer; over, the
/// rows stay where they are and the page covers only what it needs. The page's ✕ and Esc close it
/// and clear the selection, through the same form guard as choosing another row. Two or more ticked
/// rows open no page (there is no one page to show): the bulk bar is the way to act on them.
/// Both are one view in the tree whichever mode is on, so changing mode never rebuilds a page and
/// its unsaved form.
///
/// **Every pane is bounded.** Both are given the whole height and an exact width; neither sizes the
/// window (`CLAUDE.md`, "one unbounded child can scroll the whole window").
struct SplitPanes<Primary: View, Detail: View>: View {
    /// Which pane has the remembered width.
    enum Sizing { case list, detail }

    private let sizing: Sizing
    private let minPrimary: CGFloat
    private let minDetail: CGFloat
    /// The section's expand and narrow-window state, or nil for a screen with neither.
    private let pane: PaneState?
    /// What the page is showing, or nil when it is an empty state or a selection summary — which
    /// are never widened over the list, since they say nothing without it.
    private let item: AnyHashable?
    private let primary: Primary
    private let detail: Detail
    private let screen: String
    /// Clears the screen's selection, for screens that do not use `paneFollows` (which supplies it).
    private let clearing: (() -> Void)?

    @AppStorage private var storedWidth: Double
    @AppStorage private var storedMode: String
    /// The width while a drag is in progress; written to `storedWidth` when it ends, so a drag is
    /// one write rather than one per frame.
    @State private var dragWidth: CGFloat?
    /// A form inside the page asked for the whole width — Add Service, inside a group's page.
    @State private var formWantsFullWidth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Optional, like everywhere else: a split drawn outside the main window has no guard to ask.
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    @Environment(\.paneClearSelection) private var inheritedClear
    @Environment(\.themeChoice) private var themes

    /// A row section's split: the list on the left at its remembered width, the selected item's
    /// page on the right.
    init(list key: String, pane: PaneState, showing item: AnyHashable?,
         clearing: (() -> Void)? = nil,
         @ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.init(key, sizing: .list, minPrimary: 260, minDetail: 360,
                  pane: pane, item: item, clearing: clearing, primary: primary, detail: detail)
    }

    /// Suggestions, the Docker Hub browser and Notifications: a flexible list at least 240 wide and
    /// a detail pane of at least 260, split in the centre until it is dragged.
    init(_ key: String, sizing: Sizing = .detail,
         minPrimary: CGFloat = 240, minDetail: CGFloat = 260,
         pane: PaneState? = nil, item: AnyHashable? = nil, clearing: (() -> Void)? = nil,
         @ViewBuilder primary: () -> Primary, @ViewBuilder detail: () -> Detail) {
        self.sizing = sizing
        self.minPrimary = minPrimary
        self.minDetail = minDetail
        self.pane = pane
        self.item = item
        self.screen = key
        self.clearing = clearing
        self.primary = primary()
        self.detail = detail()
        // 0 means "never dragged": the divider then sits in the centre (Kamal, 17 October), so
        // neither pane starts squeezed. Once dragged, the width is remembered for this screen.
        _storedWidth = AppStorage(wrappedValue: 0, "paneWidth.\(key)")
        _storedMode = AppStorage(wrappedValue: PaneMode.standard(for: key).rawValue, PaneMode.defaultsKey(key))
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let layout = arrangement(total)
            let closing = closeAction(layout)
            // One tree for both modes: the list at the left, the page (and its divider) at the
            // trailing edge. In the split their widths add up to the whole, so they only meet; in
            // list only the list is the whole width and the page lies over its end.
            ZStack(alignment: .trailing) {
                if layout.showsList {
                    primary
                        .frame(width: layout.listFillsWidth ? total : sizedWidth(total, for: .list))
                        .frame(maxHeight: .infinity)
                        .frame(width: total, alignment: .leading)
                        // A row section's page is beside the list unless the window is too narrow
                        // for both or the list is on its own, and that page is where a selection of
                        // several is acted on.
                        .environment(\.pageBesideList, pane != nil && !layout.listOnly && !layout.overlay)
                        .environment(\.paneModeControl, PaneModeControl(mode: mode, toggle: toggleMode))
                }
                if !layout.listOnly {
                    HStack(spacing: 0) {
                        if layout.showsList { divider(total) }
                        page(layout, total: total, close: closing)
                    }
                    .background {
                        // Opaque, and the window's own ground: the rows must not show through.
                        if layout.overlay { Theme.contentBackground(themes, opaque: true) }
                    }
                    .shadow(color: .black.opacity(layout.overlay ? 0.14 : 0), radius: 8, x: -2)
                    .transition(.move(edge: .trailing))
                }
            }
            .coordinateSpace(.named(Self.space))
            .onPreferenceChange(PaneWantsFullWidth.self) { formWantsFullWidth = $0 }
            // Out of the fold, the list is beside the page again; back into it, the page wins.
            .onChange(of: layout.compact) { _, compact in if !compact { pane?.compactShowsList = false } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: layout.full)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: layout.overlay)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: layout.listOnly)
            // Esc closes an open page in list only. `.onKeyPress` and `.onExitCommand` cannot do it:
            // both need SwiftUI focus inside this view, and the list's rows are an AppKit table that
            // keeps first responder, so Esc never reached them. See `EscapeCloser`.
            .background { if layout.overlay, let closing { EscapeCloser(close: closing) } }
            .focusedSceneValue(\.paneModeCommand, PaneModeCommand(mode: mode, toggle: toggleMode))
        }
        // A newly chosen item is shown, in a narrow window, rather than left behind the list.
        .onChange(of: item) { _, chosen in
            if chosen != nil { pane?.compactShowsList = false }
            // A closed page forgets that it was widened: the next one opens at the divider.
            else if mode == .listOnly { pane?.expanded = false }
        }
    }

    /// The page, with a close bar of its own where its header has no stepper to carry the ✕ — the
    /// screens that are not row sections.
    @ViewBuilder
    private func page(_ layout: Arrangement, total: CGFloat, close: (() -> Void)?) -> some View {
        let width = layout.full ? total : sizedWidth(total, for: .detail)
        VStack(spacing: 0) {
            if pane == nil, let close {
                HStack {
                    Spacer(minLength: 0)
                    ActionCluster {
                        IconActionButton(systemImage: "xmark", label: "Close", help: "Close (Esc)", action: close)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .environment(\.paneLayout, pane.map { pane in
            PaneLayout(isFull: layout.full, isCompact: layout.compact, close: close) {
                guard layout.compact else { return pane.expanded.toggle() }
                // Hides the page, and any form on it with its draft: ask first.
                let showList = { pane.compactShowsList = true }
                if let formGuard { formGuard.confirmLeaving(showList) } else { showList() }
            }
        })
    }

    // MARK: Mode

    private var mode: PaneMode { PaneMode(rawValue: storedMode) ?? .standard(for: screen) }

    private func toggleMode() {
        storedMode = (mode == .listOnly ? PaneMode.twoPanes : .listOnly).rawValue
    }

    /// Closes the open page, in list only, or nil when there is nothing to close. Clearing the
    /// selection is the close: the page follows the selection through the form guard
    /// (`paneFollows`), which asks about a dirty form and, on Keep Editing, puts the selection back.
    private func closeAction(_ layout: Arrangement) -> (() -> Void)? {
        guard mode == .listOnly, item != nil, let clear = clearing ?? inheritedClear else { return nil }
        return clear
    }

    // MARK: Layout

    private struct Arrangement {
        /// Too narrow for both panes.
        var compact: Bool
        /// The page covers the list.
        var full: Bool
        /// Only the list, at the whole width, and no page.
        var listOnly: Bool
        /// List only with a page open: the page lies over the list's trailing edge.
        var overlay = false
        var showsList: Bool { !full }
        var listFillsWidth: Bool { listOnly || overlay }
    }

    private func arrangement(_ total: CGFloat) -> Arrangement {
        let listMode = mode == .listOnly
        guard let pane else {
            // A screen with no narrow-window fold: the split, or the rows with a page over them.
            return Arrangement(compact: false, full: false, listOnly: listMode && item == nil,
                               overlay: listMode && item != nil)
        }
        let compact = total < minPrimary + minDetail + 1
        guard item != nil else {
            // Nothing to widen: the list, beside an empty page if there is room for one.
            return Arrangement(compact: compact, full: false, listOnly: compact || listMode)
        }
        if formWantsFullWidth { return Arrangement(compact: compact, full: true, listOnly: false) }
        if compact {
            return pane.compactShowsList
                ? Arrangement(compact: true, full: false, listOnly: true)
                : Arrangement(compact: true, full: true, listOnly: false)
        }
        return Arrangement(compact: false, full: pane.expanded, listOnly: false,
                           overlay: listMode && !pane.expanded)
    }

    /// The width of `side` with the window at `total`: the remembered pane's own width, held inside
    /// both minimums, and the other pane's the remainder.
    private func sizedWidth(_ total: CGFloat, for side: Sizing) -> CGFloat {
        let remembered = rememberedWidth(total)
        return side == sizing ? remembered : max(0, total - remembered - 1)
    }

    private func rememberedWidth(_ total: CGFloat) -> CGFloat {
        let wanted = dragWidth ?? (storedWidth > 0 ? CGFloat(storedWidth) : (total - 1) / 2)
        return clamped(wanted, in: total)
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

// MARK: - Esc

/// Closes the overlaid page on Esc while the list has focus. A local monitor, installed only while
/// it is in the tree (the page lies over the list), because the list's `NSTableView` is first
/// responder and SwiftUI's key handlers on an ancestor never see its keys.
///
/// It yields to anything that owns Esc. Focus anywhere but the list (the window bar's search box, a
/// field or button in the page) is left alone. With the list focused, the window gets the key
/// equivalent first, so a form's Cancel (`.cancelAction`) still fires and only an Esc nothing claims
/// closes the page.
private struct EscapeCloser: NSViewRepresentable {
    let close: () -> Void

    @MainActor final class Coordinator {
        var close: () -> Void = {}
        var monitor: Any?
        weak var view: NSView?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      event.keyCode == 53,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      Self.listHasFocus(window) else { return event }
                if window.performKeyEquivalent(with: event) { return nil }
                self.close()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The list, or nothing in particular, is first responder.
        private static func listHasFocus(_ window: NSWindow) -> Bool {
            guard let responder = window.firstResponder, responder !== window else { return true }
            var view = responder as? NSView
            while let current = view {
                if current is NSTableView { return true }
                view = current.superview
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.close = close
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.close = close }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
}

// MARK: - Layout mode

/// Whether a screen is the split or just its rows. Remembered per screen across launches under
/// `paneMode.<key>`, beside `paneWidth.<key>`: window layout, not a setting, so it is not in the
/// registry.
enum PaneMode: String {
    case twoPanes, listOnly

    /// Logs and Activity are long feeds read top to bottom, not things you pick one of: they open on
    /// the rows. They become row lists in the next job and are given their key now.
    static let listOnlyByDefault: Set<String> = ["logs", "activity"]

    static func standard(for screen: String) -> PaneMode {
        listOnlyByDefault.contains(screen) ? .listOnly : .twoPanes
    }

    static func defaultsKey(_ screen: String) -> String { "paneMode.\(screen)" }
}

/// The mode and the flip, for the toolbar's button.
struct PaneModeControl {
    let mode: PaneMode
    let toggle: () -> Void
}

/// The same, for the View menu: published by the split on screen as a focused scene value, so the
/// item is disabled wherever there is no split.
struct PaneModeCommand {
    let mode: PaneMode
    let toggle: () -> Void
}

struct PaneModeCommandKey: FocusedValueKey { typealias Value = PaneModeCommand }

extension FocusedValues {
    var paneModeCommand: PaneModeCommand? {
        get { self[PaneModeCommandKey.self] }
        set { self[PaneModeCommandKey.self] = newValue }
    }
}

/// The toggle at the left of a list's toolbar, before select-all. Draws nothing outside a split.
///
/// Its glyph is the layout a click **switches to**, as the expand button's is: `rectangle` while the
/// split is showing (go to the rows alone) and `rectangle.split.2x1` while the rows are alone.
/// The two layouts side by side, the current one lit, like Finder's view buttons (Kamal, 23 October).
/// It replaced one button whose glyph was the layout you'd switch *to*: a bare square by default,
/// which read as an empty checkbox beside the real one.
struct PaneModeButton: View {
    @Environment(\.paneModeControl) private var control

    var body: some View {
        if let control {
            ActionCluster {
                segment(.listOnly, systemImage: "line.3.horizontal", label: "Show List Only", control)
                segment(.twoPanes, systemImage: "rectangle.split.2x1", label: "Show Two Panes", control)
            }
        }
    }

    private func segment(_ mode: PaneMode, systemImage: String, label: String,
                         _ control: PaneModeControl) -> some View {
        IconActionButton(systemImage: systemImage, label: label, help: label, active: control.mode == mode) {
            if control.mode != mode { control.toggle() }
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
    /// Closes the page and clears the selection — set only in list-only mode, where the page is
    /// something opened over the rows rather than half of the screen.
    let close: (() -> Void)?
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
private struct PaneClearSelectionKey: EnvironmentKey { static var defaultValue: (() -> Void)? { nil } }
private struct PaneModeControlKey: EnvironmentKey { static var defaultValue: PaneModeControl? { nil } }
private struct PaneHeaderActionsKey: EnvironmentKey { static var defaultValue: PaneHeaderActions? { nil } }

/// The row's own actions, for a page that is a form with a `FormHeader` of its own — a group, a
/// registry, a domain. Delete left the rows (Kamal, 17 October) for `⋮` and the page header, and
/// these pages' headers are drawn by the form, which does not know what section it is in; the
/// section hands them in with `paneHeaderActions`, as it hands in the stepper with `paneStep`.
struct PaneHeaderActions {
    let content: AnyView
}

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
    /// Empties the list's selection; set by `paneFollows` above the split, so closing the page needs
    /// no argument from the section.
    var paneClearSelection: (() -> Void)? {
        get { self[PaneClearSelectionKey.self] }
        set { self[PaneClearSelectionKey.self] = newValue }
    }
    /// Set by `SplitPanes` on the list: the screen's mode and how to flip it, for the toolbar button.
    var paneModeControl: PaneModeControl? {
        get { self[PaneModeControlKey.self] }
        set { self[PaneModeControlKey.self] = newValue }
    }
    /// What a form's header draws before the stepper, while the form is a row's page.
    var paneHeaderActions: PaneHeaderActions? {
        get { self[PaneHeaderActionsKey.self] }
        set { self[PaneHeaderActionsKey.self] = newValue }
    }
    /// Set on a row section's list while its page is on screen beside it: the bulk bar stands down,
    /// because the page's summary of several carries the same actions (`BulkActionBar`).
    @Entry var pageBesideList = false
}

/// A form inside a page that needs the whole width while it is on screen. Add Service, inside a
/// group's page, is the one: it is a form, and forms are full width (Q58).
struct PaneWantsFullWidth: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// The row's actions — `RowActionPlace.header` — for a form-shaped page's `FormHeader`.
    func paneHeaderActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        environment(\.paneHeaderActions, PaneHeaderActions(content: AnyView(content())))
    }

    /// Leaves the split: no stepper, no expand button, and Back where a form expects one. For a
    /// form that is opened from inside a page and must not behave as the page itself.
    func outsideSplitPane() -> some View {
        environment(\.paneLayout, nil)
            .environment(\.paneStep, nil)
            .environment(\.paneHeaderActions, nil)
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

/// View ▸ Show List Only / Show Two Panes, for the split on screen.
struct PaneModeMenuItem: View {
    @FocusedValue(\.paneModeCommand) private var command

    var body: some View {
        Button(command?.mode == .listOnly ? "Show Two Panes" : "Show List Only") { command?.toggle() }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(command == nil)
    }
}
