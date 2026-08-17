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

    /// Volumes, Networks and Images share one generic state type — see `ResourceUIState`.
    @State private var volumesUI = ResourceUIState<ContainerVolume>(
        sortOrder: [KeyPathComparator(\ContainerVolume.name)])
    @State private var networksUI = ResourceUIState<ContainerNetwork>(
        sortOrder: [KeyPathComparator(\ContainerNetwork.id)])
    @State private var imagesUI = ResourceUIState<ContainerImage>(
        sortOrder: [KeyPathComparator(\ContainerImage.reference)])

    @State private var selection: Section? = .dashboard

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
                row(.images, count: model.imagesState == .loaded ? model.images.count : nil)
            }

            // Volumes and Networks, by contrast, really are container-only, and that was worth
            // checking against the CLI rather than assuming: `container run` takes `--volume`
            // and `--network`, and `machine create` takes **neither** — a machine's storage is
            // its disk image plus `--home-mount`, and its address comes from the runtime's own
            // vmnet bridge rather than from a network you created. So they stay here, under the
            // thing they actually attach to.
            SwiftUI.Section("Containers") {
                row(.containers, count: model.state == .loaded ? model.containers.count : nil)
                row(.volumes, count: model.volumesState == .loaded ? model.volumes.count : nil)
                row(.networks, count: model.networksState == .loaded ? model.networks.count : nil)
            }

            // Its own group: a machine is the VM containers run inside, not another resource
            // alongside them. Grouping it with images and volumes would imply otherwise.
            SwiftUI.Section("Virtualisation") {
                row(.machines, count: model.machinesState == .loaded ? model.machines.count : nil)
            }

            // The mockup shows eight hosts here. There is **one**, and inventing the other
            // seven to match a picture would be the fabricated-fixtures mistake in the UI
            // layer. The group is real, its contents are what actually exists.
            SwiftUI.Section("Hosts") {
                hostRow
            }

            SwiftUI.Section("System") {
                row(.settings, count: nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // 214pt, the mockup's own `.sidebar { flex: 0 0 214px }`. Left to SwiftUI's default
        // the column came up narrow enough to truncate "Containers" to "Contai…" once the
        // counts were added — a sidebar that cannot show its own labels.
        .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
    }

    /// This Mac. Deliberately **not** selectable: with a single host, a row that navigated
    /// would either duplicate Containers or do nothing at all, and a control that drives
    /// nothing is the failure this project keeps re-learning. It is a status readout until
    /// Phase 2 gives it siblings to switch between.
    private var hostRow: some View {
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
        .selectionDisabled()
        .help(hostHelp)
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
    private func row(_ section: Section, count: Int?) -> some View {
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
        .tag(section)
    }

    /// Mode and security posture, always visible. Both lines say what is true **now** rather
    /// than what is planned: there is no pairing yet, and the footer says so instead of
    /// showing a reassuring "mTLS" with nothing behind it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            // Short enough to sit on one line at the sidebar's width. The first draft wrapped
            // to three, which turned a quiet status footer into the loudest thing on screen.
            Label("Client mode", systemImage: "dot.radiowaves.left.and.right")
                .padding(.top, 7)
            Label("No paired hosts", systemImage: "key")
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

    var body: some View {
        NavigationSplitView {
            sidebar
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
        } detail: {
            switch selection ?? .dashboard {
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
