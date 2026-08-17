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

            // The mockup shows eight hosts here. There is **one**, and inventing the other
            // seven to match a picture would be the fabricated-fixtures mistake in the UI
            // layer. The group is real, its contents are what actually exists.
            group("Hosts") {
                hostRow
            }

            group("System") {
                row(.settings, count: nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// This Mac. Deliberately **not** selectable: with a single host, a row that navigated
    /// would either duplicate Containers or do nothing at all, and a control that drives
    /// nothing is the failure this project keeps re-learning. It is a status readout until
    /// Phase 2 gives it siblings to switch between.
    private var hostRow: some View {
        Group {
            if railed {
                // The machine glyph *tinted* by the state, not the bare 8pt dot: alone in a
                // 64pt column a dot reads as a stray bullet, and it would be the only thing in
                // the rail that was not an icon.
                Image(systemName: "desktopcomputer")
                    .font(.system(size: railIconSize))
                    .foregroundStyle(hostDotColor)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .help("\(model.hostLabel) — \(hostHelp)")
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(hostDotColor)
                        .frame(width: 8, height: 8)
                    Text(model.hostLabel)
                    Spacer(minLength: 6)
                    if model.state == .loaded {
                        Text("\(model.running.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(hostHelp)
            }
        }
        .selectionDisabled()
    }

    /// Derived from the load state rather than from `AppModel`'s private preflight verdict —
    /// the observable state already says everything the dot needs, and reaching past the
    /// model's own boundary for it would be the wrong trade for one colour.
    private var hostDotColor: Color {
        switch model.state {
        case .loaded: Theme.online
        case .unavailable, .failed: Theme.danger
        // Not yet known. A hollow-looking grey, never green — claiming a host is up before
        // we have heard from it is the offline-detection bug again.
        case .idle, .loading: .secondary
        }
    }

    private var hostHelp: String {
        switch model.state {
        case .loaded: "\(model.running.count) running of \(model.containers.count)"
        case .unavailable(let reason), .failed(let reason): reason
        case .idle, .loading: "Checking the container runtime…"
        }
    }

    /// A section row: icon, title, and the count trailing.
    ///
    /// `count` is optional and `nil` renders nothing, because Images, Volumes and Networks
    /// load lazily when their tab is first opened. Showing `0` for "not fetched yet" would
    /// make an unvisited tab indistinguishable from an empty one — the same
    /// unknown-versus-zero confusion the CPU column already refuses to make.
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
        }
        // The honeydew wash, on the content column only.
        //
        // The mockup specified `--content-bg: #ffffff`, and a flat white panel beside a Liquid
        // Glass sidebar reads as *absent* rather than as a decision. This is deliberately faint
        // — a ground for cards to sit on, not a colour anyone should notice — and cards keep
        // their own opaque surface so data contrast is untouched.
        //
        // `ignoresSafeArea` so it reaches under the toolbar; without it the wash stops at the
        // content inset and draws a visible seam across the top of every section.
        .background(Theme.contentBackground.ignoresSafeArea())
        // The modal treatment. Dimming *and* disabling: a dim alone would look modal while
        // still accepting clicks, which is worse than no dim at all — it says "you cannot
        // touch this" and then lets you.
        //
        // `.allowsHitTesting(false)` rather than `.disabled(true)` because `disabled`
        // recursively greys every control, which fights the dim and makes text unreadable.
        // The dim already communicates the state; this just makes it true.
        // The wordmark goes in the title bar, replacing the plain word "Flotilla" — the
        // sidebar was too narrow for the lockup and wrapped it to "melonfl / eet".
        //
        // `.navigation` places it top-leading, just after the sidebar toggle, which is where
        // the title text sat.
        .toolbar {
            // Ours, in the system button's place. Flipping `railed` directly rather than
            // letting the system hide the column first means no flash of a vanished sidebar
            // on the way to the rail.
            ToolbarItem(placement: .navigation) {
                Button {
                    railed.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(railed ? "Show the sidebar labels" : "Collapse the sidebar to icons")
                .accessibilityLabel(railed ? "Expand sidebar" : "Collapse sidebar to icons")
            }
            ToolbarItem(placement: .navigation) {
                Wordmark(size: 14)
                    .fixedSize()          // never wrap — it is a lockup, not a paragraph
            }
            // On macOS 26 every toolbar item is given its own Liquid Glass capsule. That is
            // right for controls and wrong for a logo: it drew an off-white pill behind the
            // wordmark that read as a mismatched, non-transparent patch against the title bar.
            // Hiding the shared background lets the mark sit directly on the glass.
            .sharedBackgroundVisibility(.hidden)
        }
        // Suppress the window's own title text. Without this the title bar reads
        // "melonfleet | Flotilla   Flotilla" — the name twice.
        //
        // This replaces an `NSViewRepresentable` that reached for `view.window` and set
        // `titleVisibility = .hidden`. It did not work, and the reason is worth keeping: a
        // `NavigationSplitView` re-asserts the title as a toolbar item of its own, so setting
        // the window property lost a race it could not win. `removing: .title` removes that
        // item, which is the thing actually being drawn.
        .toolbar(removing: .title)
        // The View menu and ⌘⌥S still reach the split view directly, and both ask for the old
        // behaviour. Translate rather than obey: rail it, and put the column straight back.
        .onChange(of: columnVisibility) { _, requested in
            guard requested != .all else { return }
            railed.toggle()
            columnVisibility = .all
        }
        .animation(.easeInOut(duration: 0.18), value: railed)
        .allowsHitTesting(model.openFormCount == 0)
        .overlay {
            if model.openFormCount > 0 {
                Rectangle()
                    .fill(.black.opacity(0.28))
                    .ignoresSafeArea()
                    // Not decorative: it is what tells the user the window is inert.
                    .accessibilityLabel("Dimmed — a form is open in front")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.openFormCount)
        // The popover can ask for a section; the window owns the selection. Consumed and
        // cleared here so a second click on "Settings…" works as well as the first.
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
}
