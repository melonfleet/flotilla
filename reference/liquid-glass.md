# Liquid Glass in SwiftUI (macOS 26) — Flotilla UI notes

Flotilla targets macOS 26 only, so it uses the real Liquid Glass APIs (not faux
cards). Reference for the UI layer.

## Core APIs

- `.glassEffect()` — applies the regular variant in a Capsule by default.
- `.glassEffect(.regular)` / `.glassEffect(.clear)` — variants.
- `.glassEffect(.regular, in: .rect(cornerRadius: 12))` / `in: .capsule` / `in: .circle`
  — specify the shape (use rounded-rect for the container/sidebar cards).
- `GlassEffectContainer { … }` — wrap multiple glass elements so they share one
  sampling region and can merge/morph. Glass can't sample other glass, so group
  nearby glass pieces in a container instead of stacking them.
- `.glassEffectID(_:in:)` — links elements so SwiftUI can morph between them in
  animations.

## Design rules (Apple)

- Glass belongs to the **functional layer** — controls, navigation, toolbars,
  transient UI. **Never** the content layer (the container grid's data stays plain).
- Use a **single** glass layer in a given ZStack; don't stack glass on glass.
- Group multiple glass controls inside a `GlassEffectContainer`.

## Where Flotilla uses it

- Menu-bar popover chrome and the main-window toolbar / sidebar surfaces.
- The fleet sidebar host rows and the "Run / Pull image" control cluster.
- The container **cards themselves are content** — keep them as standard surfaces
  (the mockup look), not glass, so data stays legible.

## App icon

Build the watermelon icon as a layered macOS 26 icon: sails/seeds on a translucent
glass tier over the pink flesh, with the green rind base (see `design/icon-app.svg`
for the flat reference, `design/branding.md` for the palette). The menu-bar extra
uses the monochrome three-sails template (`design/icon-menubar.svg`, `currentColor`).

## Sources

- [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [Glass](https://developer.apple.com/documentation/swiftui/glass)
- [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [LiquidGlassReference (community)](https://github.com/conorluddy/LiquidGlassReference)
