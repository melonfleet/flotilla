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
- **The allowlist audit is done (18–19 August) and its blocker is closed.** All 47 specs are
  audited against captured `--help` in `reference/cli-help/` — 32 OK, 13 too loose — and the
  blocking finding turned out to be architectural: five *well-formed* commands that no value
  shape can refuse. `WirePolicy` + `CommandSpec.exposure` is the third capability dimension
  alongside `MountPolicy`/`ExecPolicy` (`DECISIONS.md` Q14). **A Phase 2 host peer must build its
  `ContainerCLI` with `.remotePeer`**; the default is `.localOwner` because there is no wire yet.
  Two items remain and are policy, not grammar: `run --publish` accepting any host interface, and
  the opaque `--opt`/`--option` namespaces. See `research/ALLOWLIST-AUDIT.md`.
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
- **A feature that only records while you are looking at it is inert.** The Activity feed
  worked for containers and not for images, volumes or networks, because
  `recordExistence` runs inside those sections' `refresh` — and only their own `.task`
  called it. So create/delete events existed only while you happened to be on that screen.
  The poll loop now refreshes machines, images, volumes and networks every **sixth** tick
  (~30s at the default interval): often enough that the feed and the sidebar counts are
  honest, rarely enough not to spawn four processes a second for state that barely changes.
- **"Busy" and "unavailable" are different states.** `IconActionButton` draws a spinner when
  `busy` is true, and a sweep passed `busy: network.isBuiltin` to mean "you cannot delete
  this" — so the built-in network's delete button span forever, claiming the app was working
  when it was refusing. Same mistake on the Files tab's up-one-directory and upload buttons.
  There is now a separate `disabled:` parameter: `busy` is *in flight*, `disabled` is *not
  offered*.
- **A poll loop cannot see an action with no net state change.** Restarts never appeared in
  the activity strip: the loop compares one refresh with the next, and a restart of a running
  thing ends running. Start and stop each leave a lasting state, which is why only those two
  showed up — and a faster poll would not help, because both halves can land between two
  refreshes. Verified: a CLI stop-then-start of `cache` produced **no event at all**. Such
  actions are now recorded by whoever performs them, with `ContainerEvent.action` set so a
  performed action stays distinguishable from an observed transition.
- **One unbounded child can scroll the whole window.** The activity strip broke Machines
  outright — sidebar scrolled up behind the title bar, table showing only filler rows —
  and then broke Containers too once I "simplified" it. Cause: the strip's **empty-state**
  branch had no height, so the enclosing stack sized to its content and grew past the
  window. Containers happened to have one event and took the bounded `ScrollView` branch,
  which is why only Machines failed at first, and why removing that `ScrollView` broke
  both. Every branch of a bottom band needs an explicit height. It cost five builds of
  bisection because I kept testing the *populated* path.
- **Check an SF Symbol exists before shipping it.** `ellipsis.vertical` is not a real
  symbol. `Image(systemName:)` renders *nothing* for an unknown name — no placeholder, no
  warning, no build error — so every overflow menu in the app silently disappeared. Verify
  with `NSImage(systemSymbolName:accessibilityDescription:) != nil`; the vertical dots are
  a rotated `ellipsis`.
- **Do not guess a row height.** The containers table was capped to
  `count * 28 + 32` for short lists, to hide the placeholder rows macOS draws past the last
  row. The real rows are taller, so the space computed for five containers held four and the
  fifth had to be scrolled to — inside a pane with a large empty margin below it. The true
  row height depends on font, control size and whether a cell wraps, so no constant can be
  right for long. The table fills the pane now, as the machines table always did.
- **Test the policy production ships.** `machine run` has two shapes — a boot command and
  a bare login shell — and `substituting(_:into:)` replaced the strict spec *wholesale*
  when `ExecPolicy.interactiveShell` was in force, destroying the boot form. `AppModel`
  builds its CLI with `.interactiveShell`, so machine **Start and Restart could never work
  in the app**, failing with "'--' is not accepted here" — while the suite was green,
  because the test validated under the *default* policy. A grammar test that does not use
  production's policy is testing a configuration nothing ships. The substitution is now
  keyed on whether the argv carries a `--`, so both shapes survive and neither is widened.
- **An absent operand can still be a grant.** `build`'s context was `min: 0` because the
  CLI defaults it to `.` — reasoning about CLI convenience at a security boundary. The
  validator only shape-checks operands that *exist*, so under `.denyHostPaths` a build
  still archived the process working directory, and on the Phase 2 host peer that
  directory is an execution detail the remote caller never chose. Appending `.` would
  not fix it either: a relative path cannot be checked against absolute policy roots.
  Now `min: 1`. Found by the review on 9 August; **two existing tests asserted the wrong
  behaviour** and had to be corrected with it.
- **The file panel is the authorisation.** `AppModel.buildImage` builds a `ContainerCLI`
  scoped to `.roots([chosen directory])` for one command. That is a real widening of the
  app's `.denyHostPaths` default and is the sanctioned exception to "one instance, one
  boundary" — because it goes the safe way round: narrow, explicit, per-invocation, and
  named in the call rather than inherited and forgotten. The alternatives were worse —
  `.unrestricted` on the shared CLI would have widened bind mounts in Run too.
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
- **`Set.first` is not "the one they clicked".** `Table`'s `primaryAction` hands back the
  *selection* as a `Set`, and this table multi-selects — so `ids.first` is an arbitrary member,
  and double-clicking one of several selected rows could open a different container. An
  ambiguous activation should open nothing.
- **Two presentations of one list must share one order.** The table bound `sorted` and the
  detail stepper walked `sorted`, but the cards grid used `ForEach(visible)` — unsorted. So in
  Cards the grid showed model order while Previous/Next walked sort order: the "next" container
  was not the next card, and "N of M" indexed a list you were not looking at. The stepper's own
  docstring claims it walks the containers *as currently shown*, which made the docstring the
  bug report. Both found by **Grok 4.6 in a review eval on 2026-08-18** — in code that had
  already been through the review and me, which is the argument for a third model family in one line.
- **A GUI-launched app does not inherit your shell's `PATH`.** Flotilla reported "Apple's
  `container` CLI isn't installed" on a machine where it was installed *and running*, and no
  amount of `container system start` could change the verdict. `container` lives in
  `/usr/local/bin`; the `PATH` LaunchServices hands a bundled app is exactly
  `/usr/bin:/bin:/usr/sbin:/sbin` — measured with `ps eww` on the running process. So
  `locateOnPath` could not find it, and `/usr/bin/env container` (the old `LocalHost` launch)
  could not run it either. It had *always* been broken from the Dock and had never been noticed,
  because every screenshot I take is of an app launched from a terminal, which inherits my rich
  `PATH`. A reboot is what made it visible. Detection and execution had to be fixed together —
  resolve `PATH` then `/usr/local/bin`, and launch the **absolute path** — or preflight would
  have said "ready" while every command failed. Verify with
  `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin build/Flotilla.app/Contents/MacOS/Flotilla`, which
  reproduces the real launch environment; the same trick applies to any future binary lookup.
- **The answer is sometimes inside the failure.** `container system status` reports a stopped
  service by **exiting 1 while printing the status JSON** (`"status":"unregistered"`, empty
  fields, empty stderr — measured). `ContainerCLI.execute` throws on non-zero, so the decodable
  answer was discarded and preflight reported "installed but not usable" with the raw JSON pasted
  into an English sentence — no auto-start, no button, because the app could not tell that state
  apart from a real fault. There is now one narrowly-scoped `attempting(_:)` path that validates
  as usual but returns a non-zero exit rather than throwing on it. Before assuming a non-zero
  exit means "no information", read what the command printed.
- **The same test mistake, a fifth time.** The scripted host for "service not running" returned
  the status JSON with **exit 0**, which is not what the CLI does, so the new `.serviceStopped`
  path was green in the suite and never fired on the real machine. It was caught by stopping the
  real service and watching the app, not by testing. Fixtures for a *failure* mode need the
  failure's exit code captured too, not just its output.
- **A deadlock regression test hangs; it does not fail.** `LocalHost` read stdout to EOF before
  touching stderr, which deadlocks any child that fills the stderr pipe buffer (64 KiB on Darwin).
  Three hundred tests were green because every one of them uses a scripted host that never opens a
  pipe — the bug lived at the one boundary no test crossed. When the fix's own test finally ran, a
  *second* bug surfaced the same way: it sat for **30.36s against a 0.3s deadline** because
  `sh -c 'trap "" TERM; sleep 30'` forks `sleep`, so `SIGKILL` reaps the shell while the grandchild
  inherits the pipe and holds it open. The source comment asserting the drain "cannot outlive the
  process, which the child's exit guarantees" was simply wrong. **A child's exit does not guarantee
  EOF on its pipes.** Any wait on a reader needs its own bound, and abandoned output must report as
  truncated rather than complete. If a test for a hang can only hang, give it a wall-clock
  assertion so the failure is legible.
- **Enforcing a value that was never enforced is a behaviour change, not a bug fix.**
  `timeoutHint` sat on every `CommandSpec` unread for weeks, so its numbers had never been
  load-bearing and nothing would have caught a wrong one. Wiring it up without checking spec by
  spec would have killed `image pull` and `build` at whatever the default happened to be. They
  carry 1800s and the interactive substitutes carry 0; that was verified before the switch was
  thrown, not after. Treat "this field is currently ignored" as "these values are unverified".
- **A knob whose only reachable outcome is failure should be deleted, not documented.**
  `stats(noStream: false)` asked a streaming command for output through a runner that reads to EOF
  — an infinite read before the deadline existed, a guaranteed timeout after. No caller ever passed
  it. This is the same family as a setting with no production consumer: the honest fix is to remove
  the option and name what would actually be needed (Phase 4's streaming API).
- **A user-facing error message is a disclosure surface.** The first version of
  `ContainerCLIError.timedOut` interpolated the whole argv into a sentence bound for an alert —
  which is exactly SEC-03's fault in `auditDescription`, reproduced on a *more* exposed surface
  while in the middle of fixing it. Only the leading non-flag tokens are named now; everything from
  the first `-` onward is dropped, because argv is where `--env TOKEN=…` and home-directory mount
  paths live.

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
│   ├── WirePolicy          → which subcommands a remote peer may reach at all
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
5. **Primary view (Q2):** a table; cards remain an alternate toggle. **The running-first
   default was reversed on 9 August** — the table now sorts by name. Running-first meant
   that stopping a container moved its row to the bottom, so the thing you just acted on
   left the place you were looking; with a screenful of rows that is a hunt every time. The
   state column is still sortable, so running-first is one click away. Sorting by relevance
   was a reasonable guess that using the app disproved.
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
