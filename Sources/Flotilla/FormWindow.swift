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

        // Make it *feel* modal, which is the half a plain window does not give you.
        //
        // Attached as a child of the main window, so it always floats in front and can never
        // end up lost behind the thing it is modal to — the failure that makes a free-floating
        // form worse than a sheet. Child windows also move with their parent, so dragging the
        // main window does not leave the form stranded across the screen.
        if let parent = mainWindow(excluding: window) {
            if window.parent == nil {
                parent.addChildWindow(window, ordered: .above)
            }
            // Centred on the parent rather than the screen: with a large display the screen
            // centre can be nowhere near the window you were working in.
            let frame = window.frame
            let target = NSRect(
                x: parent.frame.midX - frame.width / 2,
                y: parent.frame.midY - frame.height / 2,
                width: frame.width,
                height: frame.height
            )
            if window.frame.origin != target.origin {
                window.setFrame(target, display: false)
            }
        }
    }

    /// The app's main window — the one the form is modal *to*. Identified by title rather than
    /// by index because window order changes as things open and close.
    private static func mainWindow(excluding form: NSWindow) -> NSWindow? {
        NSApp.windows.first {
            $0 !== form && $0.isVisible && $0.title == "Flotilla" && $0.parent == nil
        }
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

    /// Close-only chrome **plus** the modal treatment: the window is parented and centred on
    /// the main window, and the interface behind it dims and stops accepting clicks for as
    /// long as this form is open.
    ///
    /// Counted rather than flagged, so two open forms do not lift each other's dim.
    func modalFormWindow(_ model: AppModel) -> some View {
        formWindowChrome()
            .onAppear { model.formDidOpen() }
            .onDisappear { model.formDidClose() }
    }

    /// Close-and-zoom chrome, for detail windows whose content can usefully fill the screen.
    func detailWindowChrome() -> some View {
        background(DetailWindowChrome().frame(width: 0, height: 0))
    }
}
