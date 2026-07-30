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
            .navigationTitle("Flotilla")
            .listStyle(.sidebar)
            // Liquid Glass on the **sidebar**, per the placement note in
            // `research/review/mockups/main-window.html`: "Glass on sidebar, toolbar and the
            // Run/Pull cluster. The table and inspector rows are the content layer and stay
            // opaque, so data stays legible over a busy desktop picture."
            //
            // Hiding the scroll background is what lets the glass show through — a `List`
            // paints its own opaque backing otherwise, which is why the sidebar read as flat
            // white no matter what was placed behind it.
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
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
    }
}
