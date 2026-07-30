import SwiftUI

/// The house shape for a modal form: a red circular close button, top-leading, and nothing
/// else in the way.
///
/// This is the resolution of a genuine conflict. The owner wanted the web-modal behaviour — the
/// interface behind greys out and stops responding — *and* macOS's own red close button.
/// Those cannot coexist: traffic lights only exist on a real title bar, a native sheet has no
/// title bar, and a plain window is not modal. Having tried the window route, the sheet is the
/// better trade: real modality from the system, with a drawn close control instead of a
/// borrowed one.
///
/// The button is deliberately **not** a traffic-light imitation sitting where a title bar
/// would be. It is a close control that happens to be red and carries the × everyone already
/// reads as close — which was the point all along: an icon travels further than the word
/// "Close".
struct ModalCloseButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.red)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    // The glyph appears on hover, as macOS's own close button does; the red
                    // circle alone already means close.
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Icon-only controls need naming: a red circle is obvious to sighted users and silent
        // to everyone else.
        .accessibilityLabel("Close")
        .help("Close")
        // Escape closes a sheet natively, but only if something does not swallow the key
        // first; binding it here makes it explicit rather than incidental.
        .keyboardShortcut(.cancelAction)
    }
}

/// Wraps a form's content with the close button and consistent padding, so every modal in the
/// app opens the same way and closes the same way.
struct ModalCard<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ModalCloseButton(action: onClose)
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            content
        }
    }
}
