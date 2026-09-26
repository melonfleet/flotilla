import SwiftUI
import FlotillaCore

/// The two colours a theme is made of, and the ink that reads on the bar.
///
/// **The single table for all six themes.** `Theme`'s bar, bar-text and background tokens read
/// it, and so do the sketches in Settings, so a preview can never disagree with the window it
/// previews. The values and the contrast measurements behind them are in `design/THEMES.md`.
struct ThemePalette: Equatable {
    /// The window bar.
    let bar: Int
    /// The wordmark and bar buttons. Seed on all four bars today; kept per theme so a future bar
    /// that needs white ink is a one-line change rather than a new rule.
    let onBar: Int
    /// The content background.
    let body: Int

    // The brand tokens, from `design/branding.md`.
    static let stripe = 0x7CB342
    static let cantaloupe = 0xEE7B4D
    static let canary = 0xF2C94C
    static let flesh = 0xFC4A6B
    static let seed = 0x241F1A
    static let white = 0xFFFFFF
    /// `cream`, the suite's warm neutral — the light background the app shipped with.
    static let cream = 0xFBF7F0
    /// Honeydew `#A7D98C` at 30% over white. Full-strength honeydew drops the online and success
    /// dots to 2.5:1 and 2.1:1, below the 3:1 a status mark needs; the wash holds 3.6 and 3.0.
    static let honeydewWash = 0xE5F4DC
}

extension ThemeName {
    /// This theme's colours in light or dark.
    ///
    /// **Every bar takes seed ink**, in both appearances: white measures 2.5:1 at best on these
    /// four bars (stripe), and seed holds 4.9:1 at worst (flesh). Every dark body is seed; the light
    /// bodies pair each bar with a neutral or wash that keeps the status colours above 3:1.
    func palette(dark: Bool) -> ThemePalette {
        if dark {
            return ThemePalette(bar: bar, onBar: ThemePalette.seed, body: ThemePalette.seed)
        }
        switch self {
        // The green bar over the green-tinted wash — the pairing the Rind theme had.
        case .stripe:
            return ThemePalette(bar: bar, onBar: ThemePalette.seed, body: ThemePalette.honeydewWash)
        case .flesh, .cantaloupe:
            return ThemePalette(bar: bar, onBar: ThemePalette.seed, body: ThemePalette.cream)
        // Canary over white is 1.6:1 bar-to-body. The bar's own `Divider` is what separates them:
        // it is there for every theme, and this is the one that depends on it.
        case .canary:
            return ThemePalette(bar: bar, onBar: ThemePalette.seed, body: ThemePalette.white)
        }
    }

    /// The bar is the same brand colour in light and dark; only the body and its surroundings change.
    private var bar: Int {
        switch self {
        case .stripe: ThemePalette.stripe
        case .flesh: ThemePalette.flesh
        case .cantaloupe: ThemePalette.cantaloupe
        case .canary: ThemePalette.canary
        }
    }
}

/// The user's pair: the theme drawn in light and the theme drawn in dark.
///
/// Carried in the SwiftUI environment rather than read from a global, and that is load-bearing:
/// the bar and background are dynamic `NSColor`s, which re-resolve when the *appearance* changes
/// but have no way to know that the *theme* did. A new `ThemeChoice` in the environment re-runs
/// the few views that paint the bar and background, and they build their colours afresh — so a
/// choice in Settings repaints the window at once, with no relaunch.
struct ThemeChoice: Equatable {
    var light: ThemeName
    var dark: ThemeName

    /// What a fresh install draws: the look the app shipped with.
    static let `default` = ThemeChoice(light: SettingsKeys.lightTheme.defaultValue,
                                       dark: SettingsKeys.darkTheme.defaultValue)
}

extension EnvironmentValues {
    @Entry var themeChoice: ThemeChoice = .default

    /// The ink for glyphs painted on the window bar, set by `WindowBar` from the theme.
    ///
    /// `nil` everywhere else. Glyphs on a *selected table row* go white, and they still do; this
    /// exists because the bar is the one coloured surface whose ink is not white: seed, on all four
    /// bars, because white measures 2.5:1 at best on them.
    @Entry var barInk: Color? = nil
}

extension Color {
    /// An opaque sRGB colour from a `0xRRGGBB` value, **fixed** — for the Settings sketches, which
    /// must draw a dark theme as dark even while the app is light. Everywhere else, use `Theme`'s
    /// dynamic tokens.
    init(hex: Int, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
