# Themes

**Status: specified 26 September 2026. Not yet built.**
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

## The six themes

Themes are **named after their toolbar colour**. The toolbar text colour belongs to the theme.

| Appearance | Name | Toolbar | Toolbar text | Body |
|---|---|---|---|---|
| Light | **Cantaloupe** *(default)* | cantaloupe `#EE7B4D` | seed | cream `#FBF7F0` |
| Light | **Rind** | rind `#1B5E20` | white | honeydew wash `#E5F4DC` (honeydew at 30% over white) |
| Light | **Canary** | canary `#F2C94C` | seed | white `#FFFFFF`, **with a divider line under the toolbar** |
| Dark | **Flesh** *(default)* | flesh `#FC4A6B` | seed | seed `#241F1A` |
| Dark | **Rind** | rind `#1B5E20` | white | seed `#241F1A` |
| Dark | **Cantaloupe** | cantaloupe `#EE7B4D` | seed | seed `#241F1A` |

Surfaces derived from the body (raised panels, hairlines) are computed per body, not hand-picked, so
every theme stays consistent.

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

| Theme | Toolbar text | Body text | Weakest status colour on body |
|---|---|---|---|
| Light Cantaloupe | 5.9 | 19.7 | warning **2.1** ✗ (existing issue; see below) |
| Light Rind (wash) | 7.9 | 18.3 | success 3.0, online 3.6 (warning aside) |
| Light Rind (full honeydew) | 7.9 | 12.9 | online **2.5**, success **2.1** ✗: **why the body is a wash** |
| Light Canary | 10.3 | 21.0 | warning 2.2 (toolbar to body only 1.6, hence the divider) |
| Dark Flesh | 4.9 | 16.3 | danger 5.2 |
| Dark Rind | 7.9 | 16.3 | danger 5.2 (toolbar to body only 2.1: subdued, but deliberate) |
| Dark Cantaloupe | 5.9 | 16.3 | danger 5.2 |

**Fix this before building themes:** light-mode `warning` `#E5A100` fails 3:1 on **every** light body,
including today's. Replace it with a deeper amber that passes on cream, the honeydew wash and white.

## Rules this changes or keeps

- **Retired:** "pink is brand and selection". Selection now follows the system accent.
- **Kept:** pink is never an error colour. Green means running and healthy, which is why buttons
  never take a rind toolbar's colour.
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
- Verify every screen in all six themes, on a real launch, before shipping. Six themes means six
  full passes.
