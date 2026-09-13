import SwiftUI

/// The **melonfleet | Flotilla** wordmark, matching
/// `design/brand/logos/melonfleet-flotilla{,-dark}.svg` element for element.
///
/// Rendered natively rather than shipped as an image, and that is a deliberate refusal: the
/// brand SVGs open with
/// `@import url('https://fonts.googleapis.com/css2?family=Ubuntu:wght@500…')`. Flotilla
/// promises no telemetry and no phone-home, with an About view listing every network
/// destination — a logo that fetches a font on every launch would make that claim false, and
/// would render as Helvetica anywhere the font is absent.
///
/// **The first version of this was wrong**, built by reading the SVG's colour list rather than
/// its geometry. It painted "melonfleet" in near-black with a pink pipe and an ordinary letter
/// `o`. The real mark is green (`#1B5E20`, `#7CB342` on dark), the separator is a warm grey
/// rule, and the `o` of melonfleet **is a watermelon** — concentric rind, pith and flesh with
/// three seeds. That melon is the whole identity; a plain `o` is a different logo.
struct Wordmark: View {
    /// Type size in points. Every proportion below is derived from the SVG's own 72pt
    /// geometry, so the lockup scales as one piece.
    var size: CGFloat = 15

    /// Paints the whole lockup in one colour instead of the brand palette — for the coloured
    /// window bar, where green-on-orange is a complementary clash and the near-black app name
    /// reads heavy.
    ///
    /// **The melon survives it.** Flattening the `o` to a filled disc would be a different logo:
    /// the geometry is the identity, which is the lesson this file was rewritten for. So the
    /// rind, pith, flesh and seeds are still four concentric shapes — drawn in one colour at
    /// descending opacity, the way a monochrome template icon keeps its structure. The menu-bar
    /// glyph already does exactly this.
    var monochrome: Color?

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Palette — straight from the two SVGs

    /// `#1B5E20` on light, `#7CB342` on dark.
    private var melonGreen: Color {
        if let monochrome { return monochrome }
        return colorScheme == .dark
            ? Color(red: 0x7C / 255, green: 0xB3 / 255, blue: 0x42 / 255)
            : Color(red: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255)
    }
    /// `#241F1A` on light, `#FBF7F0` on dark — the app name.
    private var appInk: Color {
        if let monochrome { return monochrome }
        return colorScheme == .dark
            ? Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xF0 / 255)
            : Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)
    }
    /// `#6E675C` on light, `#C7BFB2` on dark. A warm grey rule — **not** the pink accent.
    private var rule: Color {
        if let monochrome { return monochrome.opacity(0.55) }
        return colorScheme == .dark
            ? Color(red: 0xC7 / 255, green: 0xBF / 255, blue: 0xB2 / 255)
            : Color(red: 0x6E / 255, green: 0x67 / 255, blue: 0x5C / 255)
    }
    private var flesh: Color {
        // Mid-opacity in monochrome, so the flesh still separates from the rind and the pith
        // and the slice keeps its three rings.
        monochrome?.opacity(0.62) ?? Color(red: 0xFC / 255, green: 0x4A / 255, blue: 0x6B / 255)
    }
    private var seedInk: Color {
        monochrome ?? Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)
    }
    /// The pith ring — white against the brand palette, and a near-transparent hole in
    /// monochrome so the rind reads as a ring rather than a solid edge.
    private var pith: Color { monochrome?.opacity(0.16) ?? .white }

    /// Ubuntu Medium when installed, falling back to the system font at the same weight. The
    /// fallback is legible and on-weight; it simply is not the brand face, which is the honest
    /// trade for not bundling a font yet.
    private var brandFont: Font {
        NSFont(name: "Ubuntu Medium", size: size) != nil
            ? .custom("Ubuntu Medium", size: size)
            : .system(size: size, weight: .medium)
    }

    var body: some View {
        // `.firstTextBaseline`, not the default `.center`. This matters more than it looks:
        // the melon and the rule both position themselves with `alignmentGuide(.firstTextBaseline)`,
        // and a guide for an alignment the stack is not using is **silently ignored** — which
        // is exactly what left the melon floating above the word. A circle centred in the line
        // box sits higher than a lowercase letter, because the line box includes ascender and
        // descender space the letter does not use.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("mel").font(brandFont).foregroundStyle(melonGreen)
            melon
            Text("nfleet").font(brandFont).foregroundStyle(melonGreen)

            // The SVG's rule: 5pt wide and 72pt tall against 72pt type, with 22pt of air
            // either side. Kept proportional so it stays a rule and never reads as an "l".
            RoundedRectangle(cornerRadius: size * 0.035)
                .fill(rule)
                .frame(width: max(1, size * 0.07), height: size)
                // Spans y 19…91 against a baseline at 80, so 11 of its 72 points hang below
                // the baseline. Without this the stack would align its bottom to the baseline
                // and the rule would sit a sixth of its height too high.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * (11.0 / 72.0) }
                .padding(.horizontal, size * 0.30)

            Text("Flotilla").font(brandFont).foregroundStyle(appInk)
        }
        // One label for the lockup: a name, not five fragments read out in turn.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("melonfleet Flotilla")
    }

    /// The `o` of melonfleet, as a watermelon slice seen end-on.
    ///
    /// Radii are the SVG's 18.5 / 15.4 / 13 against 72pt type, expressed as fractions of
    /// `size` so the melon tracks the letters at any scale. Seeds sit at the same relative
    /// offsets. Drawn with concentric circles rather than an image so it stays crisp and
    /// theme-aware.
    private var melon: some View {
        let diameter = size * (18.5 * 2 / 72)
        let seedSize = CGSize(width: size * (1.1 * 2 / 72), height: size * (1.7 * 2 / 72))
        return ZStack {
            Circle().fill(melonGreen)                                  // rind
            Circle().fill(pith).frame(width: diameter * (15.4 / 18.5))    // pith
            Circle().fill(flesh).frame(width: diameter * (13 / 18.5))     // flesh
            // Three seeds: one above centre, two below, per the SVG's coordinates.
            seed(seedSize).offset(y: -diameter * (8 / 37))
            seed(seedSize).offset(x: -diameter * (6 / 37), y: diameter * (2.5 / 37))
            seed(seedSize).offset(x: diameter * (6 / 37), y: diameter * (2.5 / 37))
        }
        .frame(width: diameter, height: diameter)
        // The melon stands in for a letter, so it sits on the baseline like one. In the SVG
        // its centre is at y 61 with r 18.5, putting its lowest point at 79.5 against a
        // baseline of 80 — half a point of overshoot, the same trick every typeface uses so a
        // round letter does not read as short beside a flat-bottomed one.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + size * (0.5 / 72.0) }
    }

    private func seed(_ size: CGSize) -> some View {
        Ellipse().fill(seedInk).frame(width: size.width, height: size.height)
    }
}
