import SwiftUI
import AppKit

/// Makes a form window carry **only the red close button** — no minimise, no zoom.
///
/// the owner's point, and it is right: minimise and maximise make no sense on a
/// "New Network" form. There is nothing to zoom to and nothing worth parking in the Dock;
/// the only meaningful action is close. Leaving the buttons enabled offers two operations
/// that either do nothing useful or leave the form stranded.
///
/// SwiftUI has no modifier for this — `windowMinimizeBehavior` does not exist on this SDK
/// (checked, rather than assumed) and `windowResizability` controls sizing, not the buttons.
/// So this reaches the `NSWindow` through a zero-size representable and hides the two
/// controls directly.
///
/// Applied to forms only. The **main window keeps all three**: it is the product, and
/// minimising or zooming it are both reasonable things to want.
private struct FormWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window yet at make time, so defer until it is in the hierarchy.
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Re-applied on update because a window can be recreated — a `WindowGroup` reopened
        // after being closed comes back fresh, and it would come back with all three buttons.
        DispatchQueue.main.async { Self.apply(to: view.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Hiding the buttons alone leaves the *behaviours* reachable — double-clicking the
        // title bar still zooms, and ⌘M still minimises — which would be worse than showing
        // the controls, because the window would move with no visible way to bring it back.
        window.styleMask.remove(.miniaturizable)
        window.collectionBehavior.insert(.fullScreenNone)
    }
}

/// Hides minimise but keeps zoom — for windows you *read* rather than fill in.
private struct DetailWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: view.window) }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.styleMask.remove(.miniaturizable)
    }
}

extension View {
    /// Close-only window chrome, for forms presented in their own window.
    func formWindowChrome() -> some View {
        background(FormWindowChrome().frame(width: 0, height: 0))
    }

    /// Close-and-zoom chrome, for detail windows whose content can usefully fill the screen.
    func detailWindowChrome() -> some View {
        background(DetailWindowChrome().frame(width: 0, height: 0))
    }
}
