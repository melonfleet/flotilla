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
    /// The chosen themes, for the content background. See `ThemeChoice`.
    @Environment(\.themeChoice) private var themes

    /// Owned here, not in `ContainersView`. This view is the window's root and is built
    /// once; the detail views are destroyed and recreated on every sidebar change, so any
    /// `@State` they hold is lost. Keeping the containers screen's columns, sort, filter and
    /// search here is what makes them survive a trip to Images and back.
    @State private var containersUI = ContainersUIState()

    /// Same reasoning as `containersUI`, and owned here for the same reason — `MachinesView`
    /// is rebuilt from scratch on every sidebar change.
    @State private var machinesUI = MachinesUIState()
    @State private var clustersUI = ResourceUIState<K8sNode>(
        sortOrder: [KeyPathComparator(\K8sNode.node)])
    @State private var activityUI = ActivityUIState()
    @State private var logsUI = LogsUIState()

    /// Volumes, Networks and Images share one generic state type — see `ResourceUIState`.
    @State private var volumesUI = ResourceUIState<HostedVolume>(
        sortOrder: [KeyPathComparator(\HostedVolume.name)])
    @State private var networksUI = ResourceUIState<HostedNetwork>(
        sortOrder: [KeyPathComparator(\HostedNetwork.name)])
    @State private var imagesUI = ResourceUIState<HostedImage>(
        sortOrder: [KeyPathComparator(\HostedImage.reference)])
    @State private var registriesUI = ResourceUIState<RegistryRow>(
        sortOrder: [KeyPathComparator(\RegistryRow.nameSortKey)])
    @State private var dnsUI = ResourceUIState<LocalDNSDomain>(
        sortOrder: [KeyPathComparator(\LocalDNSDomain.nameSortKey)])
    @State private var hostsUI = ResourceUIState<HostRow>(
        sortOrder: [KeyPathComparator(\HostRow.nameSortKey)])

    @State private var selection: Section? = .overview

    /// Icons-only mode — what collapsing the sidebar means here.
    ///
    /// The system sidebar toggle hides the sidebar *outright*, and that is the wrong behaviour
    /// for this window: with the navigation gone every section is two clicks away behind a
    /// button that looks like it broke the app. The owner asked for a rail instead, so the intent
    /// is **reinterpreted** rather than the control removed — see `columnVisibility`.
    ///
    /// **Collapsed by default** (the owner, 6 October), and remembered once changed.
    @AppStorage("sidebarRailed") private var railed = true

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
    ///
    /// **Measured against the lifted split view.** `sidebarCardLift` raises both columns, so this
    /// was tuned with 18pt of lift already applied. On macOS 27 there is no lift, and the content
    /// fell 18pt lower than it had ever sat — so the lift is taken back out here, keeping the
    /// content's first control 26pt below the bar on both systems, level with the sidebar's first
    /// row (measured: 291 against 293).
    private var contentTopInset: CGFloat { 17 + sidebarCardLift }

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
            // One flat list with thin dividers between its blocks (the owner, 6 October):
            // Overview | what containers are made of and run on | Hosts | what happened.
            // Containers first, as Docker does — this is a containers application.
            SwiftUI.Section {
                row(.overview, count: nil)
            }
            SwiftUI.Section {
                row(.containers, count: model.state == .loaded ? model.containers.count : nil)
                row(.images, count: model.imagesState == .loaded ? model.images.count : nil)
                row(.registries, count: model.registryRows.count)
                row(.volumes, count: model.volumesState == .loaded ? model.volumes.count : nil)
                row(.networks, count: model.networksState == .loaded ? model.networks.count : nil)
                row(.dns, count: model.dnsState == .loaded ? model.dnsDomains.count : nil)
                row(.machines, count: model.machinesState == .loaded ? model.machines.count : nil)
                row(.clusters, count: model.clustersState == .loaded ? model.clusters.count : nil)
            }
            SwiftUI.Section {
                row(.hosts, count: 1 + model.hostMode.hosts.count)
            }
            SwiftUI.Section {
                row(.activity, count: model.activity.isEmpty ? nil : model.activity.count)
                row(.logs, count: nil)
            }

            // **No System group.** Settings moved to the gear at the window's trailing edge
            // (`WindowBar`), on the owner's reasoning that the left nav should list the things you
            // manage — containers, volumes, machines — and not the application's own
            // preferences. `.settings` is still a real `Section`: the gear, the menu-bar popover
            // and the dashboard all reach it through `model.pendingSection`.
        }
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
        // The corner furthest from the toolbar, which is where the runtime's own state belongs:
        // visible without being asked for, and out of the way of the things you manage.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RuntimeStatusBand(model: model, railed: railed)
        }
        // The collapse control, in the middle of the sidebar's edge (the owner, 6 October) —
        // moved from the window bar, where it sat beside the logo.
        .overlay(alignment: .trailing) {
            Button { railed.toggle() } label: {
                Image(systemName: railed ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 40)
                    .background(.regularMaterial, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .help(railed ? "Show the sidebar labels" : "Collapse the sidebar to icons")
            .accessibilityLabel(railed ? "Expand sidebar" : "Collapse sidebar to icons")
        }
    }

    /// Kept equal to the 10pt this adds to `contentTopInset`, so the first row and the section
    /// controls beside it stay on one line. Change them together or not at all.
    private let sidebarTopInset: CGFloat = 10

    /// How far the floating sidebar card rises towards the window bar.
    ///
    /// **macOS 26:** measured on screen, the card's top sat 30pt below the bar's divider while its
    /// left edge was 11pt from the window's. 18 brings the top inset to about the side inset, so
    /// the card is evenly spaced from the chrome around it rather than floating low.
    ///
    /// **macOS 27: zero, because there is no card to lift.** The sidebar is no longer an inset
    /// glass card — its background starts at the bar's divider and runs flush to the window's
    /// left edge (pixel-scanned, 26 September). The same 18pt therefore slid the sidebar's top
    /// *under* the bar, which paints over it: the owner saw Dashboard tucked up against the bar,
    /// 10pt below it, while the content column's first control sat 26pt below — out of line by
    /// the lift exactly. With no lift the two start within 2pt of each other again.
    private var sidebarCardLift: CGFloat {
        if #available(macOS 27, *) { 0 } else { 18 }
    }

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

    /// The section itself, shared by both shells so there is one switch on the selection rather
    /// than one per navigation mode — two copies would be free to disagree about which view a
    /// section maps to.
    @ViewBuilder
    private var detailContent: some View {
        // Export and import belong to no section, so they sit over whichever is selected (Q29).
        if let screen = model.configurationScreen {
            switch screen {
            case .export:
                ExportConfigurationView(model: model) { model.configurationScreen = nil }
            case .importFile(let url):
                ImportConfigurationView(model: model, url: url) { model.configurationScreen = nil }
                    .id(url)
            }
        } else {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection ?? .overview {
        case .activity:
            ActivityView(model: model, ui: activityUI) { selection = $0 }
        case .logs:
            LogsView(model: model, ui: logsUI)
        case .overview:
            // The tiles drill down, so Overview drives the sidebar selection — a panel that
            // shows you a problem but cannot take you to it is a poster.
            OverviewView(model: model) { selection = $0 }
        case .hosts:
            // Each host's landing page is the per-Mac dashboard (6 October).
            HostsView(model: model, ui: hostsUI) { selection = $0 }
        case .containers:
            ContainersView(model: model, ui: containersUI)
        case .images:
            ImagesView(model: model, ui: imagesUI)
        case .registries:
            RegistriesView(model: model, ui: registriesUI)
        case .volumes:
            VolumesView(model: model, ui: volumesUI)
        case .networks:
            NetworksView(model: model, ui: networksUI)
        case .dns:
            DNSView(model: model, ui: dnsUI)
        case .machines:
            MachinesView(model: model, ui: machinesUI)
        case .clusters:
            ClustersView(model: model, ui: clustersUI)
        case .settings:
            SettingsView(model: model)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Full width, above everything — so the sidebar starts below it.
            WindowBar(model: model, railed: $railed)
                // **Draws last, despite being first.** `sidebarCardLift` below makes the split
                // view overlap the bar's bottom by design, and in a `VStack` the later view
                // paints over the earlier one — so the sidebar column's rounded glass corner was
                // painting a pale notch across the bar's bottom-left. Visible as a strange wedge
                // under the close button, which is exactly how the owner described it.
                //
                // The overlap is wanted; the paint order was not.
                .zIndex(1)
            splitView
                // Lifts the **floating sidebar card**, not its contents.
                //
                // The first attempt at this pulled the `List` up instead, which moved the rows
                // inside a card that stayed where it was — so Dashboard clipped against the
                // card's rounded top while the gap above the card was untouched. The gap the
                // owner meant is between the window bar's divider and the card's own edge, and
                // that edge is the system's: macOS 26 insets the glass card from its column, and
                // the column starts where this view does.
                //
                // A **negative top padding** is the one shape that moves it without dragging the
                // bottom: the child is offset up by this much and given that much more height,
                // so the card rises and the runtime band stays exactly where it is — which
                // matters, because the window's height is set by that band's divider lining up
                // with the Utilisation table.
                .padding(.top, -sidebarCardLift)
                // Pairing by code: the four words, on whichever screen is open. On the split view
                // rather than beside the operation sheet below, so two sheets never share a view.
                // Dismissed any other way, the answer is no — pairing must never hang waiting.
                .sheet(item: Binding(get: { model.hostMode.wordsPrompt },
                                     set: { if $0 == nil { model.hostMode.wordsPrompt?.reply(false) } })) { prompt in
                    PairingWordsSheet(prompt: prompt)
                }
        }
        // Up into the traffic-light row, so the bar IS the top of the window rather than a
        // second band under it. `.hiddenTitleBar` stops the title bar being *drawn* but SwiftUI
        // still insets content by its height, which left the logo one row below the lights and
        // the window carrying ~88pt of chrome against Docker's ~52. `WindowBar` reserves the
        // buttons' width at its leading edge, so nothing lands under them.
        .ignoresSafeArea(.container, edges: .top)
        // The wash has to reach the top of the window now that the content does.
        .background(Theme.contentBackground(themes).ignoresSafeArea())
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
        // The operation panel. Here rather than on each section, because the operations it
        // reports outlive the screen that started them: a pull begun on the New Image form is
        // still running after Back, and a panel owned by that form would go with it.
        //
        // A **sheet**, like About and the support bundle — the two other things `ModalCard` is
        // still for. It has to be: `ModalCard` draws a title bar and content and no surface of
        // its own, because a sheet supplies that. Hand-rolling it as an overlay drew the card's
        // text straight onto the window with the sidebar showing through it.
        .sheet(item: Binding(get: { model.activeOperation },
                             set: { if $0 == nil { model.activeOperation = nil } })) { operation in
            OperationProgressView(progress: operation) { model.activeOperation = nil }
        }
        // The Host column follows the fleet (the owner, 7 October): shown once a host is paired —
        // four `default` networks with nothing to tell them apart is what it is for — and hidden
        // when there is only This Mac, where it would read "This Mac" on every row. Applied only
        // when that changes, so hiding or showing it by hand in between is left alone.
        .onChange(of: model.hostMode.trustedHosts.isEmpty, initial: true) { _, thisMacOnly in
            let visibility: Visibility = thisMacOnly ? .hidden : .visible
            containersUI.columnCustomization[visibility: "host"] = visibility
            imagesUI.columnCustomization[visibility: "host"] = visibility
            volumesUI.columnCustomization[visibility: "host"] = visibility
            networksUI.columnCustomization[visibility: "host"] = visibility
            logsUI.columnCustomization[visibility: "host"] = visibility
            // On hosts says nothing with no hosts, so it follows the same rule.
            volumesUI.columnCustomization[visibility: "spread"] = visibility
            networksUI.columnCustomization[visibility: "spread"] = visibility
        }
        .onChange(of: model.pendingSection) { _, requested in
            guard let requested else { return }
            // A menu request is for the form it names: an open Export or Import screen, which
            // sits over every section, would otherwise hide it.
            model.configurationScreen = nil
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
