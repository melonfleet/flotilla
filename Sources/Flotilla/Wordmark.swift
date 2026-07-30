import SwiftUI

/// The **melonfleet | Flotilla** wordmark.
///
/// Rendered natively rather than shipped as an image, and that is a deliberate refusal rather
/// than a shortcut. `design/brand/logos/melonfleet-flotilla.svg` opens with:
///
/// ```
/// @import url('https://fonts.googleapis.com/css2?family=Ubuntu:wght@500&display=swap')
/// ```
///
/// Flotilla's whole settings and diagnostics story is built on *no telemetry, no account, no
/// phone-home*, with an About view that lists every network destination. Shipping a logo that
/// fetches a font from Google would make that claim false — for a decorative asset, on every
/// launch. It would also render as Helvetica on any Mac without the font, so the fidelity it
/// promises is not even reliable.
///
/// Drawn as text instead: no network, crisp at any size, correct in light and dark without two
/// assets to keep in step, and real selectable text for VoiceOver rather than an image needing
/// a label.
///
/// The two brand SVGs supply the spec this matches — `Ubuntu` Medium, the pink `#FC4A6B` pipe
/// separating the suite name from the app name, near-black `#241F1A` on light and cream
/// `#FBF7F0` on dark.
struct Wordmark: View {
    /// Cap height of the type, in points. Everything else scales from it.
    var size: CGFloat = 15

    @Environment(\.colorScheme) private var colorScheme

    /// `#241F1A` on light, `#FBF7F0` on dark — from `design/brand/BRAND.md`.
    private var ink: Color {
        colorScheme == .dark
            ? Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xF0 / 255)
            : Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)
    }

    /// Watermelon flesh. The one accent, per `DECISIONS.md` item 11 — no second palette.
    private var accent: Color {
        Color(red: 0xFC / 255, green: 0x4A / 255, blue: 0x6B / 255)
    }

    /// Ubuntu Medium when present, falling back to the system font at the same weight rather
    /// than to something arbitrary. The fallback is legible and on-weight; it simply is not
    /// the brand face, which is the honest trade for not bundling a font yet.
    private func brandFont(_ weight: Font.Weight) -> Font {
        if NSFont(name: "Ubuntu Medium", size: size) != nil {
            return .custom("Ubuntu Medium", size: size)
        }
        return .system(size: size, weight: weight)
    }

    var body: some View {
        HStack(spacing: size * 0.34) {
            Text("melonfleet")
                .font(brandFont(.medium))
                .foregroundStyle(ink.opacity(0.75))
            Text("|")
                .font(brandFont(.medium))
                .foregroundStyle(accent)
            Text("Flotilla")
                .font(brandFont(.semibold))
                .foregroundStyle(ink)
        }
        // One label for the whole lockup: read as a name, not as three fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("melonfleet Flotilla")
    }
}
