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

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Palette — straight from the two SVGs

    /// `#1B5E20` on light, `#7CB342` on dark.
    private var melonGreen: Color {
        colorScheme == .dark
            ? Color(red: 0x7C / 255, green: 0xB3 / 255, blue: 0x42 / 255)
            : Color(red: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255)
    }
    /// `#241F1A` on light, `#FBF7F0` on dark — the app name.
    private var appInk: Color {
        colorScheme == .dark
            ? Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xF0 / 255)
            : Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)
    }
    /// `#6E675C` on light, `#C7BFB2` on dark. A warm grey rule — **not** the pink accent.
    private var rule: Color {
        colorScheme == .dark
            ? Color(red: 0xC7 / 255, green: 0xBF / 255, blue: 0xB2 / 255)
            : Color(red: 0x6E / 255, green: 0x67 / 255, blue: 0x5C / 255)
    }
    private let flesh = Color(red: 0xFC / 255, green: 0x4A / 255, blue: 0x6B / 255)
    private let seedInk = Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)

    /// Ubuntu Medium when installed, falling back to the system font at the same weight. The
    /// fallback is legible and on-weight; it simply is not the brand face, which is the honest
    /// trade for not bundling a font yet.
    private var brandFont: Font {
        NSFont(name: "Ubuntu Medium", size: size) != nil
            ? .custom("Ubuntu Medium", size: size)
            : .system(size: size, weight: .medium)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("mel").font(brandFont).foregroundStyle(melonGreen)
            melon
            Text("nfleet").font(brandFont).foregroundStyle(melonGreen)

            // The SVG's rule: 5pt wide and 72pt tall against 72pt type, with 22pt of air
            // either side. Kept proportional so it stays a rule and never reads as an "l".
            RoundedRectangle(cornerRadius: size * 0.035)
                .fill(rule)
                .frame(width: max(1, size * 0.07), height: size)
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
            Circle().fill(.white).frame(width: diameter * (15.4 / 18.5))  // pith
            Circle().fill(flesh).frame(width: diameter * (13 / 18.5))     // flesh
            // Three seeds: one above centre, two below, per the SVG's coordinates.
            seed(seedSize).offset(y: -diameter * (8 / 37))
            seed(seedSize).offset(x: -diameter * (6 / 37), y: diameter * (2.5 / 37))
            seed(seedSize).offset(x: diameter * (6 / 37), y: diameter * (2.5 / 37))
        }
        .frame(width: diameter, height: diameter)
        // The melon stands in for a letter, so it sits on the text baseline rather than being
        // centred against the line box — otherwise it floats above the word.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - diameter * 0.16 }
    }

    private func seed(_ size: CGSize) -> some View {
        Ellipse().fill(seedInk).frame(width: size.width, height: size.height)
    }
}
