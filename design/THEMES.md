# Themes

**Status: specified and built 26 September 2026; twelve themes and the matte finish 5 October.** Code: `Sources/Flotilla/ThemePalette.swift` (the twelve
themes), `Theme.swift` (the tokens), `ThemePicker.swift` (Settings), and `LightTheme`/`DarkTheme` in
`FlotillaCore`.
The palette's source of truth is [`branding.md`](branding.md). This file decides how the palette is applied.

## The rule

**A theme changes exactly two things: the toolbar (window bar) and the body (content background).**
Everything else is fixed per appearance, the same in every theme:

| Fixed element | Light | Dark |
|---|---|---|
| Charts, graphs, sparklines | one set | one set |
| Status: online, success, danger, warning, info | one set | one set |
| Tag colours (7) | one set | one set |
| Links | the macOS link colour (`NSColor.linkColor`) | the same, which adapts itself |
| Buttons | standard macOS: neutral grey; the default (Return) button uses the **system accent** | the same |
| Sidebar selection, row selection, focus rings | the **system accent** set in System Settings, as in System Settings itself | the same |

The brand stays on the toolbar, the body, charts and status colours, the wordmark and the app icon.
Everywhere else, Flotilla looks and behaves like standard macOS.

## The themes

**Four bars, the same four everywhere** (the owner, 26 September — revised the same day from a
first draft of three light and three dark). Each theme is named after its bar, and the bar is the
same brand colour in every row; only the body changes.

| Theme | Bar | Bar ink | Light body | Dark body |
|---|---|---|---|---|
| **Stripe** | stripe `#7CB342` | seed | cream `#FBF7F0` | seed `#241F1A` |
| **Flesh** | flesh `#FC4A6B` | seed | cream | seed |
| **Cantaloupe** | cantaloupe `#EE7B4D` | seed | cream | seed |
| **Canary** | canary `#F2C94C` | seed | cream (the bar's existing divider separates them) | seed |
| **Stripe Honeydew** *(light only)* | stripe | seed | honeydew wash `#E5F4DC` (honeydew at 30% over white) | — |
| **Flesh Honeydew** *(light only)* | flesh | seed | honeydew wash | — |
| **Cantaloupe Honeydew** *(light only)* | cantaloupe | seed | honeydew wash | — |
| **Canary Honeydew** *(light only)* | canary | seed | honeydew wash | — |

**Twelve themes: three rows of four, one background per row** (the owner, 5 October). Light has a
cream row and a honeydew row; dark has one row on seed. Each row holds the same four bars in the same
order, and the picker lays them out four to a row, so every bar sits above its own honeydew form.
This replaced the first honeydew step earlier the same day (six light: two honeydew themes added
beside four with mixed bodies). It moved **Stripe off the wash**, where it had been since it was
built, so the old Stripe is now Stripe Honeydew. It also moved **Canary off white**.

The honeydew row is light-only: every dark body is seed, so a dark form would only repeat the dark
row. It comes from the owner's design references: pastel commuter tumblers with a saturated lid over a
pastel body and a thin rim between, which maps onto bar, body and divider. A theme is named after its
bar, plus "Honeydew" when its body is the wash. `LightTheme` and `DarkTheme` are separate types, so
the dark setting cannot hold a light-only theme.

**Defaults:** Cantaloupe for light, Flesh for dark — the look the app shipped with. Both pickers
offer every theme in their row, so choosing Stripe for both is a valid pair.

**Every bar takes seed ink.** White measures 2.5:1 at best on these four bars (stripe), under the
4.5:1 the wordmark needs; seed holds 4.9:1 at worst (flesh). The ink is still a per-theme value in
`ThemePalette`, so a future bar that needs white is one line.

Raised panels and hairlines do **not** vary by theme: every light body works under white cards and
every dark theme shares seed. Dark cards are seed lifted 6% towards white, `#312D28`.

## The matte finish

**Every theme's bar and body are the brand colour with 15% of its OKLCH chroma removed** (the owner,
5 October). The colours stay the same hues, just softer, like the powder-coated tumblers the themes
come from, and the app looks less bright. Lightness is kept, so every contrast figure below moves by
0.06 at most. The tables above name the brand tokens; this is what the window draws:

| Token | Brand | Matte (drawn) |
|---|---|---|
| stripe | `#7CB342` | `#82B155` |
| flesh | `#FC4A6B` | `#EF5C72` |
| cantaloupe | `#EE7B4D` | `#E4825C` |
| canary | `#F2C94C` | `#EDCA67` |
| cream | `#FBF7F0` | `#FAF7F1` |
| honeydew wash | `#E5F4DC` | `#E6F3DF` |
| seed (dark body) | `#241F1A` | `#231F1B` |

- **Bar and body only.** The bar ink stays brand seed, so text is as dark as it can be. Status, chart,
  tag and link colours are fixed per appearance, as before, and are not finished.
- **Not a setting.** It is the look, the same for every theme.
- **Chosen from screenshots.** Five finishes were captured for Cantaloupe, Stripe and Flesh in light
  and dark (`~/melonfleet/experiments/matte-2026-10-05/`, outside the repo):
  - chroma −15%;
  - chroma −30%;
  - a static grain texture;
  - chroma −15% with grain;
  - a frosted bar.

  Frost was ruled out: in dark it dropped seed ink on the bar to 3.3–4.1:1, under the 4.5 the
  wordmark needs. The owner picked chroma −15% without grain.
- The conversion is `OKLab` in `FlotillaCore`, and `OKLabTests` pins every value in this table.

## Choosing a theme

- **Settings → Appearance** has two pickers: **Light theme** and **Dark theme**. Each shows every
  theme as a clickable **sketch**: a miniature window with the theme's toolbar, body, two or three
  sample rows and a status dot, with the current choice marked.
- The **Appearance mode** (Auto, Light, Dark) is unchanged. **Auto switches between the chosen
  light and dark themes.** Choosing only a light theme is fine: the dark picker keeps its default.
- The choice applies live, with no relaunch, and is saved in preferences. The install defaults are
  **Cantaloupe** (light) and **Flesh** (dark).
- Precedent: VS Code's preferred light and dark colour themes.

## Measured contrast (5 October 2026, with the matte finish)

WCAG ratios. Text needs 4.5:1; non-text marks, such as status dots and chart lines, need 3:1.

| Theme | Bar ink (seed) | Bar vs body | Weakest status colour on body |
|---|---|---|---|
| Stripe, light (cream) | 6.5 | 2.4 | success 3.2 |
| Flesh, light (cream) | 5.0 | 3.1 | success 3.2 |
| Cantaloupe, light (cream) | 6.0 | 2.6 | success 3.2 |
| Canary, light (cream) | 10.3 | **1.5** (relies on the divider) | success 3.2 |
| Stripe Honeydew | 6.5 | 2.2 | success 2.94 |
| Flesh Honeydew | 5.0 | 2.8 | success 2.94 |
| Cantaloupe Honeydew | 6.0 | 2.4 | success 2.94 |
| Canary Honeydew | 10.3 | **1.4** (closest pair; relies on the divider) | success 2.94 |
| All four, dark | 5.0–10.3 | 5.0–10.3 | danger 5.2 |

The status column depends only on the body, so each row shares one figure. Re-measured on
5 October to two decimal places, **success on the honeydew wash is 2.94:1** (2.95 before the
matte finish). That is a hair under
the 3:1 a status mark needs; it had been recorded as 3.0. It is not fixed here: deepening
success changes it in every theme, so it is a separate decision.

Two measurements shaped the design. **Full-strength honeydew hid the green status colours**
(online 2.5:1, success 2.1:1), which is why Stripe's light body is a 30% wash. And **white bar ink
failed** on every bar, which is why the ink is seed.

**Fixed with themes:** light-mode `warning` `#E5A100` failed 3:1 on **every** light body, including
the one the app always shipped with. It is now `#A87600`, the same hue deepened; its worst case, the
honeydew wash, holds 3.5:1.

## Rules this changes or keeps

- **Retired:** "pink is brand and selection". Selection now follows the system accent.
- **Kept:** pink is never an error colour. Green means running and healthy, which is why buttons
  never take the Stripe bar's colour.
- **Kept:** every colour is a dynamic `NSColor`, so no appearance is frozen into another.

## Implementation notes

- Almost all colour already flows through `Sources/Flotilla/Theme.swift`: about 20 tokens and 250
  uses. The only hardcoded colours outside it are 8 in `Wordmark.swift`. The work is making
  `titleBar`, `onTitleBar`, `contentBackground` and the surfaces derived from the body read the
  selected theme; every other token stays as it is.
- **Delete `Resources/Assets.xcassets/AccentColor.colorset`** so AppKit's sidebar selection, table
  selection and focus rings follow the system accent. Brand `.tint(Theme.accent)` calls move to
  system defaults. `accentText` and `accentTint` get reassigned during the build: they need a
  per-use review, not a blind swap.
- The theme identifiers and their settings keys belong in `FlotillaCore` settings, Foundation-only;
  the colours stay in the app target.
- Verify every screen in all twelve variants (eight light, four dark) on a real launch before
  shipping.
