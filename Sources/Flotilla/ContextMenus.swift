import SwiftUI
import AppKit
import FlotillaCore

/// Shared pieces for **row context menus**, which every list surface in Flotilla is expected
/// to have: containers, images, volumes, networks.
///
/// This exists so the menus are one pattern rather than four interpretations. The house rules,
/// in order:
///
/// 1. **Parity with the visible controls.** A context menu offers what the row's own buttons
///    offer — never a capability you can *only* reach by right-clicking, and never fewer
///    actions than the buttons beside it. A menu that disagrees with the toolbar is how you
///    end up with two mental models of the same object.
/// 2. **Primary actions, then Copy, then destructive — last, and separated.** Delete sitting
///    next to Restart is how you lose a container you meant to bounce.
/// 3. **Copy is a submenu, always shaped the same way**, so "the identifier is under Copy"
///    holds true on every screen.
/// 4. **Disabled, not absent, while busy.** A menu whose items vanish mid-action makes the
///    app look broken; a greyed item explains itself.
@MainActor
enum Clipboard {
    /// Copies, and says so (the owner, 10 October): every Copy in the app ends here, so every one
    /// shows the same brief "Copied" and VoiceOver hears it.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        CopyFeedback.shared.show()
    }
}

/// The "Copied" confirmation: shown over the window for a moment after any copy.
@MainActor
@Observable
final class CopyFeedback {
    static let shared = CopyFeedback()
    private(set) var visible = false
    @ObservationIgnored private var generation = 0

    func show() {
        generation += 1
        let mine = generation
        visible = true
        AccessibilityNotification.Announcement("Copied").post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if generation == mine { visible = false }
        }
    }
}

/// Draws `CopyFeedback` at the bottom of the window — a fade only, so Reduce Motion has nothing to
/// reduce.
struct CopyFeedbackOverlay: ViewModifier {
    private var feedback: CopyFeedback { .shared }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if feedback.visible {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)   // announced instead
            }
        }
        .animation(.easeOut(duration: 0.15), value: feedback.visible)
    }
}

/// The uniform **Copy** submenu.
///
/// Pairs whose value is nil or empty are dropped rather than rendered as a disabled row: a
/// container with no IP has nothing to copy, and offering "Copy IP Address" that yields an
/// empty clipboard is worse than not offering it. Order the pairs most-identifying first —
/// the name or reference you would paste into a terminal.
struct CopyMenu: View {
    let pairs: [(label: String, value: String?)]

    init(_ pairs: [(label: String, value: String?)]) {
        self.pairs = pairs
    }

    private var available: [(label: String, value: String)] {
        pairs.compactMap { pair in
            guard let value = pair.value, !value.isEmpty else { return nil }
            return (pair.label, value)
        }
    }

    var body: some View {
        if !available.isEmpty {
            Menu("Copy") {
                ForEach(available, id: \.label) { item in
                    Button(item.label) { Clipboard.copy(item.value) }
                }
            }
        }
    }
}
