import SwiftUI
import AppKit

/// Window chrome for the container detail window — the only window Flotilla opens besides
/// the main one.
///
/// Forms used to live here too, as close-only windows. They are now sheets: the owner wanted the
/// interface behind to grey out and stop responding, and only a real sheet gets that from the
/// system. A sheet has no title bar, so it cannot carry macOS's close button — hence
/// `ModalCloseButton`, the red × drawn in `ModalCard`.
///
/// What is left is the detail window's chrome. It keeps **zoom**, because a log or a JSON tree
/// genuinely benefits from filling the screen, and loses **minimise**, which would only strand
/// it. SwiftUI has no modifier for either — `windowMinimizeBehavior` does not exist on this SDK
/// (checked, not assumed) — so this reaches `NSWindow` through a zero-size representable.
///
/// Note it changes the style mask as well as hiding the button: hiding it alone leaves ⌘M
/// working, and a window that minimises with no visible way back is worse than one showing a
/// control you did not want.
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
    /// Close-and-zoom chrome, for detail windows whose content can usefully fill the screen.
    func detailWindowChrome() -> some View {
        background(DetailWindowChrome().frame(width: 0, height: 0))
    }
}
