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

    @State private var selection: Section? = .containers

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle("Flotilla")
            .listStyle(.sidebar)
        } detail: {
            switch selection ?? .containers {
            case .containers:
                ContainersView(model: model)
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
