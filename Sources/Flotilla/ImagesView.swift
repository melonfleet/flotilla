import SwiftUI
import FlotillaCore

/// PLACEHOLDER — the CLI owner replaces this wholesale (see `PHASE1-UI.md`, his scope).
///
/// It exists only so the sidebar the core owner built can route to every section without leaving
/// `main` unbuildable while the two halves land at different times. The real screen lists
/// `cli.listImages()`, offers **Pull image…** and delete, and shows repository, tag and
/// size.
struct ImagesView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView(
            "Images",
            systemImage: "square.stack.3d.up",
            description: Text("Not built yet — the image list, pull and delete land with the rest of the Phase 1 UI.")
        )
    }
}
