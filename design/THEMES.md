# Themes

**Status: specified and built 26 September 2026.** Code: `Sources/Flotilla/ThemePalette.swift` (the six
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

**Four themes, the same four in light and dark** (the owner, 26 September — revised the same day
from a first draft of three light and three dark). Each is named after its bar, and the bar is the
same brand colour in both appearances; only the body changes.

| Theme | Bar | Bar ink | Light body | Dark body |
|---|---|---|---|---|
| **Stripe** | stripe `#7CB342` | seed | honeydew wash `#E5F4DC` (honeydew at 30% over white) | seed `#241F1A` |
| **Flesh** | flesh `#FC4A6B` | seed | cream `#FBF7F0` | seed |
| **Cantaloupe** | cantaloupe `#EE7B4D` | seed | cream `#FBF7F0` | seed |
| **Canary** | canary `#F2C94C` | seed | white `#FFFFFF` (the bar's existing divider separates them) | seed |
| **Canary Honeydew** *(light only)* | canary `#F2C94C` | seed | honeydew wash `#E5F4DC` | — |
| **Flesh Honeydew** *(light only)* | flesh `#FC4A6B` | seed | honeydew wash `#E5F4DC` | — |

**Six light themes, four dark** (5 October). The two honeydew themes are light-only: every dark body
is seed, so a dark form would only repeat dark Canary or dark Flesh. They come from the owner's design
references, pastel commuter tumblers whose saturated lid sits over a pastel body with a thin rim
between, which maps onto bar, body and divider. A theme is named after its bar, plus its body when
that body is not the bar's usual one. `LightTheme` and `DarkTheme` are separate types so the dark
setting cannot hold a light-only theme.

**Defaults:** Cantaloupe for light, Flesh for dark — the look the app shipped with. Both pickers
offer all four, so choosing Stripe for both is a valid pair.

**Every bar takes seed ink.** White measures 2.5:1 at best on these four bars (stripe), under the
4.5:1 the wordmark needs; seed holds 4.9:1 at worst (flesh). The ink is still a per-theme value in
`ThemePalette`, so a future bar that needs white is one line.

Raised panels and hairlines do **not** vary by theme: every light body works under white cards and
every dark theme shares seed. Dark cards are seed lifted 6% towards white, `#312D28`.

## Choosing a theme

- **Settings → Appearance** has two pickers: **Light theme** and **Dark theme**. Each shows every
  theme as a clickable **sketch**: a miniature window with the theme's toolbar, body, two or three
  sample rows and a status dot, with the current choice marked.
- The **Appearance mode** (Auto, Light, Dark) is unchanged. **Auto switches between the chosen
  light and dark themes.** Choosing only a light theme is fine: the dark picker keeps its default.
- The choice applies live, with no relaunch, and is saved in preferences. The install defaults are
  **Cantaloupe** (light) and **Flesh** (dark).
- Precedent: VS Code's preferred light and dark colour themes.

## Measured contrast (26 September 2026)

WCAG ratios. Text needs 4.5:1; non-text marks, such as status dots and chart lines, need 3:1.

| Theme | Bar ink (seed) | Bar vs body | Weakest status colour on body |
|---|---|---|---|
| Stripe, light | 6.5 | 2.2 | success 3.0 |
| Flesh, light | 4.9 | 3.1 | success 3.2 |
| Cantaloupe, light | 5.9 | 2.6 | success 3.2 |
| Canary, light | 10.3 | 1.6 (hence the divider) | success 3.4 |
| Canary Honeydew, light | 10.3 | **1.4** (closest pair; relies on the divider) | success 3.0 |
| Flesh Honeydew, light | 4.9 | 2.9 | success 3.0 |
| All four, dark | 4.9–10.3 | 4.9–10.3 | danger 5.2 |

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
- Verify every screen in all eight variants (four themes, light and dark) on a real launch before
  shipping.
