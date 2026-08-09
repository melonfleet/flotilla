# Flotilla — project guide for Claude Code

You are helping build **Flotilla**, a native macOS app that manages Apple's
`container` CLI on the local machine and across a fleet of remote Apple Silicon
Macs.

This is a **personal, non-commercial** project. Read `DECISIONS.md` before changing
product or security direction, `PHASE1.md` for the current build contract and
ownership, `research/FEATURES.md` for the consolidated phase-ordered scope, and
`PLAN.md` for the six-phase roadmap. Settled decisions are not open design
questions.

## Project status (2026-08-01)

- `FlotillaCore` is real and substantial. Foundation-only, and contains:
  - `container` JSON models pinned to **real captured output** — see the fixture
    warning below;
  - `ContainerHost`, `LocalHost`, `CommandResult`;
  - `ContainerCLI`, now covering reads **and** mutations: run, start, stop, kill,
    restart, remove, prune, inspect, logs, images (pull/tag/delete/prune),
    volumes, networks, `system df`;
  - the Q1 `Allowlist` and host-path `MountPolicy` boundary. `MountPolicy` is
    injectable at `ContainerCLI.init` — it used to be hardcoded, which left Phase 2
    with no way to narrow it;
  - a typed settings registry with managed `defaults` + `locked` precedence;
  - `StatsSampler` (CPU deltas + bounded history), `JSONPrettyPrinter`, diagnostics
    snapshot, error log, redaction.
- The macOS app has a `MenuBarExtra` glance and a main window with Containers
  (sortable, hideable columns, per-row actions, context menus, cards with
  sparklines), Images, Volumes, Networks, Settings, a run sheet with a validated
  live command preview, and container detail **embedded in the window** with Overview /
  Processes / Logs / Terminal / Inspect / Configuration, a Back button and a prev/next
  stepper through the containers as currently filtered and sorted.
- **Machines** (the Linux micro-VMs containers run inside) is a peer section under a
  `Virtualisation` sidebar heading, built to the same shapes: list/cards toggle,
  state filter, hideable columns, row actions, a `ModalCard` create form, and an
  embedded detail with Overview / Shell / Logs / Settings / Inspect. Its view state
  lives in `MachinesUIState`, owned by `MainWindowView` — a section view is rebuilt on
  every sidebar change, so anything held as its own `@State` is lost. Machine
  terminals use a **second** `TerminalSessionStore`, because the store is keyed by a
  plain string and a machine named `web` would otherwise collide with a container
  named `web`. Read the `MACHINES-SPEC.md` addendum before touching the CLI calls.
- **Everything is embedded now — forms included** (9 August, the owner's call). This
  **reverses** the old "forms are modal, places are navigable" rule, and the newer
  argument is better: once Machines grew an embedded detail with Back and a tab strip, a
  floating card with a red × was the only surface in the app you left a different way.
  Run, New Machine, New Volume, New Network, Pull Image and Tag Image are all screens with
  `FormHeader` (Back, icon, title) and Save bottom-right. It also killed a real cost —
  every modal carried a hand-picked frame (560×680, 560×660, 440 wide) that copy had to be
  *trimmed to fit*, which is backwards.
  `ModalCard` survives for **About** and **Support Bundle** only: those are dialogs you
  acknowledge, not forms you fill in and save.
  Detail is embedded too, and always should have been —
  `research/review/mockups/container-detail.html` has the app sidebar in it. Detail went
  window → sheet → embedded over 1–2 August; the sheet cost resizability, height for the
  Terminal tab, and left the sidebar inert. Do not turn any of it back into a sheet.
- **216 tests pass on macOS.** `FlotillaCore` also builds and tests on Linux with
  Swift 6.1 via `Package@swift-6.1.swift`. Keep the portable core Foundation-only
  so backend and data work stays independently verifiable.
- **There is an app bundle now**, built by `Scripts/make-app.sh` — a real
  `dev.melonfleet.Flotilla` identity, Info.plist, icon and ad-hoc signature. This
  is **not** the Xcode migration; it is the cheap half. Four features were gated on
  it, not on missing code: notifications (`UNUserNotificationCenter` *crashes*
  without a bundle), the menu-bar/Dock setting (`LSUIElement`), launch at login
  (`SMAppService`), and signing hygiene. Xcode still owns notarization and Sparkle.
- **`LSUIElement` now ships `false`, and that is load-bearing** — see the launch
  lesson below. `Scripts/make-app.sh --menubar` flips it for testing.
- **Known limitation:** with *Show Flotilla in: Menu bar*, the Dock icon correctly
  disappears but a window still opens at login. `.suppressed`, `dismissWindow` and
  an AppKit `close()` were all tried and none held. Do not re-attempt without a new
  idea; the fix is probably a real `NSWindow` delegate once the Xcode project lands.
- Phase 2 networking is not implemented: no `Wire`, `RemoteHost`,
  Network.framework transport, mTLS listener, Bonjour, or persisted host policy
  store.

### The Terminal tab, and the one dependency

`container exec` supports `-i/--interactive` and `-t/--tty` and yields a **real PTY** —
verified against the live CLI, not the docs. Without a PTY on the calling side it fails
with "Operation not supported by device", so the terminal needs one; **SwiftTerm** (MIT)
supplies both that and the VT100 emulation. It is the only third-party dependency, is
attached to the **`Flotilla` target only**, and `Package@swift-6.1.swift` is untouched so
`FlotillaCore` still builds and tests on Linux.

This is **Phase 4 scope pulled forward** at the owner's request, not a quiet scope change.

The security shape matters more than the feature. `Allowlist` still refuses
`exec <id> sh` by default and must keep doing so — the permissive grammar is selected by
`ExecPolicy.interactiveShell`, which only a `ContainerCLI` built for the machine's own owner
carries. The same tokens over the Phase 2 wire are remote code execution on someone else's
Mac. `AppModel` sets the policy in one place; `TerminalTab` reads `model.cli.execPolicy`
rather than hardcoding it, so a CLI pointed at a remote peer makes the terminal refuse.

Note the separator trap: `exec` must never receive `--`, and `interactiveExec` uses
`.command` trailing — the very case that used to append one. That is now keyed on the
subcommand, with a test.

### Hard-won lessons — read before trusting anything here

Nine bugs of the same family, all invisible to a green test suite. The suite checked
that we *built* the right command; almost nothing checked the command was
*accepted*.

- **Fixtures must be captured, never written.** `volumes.json` and `networks.json`
  were fabricated flat shapes matching the models rather than the CLI. The real
  payloads nest under `configuration`/`status`, so `ContainerNetwork` decoded only
  `id`, and `ContainerVolume` *threw* the moment a volume existed. Tests were green
  throughout. Capture with the real CLI or leave the gap.
- **Exit codes must be checked.** `LocalHost.run` returned `exitCode` and an `ok`
  property nothing read, so every CLI failure was silent — a duplicate network, a
  failed start, a refused pull. `ContainerCLI.succeeding(_:)` now throws on
  non-zero.
- **The `Allowlist` must be at least as strict as the CLI.** `--publish` accepted a
  bare port the CLI refuses; `start` accepted 32 operands when the CLI takes one.
  A too-loose shape is the dangerous direction, and in Phase 2 that grammar faces a
  remote caller. `reference/cli-help/` holds captured `--help` for 49 subcommands —
  audit against it, not against docs, which have been wrong repeatedly.
- **the review's verdict stands:** the `Allowlist` is **not** trustworthy as the complete
  Phase 2 wire boundary yet (22 plugin-backed specs unverified). See
  `research/ALLOWLIST-AUDIT.md`.
- **A setting that drives nothing is worse than a missing one.** Appearance,
  presentation, poll interval and notifications were all inert; and no setting
  persisted at all, because `SettingsStore` is in-memory by design and the app layer
  never wrote `userValuesSnapshot()` anywhere.
- **Do not let SwiftUI infer whether the main window opens.** With an accessory
  activation policy at launch, SwiftUI never instantiates the `Window` scene at all
  — no window object, `onAppear` never fires, and a later switch to `.regular` does
  not build one. `setActivationPolicy` returns `true` throughout, so nothing looks
  wrong. The app came up as a menu-bar icon with nothing behind it for days.
  `defaultLaunchBehavior(.presented)` states it instead of guessing.
- **The same unchecked-result bug keeps recurring.** After `LocalHost.run`'s exit
  code: `NSApp.setActivationPolicy` returns a `Bool` that was discarded, so a
  refused policy change reported to nobody. And `UserDefaults(suiteName:)` was
  handed our *own* bundle identifier — AppKit rejects that out loud on every launch
  — returning nil, with `?? .standard` quietly doing the right thing. Correct by
  luck. When an API returns a result, read it; when a fallback carries the real
  behaviour, that is a bug waiting for someone to edit the line above it.
- **Verify the mechanism, not just the symptom.** Three attempts to suppress the
  menu-bar-only launch window each "worked" in a test that was confounded — the
  window was not appearing for an unrelated reason at the time. Always establish a
  known-good control before believing a fix.
- **Run the app.** The flicker, the dead Refresh, the useless columns and the
  fabricated fixtures were all found by using it, not by testing it.
- **Four more of the same family, in the `machine` leaves** (3 August). `machine run`
  was **absent from the `Allowlist` entirely** while both Start and the Shell tab
  used it, so neither had ever worked. `machine start` does not exist. `machine run`
  with no command needs a PTY and fails *after* booting the VM, so Start reported
  failure on a success. And `--home-mount` takes a bare `ro` on `create` but
  `home-mount=ro` on `set` — the allowlist demanded one and the UI sent the other, so
  the path could not succeed either way. The canonical-shape test was green
  throughout **because it asserted the same wrong spelling**. A test that encodes the
  grammar you guessed only proves you guessed consistently.
- **A picker whose options fail is worse than no picker.** The create form offered
  Ubuntu, Debian and Fedora. None of them boot as a machine; each pulls ~100 MB,
  creates a record, and dies. `research/MACHINES-SPEC.md` has the table. Offer what
  you have actually run.
- **Do not classify on one measurement.** A single probe said `alpine:latest` failed;
  it had not, the boot was still settling. That one data point would have removed a
  working option from the form.
- **`Scripts/make-app.sh` now refuses to package a screenshot scaffold.**
  `Scripts/check-defaults.sh` asserts the known-good `@State` defaults are present —
  Overview as the default detail tab, `.dashboard` as the sidebar selection, no
  pre-populated `detailTarget`, and so on. It asserts the *good* line is there rather
  than blacklisting bad ones, because a blacklist only catches the mistake already made.
  It has a negative control: reintroduce a scaffold and the packaging step fails.
- **A revert is not done until the running instance is replaced.** A temporary
  `showingCreate = true` scaffold was reverted, the bundle was rebuilt, and the check
  "binary is newer than every source file" passed — but the app was never relaunched,
  so the owner spent the next stretch with a create modal opening every time he clicked
  Machines. Reverting a scaffold means source, artefact **and** process. This is the
  second time a stale artefact has been mistaken for a code bug.
- **A note claiming a protection is a promise the code must keep.** The machine Inspect
  panel printed "Secrets are redacted" under `userSetup.username: example`. Every
  redaction rule matched a *path* (`/Users/<name>`); nothing matched a bare account
  field, so the host user's own name was displayed **and handed out by Copy JSON**.
  The docstring even named that field as the reason redaction mattered there. There is
  now a `.username` category, a rule, a detector and two tests — and bare `user` is
  deliberately *not* matched, because container config uses it for the runtime user.
  This is the third time a real username has escaped: twice into fixtures, once here.
- **A gauge that always reads full is worse than no gauge.** The dashboard reported
  memory at 96–98% permanently. The comment said the sum matched Activity Monitor; the
  code summed `active + inactive + wired + compressed`, and `inactive_count` is
  reclaimable file cache that Activity Monitor excludes. "Used" is **App Memory
  (`internal - purgeable`) + Wired + Compressed**. The panel also printed the total as
  "68.72 GB" because `ByteCountFormatter.file` is decimal and Apple counts RAM in binary
  units — 64 GiB is "64 GB" everywhere on the machine, so 68.72 invited the obvious
  question. Evidence in `Scripts/probes/memory-accounting.swift`, cross-checked against
  `top` at the same instant. Disk sizes stay decimal; the two conventions differ by
  medium and matching each beats picking one.
- **Share the mechanism, not the screenshot.** The machine Inspect tab shipped
  JSON-only because `InspectRow` and the flatten walk were `private` to
  `ContainerDetailView`. Both now use `InspectTable.swift`, so a fix to the walk cannot
  apply to one panel and not the other.
- **An untouched form is not a broken one.** The Run screen opened with two red
  validation errors — `'' isn't a valid imageReference` under the image field and the
  same sentence again under Preview — because the validator legitimately fails on an
  empty image and nothing distinguished "not filled in yet" from "wrong". Errors are
  now suppressed until the required field has content, and the field-level message and
  the preview message no longer duplicate each other. Same family as the machine form's
  red "Enter an image reference."
- **A default is a recommendation.** The machine create form defaulted to half the host,
  because `machine create` does — which on this Mac proposed **6 cores and 32 GB** for a
  scratch VM. Matching the CLI sounded principled and gave bad advice. 2 cores / 4 GB
  now; the steppers still reach the full host.
- **`case A, B where cond:` binds `where` to `B` only.** Written as
  `case .loaded, .loading where displayed.isEmpty:` the `.loaded` arm matched
  unconditionally, so the Machines list rendered "No matching machines" with two
  machines in the model. Swift accepts it without a warning. Repeat the clause on
  every pattern that needs it.

### Branding

**`design/brand/BRAND.md` is the source of truth for colour, not the mockups.** `Theme.swift`
used to be transcribed from `research/review/mockups/assets/mac.css`, whose token block names
its status colours `--sys-red`/`--sys-orange`/`--sys-blue` — macOS system colours, deliberately.
Transcribed faithfully, that put a **plain blue** on the dashboard, the one hue with no place in
a watermelon identity, while `BRAND.md` had a sanctioned teal `#2C7A7B` all along. Nobody had
reconciled the two documents. Semantic colours now quote `BRAND.md` exactly; dark-mode
counterparts it does not specify are *derived* and labelled as derived. The content column
carries a faint honeydew wash so it reads as a decision rather than as absent.

The approved watermelon language; light and dark are both first-class. Icons are
**generated** from the brand geometry by `Scripts/make-icons.swift`, and the
wordmark is **drawn** in SwiftUI (`Wordmark.swift`) rather than shipped as an
image — the brand SVGs contain
`@import url('https://fonts.googleapis.com/…')`, and an app that promises no
phone-home must not fetch a font. The menu-bar glyph is a monochrome **template**
image, so macOS inverts it for light and dark from one asset.

`Wordmark.swift` must match `design/brand/logos/melonfleet-flotilla{,-dark}.svg`
**element for element**, and the first version did not: it was built from a `grep`
of the SVG's colours instead of its structure, so "melonfleet" came out near-black
rather than green, the rule came out pink, and the `o` was an ordinary letter. The
`o` **is a watermelon** — rind, pith, flesh and three seeds — and that melon is the
whole identity. Read the geometry, not the palette.

Do not put personal identity, personal email addresses, credentials, local user
paths, private keys, certificates, or tokens into tracked files.

## Current and target architecture

```text
Flotilla.app / SwiftPM executable
├── FlotillaCore  (Foundation-only; shared by client and host modes)
│   ├── Models
│   ├── ContainerCLI
│   ├── ContainerHost
│   │   ├── LocalHost       → Process on this Mac
│   │   └── RemoteHost      → Phase 2 mTLS peer (not built)
│   ├── Allowlist           → default-deny command/argument schemas
│   ├── MountPolicy         → host bind-mount boundary
│   ├── Settings            → typed registry; defaults/user/locked precedence
│   ├── Diagnostics         → snapshot, error log, redaction
│   ├── Wire                → Phase 2 framing/messages (not built)
│   └── Transport           → Phase 2 Network.framework/mTLS (not built)
├── Client UI
│   ├── MenuBarExtra
│   ├── main window
│   └── cross-host container table
└── Stateful host runtime (Phase 2+; not built)
    ├── mTLS listener + Bonjour advertisement
    ├── certificate and peer allowlists
    ├── persisted policy/settings store
    └── local `container` execution after allowlist validation
```

`ContainerHost` is the execution spine: UI code must not construct raw commands
or care whether a host is local or remote. All commands must flow through
`ContainerCLI`, and every local or remote execution path must cross the
`Allowlist` and applicable `MountPolicy`.

The app is currently a SwiftPM executable. There is no Xcode project yet. Move to
an Xcode project when app-bundle metadata, `LSUIElement`, signing, notarization,
and distribution require it; do not document that migration as already done.

## Settled decisions — do not relitigate

The full reasoning and rejected alternatives are in `DECISIONS.md`. A newcomer
must preserve all of the following:

1. **Integration:** shell out to `container` and decode `--format json`; do not
   link the Containerization framework.
2. **Transport:** Network.framework + mTLS, with Bonjour and mandatory manual host
   entry. No system `ssh`, gRPC, generic remote shell, or Kubernetes.
3. **Product shape:** one app with client and host modes; host mode is
   **stateful**, with a persisted policy store.
4. **Wire shape (Q1):** args passthrough constrained by a default-deny subcommand
   allowlist and argument schemas. Enforce frame-length, concurrency, and deadline
   limits before spawning. Neither arbitrary command strings nor typed RPCs per
   CLI operation are the design.
5. **Primary view (Q2):** a running-first table; cards remain an alternate toggle.
6. **Managed settings (Q4):** two tiers now—`defaults` seed values users may
   change, and `locked` values that override and disable editing.
7. **Phase 1 scope (Q5/Q6):** the consolidated `research/FEATURES.md` scope,
   including volumes, networks, settings registry, security baseline,
   diagnostics/support bundle, and full per-category notifications.
8. **`config.toml` (Q7):** read in Phase 1, edit locally in Phase 3, and edit
   remotely only if evidence shows it is necessary.
9. **Identity (Q8):** bundle identifier and namespace root are fixed at
   `dev.melonfleet.Flotilla` / `dev.melonfleet.*`.
10. **Sandboxing (Q9):** no App Sandbox for v1. Hardened runtime, Developer ID
    signing, notarization, and least entitlements still apply.
11. **Appearance:** onboarding asks the user; `Auto` is preselected and means
    follow the system. Light and dark are equally supported. Keep the single
    watermelon accent; do not introduce another accent palette.
12. **Runtime policy:** restart and health are self-implemented and run on the
    host peer, not only while a client laptop is connected.
13. **Installation and updates:** never silently perform a privileged `container`
    package install. Sparkle serves unmanaged Macs; Jamf owns managed-mini app
    updates.

The canonical preference domain, Keychain/launchd/package namespace, and Jamf
payload domain all derive from `dev.melonfleet.Flotilla`.

## Build, run, and test

### macOS

Use Apple Silicon, macOS 26, and Swift 6.2 or newer:

```sh
swift build
swift test
swift run Flotilla
```

The tests use captured JSON and do not need a live `container` installation. With
the CLI installed, exercise the live data surface separately:

```sh
swift run flotilla-probe
```

### Linux

Use Swift 6.1:

```sh
swift build
swift test
```

SwiftPM selects `Package@swift-6.1.swift`. It deliberately omits the macOS-only
SwiftUI target. Never add SwiftUI, AppKit, Network.framework, Security, or other
Apple-only imports to `FlotillaCore`.

## Phase 1 working rules

- Follow `PHASE1.md` ownership. Do not duplicate existing models, registries, or
  security boundaries.
- Read `reference/container-cli.md` before adding CLI operations.
- Add fixtures for every new decode path and tests for new behavior.
- Keep types `Sendable` and match the surrounding code's idioms.
- Say when work is unfinished; source files existing is not evidence that their
  full Phase 1 contract is complete.
- Do not run Git when a task or build contract says not to.

## Critical environment constraint — nested virtualization

The development laptop is M2 Max. Apple's `container` boots a Linux micro-VM per
container, and real container launch inside a UTM macOS guest requires nested
virtualization unavailable on that host.

- Local development and real local containers run natively on the laptop.
- Bonjour, mTLS, wire, UI, and rejection paths can be tested in macOS VMs.
- Real remote lifecycle tests use a physical Apple Silicon Mac, currently the M1
  Mac mini, as the host-mode peer.
- Manual host entry remains mandatory because mDNS does not cross VLANs/subnets.

## Reference

- Apple `container`: https://github.com/apple/container
- Apple Containerization framework: https://github.com/apple/containerization
- Local-only inspiration: https://github.com/tdeverx/contained-app
  (**PolyForm Noncommercial**; learn from patterns, do not copy code)
