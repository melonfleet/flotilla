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

    @State private var selection: Section? = .containers

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
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
            switch selection ?? .containers {
            case .containers:
                ContainersView(model: model, ui: containersUI)
            case .images:
                ImagesView(model: model)
            case .volumes:
                VolumesView(model: model)
            case .networks:
                NetworksView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
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
    }
}
