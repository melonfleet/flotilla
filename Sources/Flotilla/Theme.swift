import SwiftUI
import AppKit
import FlotillaCore

/// The watermelon palette.
///
/// **Source of truth is `design/brand/BRAND.md`**, not the mockups. That distinction matters
/// because this file used to be transcribed from `research/review/mockups/assets/mac.css`, whose
/// token block names its status colours `--sys-red`, `--sys-orange` and `--sys-blue` — macOS
/// system colours, deliberately. Faithfully transcribed, that gave the app a **plain blue** on
/// the dashboard's CPU chart and disk-read marker, which is the one hue with no place in a
/// watermelon identity. `BRAND.md` had a sanctioned informational colour all along (teal
/// `#2C7A7B`); nobody had reconciled the two documents.
///
/// So: brand values are quoted exactly and labelled. Where a slot needs a dark-mode counterpart
/// that `BRAND.md` does not specify, it is **derived** — lifted in lightness until it holds on a
/// dark surface — and said to be derived rather than passed off as brand.
///
/// Three rules carried forward, all load-bearing:
///
/// - **Pink is brand and selection. Pink is NEVER an error colour.** The accent and a failure
///   must not look alike, or a selected row reads as a broken one.
/// - **Green means running/healthy.** It is the brand's own green now, not Material's.
/// - Every colour is a *dynamic* `NSColor`, so light and dark resolve at draw time. A plain
///   `Color(red:green:blue:)` freezes one appearance into the other — the same class of mistake
///   as hardcoding a `preferredColorScheme`.
enum Theme {

    // MARK: Brand — quoted from BRAND.md

    /// `rind #1B5E20` — primary brand green, structure.
    static let rind = dynamic(light: 0x1B5E20, dark: 0x7CB342)
    /// `stripe #7CB342` — secondary green.
    static let stripe = dynamic(light: 0x7CB342, dark: 0x9CCB63)
    /// `honeydew #A7D98C` — pale accent green. Used at low alpha as the content wash.
    static let honeydew = dynamic(light: 0xA7D98C, dark: 0xA7D98C)
    /// `cantaloupe #EE7B4D`.
    static let cantaloupe = dynamic(light: 0xEE7B4D, dark: 0xF59A76)
    /// `canary #F2C94C`.
    static let canary = dynamic(light: 0xF2C94C, dark: 0xF7D97A)

    /// The app tint: selection fills, links, focus rings, prominent buttons.
    /// `flesh-deep #E63956` on light for contrast, `flesh #FC4A6B` on dark.
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
    // Semantic, not decorative. These are the colours a *status* is allowed to use, and they
    // now come from BRAND.md's semantic row rather than from macOS.

    /// A running container, an online host. Brand `stripe`, darkened on light because
    /// `#7CB342` on white is too weak to read as a state at 7pt.
    static let online = dynamic(light: 0x4C8C2B, dark: 0x7CB342)
    /// Completed successfully. `success #1D9E75` exactly; dark is derived.
    static let success = dynamic(light: 0x1D9E75, dark: 0x3FCB9B)
    /// Failed, unreachable, exited non-zero. `danger #C9302C` exactly; dark is derived.
    static let danger = dynamic(light: 0xC9302C, dark: 0xF2635F)
    /// Needs attention but is not broken: untrusted, restarting, degraded.
    /// `warning #E5A100` exactly; dark is derived.
    static let warning = dynamic(light: 0xE5A100, dark: 0xF5C242)
    /// Informational, and "not yet built" markers. `info #2C7A7B` exactly; dark is derived.
    ///
    /// **This replaces the system blue.** It is the single change that removes the last
    /// out-of-family hue from the app.
    static let info = dynamic(light: 0x2C7A7B, dark: 0x59B3B0)

    // MARK: Surfaces

    /// The wash behind the content column.
    ///
    /// Honeydew at low alpha rather than the flat `#FFFFFF` the mockup specified — a white
    /// content area next to a Liquid Glass sidebar reads as *absent* rather than as a choice.
    /// Kept deliberately faint: this is a ground for cards to sit on, not a colour anyone
    /// should notice. Cards stay `raisedSurface` so data keeps maximum contrast.
    ///
    /// Dark is a deep rind-cast neutral, not pure grey, so the green character survives the
    /// appearance switch instead of the app looking like two different products.
    static let contentBackground = dynamic(light: 0xEDF6E4, dark: 0x171C14,
                                           lightAlpha: 0.55, darkAlpha: 0.85)

    /// Cards, tables and popovers sitting on `contentBackground`. Opaque on purpose — the
    /// placement note in the mockups puts glass on chrome only, and data must stay legible
    /// over a busy desktop picture.
    static let raisedSurface = dynamic(light: 0xFFFFFF, dark: 0x1F241C)

    /// Hairlines and card borders, tinted to the same family rather than neutral grey.
    static let hairline = dynamic(light: 0x1B5E20, dark: 0xA7D98C,
                                  lightAlpha: 0.14, darkAlpha: 0.16)

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
