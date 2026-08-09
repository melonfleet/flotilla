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

/// The same treatment for a row that cannot be a `Button`.
///
/// The container rows hold their own start/stop `Button`, and a `Button` inside another
/// `Button`'s label does not receive clicks on macOS — which is why those rows use
/// `onTapGesture` in the first place. This gives them the hover highlight anyway, plus a brief
/// flash on tap so activation is visible.
struct MenuRowHighlight: ViewModifier {
    let action: () -> Void
    @State private var hovering = false
    @State private var flashing = false

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture {
                flashing = true
                action()
                // Long enough to register, short enough not to feel like a delay. The row is
                // usually gone by the time it ends — the popover closes — which is fine.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(140))
                    flashing = false
                }
            }
            .animation(.easeOut(duration: 0.08), value: hovering)
            .animation(.easeOut(duration: 0.08), value: flashing)
    }

    private var fill: Color {
        if flashing { return Theme.accent.opacity(0.30) }
        return hovering ? Theme.accent.opacity(0.14) : .clear
    }
}

extension View {
    /// Hover highlight and tap flash for a popover row that owns nested controls.
    func menuRowHighlight(action: @escaping () -> Void) -> some View {
        modifier(MenuRowHighlight(action: action))
    }
}
