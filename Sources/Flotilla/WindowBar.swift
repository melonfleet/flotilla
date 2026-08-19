import SwiftUI
import AppKit

/// The full-width bar across the top of the window: sidebar toggle and wordmark at the leading
/// edge, window-level controls at the trailing edge, and the split view — sidebar included —
/// starting **below** it. The arrangement the owner asked for from Docker Desktop; deliberately not
/// the colour, so this carries our own chrome rather than a blue strip.
///
/// **Why this is the window's first content row and not a titlebar accessory.** The accessory
/// route was tried first, on the second reviewer's research, and it cannot produce this layout — measured, not
/// assumed. `NSTitlebarAccessoryViewController` with `layoutAttribute = .bottom` installed fine
/// and Apple does maximise its width, but AppKit laid it out at **`(208, y) 972 × 36` in an
/// 1180pt window**: the content area only, offset by exactly the sidebar's width. The reason is
/// structural — a `NavigationSplitView` sidebar is *full height*, running up under the title
/// bar, so nothing living in the titlebar region can span across it. The bar therefore has to be
/// above the split view in the content, with `.windowStyle(.hiddenTitleBar)` letting the content
/// reach the top of the window while the traffic lights keep floating over it.
///
/// A cautionary note on how that was found: the first measurement was taken immediately after
/// `addTitlebarAccessoryViewController` and reported the full 1180pt width, because AppKit had
/// not laid the view out yet. Measuring three seconds later told the truth. A geometry reading
/// taken before layout is not a measurement, it is a guess with a number attached.
struct WindowBar: View {
    let model: AppModel
    @Binding var railed: Bool

    /// Room for the traffic lights, which float over the content under `.hiddenTitleBar`.
    ///
    /// A constant, and honestly so: `window.standardWindowButton(_:)` could be measured instead,
    /// but that needs an `NSWindow` reach-around and this value is fixed by the system's own
    /// button metrics. Docker's strip does the same thing. If the buttons ever move, the symptom
    /// is cosmetic and obvious rather than silent.
    private let trafficLightInset: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Beside the logo, where Docker keeps its own — and it has to live here now:
                // with the title bar hidden there is no toolbar to hang a `ToolbarItem` on.
                Button {
                    railed.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(IconActionButtonStyle())
                .help(railed ? "Show the sidebar labels" : "Collapse the sidebar to icons")
                .accessibilityLabel(railed ? "Expand sidebar" : "Collapse sidebar to icons")

                Wordmark(size: 13)
                    .fixedSize()          // a lockup, never wrapped

                Spacer(minLength: 12)

                AppLinksMenu()
                // Beside the gear, because it is the same kind of thing — an app-level control,
                // not a control for whatever section you happen to be on. It is also *in*
                // Settings; this is the shortcut, and both write the one stored preference.
                AppearanceToggleButton(model: model)
                SettingsToolbarButton {
                    // Through the model, not a captured binding. `pendingSection` already exists
                    // for exactly this — the menu-bar popover drives the window's selection the
                    // same way — and it keeps this view ignorant of how navigation is stored.
                    model.pendingSection = .settings
                }
            }
            .padding(.leading, trafficLightInset)
            .padding(.trailing, 12)
            .frame(height: 44)
            Divider()
        }
        // The whole bar is a window-drag handle, because with the title bar hidden the strip
        // *looks* like the place you would grab to move the window — and controls inside it keep
        // their own clicks, since a gesture on the container does not swallow a button's hit.
        .background(WindowDragArea())
    }
}

/// Makes its area drag the window, restoring what `.hiddenTitleBar` takes away.
///
/// `mouseDownCanMoveWindow` rather than a `DragGesture` doing arithmetic on the window's origin:
/// AppKit already implements window dragging, including snapping and multi-display edges, and a
/// hand-rolled version would be a worse copy of it.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
