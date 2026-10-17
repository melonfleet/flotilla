import SwiftUI

/// The list-left, page-right split that Suggestions, the Docker Hub browser and Notifications share:
/// a flexible list at least 240 wide, a divider, and a detail pane of 260–400 (ideal 400).
///
/// One definition so the three cannot drift in width or divider. Each pane is bounded by the
/// caller's own content; this only fixes the widths.
struct SplitPanes<Primary: View, Detail: View>: View {
    @ViewBuilder let primary: Primary
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            primary.frame(minWidth: 240, maxWidth: .infinity)
            Divider()
            detail.frame(minWidth: 260, idealWidth: 400, maxWidth: 400)
        }
    }
}
