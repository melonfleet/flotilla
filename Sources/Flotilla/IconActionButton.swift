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
    /// Working — shows a spinner in place of the glyph.
    var busy: Bool = false
    /// Unavailable — dimmed, no spinner.
    ///
    /// Separate from `busy` because conflating them produced a real bug: a built-in network's
    /// delete button was passed `busy: network.isBuiltin`, so it span forever. A permanent
    /// spinner claims the app is doing something, which is the opposite of what "you cannot do
    /// this" should look like. `busy` means *in flight*; `disabled` means *not offered*.
    var disabled: Bool = false
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
        .disabled(busy || disabled)
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
        /// `.increased` inside a **selected** table row, where the accent fill is painted behind
        /// the cell. Without reading this, the destructive red trash and the secondary glyphs sat
        /// on a pink background at almost no contrast and looked like they had vanished.
        @Environment(\.backgroundProminence) private var prominence

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
            // On a selected row everything goes white, destructive included. A red-on-accent
            // trash is unreadable, and the row already says "destructive" through the
            // confirmation it opens — losing the red for the moment the row is selected costs
            // less than losing the button.
            if selected { return AnyShapeStyle(isEnabled ? .white : .white.opacity(0.55)) }
            guard isEnabled else { return AnyShapeStyle(.tertiary) }
            if destructive { return AnyShapeStyle(Theme.danger) }
            return AnyShapeStyle(hovering || configuration.isPressed
                                 ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            // White washes on the accent fill; the brand tint would be invisible on it.
            if selected {
                if configuration.isPressed { return .white.opacity(0.34) }
                return hovering ? .white.opacity(0.18) : .clear
            }
            if configuration.isPressed { return tint.opacity(0.28) }
            return hovering ? tint.opacity(0.13) : .clear
        }

        private var selected: Bool { prominence == .increased }
    }
}


/// The `⋯` label for a row's overflow menu.
///
/// A `Menu` is not a `Button`, so it cannot take `IconActionButtonStyle`; without this it kept
/// the default foreground and disappeared into the accent fill of a selected row — the same
/// problem the trash had, and the one the owner reported.
///
/// Vertical dots by rotation: **`ellipsis.vertical` is not a real SF Symbol.**
/// `NSImage(systemSymbolName:)` returns nil for it, and `Image(systemName:)` renders nothing at
/// all for an unknown name, which is how every overflow menu in the app silently vanished once.
struct RowOverflowLabel: View {
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .foregroundStyle(colour)
    }

    private var colour: AnyShapeStyle {
        if prominence == .increased {
            return AnyShapeStyle(isEnabled ? .white : .white.opacity(0.55))
        }
        return AnyShapeStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
}
