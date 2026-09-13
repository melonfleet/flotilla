# Flotilla — branding

> **Part of the melonfleet suite.** The canonical brand system — full palette (incl.
> the melon spectrum), Ubuntu / Open Sans / Ubuntu Mono type, `dev.melonfleet.*`
> identifiers, and the logo set — lives in `../../brand/BRAND.md`. This file covers only
> **Flotilla's product specifics**: its three-sails watermelon icon and its signature
> accent (watermelon flesh + rind). Everything else is inherited from the suite.

## Concept

A flotilla of sails over a **watermelon slice**: pink flesh field, green rind base,
white pith line, three white sails, black seeds. Playful, personal, and distinct
from Docker's blue whale.

## Icon

- App icon: `design/icon-app.svg` (watermelon slice + white sails, in a macOS
  squircle). On macOS 26, build it as a layered Liquid Glass icon — sails/seeds on a
  translucent tier over the pink flesh, with the rind base.
- Menu-bar: `design/icon-menubar.svg` — monochrome three-sails template
  (`currentColor`) so it adapts to light/dark menu bars. On a tinted background use
  the rind green `#1B5E20` with flesh/white sails.

## Palette

| Role | Name | Hex |
|------|------|-----|
| Rind (deep green) | `rind` | `#1B5E20` |
| Stripe (light green) | `stripe` | `#7CB342` |
| Healthy / running (green) | `success` | `#2E7D32` |
| Online dot | `online` | `#43A047` |
| Pith / sails (white) | `pith` | `#FFFFFF` |
| Flesh (pink-red) | `flesh` | `#FC4A6B` |
| Flesh light | `flesh-light` | `#FF8AA3` |
| Flesh deep / brand text | `flesh-deep` | `#E63956` |
| Seed (near-black) | `seed` | `#241F1A` |

### Chrome and accent (added 2026-09-13)

The window bar is a solid brand colour and the app's accent matches it, so the
chrome and the highlights read as one surface rather than a coloured strip laid
over someone else's window. The suite doc carries the rule; this is Flotilla's
assignment of it.

**These are not new colours.** Every one is an existing suite token — the change
is which job each does, not what the palette contains.

| Role | Token | Light | Dark |
|------|-------|-------|------|
| Window bar | `titleBar` | `cantaloupe #EE7B4D` | `flesh #FC4A6B` |
| Accent — selection fills, links, prominent buttons | `accent` | `cantaloupe #EE7B4D` | `flesh #FC4A6B` |
| Accent as small type | `accent-text` | `#B4501F` | `flesh-light #FF9BB2` |
| Content ground | `contentBackground` | `cream #FBF7F0` | `#171C14` (derived) |
| On the window bar — wordmark, glyphs | `on-title-bar` | `pith #FFFFFF` | `pith #FFFFFF` |

Light and dark take **different hues**, which is the one place this palette
deliberately does not simply lighten or darken a single value.

Notes that are load-bearing rather than descriptive:

- **Dark's accent is `flesh`**, the melon's own centre. So in dark mode the bar,
  the selected row and the one warm note in the logo are the same colour.
- **`accent-text` is not the accent.** `cantaloupe` measures about 2.4:1 on
  `cream` and cannot carry small type; the burnt tone can. Never set small text in
  the accent itself. It is the one value here with no suite token yet — if a second
  product needs it, it becomes one.
- **The accent lives in two places and both must move together.** `Theme.accent`
  colours what SwiftUI draws; `Resources/Assets.xcassets/AccentColor.colorset`
  colours what *AppKit* draws — sidebar-list selection and focus rings, which
  ignore SwiftUI's `.tint()`. Changing one and not the other is how the selected
  navigation row stayed pink while the rest of the app went orange.
- **A borderless `Menu` paints its label with the accent and ignores
  `foregroundStyle`.** Once the accent matches the bar, any such control *on* the
  bar needs an explicit `.tint`, or it renders the bar's colour on the bar's
  colour and disappears while still working.

## Roles in the UI

- **Accent = brand / selection / highlight** — the selected navigation row, links,
  prominent buttons, the window bar. See the table above for the hue, which is no
  longer pink on light.
- **Green = healthy / running / online** — running badges, online dots, OK status.
  Tint bg `#E8F5E9`, text `#2E7D32`.
- **Pink stays the melon's.** `flesh` is still the logo's centre and dark mode's
  accent; it is no longer the light-mode brand colour.
- Keep data surfaces (the container cards) neutral; use the watermelon colours for
  chrome, status, and accents only — same rule as Liquid Glass (functional layer,
  not content). Seeds/black for text on light fills as usual.

Each colour earns a job — accent = brand and selection, green = health — so the
palette reads as intentional rather than decorative.

## Tag palette (added 2026-09-13)

Finder-style tags carry a **fixed seven-colour palette**, and it is deliberately *not* the brand
palette:

| Tag | Light | Dark (derived) |
|---|---|---|
| Red | `#C9302C` | `#F2635F` |
| Orange | `#E07B39` | `#F59A76` |
| Yellow | `#D9A200` | `#F5C242` |
| Green | `#4C8C2B` | `#7CB342` |
| Blue | `#3A6EA5` | `#82AEDC` |
| Purple | `#7B4FA8` | `#B693DA` |
| Grey | `#77777C` | `#9EA09B` |

**This is the one place plain blue and purple are allowed**, and the exception is argued rather
than assumed. The standing rule — no `--sys-blue`, the brand has a teal — is about colours
*Flotilla* assigns to mean something: a chart series, a status dot. A tag's colour is chosen by
the user and has to be recognisable as "the blue one" across a table of forty rows. Finder's
swatches are the vocabulary people already have for that, so matching them is worth more here
than brand consistency is. The values are pulled slightly towards the app's own saturation so a
row of pills does not read as a screenshot of a different application, and the dark values are
lifted until each holds its hue on `#171C14` while staying distinguishable from its two
neighbours in the wheel.

Seven, and no eighth. A tag is something you recognise in half a glance, which only works while
the whole vocabulary fits in visual memory; an open colour well gives you two greens you cannot
tell apart at 8pt.

**Tags are drawn as pills, never as a tinted row or card.** The pill is additive — it says one
more thing about a row without taking anything the row already said. Colouring a whole card would
put an arbitrary hue behind a state dot, a name and four values, so a container tagged
"Production" would read as *alarming* rather than as tagged. The dot carries the colour at full
strength and the capsule at 16% alpha, so a pill stays legible on white, on the raised card
surface and on a selected row.
