# Flotilla research — design/UX

Scope: menu-bar interaction, popover vs window, main-window layout, list/detail/card views,
status indicators, iconography, onboarding/first-run, empty states, notifications, dark mode,
accessibility, and what "native Mac" plus `reference/liquid-glass.md` imply. Surveyed:
**OrbStack** (closest native-Mac analogue), **Docker Desktop**, **Podman Desktop**,
**Rancher Desktop**, and **Tailscale's macOS app** (the best available model for a
menu-bar app that manages a *fleet*), plus Apple's HIG/`MenuBarExtra` platform rules.

---

## 1. What the comparables do

### OrbStack (native Swift/SwiftUI, macOS-only — the closest analogue)

- **Native app, no Electron.** Written in Swift (with Rust/Go/C components); marketed on
  "low CPU and disk usage, battery-friendly, native Swift app", starts in ~2s. Its docs say
  the GUI has "near feature parity with Docker Desktop, but with a much simpler interface…
  it feels right at home on macOS."
- **Window with a source-list sidebar** — Containers / Images / Volumes / K8s / Machines.
  Containers tab is a list; selecting a row reveals actions in a **right-hand sidebar**
  (`Logs`, `Files`, Debug Shell), rather than a full-page detail with tab bar.
- **Menu-bar applet is a real control surface, not a launcher.** Documented feature list
  (docs.orbstack.dev/menu-bar): start/stop/restart/delete containers **and Compose projects
  as a group or individually**; open logs; open terminal; **open web service in browser**;
  view and open **port forwards and bind mounts**; **copy info — ID, image, address/domain**;
  start previously-stopped containers "from anywhere". Machines: stop/restart, open terminal,
  **open files in Finder**. Toggleable in Settings.
- **Files integration** — container filesystems are browsable from macOS/Finder rather than
  in a bespoke in-app file browser.
- **`orb.local`** serves an index page of running containers with automatic domain names —
  discovery of "what's running and where do I click".
- **Complaints worth noting:** menu-bar container list shows Docker's generated names
  (`condescending_ramanujan`), so users can't tell what's what — issue #691 asks for custom
  titles/tooltips/image names in the menu. Issue #2276: on macOS 26 the menu-bar icon silently
  didn't appear because of **System Settings → Menu Bar → "Allow in the Menu Bar"**; the user
  spent a week thinking the app was broken.

### Docker Desktop (Electron; the feature-richest, and the most complained-about)

- **Left nav** — Containers, Images, Volumes, Builds, Kubernetes, Logs, Extensions. Nav is
  **right-click → Customize** to show/hide/reorder tabs (a tell that the IA is overloaded).
- **⌘K quick search** (added 4.15) across local containers/Compose apps, local images, **and
  the Docker Hub API**, with **actions inline in the result row**: start/stop/delete, view
  logs, open a terminal, peek env vars.
- **Containers view = table**, grouped by Compose project. Columns sortable, **resizable by
  dragging header dividers**, hideable; **multi-select checkboxes** for bulk cleanup (promoted
  out from behind a "bulk clean up" button in 4.15). Inline CPU/memory-over-time per row.
- **Detail = full page with a tab bar**: **Logs** (real-time, search with match highlight,
  timestamp toggle, copy/clear), **Inspect** (low-level JSON: image SHA, port mapping, env,
  mounts), **Bind mounts**, **Exec/Debug** (interactive shell = `docker exec -it`), **Files**
  (browse running *and stopped* containers, badges for recently added/modified/deleted,
  built-in editor, drag-and-drop both directions, right-click delete, download to host),
  **Stats** (CPU/memory/network/disk over time).
- **Tray "whale menu"**: Dashboard, Sign in/Sign up, Settings, Check for updates, Troubleshoot,
  Give feedback, About, Docker Hub, Documentation, Extensions, Kubernetes, Restart, Quit.
  The tray icon animates during start-up and a status strip turns green when the engine is up.
- **Anti-patterns users report:** the "You can do more when you sign in" banner reappeared on
  every window open (for-mac #7715; Docker said it's gone in 4.44 — *(verify)*); on macOS Tahoe
  the GUI wouldn't reopen after ⌘Q and the menu-bar item was dead, requiring `pkill`
  (for-mac #7833, fixed 4.73 — *(verify)*); ⌘Q semantics ("does this quit the UI or the
  engine?") changed and confused long-time users; menu-bar icon simply missing (#7682).

### Podman Desktop (Electron/Svelte; the best *onboarding* and *empty-state* work)

- **Onboarding.** Welcome screen → "Start onboarding". The redesign (issue #17316) is a
  **3-step wizard**: (1) welcome + **Recommended vs Advanced** setup, telemetry opt-in
  checkbox, "Skip entire setup" link with a confirm dialog; (2) **platform preflight checks**
  (macOS: CPU, RAM, macOS version) as a **collapsible checklist with pass/fail icons**, with
  **inline remediation actions** on failure and Next disabled until checks pass; (3) machine
  creation form (sliders for CPU/memory/disk) → **progress view with spinner + collapsible,
  searchable log viewer** → success checkmark; then CLI-tool installs reusing the same
  progress/log pattern; then a success screen with **two CTAs** ("Start your first container",
  "Look at your system overview"). Shared shell: left rail with step progress (checkmark +
  strikethrough done, bold active, dimmed future) and contextual tips. *(design in progress —
  verify what shipped)*
- **List filtering as a text grammar.** Containers page has **Running / Stopped tabs that
  literally insert `is:running` / `is:stopped` into the filter field**, and typing that text
  moves the tab. Search text survives tab switches. Grouped containers (pod/Compose) show
  `2 containers (1 filtered)`.
- **Empty states are components with actions.** `EmptyScreen` = icon/title/message/detail/
  command-line, plus a slot for a **primary button** (PR #8651: pull `quay.io/podman/hello`
  and start it, with a tooltip spelling out what the button will do). Empty state is **adapted
  per tab**, and when the list is empty *because of a filter* the button is **Clear filter**
  (which strips the search term but preserves `is:running`).
- **Detail tabs:** Summary, Logs, Inspect, Kube, Terminal. Row **⋮ overflow menu** for logs,
  terminal, restart, export, deploy-to-k8s. Bulk start and bulk delete from selection. Prune button.
- **Chrome:** resizable left nav (48–240 px, `preferences.navigationBarWidth`), **back/forward
  navigation with a long-press history dropdown**, a **status bar with pinned items**
  (`statusBar.pinnedItems`, default `["podman"]`), experimental task widget + tasks in the
  status bar, experimental title-bar search.
- **Theme & a11y:** `preferences.appearance` = system/dark/light, plus **high-contrast light and
  dark themes and accent colors** (1.27), full-colour tray icons. Open a11y workstream:
  "**status indicators accessible without hover**" (#12908), "dynamic OS theme adaptation for
  system tray" (#9360), titles/aria-labels on notification cards (#13478), keyboard focus for
  links in container details (#17611), WCAG 2.1 AA as a stated target.

### Rancher Desktop (Electron; the best *diagnostics* surfacing)

- **Containers table** columns: State (running sorted first by default), Name, Image,
  **Port(s) — clickable to open the localhost URL**, Started; all sortable; **Filter field
  top-right**; bulk selection; **action buttons at the top of the page enable/disable based on
  the selected container's state** (Stop/Start/Delete); per-row **⋮** with state-appropriate
  actions plus logs. Logs view auto-scrolls and has a search box.
- **Images tab:** `Add Image` button top-right opens **Pull / Build tabs**; Trivy **Scan**
  produces a severity-sorted vulnerability summary with expandable rows; namespace dropdown.
- **Diagnostics as a nav item with a badge.** Checks run at every launch; the **count of failed
  checks appears next to "Diagnostics" in the left nav**; the page explains each failure and
  guides a fix; individual checks can be **muted**; there's a **re-run** button.
- **Troubleshooting page** with Show Logs / Reset Kubernetes / Factory Reset. Tray menu offers
  "Open cluster dashboard".

### Tailscale for macOS (menu-bar app that manages a fleet — closest to Flotilla's *shape*)

- **They tried menu-bar-only and publicly documented why it failed.** From their beta post:
  "Menu bar dropdowns don't allow us to easily convey information through changes in shape or
  colour. They can't include a search bar… They are not great for discovery either: we
  constantly get the feedback that some of our most loved features are hidden, like Taildrop
  and ping."
- **So: a windowed app that runs *alongside* the menu-bar app** (v1.88 opt-in, default from
  1.96.2). It provides a **searchable device list with connection status**, per-device detail
  with actions (copy MagicDNS name/IP, ping, Taildrop), an **exit-node browser with latency and
  a recommended pick**, a **red dot on the Dock icon for critical errors**, a **"mini player"**
  compact mode, and a **product tour on install/update**.
- **Popover redesign**: sectioned into **This Device / My Devices / Shared Devices / Exit Nodes
  / Quick Actions**, with per-device OS icons, last-seen timestamps, connection-type indicator,
  full native dark mode, full keyboard navigation (previously a flat scrollable list).
- **Deliberate scope boundary:** "We want the Mac app to still be a *client* only, and not an
  admin tool." Fleet-wide/admin actions link out to the admin console with an ↗ affordance.
  **Settings stays a separate window** reachable four ways (menu-bar → Settings…, app menu,
  ⌘, and a gear icon).
- **Notch occlusion:** they use `occlusionState` to detect that their menu-bar icon is hidden
  inside the MacBook notch (macOS gives no overflow, no notification, no reordering) and steer
  users to the windowed app. A menu-bar icon is not a guaranteed entry point.

### Apple platform rules (HIG + `MenuBarExtra`) — the constraints we actually have to obey

- **HIG, menu bar extras:** menu bar height is 24 pt; use a **template symbol (black + clear
  only)** so the system can tint it for light/dark menu bars and for the selected state;
  **"Display a menu — not a popover — when people click your menu bar extra. Unless the app
  functionality you want to expose is too complex for a menu, avoid presenting it in a
  popover."**; **let people decide** whether the extra is in the menu bar (a Settings toggle,
  optionally offered during setup); **don't rely on the extra being present** — the system
  hides/shows extras and you can't predict position; **also expose functionality elsewhere,
  e.g. a Dock menu**, which is always available while the app runs.
- **`NSStatusBar` docs:** "always provide a user preference for hiding your application's
  status items."
- **`MenuBarExtra`:** `.menu` style = standard dropdown; **`.menuBarExtraStyle(.window)`** =
  popover-like window for "more complex or data rich" extras, dismissing on outside click.
  `LSUIElement = true` removes Dock icon and ⌘-Tab presence — but **an app that only lives in
  the menu bar is auto-terminated if the user removes the extra**.
- **Known `MenuBarExtra` friction** *(verify against macOS 26.x + Swift 6.3 before designing
  around it)*: `.window` content is size-constrained (community reports ~half screen width);
  `SettingsLink`/`openSettings` are unreliable from a `MenuBarExtra`, and on Tahoe the
  environment action reportedly does nothing without an existing render tree; you must call
  `NSApp.activate(ignoringOtherApps: true)` immediately before `openWindow` or secondary
  windows appear behind the frontmost app. Escape hatch if we hit a wall:
  `NSStatusItem` + `NSPopover`, or an `NSPanel` (`.nonactivatingPanel`,
  `becomesKeyOnlyIfNeeded`, `.floating`, `.canJoinAllSpaces`, `animationBehavior = .utilityWindow`)
  hosting SwiftUI via `NSHostingView`.
- **Liquid Glass** (`reference/liquid-glass.md`): glass is the **functional layer** only —
  toolbars, sidebars, transient UI, control clusters; never the content layer; a single glass
  layer per ZStack; group nearby glass in a `GlassEffectContainer`; `glassEffectID` to morph.
- **Adjacent data point:** "Davit", a native SwiftUI GUI for Apple `container` (Show HN,
  Dec 2025), drew exactly two UX requests in the thread — "does it also come with a menubar
  integration?" and "would love to be able to open a Dockerfile directly in the UI to
  build/run it" — plus a note that SwiftUI settings text fields felt wrong. Useful signal about
  what this specific audience notices first.

---

## 2. Patterns worth stealing

1. **Menu-bar extra *plus* a real window, with the window as the primary UI.** Tailscale's
   published post-mortem is the strongest evidence available: dropdowns can't show state through
   shape/colour, can't hold a search field, and hide features. Flotilla already plans both
   surfaces — the lesson is to keep the popover deliberately shallow and put fleet work in the
   window, not to grow the popover.
2. **⌘K quick search with actions in the result row** (Docker 4.15). At 8 hosts × N containers,
   typing `pg` and hitting Return beats navigating a sidebar. Already in PLAN's stack.
3. **Filter tabs that are sugar over a text filter grammar** (Podman `is:running`). One mental
   model for mouse and keyboard, it round-trips, and it extends naturally to the fleet:
   `host:mini-01`, `image:postgres`, `state:stopped`.
4. **Contextual detail tabs** (Docker/Podman/OrbStack all converge): Summary, Logs, Inspect,
   Stats, Terminal, Files. Convergence this strong means users arrive with the expectation
   pre-installed; we should meet it and only ship the tabs `container` can actually back.
5. **Preflight/diagnostics as first-class UI with inline remediation and a re-run button**
   (Podman step 2 + Rancher's badge-on-nav Diagnostics). Flotilla *needs* this: `container`
   may be missing, the API service may not be started, and a fresh install needs
   `container system kernel set --recommended` before anything works. This is our single
   highest-value onboarding steal.
6. **Long operations get a progress view with a collapsible, searchable log** (Podman machine
   create; Rancher/Docker pulls). Applies directly to the `.pkg` install, `image pull`
   (which has `--progress`), and `build`.
7. **Empty states that carry the primary action, varied per context** (Podman `EmptyScreen`):
   no containers → "Run a container"; no images → "Pull image"; empty *because filtered* →
   "Clear filter". We need a fleet-specific one too: "No hosts yet → Add a host".
8. **Action buttons enable/disable from the selected row's state, plus a per-row ⋮ overflow**
   (Rancher). Avoids dead controls and keeps the toolbar small.
9. **Table with sortable/resizable/hideable columns + multi-select bulk actions** (Docker 4.15,
   Rancher, Podman). Cards look great in a mockup and stop scaling somewhere around 20 rows.
10. **Clickable ports/addresses that just open the thing** (Rancher's Port column, OrbStack's
    domains). Cheapest big win available: `status.networks[].ipv4Address` and
    `configuration.publishedPorts` are already in the JSON we decode.
11. **A Copy submenu** (OrbStack: ID, image, address/domain). Add **"Copy `container` command"**
    for CLI parity — this audience lives in the terminal and will trust a GUI more if it shows
    its work.
12. **Never show a generated identifier as the primary label** (OrbStack #691). Always
    name + image + host. Our name is `configuration.id`; the image is
    `configuration.image.reference`.
13. **Explicit client-vs-admin scope boundary** (Tailscale). Host mode should be a *status*
    surface, not a second full app — that also keeps the host-mode binary's UI cheap.
14. **Fingerprint comparison dialog for pairing** (deskflow's `FingerprintDialog`, Proxmox PDM's
    certificate-confirmation dialog, TLS trust prompts generally): show **both** fingerprints
    side by side with fixed roles and labels, include **hostname/IP** next to each so the user
    can tell *which* machine they're trusting, and on a **changed** certificate show **old and
    new** with a warning rather than silently re-prompting. Exactly Phase 2's need.
15. **Product tour on first launch and after updates** (Tailscale) / release-notes banner
    (Podman). Cheap discovery for features that are otherwise invisible.
16. **Dock badge / icon state for critical errors** (Tailscale's red dot). Our menu-bar glyph
    should encode fleet health, and if the window is open the Dock icon should too.
17. **High-contrast themes, status legible without hover, full keyboard nav** (Podman's a11y
    workstream, including their own bug "accessible status display without hover dependence").
18. **Template monochrome menu-bar glyph** (HIG; `design/icon-menubar.svg` already is one).

---

## 3. Anti-patterns / things to avoid

- **Colour-only status.** Green/grey dots alone fail for colour-blind users, VoiceOver, and
  high-contrast mode. Podman filed this against themselves (#12908). Every dot needs an
  adjacent label and/or a distinct SF Symbol shape.
- **Treating the menu bar as the primary UI.** The system hides extras, the notch swallows them
  with no overflow and no notification (Tailscale's `occlusionState` workaround), the user may
  have "Allow in the Menu Bar" off in System Settings (OrbStack #2276), and HIG explicitly says
  don't rely on presence. Anything reachable *only* from the popover is effectively hidden.
- **Burying real features in the popover.** Tailscale's own words: Taildrop and ping were
  "most loved" and undiscovered because they lived in a dropdown.
- **Undescriptive labels in the menu list** (OrbStack #691) — generated names, truncated
  images, no host qualifier. In a *fleet* app, "nginx" without a host is ambiguous by construction.
- **Nag banners and sign-in gates.** Docker's "You can do more when you sign in" reappearing on
  every window open (#7715) is the single most-cited Docker Desktop UX complaint. Flotilla has
  no account; keep it that way and don't invent a substitute (no upsells, no "rate us", no
  re-appearing tips).
- **Ambiguous quit semantics.** Docker's ⌘Q ("quits the dashboard but not the daemon", then
  changed behaviour, then couldn't reopen — #7833) burned trust. For Flotilla, quitting the
  client must never stop containers or host mode, and the menu item should say so
  ("Quit Flotilla — containers keep running").
- **A dead menu-bar item / unreopenable window after closing.** Docker on Tahoe needed
  `pkill`. Our close/reopen path (menu bar → Open Flotilla, Dock menu, ⌘-click, re-launch)
  must be tested explicitly, including with `LSUIElement` on.
- **Importing web-app conventions into a native app.** Custom title bars, hover-only
  affordances, non-native scrolling/selection, bespoke context menus, no keyboard focus ring.
  OrbStack's whole pitch is that it doesn't do this — and HN's reaction to Davit ("Native
  feeling, no Electron") shows the audience checks.
- **Nav sprawl requiring a "Customize nav" feature** (Docker). If we need that, the IA is
  already wrong. Cap top-level navigation at three or four items.
- **A blocking wizard with no way out.** Podman disables Next until all preflight checks pass —
  and had to add "Skip entire setup". If `container` isn't installed, Flotilla should still open
  in a read-only/explanatory state rather than trapping the user in a modal.
- **Charts that imply live data they don't have.** `container stats` returns **cumulative**
  `cpuUsageUsec`, so CPU% requires two samples and a wall-clock delta; there's no push feed
  until Phase 4's persistent connection. Don't render a moving sparkline off a 5-second poll
  across 8 remote hosts — it's both a lie and a bandwidth/battery cost.
- **A fake terminal.** Docker's Exec tab is a shell-ish text box, and people notice. Either
  wire a real PTY through `container exec -it` or don't ship the tab.
- **Feature creep from the Linux ecosystem**: image vulnerability scanning (Rancher/Trivy),
  extension marketplaces (Docker), Kubernetes views (already rejected in DECISIONS.md).
- **Modal dialogs inside a popover.** The popover dismisses on outside click; anything
  destructive or multi-step must escalate to a window or sheet first.

---

## 4. → Proposed for Flotilla

Legend: **[core]** = v1, **[later]**, **[skip]**. Phase numbers refer to PLAN.md.
Items that change or extend `PLAN.md` / `DECISIONS.md` / `design/dashboard-mockup.html`
are flagged **⚠**.

### Phase 1 — Local MVP (the UI foundation)

- **[core] Two surfaces: `MenuBarExtra(.window)` popover + main window (`NavigationSplitView`).**
  Popover is a *glanceable status + quick actions* surface only. **⚠ Deviates from HIG's
  "display a menu, not a popover"** — justified because per-host status dots, counts, and
  running-container rows genuinely exceed what an `NSMenu` can express (HIG's own escape
  clause), and Tailscale demonstrates the sectioned-popover pattern for exactly this shape of
  app. Mitigation: no text entry, no dialogs, no destructive confirmations in the popover.
- **[core] Popover contents (fixed order):** header line "This Mac · N running" (Phase 3 adds
  the fleet rollup) → running containers with inline start/stop and name + image + host →
  divider → `Open Flotilla` (⌘O), `Run…`, `Settings…` (⌘,), `Quit Flotilla — containers keep
  running`. Sectioned like Tailscale (This Mac / Fleet / Offline) once Phase 3 lands.
- **[core] Menu-bar glyph = monochrome three-sails template** (`design/icon-menubar.svg`,
  `.renderingMode(.template)`), with **state expressed by shape/badge, not colour**: idle,
  working (subtle animation during a long op), attention (badge when something failed or a host
  is unreachable). HIG's black+clear rule keeps it correct on light/dark/tinted menu bars.
- **[core] "Show Flotilla in: Menu bar / Dock / Both" setting.** Required by HIG and the
  `NSStatusBar` docs, and it defuses the `LSUIElement` trap (a menu-bar-only app is terminated
  when the user removes the extra). **⚠ Extends PLAN.md's "menu-bar app" framing:** the window
  must be reachable without the extra.
- **[core] Main-window IA, three top-level items max:** sidebar = **Fleet** (This Mac, then
  hosts — Phase 3 fills it) ; content = **Containers** / **Images**; detail = inspector pane
  with tabs. Resist a fourth tab; Volumes/Networks/Registries live inside a single **System**
  page instead (they're `container volume|network|registry list` and rarely touched).
- **[core] ⚠ Container list is a table by default, cards as an alternate view.** Columns:
  State · Name (`configuration.id`) · Image · Host · Ports · CPU/Mem · Started. Sortable,
  resizable, hideable; running-first default sort (Rancher); multi-select for bulk stop/delete.
  The card grid from `design/dashboard-mockup.html` becomes a **"Cards" view toggle** — it's a
  lovely 4-container dashboard and a poor 40-container list. **This changes the mockup's
  premise; needs sign-off.**
- **[core] Filter grammar + tabs.** `All / Running / Stopped` tabs that insert
  `is:running` / `is:stopped` into the search field (Podman), plus `host:`, `image:`, and free
  text. Search field in the toolbar, ⌘F focuses it.
- **[core] Status vocabulary grounded in real JSON.** Drive from `status.state`
  (`running`, `stopped`, …) and add app-level states the CLI can't report: *starting*,
  *action failed*, *host unreachable*, *untrusted host* (Phase 2). Render as
  **dot + SF Symbol + text label**, never dot alone. Palette per `design/branding.md`:
  green `#2E7D32`/`#43A047` = running/online, neutral grey = stopped, pink `#FC4A6B` reserved
  for brand/selection — **so pink must not double as an error colour**; use the system's
  semantic red/orange for failures. **⚠ Small extension to branding.md** (it assigns pink and
  green jobs but doesn't define an error colour).
- **[core] Empty states with a primary action, varied by context** (Podman): no containers →
  "Run a container" + a one-line explainer of what will happen; no images → "Pull image";
  nothing matches the filter → "Clear filter" (preserving `is:` tabs); `container` not
  installed → the preflight card, not an empty list.
- **[core] Preflight / first-run as a checklist, not a wall.** Checks in order:
  `container` binary present → version vs latest → `container system status`
  (`"unregistered"` means the service is down) → Linux kernel installed. Each row shows
  pass/fail with an **inline remediation button** ("Install container…", "Start service",
  "Install recommended kernel"), plus a **Re-run** button (Rancher's Diagnostics model) and a
  **badge on the nav item** while anything fails. The guided `.pkg` install runs with user
  authorization and shows the progress+log sheet. **A "Continue anyway" path leaves the app
  usable read-only** — do not trap the user in a modal (Podman had to add exactly this escape).
  Consistent with DECISIONS.md's "never a silent privileged install".
- **[core] Progress sheet for long operations** — `.pkg` install, `image pull`
  (has `--progress`), `build`, `export`: determinate bar where the CLI gives one, spinner
  otherwise, **collapsible + searchable log**, Cancel, and "keep running in background".
- **[core] Logs view:** follow toggle, tail-N selector, search with highlight + match count,
  timestamps toggle, wrap toggle, jump-to-bottom, copy/save, monospace (Ubuntu Mono per the
  brand). **Plus a `--boot` toggle** — micro-VM boot logs are a `container`-specific
  diagnostic no comparable has, and they're the first thing you want when a container won't start.
- **[core] Row context menu + Copy submenu:** ID, name, image reference, IPv4 address,
  published port URL, and **"Copy `container` command"** (CLI parity, and it teaches the CLI).
- **[core] Clickable ports/addresses** → open `http://<ip>:<port>` in the browser (Rancher/OrbStack).
- **[core] Destructive-action policy:** confirm on delete with the object named and a
  "Don't ask again" checkbox; bulk delete says how many; **no confirmations inside the popover**
  (escalate to the window). Nothing here is undoable, so wording carries the weight.
- **[core] Dark mode as a first-class pass**, using the mockup's token pairs promoted into an
  asset catalog; verify in Light, Dark, Increase Contrast, and Reduce Transparency (the last
  one matters because Liquid Glass degrades to opaque). Follow the system appearance only —
  **[skip]** an in-app theme picker and accent-colour engine (Podman's approach): macOS already
  owns this, and a custom picker is a permanent maintenance tax.
- **[core] Accessibility baseline:** every control keyboard-reachable in a sane order; VoiceOver
  labels that state status in words; no hover-only affordances (Podman #12908); visible focus
  rings; respect Reduce Motion (kill the glass morphs) and Reduce Transparency; standard
  shortcuts (⌘, ⌘F ⌘R ⌘W ⌘K, Space to peek); Dynamic-Type-ish scaling doesn't break the table.
  Cheap now, near-impossible to retrofit.
- **[core] Liquid Glass placement, per `reference/liquid-glass.md`:** glass on the popover
  chrome, window toolbar, sidebar surface, and the Run/Pull control cluster (grouped in one
  `GlassEffectContainer`); **container cards and the table stay standard opaque surfaces**;
  never glass-on-glass. Check legibility over a busy desktop picture before committing.
- **[core] ⌘K command palette** over hosts, containers, images, and actions
  (Docker 4.15's model, minus the Hub search). In PLAN's stack already; if Phase 1 gets tight,
  slip to Phase 3 when the fleet makes it indispensable.
- **[later] Sparklines on cards.** `container stats` gives cumulative `cpuUsageUsec`, so
  Phase 1 ships a **numeric CPU%/mem cell from a two-sample delta**; the moving sparkline waits
  for Phase 4 streaming. **⚠ The mockup shows sparklines** — this defers that detail.
- **[later] Dockerfile → build/run from the UI** (drag a Dockerfile onto the window; the one
  concrete feature request in the Davit HN thread). Rancher's Add Image → Pull/Build tab pair
  is the shape to copy.

### Phase 2 — Host mode + client mode over mTLS

- **[core] Add-host sheet with two paths in one place:** discovered-by-Bonjour list (live,
  with a spinner and a "not seeing your Mac?" hint) **and** "Add manually" (hostname/IP + port).
  Manual is mandatory per DECISIONS.md, so it must be a peer of discovery, not a hidden
  fallback.
- **[core] Pairing dialog with side-by-side fingerprints** (deskflow/Proxmox pattern):
  fixed roles (this Mac on the left, the host on the right), **hostname + IP under each**, the
  SHA-256 rendered in short grouped hex *and* a word/emoji derivation for eyeball comparison,
  and explicit **Trust / Cancel**. On a **changed** fingerprint show old vs new with a real
  warning and default to Cancel. Never auto-trust, never silently re-prompt.
- **[core] Trust management view** (Settings → Hosts): the Keychain-backed allowlist as a list
  with host, fingerprint, date added, last seen, and **Revoke**. Pink = key/identity accents,
  per branding.md.
- **[core] Host-mode UI is deliberately minimal** — a status window plus its own menu-bar item:
  listening address/port, Bonjour advertising on/off, allowlist count, last client + timestamp,
  a rolling list of recently executed commands, and a big obvious "Stop accepting connections".
  **No container management UI in host mode.** **⚠ Extends DECISIONS.md's "one app, two modes,
  headless-ish"** with an explicit UX rule, borrowed from Tailscale's client-not-admin boundary.
- **[core] Mode switch in Settings** with a plain-language consequence explainer and a confirm
  ("Host mode lets allowlisted Macs run containers here"). Never switchable remotely.
- **[core] Per-host connection states with distinct visuals:** online / connecting /
  unreachable / **untrusted** / version-mismatch. "Untrusted" must not look like "offline" —
  they need different fixes.
- **[later] Notification categories designed now, shipped Phase 3:** host went offline,
  container exited non-zero, pairing request from an unknown cert, update available. Per-category
  toggles, coalesced (never one per container in a restart storm), and **zero** promotional
  notifications. **⚠ PLAN.md doesn't mention notifications at all** — this adds them.

### Phase 3 — Fleet view

- **[core] Fleet sidebar per the mockup:** "All hosts" aggregate row with total count, then one
  row per host with a status dot + container count, offline hosts dimmed with "—". Plus the
  mode/keys footer already in the mockup.
- **[core] Aggregate header rollup** ("6 hosts online · 14 containers"), **clickable to filter**
  rather than being decoration.
- **[core] Host detail page:** `container system version`, `system df` disk usage, service
  status, container/image counts, last-seen, fingerprint, and per-host actions (prune, restart
  service).
- **[core] Group-by-host in the container list** (Podman's group headers with
  "N containers (M filtered)" counts) so the flat fleet list stays legible.
- **[core] Menu-bar glyph badge when any host is unreachable or a container is crash-looping**,
  plus a red dot on the Dock icon while the window is open (Tailscale).
- **[core] Cross-host search and bulk actions** (stop all on host X) — the ⌘K palette should
  accept `host:` scoping.
- **[later] Sidebar sections and custom host display names** (This Mac / Fleet / Offline;
  drag to reorder). Custom names pre-empt the OrbStack #691 legibility problem for hostnames
  like `mac-mini-3.local`.
- **[later] Dock menu mirroring the popover essentials** — HIG recommends it precisely because
  the menu-bar extra can vanish into the notch.
- **[skip] "Mini player" compact window** (Tailscale). Redundant: our popover already is that.

### Phase 4 — Live streaming + exec

- **[core, this phase] Live logs/stats over the persistent connection**, and only then real
  sparklines + a **Stats tab** (CPU/mem/net/disk) with Swift Charts. Ship a **sampling-interval
  setting** and **pause streaming when the window is hidden** — 8 hosts × per-second stats is a
  battery and bandwidth cost with no user visible in front of it.
- **[core, this phase] Exec terminal tab with a real PTY** (`container exec -it`), with
  reconnect and a copy-transcript action — or don't ship the tab at all (Docker's half-terminal
  is a known irritant).
- **[later] Restart/health policy UI:** per-container policy picker, health-check definition,
  and a history timeline. Because `container` has **no** native `--restart` or healthcheck
  (DECISIONS.md: we implement it), the UI must say so — a policy that silently only applies
  while Flotilla is running would be a trust-destroying lie.
- **[later] Files tab** built on `container cp`: read-only browse + download first; editing and
  drag-and-drop (Docker's version) only if it proves useful.
- **[skip for now] Compose-like multi-container grouping.** `container` has no compose; the
  honest version is grouping by label, and it's not worth Phase 1–4 attention.

### Phase 5 — Auto-updates

- **[core, this phase] Sparkle UX:** "Check for Updates…" in both the popover and Settings, an
  automatic-check toggle with a **first-run consent prompt** (never silently phone home),
  release notes rendered in the update dialog, and clear failure messaging.
- **[later] "What's New" sheet after an update** (Tailscale's product tour; Podman's
  release-notes banner) — with a dismissal that actually sticks, unlike Docker's sign-in banner.

### Phase 6 — Jamf / configuration profiles

- **[core, this phase] Managed-settings presentation:** any setting delivered by a
  configuration profile renders **disabled with a lock glyph and a "Managed by configuration
  profile" note**, and the pairing/cert UI is hidden entirely when the identity arrives via
  profile. Mirrors how Docker/Podman surface admin-managed settings, and prevents "why won't
  this toggle move" support loops with yourself.

### Explicit skips

- **[skip] Accounts / sign-in / upsell banners** (Docker). Personal app; and it's the most
  complained-about thing in the whole survey.
- **[skip] Telemetry opt-in dialog** (Podman step 1). No telemetry → one fewer onboarding step.
  (The operations study owns the decision; the UX consequence is ours.)
- **[skip] Image vulnerability scanning UI** (Rancher/Trivy) — no runtime support, large surface.
- **[skip] Extensions/marketplace** (Docker) — inconceivable for an 8-node personal fleet.
- **[skip] Kubernetes views** — already rejected in DECISIONS.md.
- **[skip] Customizable/reorderable nav tabs** (Docker) — a symptom of IA sprawl; we cap nav at
  three or four items instead.
- **[skip] A web dashboard / `orb.local` equivalent.** Would mean an HTTP server on every host,
  contradicting DECISIONS.md's mTLS-only transport. If the "what's running where" index proves
  valuable, it belongs in the app's own fleet view.
- **[skip] In-app theme/accent picker** — follow the system.
- **[later, only if blocked] `NSStatusItem` + `NSPopover` / `NSPanel` instead of
  `MenuBarExtra(.window)`.** Start with the SwiftUI scene; graduate only if we hit the
  documented walls (popover size limits, Settings-window activation, click-vs-right-click
  differentiation). **⚠ Implementation detail not covered by DECISIONS.md** — worth recording
  once we've tested on macOS 26.x, since the whole app layer hangs off it.
