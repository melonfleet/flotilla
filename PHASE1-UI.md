# Phase 1 UI — build contract

The engine is done: `FlotillaCore` exposes **20 tested operations** and a settings registry.
The UI reaches almost none of it. This closes that gap by building the **approved design**
in `research/review/mockups/` (open those first — they are the spec, not decoration).

## The one hard constraint — read this before writing a line

**You cannot compile SwiftUI on your VM.** `Package@swift-6.1.swift` deliberately excludes
the macOS app target so the Foundation-only core stays Linux-testable. So for this task you
are writing code you cannot build, and **the app owner compiles and runs it on the Mac**.

That means: be conservative. Prefer plain, obvious SwiftUI over clever. Match the idioms
already in `Sources/Flotilla/` exactly. Do not invent APIs — if you need something from
`FlotillaCore`, check it exists first (`grep "public func" Sources/FlotillaCore/*.swift`).
A guessed API name costs a whole round-trip.

You **can** still run `swift build && swift test` to prove you have not broken the core.

## What already exists (build on it, do not duplicate)

- `Sources/Flotilla/FlotillaApp.swift` — `MenuBarExtra` + `Window`, `AppDelegate` shim.
- `Sources/Flotilla/AppModel.swift` — `@MainActor @Observable`. Has `state` (`idle/loading/
  unavailable/loaded/failed`), `containers`, `busy`, `actionError`, `preflight`,
  `refresh()`, `reload()`, `runPreflight()`, `perform(_:on:)`, `isRunning(_:)`.
- `Sources/Flotilla/MainWindowView.swift` — table + cards + search + view toggle + context menu.
- `Sources/Flotilla/MenuBarView.swift` — the popover. **Leave it alone.**

`ContainerCLI` operations available now: `listContainers listImages listVolumes listNetworks
stats systemStatus versions start stop restart remove run pull removeImage createVolume
removeVolume createNetwork removeNetwork logs`.

## Navigation contract — BOTH of you code against this

the core owner creates it; the CLI owner codes against it without editing it.

```swift
// Sources/Flotilla/Navigation.swift  (the core owner)
enum Section: String, CaseIterable, Identifiable, Hashable {
    case containers, images, volumes, networks, settings
    var id: Self { self }
    var title: String { ... }        // "Containers", "Images", …
    var systemImage: String { ... }  // SF Symbol
}
```

The window becomes a `NavigationSplitView`: sidebar lists `Section.allCases`, detail switches
on the selection and renders that section's root view. Each section's root view is a
**separate file** so the two of you never edit the same one.

Every screen follows the same shape as `MainWindowView`: a toolbar row, then a `switch` on
load state that distinguishes **loading / unavailable / empty / loaded** — never render an
empty list for a failed load.

---

## CORE OWNER — shell, settings, volumes, networks

1. **`Navigation.swift`** — the enum above. Small, do it first.
2. **`MainWindowView.swift`** — convert to `NavigationSplitView` with the sidebar, and route
   to each section's root view. Move the existing container table/cards into
   `ContainersView.swift` unchanged (the CLI owner then extends that file — so do this early and
   keep it mechanical).
3. **`SettingsView.swift`** — the real payoff for your registry work. Render the settings
   grouped, honouring the two-tier model: a **locked** setting shows a padlock and is
   disabled (`isLocked(key)`), a `defaults`-seeded one is editable. Include the appearance
   control (Light / Dark / Auto).
4. **`VolumesView.swift`** and **`NetworksView.swift`** — list with create and delete, using
   `listVolumes/createVolume/removeVolume` and `listNetworks/createNetwork/removeNetwork`.
   Destructive actions confirm first.

## CLI OWNER — containers, images, detail

1. **`ContainersView.swift`** (after the core owner moves it) — bring it up to the mockup:
   - filter tabs **All / Running / Stopped** alongside the existing search
   - a **bulk action bar** when rows are multi-selected (the `selection` state already
     exists and is currently unused) — Start / Stop / Restart / Delete on the selection
   - extra columns: **ports** and **created**, from `Container.configuration`/`status`
   - the table currently renders empty placeholder rows when nearly empty — set a sensible
     row count/`.frame` so it does not look broken with one container
2. **`ContainerDetailView.swift`** — a detail pane or sheet for the selected container:
   overview (image, id, state, ports, network, created) plus a **Logs** tab backed by
   `cli.logs(id, lines:)`. Live streaming and exec are Phase 4 — a bounded fetch with a
   Reload button is correct for now.
3. **`ImagesView.swift`** — list via `listImages`, with **Pull image…** (prompt for a
   reference) and delete. Show repository, tag, and size where the model has them.

---

## Rules
- Add UI only in `Sources/Flotilla/`. Do **not** change `FlotillaCore` — if you need
  something from it that is missing, say so in your report rather than adding it.
- Every action goes through `AppModel` → `ContainerCLI`. A view must **never** build an argv
  or call a host directly; that is what keeps the Allowlist meaningful.
- Reuse `AppModel.busy` and `actionError` for in-flight and failure states.
- Nothing may hardcode `preferredColorScheme` — appearance is the user's choice.
- Run `swift build && swift test` to confirm the core still passes (114 tests).
- Do **not** run git. Report what you built, and anything you had to guess.
