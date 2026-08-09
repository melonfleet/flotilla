import SwiftUI

/// A row/toolbar icon button that reacts to the pointer, and shows when it is working.
///
/// The row actions were `.buttonStyle(.borderless)` with `.disabled(busy)` and nothing else, so:
/// pointing at one did nothing visible, clicking it did nothing visible, and while the action
/// ran the button simply greyed out. The owner read the Restart button as broken because of this —
/// it is not; `ContainerCLI.restart` is stop-then-start and both halves work, verified against
/// a live container on 9 August (STARTED moved and the IP changed). It just gave no sign of
/// having been pressed, and restarting a *running* container leaves the row looking identical,
/// so there was nothing at all to see.
///
/// Two things fix that, and both are needed. The hover/pressed states say "this is a control and
/// you just hit it". The in-place spinner says "and it is still going" — a stop-then-start takes
/// several seconds, and a greyed-out icon for that long is indistinguishable from a dead button.
struct IconActionButton: View {
    let systemImage: String
    let label: String
    let help: String
    var busy: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: systemImage)
                }
            }
            // Fixed box so the row does not reflow when the glyph swaps for the spinner, and
            // so every target is the same size whatever the glyph's natural width.
            .frame(width: 18, height: 18)
        }
        .buttonStyle(IconActionButtonStyle(destructive: destructive))
        .disabled(busy)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Hover and pressed feedback for a compact icon button.
///
/// Kept subtle: these sit several-to-a-row inside table cells, and a strong fill would turn a
/// quiet row into a strip of buttons competing with the data. A tint plus a small inward scale
/// is enough — the scale in particular reads as "pressed" even at 18pt where a colour shift is
/// easy to miss.
struct IconActionButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, destructive: destructive)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let destructive: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .padding(3)
                .background(fill, in: RoundedRectangle(cornerRadius: 5))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .contentShape(.rect)
                // Only track hover while enabled: a disabled button that lights up is a lie.
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.09), value: hovering)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
        }

        private var tint: Color { destructive ? Theme.danger : Theme.accent }

        private var foreground: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(.tertiary) }
            if destructive { return AnyShapeStyle(Theme.danger) }
            return AnyShapeStyle(hovering || configuration.isPressed
                                 ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return tint.opacity(0.28) }
            return hovering ? tint.opacity(0.13) : .clear
        }
    }
}
