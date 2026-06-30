# Flotilla — branding

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

## Roles in the UI

- **Pink = brand / selection / highlight** — selected host, key/identity accents,
  emphasis. Tint bg `#FFE3EA`, text `#C2185B`/`#E63956`.
- **Green = healthy / running / online** — running badges, online dots, OK status.
  Tint bg `#E8F5E9`, text `#2E7D32`.
- Keep data surfaces (the container cards) neutral; use the watermelon colours for
  chrome, status, and accents only — same rule as Liquid Glass (functional layer,
  not content). Seeds/black for text on light fills as usual.

Both watermelon colours earn a job (pink = brand, green = health), so the palette
reads as intentional rather than decorative.
