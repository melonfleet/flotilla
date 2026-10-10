import SwiftUI

/// Hover and pressed feedback for menu-bar popover rows.
///
/// The popover's rows were built with `.buttonStyle(.plain)` and, for the container rows, a
/// bare `.onTapGesture`. Both do exactly what they say: nothing visual. So pointing at a row
/// highlighted nothing and clicking it looked identical to not clicking it — the actions were
/// firing, but the popover gave no sign of it, which is indistinguishable from a dead control.
///
/// A real `NSMenu` item highlights on hover and flashes on activation, and people read that as
/// "this is a thing you can click". `.plain` opts out of it, which is right inside a form and
/// wrong in a menu.
///
/// Deliberately a tint rather than the full-bleed accent fill AppKit uses: the popover rows
/// carry secondary text and coloured state dots, and a saturated fill behind them would force
/// white-on-accent for everything and lose the state colours.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(.rect)
                // Pointer feedback as well as colour: on macOS the cursor is half the signal.
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.08), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fill: Color {
            if configuration.isPressed { return Theme.accent.opacity(0.30) }
            return hovering ? Theme.accent.opacity(0.14) : .clear
        }
    }
}

