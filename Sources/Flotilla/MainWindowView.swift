import SwiftUI
import FlotillaCore

/// The main window: **the product**.
///
/// Per the Phase 1 UI navigation contract: a `NavigationSplitView` whose sidebar lists
/// every `Section` and whose detail switches on the selection. Each section owns a
/// separate root-view file (`ContainersView`, `ImagesView`, `VolumesView`, `NetworksView`,
/// `SettingsView`) so ownership never collides. This file is only the shell — it must not
/// grow section-specific logic.
struct MainWindowView: View {
    let model: AppModel

    /// Owned here, not in `ContainersView`. This view is the window's root and is built
    /// once; the detail views are destroyed and recreated on every sidebar change, so any
    /// `@State` they hold is lost. Keeping the containers screen's columns, sort, filter and
    /// search here is what makes them survive a trip to Images and back.
    @State private var containersUI = ContainersUIState()

    /// Same reasoning as `containersUI`, and owned here for the same reason — `MachinesView`
    /// is rebuilt from scratch on every sidebar change.
    @State private var machinesUI = MachinesUIState()
    @State private var activityUI = ActivityUIState()
    @State private var logsUI = LogsUIState()

    /// Volumes, Networks and Images share one generic state type — see `ResourceUIState`.
    @State private var volumesUI = ResourceUIState<ContainerVolume>(
        sortOrder: [KeyPathComparator(\ContainerVolume.name)])
    @State private var networksUI = ResourceUIState<ContainerNetwork>(
        sortOrder: [KeyPathComparator(\ContainerNetwork.id)])
    @State private var imagesUI = ResourceUIState<ContainerImage>(
        sortOrder: [KeyPathComparator(\ContainerImage.reference)])

    @State private var selection: Section? = .dashboard

    /// Icons-only mode — what collapsing the sidebar means here.
    ///
    /// The system sidebar toggle hides the sidebar *outright*, and that is the wrong behaviour
    /// for this window: with the navigation gone every section is two clicks away behind a
    /// button that looks like it broke the app. The owner asked for a rail instead, so the intent
    /// is **reinterpreted** rather than the control removed — see `columnVisibility`.
    @State private var railed = false

    /// Pinned to `.all`, deliberately.
    ///
    /// A request to hide the sidebar can arrive from three places — our toolbar button, the
    /// View menu, and ⌘⌥S — and only the first is ours. Rather than leave the other two doing
    /// the old disappearing act, the visibility change is translated into railing and the
    /// column put straight back, so all three routes agree and there is no way to end up with
    /// no navigation at all.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Wide enough for an 18pt symbol inside the row's selection capsule, and fixed: `min`,
    /// `ideal` and `max` are all this in rail mode, because a rail you can drag out to 180pt is
    /// just a sidebar with the labels missing.
    private let railWidth: CGFloat = 64
    private let railIconSize: CGFloat = 18

    /// Drops every section's content to the same line the sidebar's first row sits on.
    ///
    /// Measured on the Containers screen: the controls row (view toggles, filter, search) began
    /// 12pt below the window bar while the sidebar's first row began 37pt below it, so the two
    /// columns started at visibly different heights and the dashboard's first heading sat tight
    /// under the bar. Applied once here rather than in six section files — the alignment is a
    /// property of the window's two columns, not of any one screen, and six copies of a number
    /// is how the toolbar padding drifted three ways before.
    private let contentTopInset: CGFloat = 35

    /// The sidebar, rebuilt to `research/review/mockups/main-window.html`.
    ///
    /// It was a flat five-item `Label` list: no counts, no grouping, no footer. The mockup's
    /// version carries three things that list did not, and each earns its place —
    ///
    /// - **Counts**, right-aligned and tabular, so "how much is there" is answered without
    ///   visiting every tab.
    /// - **Grouping**, so the resource sections, the hosts and the app's own screens read as
    ///   three different kinds of thing rather than one undifferentiated list.
    /// - **A footer** stating the mode and the security posture, which is the sort of fact you
    ///   want visible continuously rather than buried in Settings.
    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            // The ungrouped top block is what spans **everything** below it.
            //
            // Dashboard obviously does. Images does too, and that is not obvious: a machine is
            // built from an OCI image out of the same store a container runs from — the
            // machine's `alpine:3.22` and the image list's `alpine:3.22` are the same digest.
            // Filing Images under "Containers" said otherwise.
            SwiftUI.Section {
                row(.dashboard, count: nil)
                // Activity spans every kind below, so it belongs in the ungrouped block with
                // Dashboard and Images rather than under any one section's heading.
                row(.activity, count: model.activity.isEmpty ? nil : model.activity.count)
                // Beside Activity, and above the per-kind groups, because it spans every kind:
                // Activity is what *changed*, Logs is what things *said*.
                row(.logs, count: nil)
                row(.images, count: model.imagesState == .loaded ? model.images.count : nil)
            }

            // Volumes and Networks, by contrast, really are container-only, and that was worth
            // checking against the CLI rather than assuming: `container run` takes `--volume`
            // and `--network`, and `machine create` takes **neither** — a machine's storage is
            // its disk image plus `--home-mount`, and its address comes from the runtime's own
            // vmnet bridge rather than from a network you created. So they stay here, under the
            // thing they actually attach to.
            group("Containers") {
                row(.containers, count: model.state == .loaded ? model.containers.count : nil)
                row(.volumes, count: model.volumesState == .loaded ? model.volumes.count : nil)
                row(.networks, count: model.networksState == .loaded ? model.networks.count : nil)
            }

            // Its own group: a machine is the VM containers run inside, not another resource
            // alongside them. Grouping it with images and volumes would imply otherwise.
            group("Virtualisation") {
                row(.machines, count: model.machinesState == .loaded ? model.machines.count : nil)
            }

            // **No Hosts group until Phase 2.** The mockup shows eight hosts; there was exactly
            // one, and a single unselectable row is not navigation — it is a status readout
            // wearing navigation's clothes, which is the "control that drives nothing" this
            // project keeps re-learning. `hostRow`'s own docstring conceded as much.
            //
            // Nothing is lost: the dashboard's Hosts card carries the same dot with more detail
            // (containers *and* machines running), the runtime banner explains an unhealthy
            // runtime where you can act on it, the menu-bar popover shows This Mac with live
            // CPU and memory, and the sidebar footer states the mode and pairing posture
            // continuously. Bring the group back when there are peers to switch between and the
            // row has somewhere to go — the owner's call, 18 August.

            // **No System group.** Settings moved to the gear at the window's trailing edge
            // (`WindowBar`), on the owner's reasoning that the left nav should list the things you
            // manage — containers, volumes, machines — and not the application's own
            // preferences. `.settings` is still a real `Section`: the gear, the menu-bar popover
            // and the dashboard all reach it through `model.pendingSection`.
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // Space between the sidebar's top border and its first row — without it the selected
        // row's accent capsule butts straight against the navigation's own edge.
        //
        // `safeAreaInset`, matching what the footer below already does, because
        // `.contentMargins(.top, _, for: .scrollContent)` had **no effect** on a `.sidebar`-styled
        // `List`: measured, the content column moved down 10pt and this one did not, leaving the
        // two out of line by exactly the amount that was supposed to keep them level.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: sidebarTopInset)
        }
    }

    /// Kept equal to the 10pt this adds to `contentTopInset`, so the first row and the section
    /// controls beside it stay on one line. Change them together or not at all.
    private let sidebarTopInset: CGFloat = 10

    /// In rail mode the title *and* the count move into the tooltip rather than being dropped.
    /// The count is the sidebar's one piece of at-a-glance information, and there is no room for
    /// a numeral beside an 18pt glyph without either shrinking the icon the owner asked to enlarge
    /// or widening the rail back towards a sidebar.
    private func row(_ section: Section, count: Int?) -> some View {
        Group {
            if railed {
                Image(systemName: section.systemImage)
                    .font(.system(size: railIconSize))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .help(count.map { "\(section.title) — \($0)" } ?? section.title)
            } else {
                HStack(spacing: 7) {
                    Label(section.title, systemImage: section.systemImage)
                    Spacer(minLength: 6)
                    if let count {
                        Text("\(count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .tag(section)
    }

    /// A sidebar group, with its heading dropped in rail mode.
    ///
    /// Not cosmetic: at 64pt the headings render as "Contai…" and "Virtual…" — headings that no
    /// longer name anything. The **grouping** survives without them, because the sections still
    /// draw as separated blocks, so the rail keeps the structure and loses only the words.
    @ViewBuilder
    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        if railed {
            SwiftUI.Section { content() }
        } else {
            SwiftUI.Section(title) { content() }
        }
    }

    /// Mode and security posture, always visible. Both lines say what is true **now** rather
    /// than what is planned: there is no pairing yet, and the footer says so instead of
    /// showing a reassuring "mTLS" with nothing behind it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            if railed {
                // Glyphs only, one size up, because `caption2` icons with no words beside them
                // are too small to identify. The sentence is still in the tooltip below.
                VStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Image(systemName: "key")
                }
                .font(.caption)
                .padding(.top, 7)
                .frame(maxWidth: .infinity)
            } else {
                // Short enough to sit on one line at the sidebar's width. The first draft
                // wrapped to three, which turned a quiet status footer into the loudest thing
                // on screen.
                Label("Client mode", systemImage: "dot.radiowaves.left.and.right")
                    .padding(.top, 7)
                Label("No paired hosts", systemImage: "key")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .help("Flotilla is running in client mode on \(model.hostLabel). Pairing with remote hosts over mTLS arrives in Phase 2.")
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The section itself, shared by both shells so there is one switch on the selection rather
    /// than one per navigation mode — two copies would be free to disagree about which view a
    /// section maps to.
    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .dashboard {
        case .activity:
            ActivityView(model: model, ui: activityUI) { selection = $0 }
        case .logs:
            LogsView(model: model, ui: logsUI)
        case .dashboard:
            // The tiles drill down, so the dashboard needs to drive the sidebar selection —
            // a panel that shows you a problem but cannot take you to it is a poster.
            DashboardView(model: model) { selection = $0 }
        case .containers:
            ContainersView(model: model, ui: containersUI)
        case .images:
            ImagesView(model: model, ui: imagesUI)
        case .volumes:
            VolumesView(model: model, ui: volumesUI)
        case .networks:
            NetworksView(model: model, ui: networksUI)
        case .machines:
            MachinesView(model: model, ui: machinesUI)
        case .settings:
            SettingsView(model: model)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Full width, above everything — so the sidebar starts below it.
            WindowBar(model: model, railed: $railed)
            splitView
        }
        // Up into the traffic-light row, so the bar IS the top of the window rather than a
        // second band under it. `.hiddenTitleBar` stops the title bar being *drawn* but SwiftUI
        // still insets content by its height, which left the logo one row below the lights and
        // the window carrying ~88pt of chrome against Docker's ~52. `WindowBar` reserves the
        // buttons' width at its leading edge, so nothing lands under them.
        .ignoresSafeArea(.container, edges: .top)
        // The wash has to reach the top of the window now that the content does.
        .background(Theme.contentBackground.ignoresSafeArea())
        .allowsHitTesting(model.openFormCount == 0)
        .overlay {
            if model.openFormCount > 0 {
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .ignoresSafeArea()
                    .accessibilityLabel("Dimmed — a form is open in front")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.openFormCount)
        .onChange(of: model.pendingSection) { _, requested in
            guard let requested else { return }
            selection = requested
            model.pendingSection = nil
        }
        .onAppear {
            if let requested = model.pendingSection {
                selection = requested
                model.pendingSection = nil
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
            // Replaced by ours in the toolbar below. This has to be applied to the **sidebar**,
            // not to the split view: applied outside, the system button stayed and the title
            // bar carried two sidebar icons doing different things. The item belongs to the
            // column that provides it.
            .toolbar(removing: .sidebarToggle)
            .navigationTitle("")
            .listStyle(.sidebar)
            // Liquid Glass on the **sidebar**, per the placement note in
            // `research/review/mockups/main-window.html`: "Glass on sidebar, toolbar and the
            // Run/Pull cluster. The table and inspector rows are the content layer and stay
            // opaque, so data stays legible over a busy desktop picture."
            //
            // Hiding the scroll background is the whole of it. On macOS 26 a
            // `NavigationSplitView` sidebar is *already* Liquid Glass; a `List` simply paints
            // an opaque backing over it, which is why the sidebar read as flat white.
            //
            // This used to also carry `.background(.ultraThinMaterial)`, which was the bug.
            // `ultraThinMaterial` is the 2018 `NSVisualEffectView` vibrancy, not Liquid Glass —
            // so that line replaced the system's real glass with a flat blur and then took
            // credit for it in a comment. Removing it is what turns the glass on.
            .scrollContentBackground(.hidden)
            // 214pt, the mockup's own `.sidebar { flex: 0 0 214px }`.
            //
            // **Outermost, and that matters.** This used to sit on the `List` inside `sidebar`,
            // where it did nothing at all — the 208pt column we had been looking at for weeks
            // was AppKit's *saved divider position* (`NSSplitView Subview Frames main, …`), not
            // this modifier. It only became visible when the rail work cleared that key and the
            // sidebar came back at SwiftUI's ~140pt floor with every label truncated to
            // "Dashboa…". A persisted value had been standing in for a control that was inert:
            // the same shape as the settings that drove nothing.
            .navigationSplitViewColumnWidth(
                min: railed ? railWidth : 200,
                ideal: railed ? railWidth : 214,
                max: railed ? railWidth : 260)
        } detail: {
            detailContent
                .padding(.top, contentTopInset)
        }
        // The sidebar toggle moved into `WindowBar`: with `.hiddenTitleBar` there is no title
        // bar to hang a `ToolbarItem` on, and the control belongs beside the logo anyway — which
        // is where Docker puts its own.
        .toolbar(removing: .title)
        .onChange(of: columnVisibility) { _, requested in
            guard requested != .all else { return }
            railed.toggle()
            columnVisibility = .all
        }
        .animation(.easeInOut(duration: 0.18), value: railed)
    }
}
