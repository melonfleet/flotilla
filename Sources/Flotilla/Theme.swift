import SwiftUI
import AppKit
import FlotillaCore

/// The watermelon palette, transcribed from the mockups' own token block
/// (`research/review/mockups/assets/mac.css`, `:root` and `[data-theme="dark"]`).
///
/// It exists because the built app was using macOS's **default blue** for every selection,
/// link and segmented control while the approved design is pink throughout. Nothing was
/// "wrong" in any one view; the accent had simply never been set, so every stock control
/// picked the system default and the app read as generic.
///
/// Two rules carried over from the mockup's comment, both load-bearing:
///
/// - **Pink is brand and selection. Pink is NEVER an error colour.** Errors use `systemRed`
///   and warnings `systemOrange` — the accent and a failure must not look alike, or a
///   selected row reads as a broken one.
/// - **Green means running/healthy**, and is a different green from the brand's rind.
///
/// Every colour is a *dynamic* `NSColor`, so light and dark resolve at draw time. A plain
/// `Color(red:green:blue:)` would freeze one appearance into the other, which is the same
/// class of mistake as hardcoding a `preferredColorScheme`.
enum Theme {

    // MARK: Brand

    /// The app tint: selection fills, links, focus rings, prominent buttons.
    static let accent = dynamic(light: 0xE93A5F, dark: 0xFC4A6B)

    /// Accent *text* — a deeper pink on light, a lighter one on dark, because the fill colour
    /// does not carry enough contrast as small type on either background.
    static let accentText = dynamic(light: 0xC2185B, dark: 0xFF9BB2)

    /// The wash behind a selected sidebar row. Alpha differs by appearance: the same
    /// translucency that reads as a tint on white disappears against a dark sidebar.
    static let accentTint = dynamic(light: 0xFC4A6B, dark: 0xFC4A6B,
                                    lightAlpha: 0.14, darkAlpha: 0.22)

    // MARK: State
    //
    // Semantic, not decorative. These are the colours a *status* is allowed to use.

    /// A running container, an online host.
    static let online = dynamic(light: 0x43A047, dark: 0x57C95D)
    /// Completed successfully — a darker green than `online`, for text rather than dots.
    static let success = dynamic(light: 0x2E7D32, dark: 0x7FC283)
    /// Failed, unreachable, exited non-zero.
    static let danger = dynamic(light: 0xD70015, dark: 0xFF453A)
    /// Needs attention but is not broken: untrusted, restarting, degraded.
    static let warning = dynamic(light: 0xC9510C, dark: 0xFF9F0A)
    /// Informational, and "not yet built" markers.
    static let info = dynamic(light: 0x0A64D2, dark: 0x4A9DFF)

    // MARK: Construction

    private static func dynamic(
        light: Int, dark: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

@MainActor
extension Container {
    /// The dot colour for this container's state, using `Theme`'s semantic set rather than
    /// `.green`/`.secondary` picked per call site — which is how the table and the cards
    /// ended up with slightly different greens.
    var stateColor: Color {
        if AppModel.isRunning(self) { return Theme.online }
        // "exited (137)" is not the same as "stopped", and they must not look the same:
        // one is a thing you started and finished, the other is a thing that died.
        let state = status.state.lowercased()
        if state.contains("exit") || state.contains("fail") || state.contains("dead") {
            return Theme.danger
        }
        if state.contains("restart") || state.contains("start") { return Theme.warning }
        return .secondary
    }
}
