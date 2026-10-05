import SwiftUI
import AppKit
import FlotillaCore

/// The watermelon palette.
///
/// **Source of truth is `design/branding.md`**, not the mockups. That distinction matters
/// because this file used to be transcribed from `research/review/mockups/assets/mac.css`, whose
/// token block names its status colours `--sys-red`, `--sys-orange` and `--sys-blue` — macOS
/// system colours, deliberately. Faithfully transcribed, that gave the app a **plain blue** on
/// the dashboard's CPU chart and disk-read marker, which is the one hue with no place in a
/// watermelon identity. `branding.md` had a sanctioned informational colour all along (teal
/// `#2C7A7B`); nobody had reconciled the two documents.
///
/// So: brand values are quoted exactly and labelled. Where a slot needs a dark-mode counterpart
/// that `branding.md` does not specify, it is **derived** — lifted in lightness until it holds on a
/// dark surface — and said to be derived rather than passed off as brand.
///
/// **Themes** (`design/THEMES.md`) change exactly two things: the window bar and the content
/// background. Those are the only tokens here that take a `ThemeChoice`. Everything else is fixed
/// per appearance, so there is one set of colours to check in light and one in dark, not one per
/// theme.
///
/// **Controls are macOS's own.** Buttons, selection, focus rings and links use the system accent
/// and the system link colour, as Finder and System Settings do. The melon lives in the bar, the
/// background, charts, status and the wordmark.
///
/// Three rules carried forward, all load-bearing:
///
/// - **Pink is NEVER an error colour.** Neither is the melon orange. (Pink used to be selection
///   too; selection now follows the system accent, so that half of the rule retired with themes.)
/// - **Green means running/healthy.** It is the brand's own green now, not Material's.
/// - Every colour is a *dynamic* `NSColor`, so light and dark resolve at draw time. A plain
///   `Color(red:green:blue:)` freezes one appearance into the other — the same class of mistake
///   as hardcoding a `preferredColorScheme`.
enum Theme {

    // MARK: Brand — quoted from branding.md

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

    /// The system accent: selection fills, focus rings, hover washes, the current tab's marker.
    ///
    /// **This is the user's colour, not the brand's.** Themes made the app's controls behave the way
    /// macOS's own do, so selection is whatever the user chose in System Settings ▸ Appearance —
    /// blue unless they changed it. The `AccentColor` asset that used to force watermelon onto
    /// AppKit's sidebar and focus rings is gone for exactly that reason: with it present,
    /// `Color.accentColor` would still be the brand.
    ///
    /// Never use this for data. A chart series drawn in the accent would change colour when the
    /// user changed System Settings; that is what `melon` is for.
    static let accent = Color.accentColor

    /// Clickable text: row names that open a detail view, "Copy", "Download…", breadcrumbs.
    ///
    /// The **system link colour**, fixed across every theme. It used to be a burnt orange, because
    /// `.buttonStyle(.link)` hardcodes the system blue and a blue link was the one out-of-family hue
    /// in the app. With controls following macOS, blue is now the family: this is what a link looks
    /// like in every other Mac app, which is the point.
    static let link = Color(nsColor: .linkColor)

    /// The colour for a clickable row name, given whether that row is selected.
    ///
    /// A *selected* row in a `Table` is filled with the accent, and link blue on an accent fill is
    /// the "you do not see it anymore because of their exact same color" a tester reported when
    /// both were pink. `.primary` adapts inside a selected row — SwiftUI turns it white on an
    /// emphasised selection — so it stays legible whatever accent the user picked.
    ///
    /// One function rather than the same ternary in five list views, because five copies of a
    /// rule is how the rule ends up applied in four places.
    static func rowName(selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(.primary) : AnyShapeStyle(link)
    }

    /// The wash behind a selected or current item that is not a native list row: the Settings tab
    /// list, the current terminal tab, a machine's "default" badge. The system accent at low alpha;
    /// the alpha differs by appearance because the translucency that reads as a tint on white
    /// disappears against a dark surface.
    static let accentTint = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var resolved = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return resolved.withAlphaComponent(isDark ? 0.22 : 0.18)
    })

    /// The melon as a **data** colour: the dashboard's memory series and its legend. Fixed per
    /// appearance and the same in every theme, so a chart reads the same whatever bar is on top
    /// and whatever accent the user chose. These are the values the accent had before themes.
    static let melon = dynamic(light: 0xEE7B4D, dark: 0xFC4A6B)

    /// `melon` as small type — a chart label, a JSON literal. The fill does not carry enough
    /// contrast as text on either background (`cantaloupe` is about 2.4:1 on cream), so light takes
    /// it down to a burnt tone and dark lifts it.
    static let melonText = dynamic(light: 0xB4501F, dark: 0xFF9BB2)

    // MARK: State
    //
    // Semantic, not decorative. These are the colours a *status* is allowed to use, and they
    // now come from `branding.md`'s semantic row rather than from macOS.

    /// A running container, an online host. Brand `stripe`, darkened on light because
    /// `#7CB342` on white is too weak to read as a state at 7pt.
    static let online = dynamic(light: 0x4C8C2B, dark: 0x7CB342)
    /// Completed successfully. `success #1D9E75` exactly; dark is derived.
    static let success = dynamic(light: 0x1D9E75, dark: 0x3FCB9B)
    /// Failed, unreachable, exited non-zero. `danger #C9302C` exactly; dark is derived.
    static let danger = dynamic(light: 0xC9302C, dark: 0xF2635F)
    /// Needs attention but is not broken: untrusted, restarting, degraded.
    ///
    /// **Light is `#A87600`, deepened from the brand's `#E5A100`**, which measured 2.1:1 on cream —
    /// under the 3:1 a status mark needs, on every light background the app had, before themes
    /// existed. `#A87600` is the same hue taken down until its worst case, the Rind theme's
    /// honeydew wash, holds 3.5:1. Dark is derived and was already fine.
    static let warning = dynamic(light: 0xA87600, dark: 0xF5C242)
    /// Informational, and "not yet built" markers. `info #2C7A7B` exactly; dark is derived.
    ///
    /// **This replaces the system blue.** It is the single change that removes the last
    /// out-of-family hue from the app.
    static let info = dynamic(light: 0x2C7A7B, dark: 0x59B3B0)

    // MARK: Surfaces

    /// The content background for the chosen themes: the honeydew wash, cream or white in light;
    /// seed in dark. See `ThemePalette`.
    ///
    /// Dark keeps its 0.85 alpha: the window's own dark ground shows through a little, which is
    /// what stops a flat near-black reading as a hole next to the sidebar.
    static func contentBackground(_ choice: ThemeChoice, opaque: Bool = false) -> Color {
        dynamic(light: choice.light.palette.body, dark: choice.dark.palette.body,
                lightAlpha: 1, darkAlpha: opaque ? 1 : 0.85)
    }

    /// The window bar's own ground for the chosen themes.
    ///
    /// Docker's reference strip is a solid colour, and the bar had none at all — it showed
    /// `contentBackground`, which is why it read as part of the content rather than as chrome.
    static func titleBar(_ choice: ThemeChoice) -> Color {
        dynamic(light: choice.light.palette.bar, dark: choice.dark.palette.bar)
    }

    /// What reads on `titleBar`: **seed, on all four bars.**
    ///
    /// It used to be white on both bars, on the grounds that one foreground was simpler. Measured,
    /// white on `#EE7B4D` is about 2.8:1 — under the 4.5:1 the wordmark and the bar's buttons need
    /// — and white on canary would be invisible. Seed holds 4.9:1 at worst. The ink stays a per-theme
    /// value in `ThemePalette` so a future bar that needs white is one line.
    static func onTitleBar(_ choice: ThemeChoice) -> Color {
        dynamic(light: choice.light.palette.onBar, dark: choice.dark.palette.onBar)
    }

    /// Cards, tables and popovers sitting on the content background. Opaque on purpose — the
    /// placement note in the mockups puts glass on chrome only, and data must stay legible
    /// over a busy desktop picture.
    ///
    /// **Not theme-dependent**, and that is measured rather than assumed: every light body works
    /// under white cards, and every dark theme shares seed, so one pair serves all six. Dark is seed
    /// lifted 6% towards white (`#312D28`), so a card sits *above* the background rather than
    /// reading as a hole in it.
    static let raisedSurface = dynamic(light: 0xFFFFFF, dark: 0x312D28)

    /// Hairlines and card borders, tinted to the same family rather than neutral grey.
    static let hairline = dynamic(light: 0x1B5E20, dark: 0xA7D98C,
                                  lightAlpha: 0.14, darkAlpha: 0.16)

    // MARK: Construction

    static func dynamic(
        light: Int, dark: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Theme {
    /// The one mapping from a reported state to a colour.
    ///
    /// Four colours for four states, from `ContainerState`. Both the container dot and the
    /// activity strip used to test the raw string for "exit", "fail", "dead" and "restart" —
    /// Docker's words, none of which Apple's runtime emits — so the danger and warning branches
    /// were unreachable in both, and the strip's `default` arm painted every unrecognised state
    /// amber for good measure. Two copies of a dead rule is how you get two different wrong
    /// answers; this is one live rule with one answer.
    /// The colour for an activity entry, from the state it ended in.
    ///
    /// An event's vocabulary is wider than a container's: images, volumes and networks have no
    /// lifecycle, so their events are `present`/`absent` — they exist or they do not. Those two
    /// have to be mapped here rather than through `ContainerState`, which would take both as
    /// `.other`.
    ///
    /// This is the **third** copy of the rule, found while checking the Activity section after
    /// the other two were consolidated. All three had drifted: `ActivityView` painted `present`
    /// green while `ActivityStrip` painted it grey, and both fell through to amber for anything
    /// unrecognised — the "every unknown state is a warning" default that made a dead failure
    /// rule invisible in the first place. Unrecognised is now neutral, and `unknown` — the one
    /// state that means the runtime cannot say — is the only thing that reads as a problem.
    static func color(forEventEndingIn raw: String) -> Color {
        switch raw.lowercased() {
        case "present": Theme.online
        case "absent": .secondary
        default: color(for: ContainerState(raw))
        }
    }

    static func color(for state: ContainerState) -> Color {
        switch state {
        case .running: Theme.online
        // Transient, and the one honest use of the warning tint: something is happening.
        case .stopping: Theme.warning
        // `unknown` is the runtime declining to answer — the only state that wants a person,
        // and the only one this app can call a problem. There is no "failed" to colour: a
        // clean exit, a non-zero exit and a SIGKILL all end `stopped`, measured.
        case .unknown: Theme.danger
        case .stopped, .other: .secondary
        }
    }
}

@MainActor
extension Container {
    /// The dot colour for this container's state, using `Theme`'s semantic set rather than
    /// `.green`/`.secondary` picked per call site — which is how the table and the cards
    /// ended up with slightly different greens.
    var stateColor: Color { Theme.color(for: state) }
}

extension Theme {
    /// The tag palette, as light/dark hex pairs — the one table both the SwiftUI colour and the
    /// AppKit swatch come from, so a pill and its menu item can never disagree about what "blue"
    /// is.
    ///
    /// **These are the one place plain blue and purple are allowed**, and the exception is
    /// deliberate. The rule at the top of this file — no `--sys-blue`, the brand has a teal — is
    /// about colours *Flotilla* assigns to mean something: a chart series, a status dot. A tag's
    /// colour is chosen by the user and has to be recognisable as "the blue one" across a table
    /// of forty rows, next to whatever else they have tagged. Finder's swatches are the
    /// vocabulary people already have for that, so matching them is worth more here than brand
    /// consistency is; the values are pulled slightly towards the app's own saturation so a row
    /// of pills does not read as a screenshot of a different application.
    ///
    /// Dark values are **derived**, not brand: each is lifted in lightness until it holds its hue
    /// on `#171C14` and is still distinguishable from its two neighbours in the wheel.
    private static func hexes(for tag: TagColor) -> (light: Int, dark: Int) {
        switch tag {
        case .red: (0xC9302C, 0xF2635F)
        case .orange: (0xE07B39, 0xF59A76)
        case .yellow: (0xD9A200, 0xF5C242)
        case .green: (0x4C8C2B, 0x7CB342)
        case .blue: (0x3A6EA5, 0x82AEDC)
        case .purple: (0x7B4FA8, 0xB693DA)
        case .grey: (0x77777C, 0x9EA09B)
        }
    }

    static func color(for tag: TagColor) -> Color {
        let hex = hexes(for: tag)
        return dynamic(light: hex.light, dark: hex.dark)
    }

    static func nsColor(for tag: TagColor) -> NSColor {
        let hex = hexes(for: tag)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? hex.dark : hex.light, alpha: 1)
        }
    }

    /// A tag's colour as a **drawn image**, for use inside a menu.
    ///
    /// This exists because of a measured failure: `Label { Text(tag.name) } icon: {
    /// Image(systemName: "circle.fill").foregroundStyle(Theme.color(for: tag.color)) }` renders
    /// all seven swatches in **one** colour. AppKit tints a menu item's icon itself, and a
    /// SwiftUI `foregroundStyle` on the glyph does not survive the trip — the same shape as the
    /// borderless `Menu` that ignored `foregroundStyle` and needed `.tint` instead, except that
    /// here there is no tint to set per item. A seven-colour palette drawn entirely in the accent
    /// colour is not a cosmetic defect: the menu is where you *choose* the colour.
    ///
    /// So the swatch is an `NSImage` with `isTemplate = false`, which AppKit leaves alone. The
    /// drawing block runs in the menu's own appearance context, so the dynamic colour still
    /// resolves light or dark at draw time rather than being frozen when the image is made.
    static func swatchImage(for tag: TagColor, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: CGSize(width: diameter, height: diameter), flipped: false) { rect in
            nsColor(for: tag).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        // The whole point: a template image is recoloured by the menu, which is the bug.
        image.isTemplate = false
        return image
    }

    /// How much of a selection carries a tag. Three states, because with several rows selected
    /// "is this tag on" has three answers and collapsing the middle one into either of the others
    /// is how a bulk action does something the user did not ask for.
    enum TagCoverage { case none, some, all }

    /// A tick beside the swatch, for a tag that is applied.
    ///
    /// Two glyphs in one image rather than a separate checkmark column, because a menu item has
    /// one icon slot: `Label`'s icon. A `Toggle` would supply its own indicator and push the
    /// swatch into the label text, which is what the first version did.
    static func swatchImage(for tag: TagColor, applied: Bool,
                            diameter: CGFloat = 10) -> NSImage {
        swatchImage(for: tag, coverage: applied ? .all : .none, diameter: diameter)
    }

    /// The swatch, marked with how much of the selection carries the tag: nothing for none, a
    /// tick for all, a dash for some — the same three marks a checkbox uses, because it is the
    /// same question.
    static func swatchImage(for tag: TagColor, coverage: TagCoverage,
                            diameter: CGFloat = 10) -> NSImage {
        guard coverage != .none else { return swatchImage(for: tag, diameter: diameter) }
        let image = NSImage(size: CGSize(width: diameter, height: diameter), flipped: false) { rect in
            nsColor(for: tag).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let mark = NSBezierPath()
            if coverage == .all {
                mark.move(to: CGPoint(x: rect.width * 0.24, y: rect.height * 0.52))
                mark.line(to: CGPoint(x: rect.width * 0.43, y: rect.height * 0.31))
                mark.line(to: CGPoint(x: rect.width * 0.78, y: rect.height * 0.70))
            } else {
                mark.move(to: CGPoint(x: rect.width * 0.26, y: rect.height * 0.5))
                mark.line(to: CGPoint(x: rect.width * 0.74, y: rect.height * 0.5))
            }
            mark.lineWidth = max(1.2, rect.width * 0.16)
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
