# Flotilla — decisions and rejected alternatives

The *why* behind the plan, so future-you (and a fresh Claude account) doesn't
second-guess settled choices mid-project.

## Chosen

- **Shell out to the `container` CLI + decode `--format json`.** The integration
  surface is the CLI, not the framework.
- **Network.framework + mTLS** for all remote comms, Bonjour for discovery, manual
  host-add for routed networks.
- **One app, two modes** (client/host) sharing `FlotillaCore`.
- **macOS 26 only, Apple Silicon only**, real Liquid Glass.
- **Self-implemented restart/health** (the CLI has none).
- **Sparkle (GitHub appcast)** for unmanaged updates; **Jamf** for managed minis.

## Rejected — and why

- **Linking Apple's Containerization framework directly.** Rejected: the CLI is
  young and churning; the framework API is more fragile and harder to verify than
  stable JSON output. `tdeverx/contained-app` reached the same conclusion.
- **Using the macOS `ssh` binary as the transport.** Rejected: Apple lags upstream
  on OpenSSH patches, but more importantly the menu-bar host/client model means
  both ends are our Swift code — a native Swift-to-Swift link is simpler and gives
  typed streaming, discovery, and a cert model that maps onto Jamf.
- **gRPC / third-party networking.** Rejected: Network.framework covers it with no
  dependencies and native mTLS; gRPC adds ceremony for no gain at this scale.
- **Kubernetes (or any CRI-based orchestrator).** Rejected: `container` is not a CRI
  runtime, so a CRI shim + CNI for per-VM containers on macOS is a multi-year
  project. For ~8 nodes, a fleet view + per-host run/stop + self-run restart/health
  is enough. (Nomad with a custom task driver is the *only* heavier option worth
  revisiting, and only much later.)
- **Cross-platform UI (Electron/Tauri).** Rejected: everything is Apple Silicon
  macOS; native SwiftUI buys polish and Liquid Glass for free.
- **Silent privileged auto-install of the `container` pkg.** Rejected: the pkg needs
  admin and drops a launchd service — always install with user authorization.

## Constraints to remember

- Dev laptop is **M2 Max** → no nested virtualization. Real containers can't launch
  inside a UTM macOS guest; use the physical **M1 Mac mini** as the remote host for
  full-stack tests. Networking/UI is testable in VMs.
- mDNS doesn't cross subnets/VLANs → manual host-add is mandatory, not optional.

## Infra / security decisions (setup)

- **GitHub account:** dedicated hobby account `melonfleet`, separate from the owner's
  other GitHub accounts. Repo `melonfleet/flotilla` is **private**.
- **No PII in the repo or commits:** author identity is `melonfleet` +
  `…@users.noreply.github.com`; no real name, handle, gmail, or local user paths in
  tracked files. Keep it that way.
- **SSH key in the credential manager, not on disk:** the melonfleet ed25519 key
  lives only in the password manager, served through its SSH agent behind Touch ID.
  Rejected leaving an unencrypted key on disk.
- **Commit signing through the same agent** (SSH-format signatures) → commits show
  Verified. Rejected GPG (heavier) and unsigned commits.
- **Two-account separation:** a per-account SSH host alias with `IdentityFile` and
  `IdentitiesOnly`, plus agent configuration scoping each account to its own vault,
  so a push can only ever use the identity intended for that remote.

  Deliberately no vault names, agent socket paths, aliases or public keys here: this
  file is tracked, the specifics are per-machine, and the credential manager's own
  documentation is the place to follow them.

## Identity / namespace (settled 2026-07-27)

- **Bundle identifier: `dev.melonfleet.Flotilla`.** Not `com.melonfleet.*` — the
  canonical reverse-DNS root for the whole suite is **`dev.melonfleet.*`** (see
  `design/brand/BRAND.md`, which explicitly supersedes any earlier `com.` mention),
  matching the owned `melonfleet.dev` domain. Rejected `com.melonfleet.*`.
- The same root governs everything namespaced off the bundle ID: the UserDefaults /
  managed-preference domain (`dev.melonfleet.Flotilla`), Keychain services, launchd
  labels (e.g. `dev.melonfleet.Flotilla.host`), pkg identifiers, Sparkle keys, and
  Jamf configuration-profile payloads.
- **Decide-once, change-never in practice:** changing it later strands users'
  preferences and every managed key, so this is fixed before Phase 1 ships.
  (This closes open question Q8 in `research/FEATURES.md`.)

## Appearance (settled 2026-07-27)

- **Appearance is chosen by the user during first run** — the onboarding flow asks, and
  whatever they pick is persisted to the `dev.melonfleet.Flotilla` preference domain and
  becomes their default. `Auto` (follow the system `colorScheme`) is the pre-selected
  option, not a hardcoded default. Changeable afterwards in Settings › General.
- Light and dark are both first-class; neither is the "real" theme.
- **Keep the mockups' visual language**: the dark treatment shown in
  `research/review/mockups/` is approved, and the **watermelon accent** is the single
  accent colour in both themes. Do not introduce a second accent or a theme-specific
  palette. **Amended by Q23 (2026-09-26):** controls now take the *system* accent, and themes
  apply the watermelon palette to the window bar and background. There is still no colour
  from outside the palette.
- Consequence: every view must be built and checked in **both** appearances — an
  auto default means a light bug is as user-visible as a dark one.

## Proposal review — settled 2026-07-27

All nine open questions from `research/FEATURES.md` §6 are closed. Recorded here so
they are not relitigated.

- **Wire shape: the middle path — args passthrough constrained by a subcommand
  allowlist (Q1).** The host does NOT accept an arbitrary command string, and it is not
  a generic remote shell: `args[0]` must match an allowlisted `container` subcommand and
  the arguments are schema-validated (plus frame-length, concurrency and deadline limits)
  before anything is spawned. Within that boundary we keep the args-passthrough benefit —
  Phase-1 features become fleet features in Phase 2 at low marginal cost, and the command
  string still serves as the audit record. Rejected: unbounded passthrough (the CLI owner's
  position) and fully typed per-operation RPCs (the reviewer's position).
- **Container list defaults to a TABLE, with a card/tile toggle (Q2).** Cards stop
  scaling past ~20 rows; the table is running-first, sortable and multi-select. The card
  grid survives as a toggle, not the default.
- **Host mode is stateful (Q3).** It gets a persisted policy store. Required so
  restart/health policy runs on the host peer — otherwise closing the laptop stops
  restarting containers on the minis — and so per-host settings can be read/written.
  This is a deliberate expansion of PLAN.md's "host mode just executes CLI args".
- **Two-tier managed settings now: `defaults` (seed) + `locked` (override) (Q4).**
  Adopted before Phase 2 writes the settings accessors, because retrofitting precedence
  later means rewriting every accessor. Supersedes the simpler "managed value always
  wins" note in `reference/jamf-config-profile.md`.
- **Phase 1 scope: approved as consolidated (Q5)** — i.e. the fuller Phase 1 in
  `research/FEATURES.md`, including volumes, networks, the settings registry, the
  security baseline, diagnostics and the support bundle. Not trimmed back to PLAN.md's
  original one-line Phase 1.
- **Notifications ship in Phase 1 with full per-category toggles (Q6).** Earlier than the
  UX pass proposed (Phase 3); PLAN.md did not mention them at all.
- **`config.toml`: read in Phase 1, edit locally in Phase 3, edit remotely only if it
  proves necessary (Q7).** Avoids owning a file another tool owns on a machine you may
  not be sitting at.
- **Bundle identifier `dev.melonfleet.Flotilla` (Q8)** — see the Identity / namespace
  section above.
- **No App Sandbox for v1 (Q9).** We execute an external CLI and listen for network
  connections; a useful sandbox would need brittle exceptions. Recorded explicitly so it
  isn't reopened. Note this is orthogonal to the other two: we still ship **notarized**
  with the **hardened runtime** — notarization ≠ sandboxing ≠ hardened runtime.

## Licensing note

`tdeverx/contained-app` is **PolyForm Noncommercial 1.0.0** — fine to read for
ideas and for personal non-commercial use, but don't copy its code into anything
commercial. Learn the patterns; write our own.

## Settled 2026-07-30/31 — packaging, presentation, and honesty about the runtime

### App bundle before Xcode project

`Scripts/make-app.sh` assembles a real `dev.melonfleet.Flotilla` bundle around the
SwiftPM binary — Info.plist, generated icon, ad-hoc signature — while the build stays
SwiftPM and `FlotillaCore` keeps building on Linux.

This is **not** the Xcode migration, and must not be documented as such. It exists
because four Phase 1 features were gated on a bundle identifier rather than on missing
code: `UNUserNotificationCenter.current()` does not degrade without one, it raises
`bundleProxyForCurrentProcess is nil` and kills the process; `LSUIElement` is a plist
key; `SMAppService` registers a bundle; and signing needs one. Xcode still owns
notarization, Sparkle and distribution.

The ad-hoc signature is load-bearing, not decoration: notification authorization is
remembered per code identity, so an unsigned bundle re-prompts on every rebuild.

### Presentation defaults to `both`, not `menuBar`

Honouring the previously-inert "Show Flotilla in" setting exposed its default as
hostile. `.menuBar` maps to `NSApplication.ActivationPolicy.accessory`, which removes
Flotilla from the Dock **and from ⌘-Tab** — so switching to another app left the
menu-bar icon as the only route back. For an app whose main window is the product
(Q2), being unreachable by ⌘-Tab is a defect, not a preference. `.menuBar` remains
available for anyone who wants a true accessory app.

### Forms are modal sheets with a drawn red ×; detail is a real window

Two requests conflicted: the web-modal feel (interface behind dims and stops
responding) and macOS's own red close button. They cannot coexist — traffic lights
exist only on a real title bar, a sheet has no title bar, and a plain window is not
modal. A window route was built and then removed.

Settled shape:

| Presentation | Used for | Close |
|---|---|---|
| Modal sheet in `ModalCard` | forms (run, network, volume, pull, tag) | red ×, Escape |
| Real window | container detail | macOS traffic lights, zoom kept, minimise removed |
| Alert | confirmations and errors | named buttons |

The red × is deliberately **not** a traffic-light imitation placed where a title bar
would be. It is a close control that happens to be red and carries the glyph everyone
reads as close — the point being that an icon travels further than the word "Close".
The dim is owned by `MainWindowView`, not by each sheet, so the whole interface greys
rather than just the detail pane.

### Nothing in `container` is editable after creation

Verified against the CLI: there is no `update`, `edit`, `set`, `resize` or `modify` for
containers, volumes or networks. Every one is create/delete only.

Consequences that shape the UI rather than being footnotes:

- The **create form is the only moment** any option can be chosen, so every flag the
  CLI accepts is offered there — networks get IPv4/IPv6 addressing, host-only, labels,
  plugin options and plugin; volumes get size, labels and driver options.
- The Configuration tab is **read-only by necessity**, and says so. An editable pane
  would invite changes that could never be applied.
- Changing anything means delete and recreate, which for a volume means moving data
  first. Do not offer a "resize" that quietly destroys.

### Brand assets are generated, never fetched

The brand SVGs contain `@import url('https://fonts.googleapis.com/…')`. Flotilla
promises no telemetry and no phone-home, with an About view meant to list every
network destination — shipping a decorative asset that fetches a font on every launch
would make that claim false, and would render as Helvetica anywhere the font is
absent.

So: the app icon and menu-bar glyph are **generated** from the brand geometry
(`Scripts/make-icons.swift`), and the wordmark is **drawn** in SwiftUI
(`Wordmark.swift`). The menu-bar glyph is a monochrome **template** image — macOS
inverts it, so one asset serves light and dark and there is no pair to drift.

## Revisited 2026-08-02 — XPC client libraries vs shelling out (integration, Q1)

**Outcome: keep shelling out. Not reopened, but the premise has changed and is recorded
here so nobody re-derives it from scratch.**

`research/COMPETITORS.md` found that three competitors — Orchard, Davit and Bart Reardon's
ContainerManager — do not shell out. They link `container`'s own Swift client libraries and
talk to the running daemon over XPC.

**This is a third option Q1 never considered, and the distinction matters.** "Rejected —
and why" turns down *linking Apple's Containerization framework directly*, which means
reimplementing the runtime. `ContainerAPIClient` and `MachineAPIClient` are different
things: public SwiftPM products of `apple/container` that talk to
`com.apple.container.apiserver` — the same daemon the CLI talks to, without the CLI in
between. Verified 2026-08-02 against the repository's `Package.swift` and the running
launchd services, not inferred.

### What it would genuinely buy

The entire class of bug this project keeps paying for: fabricated fixture shapes, the `--`
separator, `--size` vs `-s`, flag spellings, unchecked exit codes. All of it is CLI-parsing
fragility. Typed calls have none of it, plus lower latency and no process spawn per poll.

### Why not now

The cost is not "rewrite the CLI layer". It is that the change invalidates **two**
load-bearing decisions simultaneously.

1. **`Allowlist` is argv-shaped, and it is the Phase 2 wire boundary** — the thing the review
   audited and the thing a remote peer will face. Typed calls do not remove the need for a
   boundary; they change its shape completely, to method-and-parameter capability checks.
   That is re-deriving the security model, not refactoring.
2. **`FlotillaCore` must stay Foundation-only**, which is what lets the VM agents verify
   their own work on Linux. `ContainerAPIClient` is macOS-only and pins
   `apple/containerization` at an exact version. Putting it in the core breaks the seam the
   whole fleet arrangement depends on.

Doing that surgery while also building Phase 2 is how you get neither — and Phase 2 is the
one thing `COMPETITORS.md` says nobody else has.

### The strongest practical argument for XPC evaporated on inspection

Machine/VM management is the market's #1 gap (~13 of ~19 products), and the survey warned that the
three XPC products drive machines over XPC specifically — implying the CLI might not expose
the full surface. **Checked: it does.** `container machine` offers create, delete, inspect,
list, logs, run, set, set-default and stop, including
`machine set -n <name> cpus=4 memory=8G home-mount=ro` and an interactive `machine run`.
That is everything the XPC products do.

So an earlier suggestion — build VM management over XPC as a bounded spike — is **withdrawn**.
It would have bought a second integration path for a feature the CLI already covers. Build
machines the way everything else is built, and keep one boundary.

### Revisit if

- a `container` release breaks JSON decoding in a way that costs a day, or
- a capability appears that the CLI genuinely cannot reach.

Not because competitors do it. Three of twenty-five is not a trend.

### Related, from the same research

- **Name collision.** The market leader is called **Orchard** (Andrew Waters, 715 stars,
  notarised, `brew install --cask orchard`, "Native GUI for Apple Containers" — verified via
  Homebrew's own API). melonfleet's mothership is also Orchard. Different domain, same
  portfolio as its direct competitor. Needs a decision before either name is public;
  `COMPETITORS.md` notes this market already has two products called "Crane" and two called
  "Container Desktop".
- **Sequence the gap list against security cost, not market frequency.** the survey's ranking is
  by how often a capability appears. Every new subcommand family is new grammar facing a
  remote caller in Phase 2, and machine creation with home mounts is a filesystem grant.

## Q14 — Wire exposure is a capability, not a grammar (settled 2026-08-19)

**Decision.** `CommandSpec` carries an `Exposure`, and `ContainerCLI` carries a `WirePolicy`
alongside `MountPolicy` and `ExecPolicy`. A Phase 2 host peer constructs its CLI with
`.remotePeer`, which refuses `.localOnly` subcommands outright and requires the bounded form of
commands whose default output is unbounded. Local instances keep `.localOwner`, which is the
permissive default **because there is no wire yet** — flipping the default would refuse the app's
own machine controls to protect a peer that does not exist.

**Why, and why not a stricter grammar.** The 47-spec audit (`research/ALLOWLIST-AUDIT.md`) found
five blockers that no value shape can refuse, because the argv is already well-formed:
`machine delete production`, `machine set home-mount=rw` (which points the default machine at the
owner's home directory read-write on its next boot), `machine set-default X` (which redirects
every later bare machine operation, including the owner's own), `machine create`, and
`machine run`. `Allowlist` answers "is this argv well-formed for this subcommand" and answers it
well. It had no way to say "this subcommand is not offered to a remote caller at all", and that
is a capability question, exactly like the two dimensions already injected per CLI.

**Local-only, with the reason recorded on each spec:** the six `machine` mutations plus
`system start` (starting the host's own runtime services is the owner's decision).
**Bounded over the wire:** `logs` and `machine logs` require `-n`, `stats` requires
`--no-stream` — all three are unbounded by CLI default, which is harmless for the owner reading
their own machine and a denial of service from a peer.

**Rejected alternatives.** (1) A second allowlist table for the wire — parity that lives in two
files is parity someone has to remember, and this project has already lost that bet. (2) Refusing
the machine family for everyone — it would remove working local features to protect a peer that
does not exist. (3) Leaving it to the transport layer to filter — the boundary would then live
outside the thing that validates, and the audit's whole point is that the boundary must be
where the decision is made.

**Still open, and NOT closed by this decision:** `run --publish 0.0.0.0:...` needs a host-owned
interface/port policy, and `volume create --opt` / `network create --plugin|--option` forward
opaque key-values to host drivers whose accepted keys are undocumented. Both are noted in the
audit as needing policy rather than grammar; neither is a Phase 1 blocker.

### Q14 amended after independent review (2026-08-19)

An independent review examined the first implementation and returned "the capability concept is sound, but this
implementation is not". He was right on every count that mattered, and four things changed:

1. **A substitution bypass, and it was live.** `substituting()` swaps `machine run` for
   `interactiveMachineRun` under `ExecPolicy.interactiveShell`, and the substitute is a separate
   `CommandSpec` that carried the *default* exposure — so it laundered the local-only marking on
   the spec it replaced. `machine run -n prod -i -t` from a `.remotePeer` holding
   `.interactiveShell` would have granted a shell inside the substrate VM. Exposure is now checked
   on the **pre-substitution** spec as well as the substituted one, and both substitutes carry
   their own `.localOnly`. One guard that depends on remembering a second is not a guard.
2. **The executor no longer defaults.** `ContainerCLI.init` requires `wirePolicy` explicitly: a
   defaulted capability is one a remote-serving call site acquires by forgetting. The pure
   validator keeps its `.localOwner` default, because previews and tests genuinely *are* the local
   owner and cannot spawn anything. A `.remotePeer` CLI also now refuses to be built with an
   unrestricted `MountPolicy`, which is the one combination never intended.
3. **`machine logs` and `machine inspect` became local-only.** `--follow` *satisfied*
   `wireRequiredFlags: ["n"]` while still streaming without bound, and `machine inspect` carries
   `userSetup.username` — the exact field the redaction lesson exists for. Fail-closed until wire
   responses are redacted; the alternative was a promise with no code behind it.
4. **The registry test asserts a partition**, not a list of the interesting half, so a new spec
   fails the suite until someone states its exposure. Plus a test that every `wireRequiredFlags`
   entry resolves to a declared flag (a typo there is a self-inflicted denial of service), and one
   that drives a `.remotePeer` CLI against a recording host to prove refused commands never spawn.

**Explicitly still open, and Phase 2 host-runtime work rather than allowlist work:** byte ceilings
on responses (a single huge log line defeats a line count), enforced deadlines, concurrency and
detach requirements for long-running commands, redacted/typed projections for the read commands
that disclose paths and environment, and the host-owned interface/port and driver/plugin policies
from finding 3. `timeoutHint` enforces nothing today and says so. *(Superseded 2026-08-23: see
Q15 — concurrent drain, byte ceilings and enforced deadlines are in. Redacted projections and the
host-owned interface/port policy remain open.)*

## Q15 — The process boundary gets ceilings and a deadline (settled 2026-08-23)

**Decision.** `LocalHost` drains stdout and stderr **concurrently**, keeps at most
`maxBytesPerStream` (4 MiB, per stream) and reads-and-discards the rest, and enforces a hard
deadline carried from `ValidatedCommand.timeoutHint` with terminate → grace → `SIGKILL`. Truncation
is reported on `CommandResult`; exceeding the deadline throws `ContainerCLIError.timedOut`. This
closes three of the five items Q14 left open, and Q14's last sentence — "`timeoutHint` enforces
nothing today and says so" — is no longer true.

**Why now.** An independent audit raised all three, and each was confirmed in the tree before
anything changed. The drain order was not a slow path, it was a **deadlock**: stdout was read to
EOF before stderr was read at all, so a child that fills the stderr pipe buffer (64 KiB on Darwin)
blocks writing while we block reading, and neither side ever moves. The Logs screen asking five
sources for a thousand lines each is precisely that shape. It never fired in testing because every
fixture-backed test uses a scripted host that never touches a pipe.

**What the tests had to be.** A regression test for a deadlock **hangs** rather than fails, which
is why a green 300-test suite proved nothing here. `LocalHostRunnerTests` drives `/bin/sh` through
an injected resolver — not a widening of the allowlist, since `LocalHost` is constructed directly
and nothing crosses `Allowlist` — because no `container` subcommand lets us dictate how much goes
to which stream and how long the child lives. Ceilings are injected small so the suite stays fast.

**A second bug, found by the fix's own test.** The first version asserted that waiting on the
readers "cannot outlive the process, because the child's exit guarantees EOF". It does not.
`sh -c 'trap "" TERM; sleep 30'` cannot exec, so it forks `sleep`; `SIGKILL` reaps `sh` and `sleep`
inherits the write end of the pipe. The test failed at **30.36s against a 0.3s deadline** — the
deadline fired and then we sat anyway, an unbounded wait wearing a bounded one's clothes. Hence
`drainGrace` and `Sink.abandon()`: after the child is gone the readers get a grace period, then we
take what arrived and let them finish into a sink nobody reads. Abandoned output reports as
truncated, because it is.

**Two things deliberately removed rather than documented.**

* `stats(noStream:)`. No caller ever passed `false`, and a streaming `stats` never closes its pipe
  — an unbounded read before, a guaranteed timeout after. Its only reachable outcome was failure,
  so it was a knob that could not work. Streaming needs Phase 4's streaming API, not a `Bool`.
* The two `?? "/usr/bin/env"` fallbacks behind the container terminal and the machine console,
  each with its own hardcoded candidate list. Both are the faults this project keeps relearning:
  two authorities for one property, and a PATH lookup by another route in an app that otherwise
  launches only absolute paths (a GUI-launched app's PATH has no `/usr/local/bin`, so the
  "fallback" resolved to nothing on the exact machines it was meant to rescue). There is now one
  `AppModel.containerExecutable` calling `Preflight.locateBinary`, returning `nil`, and callers
  that say so.

**Timeout values were already sane, which is the only reason enforcing them was safe.** `image
pull` and `build` carry 1800s, `run` and `machine create` 600s, `machine run` 300s, the default
30s, and the two interactive substitutes carry **0** — no deadline, correctly, since a shell
session is meant to last. Enforcing a hint nobody had ever checked could easily have killed image
pulls; it was verified spec by spec first.

**Still not done, and not claimed:** Swift `Task` cancellation does not reach the child. Cancelling
the task that called `run` leaves the process running until its deadline — better than the previous
"until forever", but cooperative cancellation needs the async API, so it stays Phase 4 work. The
ceiling is also per stream and per invocation, not a budget across the fan-out in `aggregatedLogs`.

## Q16 — A setting must be read by something, and the app must say when it is not (settled 2026-08-23)

**Decision.** `SettingsKey` carries a `SettingAvailability`. A key is either `.available` — something
reads it — or `.notBuilt(reason:)`, in which case the Settings row is **disabled**, shows the reason,
and the key is withheld from the MDM payload. `Scripts/check-settings-consumers.sh` enforces the
first half at build time and `make-app.sh` runs it, so a setting cannot silently lose its consumer.

**Why.** The audit's largest finding was a category rather than a bug: of 26 keys, **11 were read by
nothing**. `launchAtLogin` was the clearest — its own summary named `SMAppService` and no file in the
tree called it, so the toggle moved, persisted, survived a relaunch, and did nothing. That is worse
than a missing feature: it is a claim the feature exists, and the way you find out otherwise is by
depending on it and rebooting.

**What was wired rather than annotated.** Four of the eleven turned out to be a few lines from
working, and wiring beats confessing when it is honestly cheap:

* **`launchAtLogin`** → `LoginItem`, using `SMAppService`. The status is shown, not assumed: macOS
  can accept a registration and park it in `.requiresApproval` until the user approves it in System
  Settings, and a toggle that reads "on" in that state is the same lie in smaller print.
* **`autoStartContainerService`** → the auto-start now consults the policy. It was unconditional, so
  someone who set `never` got an automatic `container system start` anyway. **The default changed
  from `.ask` to `.always`**, which is a deliberate reversal of the reasoning on
  `ServiceAutostartPolicy`: that comment equates this with a silent privileged install, and it is
  not one — it starts a user-level service the user installed, needs no authorisation, and was
  explicitly requested after a macOS update left the service stopped. The setting was inert either
  way, so `.ask` documented an intention rather than describing behaviour.
* **`containerBinaryPath`** → an override consumed by `AppModel.containerExecutable`, defaulting to
  empty (detect). A configured-but-missing path degrades to detection and the row says so.
* **`defaultContainerCPUs` / `defaultContainerMemoryMB`** → the run sheet had no CPU or memory field
  for them to prefill. `RunOptions` already carried `cpus`/`memory` and `Allowlist` already permitted
  `--cpus`/`--memory` on `run`; only the two controls were missing.

**Eight are marked `.notBuilt`,** and the wording of one is worth calling out: the summary for
`identityKeychainLabel` describes how TLS key material is protected by the Keychain. There is no TLS
identity. A security guarantee attached to a feature that does not exist is the most damaging kind of
inert setting, and it was **on by default** in the same way `SUEnableAutomaticChecks` was.

**Withheld from MDM, which is the half with no witness.** An administrator pushing `hostListenPort`
to a fleet would believe they had configured a listener. There is none. The person deceived is not at
the keyboard, so nobody is positioned to notice — so `SettingsRegistry.manageable` now excludes
unbuilt keys. A managed value for one is still *accepted* rather than rejected, because failing a
whole profile over one ignored entry is worse; the row shows both "Managed by your organization" and
the not-yet-available reason.

**`presentation` became `showDockIcon`.** Three options (`menuBar`/`dock`/`both`) over two states:
macOS has no activation policy for "Dock icon but no menu bar", so `dock` and `both` were the same
policy under two names. A toggle is the honest control. `SettingsStore.migrateLegacyKeys` carries the
one distinction that was real — `menuBar` meant no Dock icon — and `SettingsPersistence` writes the
migration immediately rather than waiting for the user's next edit. Verified end to end: this Mac's
stored `{"presentation":"both"}` became `{"showDockIcon":true}` on disk after one launch.

## Q17 — Confirmation is one decision, in one place (settled 2026-08-23)

**Decision.** `DeletePolicy` in `FlotillaCore` decides whether a destructive action confirms.
Single deletes follow `confirmDestructiveActions`; **bulk always confirms and no setting can change
that**, so `confirmBulkActions` is deleted rather than wired.

**Why bulk is mandatory.** A preference whose "off" position means *destroy several things without
asking* is a preference for a mistake, and a multi-selection is exactly where the gap between what
you think is selected and what is selected does the damage — `ContainersView` already documents that
a filter change leaves rows selected that are no longer visible. The setting had no consumer, so
mandatory confirmation is what has always actually shipped.

**Why it lives in Core.** The app target has no test target. A decision this consequential should not
sit in the untested half, so the rule is a pure type in `FlotillaCore` with tests, and the views keep
only their own wording and dialog state. What must not differ per screen is the rule; what should
differ is the sentence.

**What centralising it found.** The audit said Containers and Machines never read
`confirmDestructiveActions`, which was true, and the consequence is the opposite of how it reads:
both confirmed *unconditionally*, so the preference was a no-op on two of five screens rather than a
hole. The actual hole was next door and unreported: `ContainersView`'s **context menu** called
`model.perform(.delete, …)` directly, so right-click → Delete destroyed a container with **no dialog
at all**, two lines from a trash button that always asked. Five call sites read side by side is what
made that visible.

**Also:** `machine set home-mount=rw` now confirms, but **only when it escalates** — currently not
read-write, about to be. Confirming whenever `rw` is merely *selected* would fire on every CPU change
on a machine that already mounts home read-write, which is the default, and a dialog that appears
when nothing dangerous is happening trains people to dismiss the one that matters. Building that
check exposed two real bugs: the Configuration tab was handed the thin `machine ls` row, which has no
`homeMount` field at all, so it displayed "Read-write" for a machine this Mac reports as `ro` — and
the escalation test inherited that nil, making the new confirmation unreachable. It now takes the
inspected record and treats unknown as *confirm*.

## 2026-09-12 — Release cadence pegged to `container`, and shipping the runtime

**The owner's directive**, recorded first because the rest is my reading of it: every time Apple
releases `container`, review what changed, adapt Flotilla if anything needs adapting, re-test, and
release **with the same version number Apple used** — even when nothing needed changing, the
release exists to say "verified against this runtime". And ship the matching `container` with the
installer, either bundled or fetched during install.

The intent is right and worth building around. Flotilla is a front end to a CLI whose own
documentation guarantees stability only *within a patch series*; "which `container` was this tested
against?" is the single most useful fact about a build, and today the honest answer lives in a
comment at the top of `research/UPSTREAM-GAPS.md`. Making it the version number puts it where
nobody can miss it.

### The gap in a strict peg, and the scheme that closes it

A strict peg has no room for Flotilla's own changes, and right now those are almost all of them —
the app changed a dozen times in one day with `container` sitting still at 1.4.1. Under a strict
peg the choices are to not ship until Apple does, or to ship "1.4.1" more than once, which makes a
bug report ambiguous about which build it came from.

So: **`<container version>.<Flotilla revision>`** — a fourth component.

- `1.4.1.0` — verified against `container` 1.4.1, no Flotilla changes needed.
- `1.4.1.1` — a Flotilla change on top of the same runtime.
- `1.4.2.0` — Apple moved; the revision resets.

Considered and rejected: `1.4.1-flotilla.2`, because semver reads anything after `-` as a
*pre-release*, so it sorts **before** `1.4.1` — the update check in `UpdateCheck` would report a
newer build as older. And `1.4.1+flotilla.2`, because build metadata is excluded from ordering by
the spec, so two Flotilla builds would compare equal. A fourth integer orders correctly and reads
the way Debian's and Homebrew's revisions do. `SemanticVersion` currently refuses four components
and would need to accept them; `CFBundleVersion` is unaffected, being the commit count already.

**Settled 2026-09-12: the scheme is adopted, and a confirm-only release is `x.y.z.0`.** Zero reads
as "nothing of ours changed since Apple's release", which is exactly what that build is claiming,
and it keeps the revision counting Flotilla's changes rather than its releases. `SemanticVersion`
prints a zero revision as Apple wrote it — `1.4.1.0` renders `1.4.1` — so Flotilla never appears to
claim a revision on a version that has none, while `1.4.1.0` and `1.4.1` still compare equal.

**Consequence for the unshipped beta:** the tag becomes `v1.4.1.0-beta.2` rather than
`v1.0.0-beta.2`. Longer, and it says the useful thing — second beta, verified against `container`
1.4.1, no Flotilla revision yet — where `1.0.0` said only "first". A pre-release of a revisioned
build still sorts before it, which is the ordering the update check needs.

**Amended 2026-10-05: the beta is now `v1.5.0.0-beta.2`.** `container` 1.5.0 shipped before beta 2
was packaged, and Flotilla was verified against it (`research/CONTAINER-UPGRADE-1.5.0.md`), so the
tag names 1.5.0 instead of 1.4.1. It is applied when beta 2 is packaged, not before: a tag on an
unpackaged commit would stamp that version on every dev build made after it.

What this touched: `SemanticVersion` accepts and orders a fourth component (five is still not a
version); `Scripts/make-app.sh`'s positive shape guard accepts `X.Y.Z.R` with the same optional
pre-release suffixes; `Scripts/release.sh` names the shape in its error. `CFBundleVersion` is
untouched — it is the commit count, which is what LaunchServices compares.

### Every `container` release gets a review, not a version bump

The ritual, in order, because doing it out of order is how a release claims more than it verified:

1. Diff the documented command surface, flag by flag, at both tags — `Scripts/` has no tool for
   this yet and the method is in `research/CONTAINER-UPGRADE.md`'s verification pass.
2. `Scripts/capture-cli-help.sh` and `Scripts/capture-fixtures.sh` on the new CLI.
3. Re-run the one-line tests in `research/UPSTREAM-GAPS.md`; a lifted gap is a feature, not a
   footnote.
4. Adapt, or confirm nothing needs adapting.
5. Tag, with the new runtime named in the release notes whether or not code changed.

### Shipping `container` itself

Apple publishes one signed, notarised installer per release —
`container-<version>-installer-signed.pkg`, 118 MB, `Developer ID Installer: Apple Inc. -
Containerization (UPBK2H6LZM)` — under Apache-2.0, so redistribution is permitted with notices.

**Recommendation: bundle it, and ship two artefacts.** If a Flotilla release is already pinned to
one runtime version, bundling that exact installer makes the pairing real rather than documented,
installs offline, and removes version skew by construction. Downloading during install was the
other option and is worse: a `preinstall` script running `curl` fails on a locked-down network,
cannot be staged by Jamf, and is the kind of thing a security review rightly objects to.

Two artefacts because the audience splits: a **slim** PKG (Flotilla only, for anyone who already
has the runtime or manages it separately — which is what a Jamf fleet does) and a **bundled** one
(~130 MB, for a single Mac from cold). The installer must never *downgrade* an existing newer
`container`, and must say what it is about to install before it does.

Not built. This is Phase 5 packaging and it lands after beta2 is tagged, not alongside it.

## Q18 — Flotilla cannot report that a container failed (settled 2026-09-12)

**Question.** The dashboard and the menu-bar popover each had a "Needs attention" panel, the
container dot had a danger colour, and the activity feed had a failure tint. Each was keyed on a
container state matching `exit`, `dead`, `fail`, `restart` or `(0)`. Does Apple's `container`
produce any of those, and if not, what should those surfaces show?

**Answer: it does not, and there is no failure signal to replace it with.** Measured against
`container` 1.4.1 on 2026-09-12:

- `container ls -a --format json` reports `running` and `stopped` and nothing else.
- A container run as `sh -c 'exit 3'` ends in state `stopped`. So does one killed with
  `container kill`. A clean exit, a non-zero exit and a SIGKILL are indistinguishable in the
  listing.
- `container inspect <id>` returns a `status` object with exactly three keys — `networks`,
  `startedDate`, `state`. **There is no exit code anywhere in the payload.**
- A container whose command does not exist never becomes a record: `run` fails with the guest's
  error and leaves nothing to list.
- The runtime's own status enum, read out of the binary as a contiguous `RawValue`/`AllCases`
  block: `unknown`, `stopped`, `running`, `stopping`.

The one place an exit code does exist is the **foreground** `container run` process's own exit
status — which Flotilla never sees, because nothing it lists was run in the foreground.

**So the rules were unreachable, in five places**, and their unreachability was invisible: a
panel that is absent when there is no problem looks exactly like a panel that can never appear.
The comments asserted the intent confidently — "`exited (137)` is not the same as `stopped`, and
they must not look the same" — and described Docker's vocabulary rather than Apple's.

**The decision.** Flotilla does not claim a failure it cannot observe. `ContainerState` in
`FlotillaCore` owns the vocabulary and the single question the UI asks of it, and the answer to
"does this need a person?" is `unknown` — the runtime declining to say, which is the one listed
state that genuinely wants attention. `stopping` gets the warning tint, being the one state that
is honestly *in progress*. `stopped` is not a problem: most were stopped on purpose and the
runtime gives no way to tell the rest apart.

The panels stay, because they are absent when empty by design and the rule behind them can now
actually match. They will be rare. Rare is the point.

**Machines are the same, with one more state.** The sixth copy of the rule lived in
`MachinesView.stateColor`, testing `status.contains("error")` and `contains("fail")`. The
runtime's VM status enum — read from a binary block whose neighbours are unmistakably the VM
domain (`kernel`, `initialFilesystem`, `bootLog`, `rosetta`, then `create`/`freeze`/`thaw`/`trim`)
— is `starting`, `running`, `stopping`, `stopped`, `unknown`. No failure there either, so
`unknown` takes the danger tint and the transitional pair keeps amber. `MachineState` is a
separate type from `ContainerState` because it has `starting` and containers do not, and letting
one borrow the other's cases is how a vocabulary drifts. `starting` and `stopping` were **not**
observed directly on this Mac — `machine start` from the shell did not boot the machine — so
those two rest on the binary and on the pre-existing amber rule, which was itself written after a
real bug.

**What would reopen this.** A `container` release that reports an exit code, or a state beyond
those four. `ContainerStateTests` pins both — the known vocabulary, and every state in the
captured fixtures — so such a release arrives as a failing test rather than as silence. Proved
against a negative control: narrow the parser and the fixture test fails, naming the container.

## Q19 — Tags are the user's own data, and the log feed is a table (settled 2026-09-13)

Two changes that arrived together and share one argument.

### The Logs feed is a table, like every other section

It was a `LazyVStack` of hand-drawn rows, which is what a log *reads* like and not what the
screen is for: you come here to find the handful of lines that matter among two hundred that do
not, take them somewhere else, and jump to whatever produced them. None of that was reachable
from a stack of `Text` — no selection, so nothing to export; no columns, so nothing to hide; and
the source was a fixed-width label rather than a way in. It is now a `SwiftUI.Table` with the
same selection, checkbox column, column customisation and row context menu the other five
sections have, plus CSV export and a clickable **Object** column that opens that container's or
machine's own Logs tab.

**It has no `sortOrder`, and that is the deliberate difference.** Every other table sorts because
its rows are independent things. Log lines are not: within a source, a line's position *is* its
meaning, and there is no clock in the data — `container logs` has no `--timestamps`. A clickable
"Received" header on a fetched feed would reorder two hundred lines that all share one timestamp,
by nothing, and look authoritative doing it. The same reasoning governs the optional Received
column, which is **off by default**: it shows when Flotilla received the line, which is genuine
per-line information while streaming and one shared read time per source when fetching. The
popover that switches it on says exactly that, because a column of identical timestamps left
unexplained would be read as the container's own clock and believed.

The Received column reads `2026-09-13 12:17:19` — fixed, 24-hour, no AM/PM and no locale.
`.formatted(date:time:)` follows the user's region and was printing `12:17:19 PM`, which is right
for "Updated …" in a toolbar and wrong for a log: the date matters because one feed can carry
lines read hours apart, AM/PM costs three characters and orders nothing, and a twelve-hour clock
is the one that makes 12:04 ambiguous. It is also text-sortable, which is the other reason the
width is worth paying.

Wrapping is off by default and a long message can be opened row by row instead. The chevron
appears only on rows that actually overflow, and that is **measured** by `ViewThatFits` rather
than guessed from a character count: the column is resizable, so the same line overflows at one
width and fits at another. The first attempt tested `text.count > 96` and was wrong in both
directions.

### Tags are content, not configuration

Finder-style tagging across containers, machines, volumes and networks: a fixed palette of seven
colours, tags that carry a user-chosen name, a starter set on first run, creation from any row's
menu, and a Settings pane that renames, recolours and deletes them everywhere at once.

**Not in `SettingsStore`.** That registry is a closed list where every key is declared once,
carries a managed policy, appears in the Settings UI and the Jamf key list, and is checked by
`check-settings-consumers.sh` — all correct for "poll interval" and meaningless for "the seven
tags you made". More concretely, a `manageable` key can be seeded or locked by a configuration
profile, and an admin pushing a tag list over someone's own tags is not a capability worth
building. Tags are written to the same preference domain by the same rules that file argues for:
plist-native, one key per concern, readable with `defaults read dev.melonfleet.Flotilla
tagDefinitions`.

**The rules live in `FlotillaCore`.** `TagBook` is Foundation-only and holds every decision —
what a legal name is, that duplicate detection ignores case and diacritics, that a rename keeps
every assignment because identity is a minted id rather than the name, that deleting a tag takes
its assignments with it, that an unknown tag id is refused rather than stored where it would be
invisible. The app target has no test target; this is the same argument `DeletePolicy` and
`ActivityKind` made when they moved.

**A tag keys on kind *and* id.** A volume called `web` and a container called `web` are different
objects. The activity feed learned that the hard way — `events(for:)` was subject-only, so a
container listed a volume's history — and `TagSubject` is built so that cannot happen again.

**Deleting a container does not delete its tags.** The live inventory comes from a poll that can
fail or return early, and a sweep on every refresh would throw the user's tags away the first
time it hiccuped. The Tags pane offers an explicit **Clean Up**, counted only against kinds whose
list has actually loaded.

**Images are the one section without tags, on purpose.** In Images, "tag" already means an image
reference's tag — `nginx:latest` — with its own column, its own `Tag…` action and its own
allowlisted `image tag` command. A second, unrelated "Tags" menu on that screen would be the
ambiguity, not the consistency.

**Two AppKit behaviours were measured rather than assumed.** A menu item's icon is tinted by
AppKit, so `Image(systemName: "circle.fill").foregroundStyle(…)` rendered all seven swatches in
one colour — on the menu where you *choose* the colour. They are drawn `NSImage`s with
`isTemplate = false`. And a grouped `Form` reads a labelled control as `LabeledContent` and
renders its label in the row's leading column, so `TextField("Name", …)` put the word "Name" at
the start of all seven manager rows and pushed the swatch out of view; `.labelsHidden()` on the
row is load-bearing.

**Filtering by tag is the search field, everywhere.** A tag entry in each section's filter control
was the alternative, and Volumes and Networks could take one as a string id while Containers and
Machines could not without widening their typed `Filter` enums. A tag filter on two sections out
of four is the asymmetry this app keeps being asked to remove, so the tag's *name* is matched by
the same free-text search every section already has.

**Bulk tagging asks a three-state question, and answers it once.** With several rows selected a
tag is on all, on some, or on none, and the swatch says which — tick, dash, plain, the three marks
a checkbox uses. Picking it applies it to everything selected unless it is already on everything,
in which case it comes off. Toggling each row independently is the obvious implementation and the
wrong behaviour: on a mixed selection it would tag half and untag half, which is nobody's reading
of choosing a tag with six rows selected. On a mixed selection the item also *says* which
direction it will go, because the dash alone does not.

**What is deliberately not built.** Tags on images, and a tag filter control.

## Q20 — There is no supported-registry list, so the screen says so (settled 2026-09-13)

The question was "what other OCI registries can we use, and can we manage them from Settings?".
The first half has an awkward answer: **all of them**. Apple's `container` has no notion of a
supported registry — it pulls from anything that speaks the OCI distribution API, and the only
thing that decides where an image comes from is the host in the reference. `ghcr.io/apple/
container-builder-shim/builder:0.13.1` is in this Mac's own `container` config already. A
reference with no host resolves to `docker.io`, and there is no setting that changes that:
`container system property list` has sections for build, container, dns, kernel and machine, and
none for registries.

So the Registries screen is a **catalogue, not a compatibility matrix**, and it says that in its
own footer. It lists the registries you would otherwise have to remember the hostname of, plus
your own, plus the ones this Mac is actually signed in to. Presenting a curated list as though
unlisted registries did not work would be exactly the confident wrongness this project keeps
removing.

**The entry requirement for a built-in row is a single, real, account-independent hostname.**
That is why Amazon ECR, Azure Container Registry, Google Artifact Registry and Harbor are absent
despite being entirely usable: their hostnames are per account —
`<account>.dkr.ecr.<region>.amazonaws.com` — so a built-in row would be a row whose host cannot
be used, which is a placeholder control. They are what **Add Registry…** is for, and the form's
help names their shapes.

**The table shows three sources, and the third is what keeps it honest.** Catalogue, the user's
own additions, and whatever `container registry list` actually reports. A registry someone signed
in to from a terminal appears here marked "not in your list" rather than being invisible — a
screen about credentials that cannot see the credentials would be worse than no screen.

### The credential review the allowlist deferred

`registry login` was listed in `Allowlist` as deliberately absent — "not Phase 1, a credential
surface that deserves its own review". This is that review, and it is written on the rows rather
than only here.

1. **The secret never appears in argv.** argv is readable by every process running as this user
   through `ps`. `container registry login` offers `--password-stdin`, and the spec has **no
   password flag at all**, so the allowlist cannot construct a command carrying one even if a
   caller asks — `--password` is refused outright, and a test pins that.
2. **`ContainerHost` gained stdin, and the default implementation throws.** A host that cannot
   carry input must fail loudly; silently dropping it would run `--password-stdin` against an
   empty stdin and produce an authentication failure whose real cause was here.
3. **All three leaves are local-only.** Not merely the login: `registry list` enumerates every
   registry this Mac holds credentials for, which is an inventory of the owner's accounts, and
   `logout` destroys them. The reasoning is `image pull --scheme`'s, applied harder.
4. **`.registryHost` is a new shape, narrower than `.imageReference`.** The operand of a login is
   the host a password is sent to, so a scheme, a path, a `user@` and anything non-ASCII are all
   refused: `ghcr.io/apple` and `dоcker.io` (Cyrillic `о`) must not be accepted as destinations.
5. **The thrown error names the registry and not the account.** The first draft used
   `auditDescription` with a comment claiming it drops flag values. A probe against the live CLI
   printed `container registry login --username someone --password-stdin localhost:5001` — it
   does not, because `.identifier` is classified as not-free-form precisely so audit lines keep
   the names that make them useful. Right for every other command, wrong here: a registry
   username is often an email address and this string reaches an alert, the error log and the
   support bundle.

**Flotilla stores no credentials.** The password is held in the sheet's state, handed to the CLI,
and dropped; the Keychain entry is written by `container`. `userRegistries` in the preference
domain holds hosts and display names only.

**Verified end to end against the real CLI**, not only by unit test: a throwaway local
`registry:2`, a sign-in through `ContainerCLI.registryLogin` (so the stdin pipe itself was
exercised), the login appearing in a decoded `registryLogins()`, a wrong password refused with an
error carrying neither the username nor the password, and a sign-out leaving the store empty. The
fixture in `Fixtures/registries.json` was captured the same way — it had to be, because the JSON
calls the fields `name`/`id`/`modificationDate` while the table header says `HOSTNAME` and
`MODIFIED`, and a decoder written from the printed output would have shown an empty table to
anyone with logins.

### Q20 amended — the registry screen becomes a form, and the default becomes real (2026-09-13)

The owner used the first version, hit a bug, and asked for a redesign. Both halves are recorded
here because both changed a decision above.

**The bug: Docker Hub is three hostnames.** Signing in to `docker.io` put the credential under
`registry-1.docker.io`, so the Docker Hub row still read "Not signed in" while a second row
appeared at the bottom, for the same account, marked "not in your list". GHCR has no such rewrite,
which is what made it look like a Docker Hub problem rather than a matching problem.
`KnownRegistry.canonicalHost` folds the three spellings; Sign Out names the host the credential is
*stored* under, or it would report success and leave the login in place. Nothing else is aliased —
`gcr.io` and `us.gcr.io` are different registries.

**Two accounts on one registry is not possible, and the UI no longer implies it.** Measured: two
`registry login` calls to one host leave **one** credential, the second replacing the first,
because the store is keyed by hostname. The owner asked for multiple accounts per registry; it
cannot be built, so the row shows who you are signed in as and offers **Switch…**, which is
simply signing in again. That is what the runtime does anyway — the button names it rather than
hiding it behind a sign-out-then-sign-in dance that would achieve the same thing in two steps.

**The Add form asks for a *kind*, not a row.** The first version's picker offered "catalogue
entries not already in your list", which on any install is empty: every registry with a fixed
hostname is always listed and is never something you add. `RegistryKind` is the honest axis — the
registries people add (Amazon ECR, Azure, Google Artifact Registry, Harbor, JFrog, Gitea, a
self-managed GitLab, a bare `registry:2`) have no fixed host, and what they share is *how you
authenticate to that family*. That is what the rail teaches, and the picker only offers kinds
where `hostIsFixed` is false, so a choice that could only produce a duplicate is not offered.

Per-family guidance now lives on the kind, and a row overrides it only where a specific host
differs. `credentialHint` and `tokenURL` return nil when `hasAccounts` is false — caught by a
test, because `registry.access.redhat.com` has no sign-in and is nonetheless of kind `.redHat`,
so it had inherited Red Hat's service-account page and would have offered "Create a token…" for a
registry that takes no credential.

**The Add screen is embedded, not a sheet.** As a sheet it rendered about 400pt wide, under
`FormScaffold`'s 1000pt rail threshold — so the rail, which is the entire point, did not appear.
Embedded is also what New Volume and New Network do, per the 9 August modal-versus-embedded
decision, so the Registries tab supplies its own container instead of being wrapped in Settings'
grouped `Form`.

**`defaultRegistryDomain` now does something.** It had been persisted since the beginning, shown
in Resources as "Default registry", and read by exactly one thing: the About page, which
*displays* it. Its summary claimed it "mirrors `[registry] domain`" — `container` does have that
property, and `container system property` offers only `list`, so nothing Flotilla can run will
change it. A control that stores a value and alters nothing is the defect class this project keeps
deleting, and Settings had one of its own.

It now means what Flotilla can actually deliver: **the registry its own Pull form completes an
unqualified reference against.** `ImageReferenceHost` owns that, and the screen states the
smaller claim rather than implying the larger one — a bare name typed in a terminal still goes to
Docker Hub. Docker Hub is deliberately never rewritten even when it is the chosen default,
because the CLI already completes `nginx` to `docker.io/library/nginx:latest` including the
`library/` namespace that only Docker Hub has; prefixing `docker.io/nginx` ourselves would name
an image that does not exist. The setting moved from Resources to Registries, beside the list of
registries it can name.

**The account name shape was wrong, and it shipped.** `--username` was `.identifier`, which
refused half the account names registries actually issue: Red Hat's `12345678|name`, Quay's
`org+robot`, Harbor's `robot$name`, Google's `_json_key`, and any email address.
`.registryUsername` accepts those and still refuses anything that could change the command's
meaning. It is classified **free-form**, so the audit line redacts the account while keeping the
registry — which removed a hand-built error string that had been routing around the same problem
in one `throw` instead of fixing it at the source.

### Q20 amended again — registries can be removed, and Amazon's "popular registries" are not registries (2026-09-13)

**The panel the owner asked about lists publishers, not registries.** Amazon's ECR Public Gallery
shows "Popular registries": Docker official, Chainguard, Datadog, Ubuntu, NGINX, Python, Lambda
and the rest. Measured — `public.ecr.aws/docker/library/alpine`, `.../chainguard/static`,
`.../ubuntu/ubuntu`, `.../nginx/nginx` and `.../datadog/agent` all return a manifest from that
**one** host. They are namespaces inside `public.ecr.aws`, which is already a row; AWS's own
wording is loose. Adding them would create nine rows for one registry.

One exception, and it is a real one: **Chainguard runs its own registry at `cgr.dev`**, proven by
an anonymous manifest fetch that returns 200 there as well. That is a row.

**Built-ins can now be removed, which reverses a decision two commits old.** They used to refuse
removal with `RegistryError.builtIn` — defensible, since a built-in is code and there is nothing
to delete, and wrong for the person using it: a list of ten registries where you use two is a
list you stop reading. A built-in is **hidden**; one of the user's own is deleted. The hidden set
is stored as hosts rather than indices, so reordering the catalogue later cannot hide a different
registry than the one that was removed.

Hiding also fixed the Add form's remaining awkwardness. Its picker offers kinds with no fixed
host — and now, above them, the built-ins you removed, by name. Putting one back restores it
exactly: host, guidance, links. Typing a hidden built-in's host does the same thing rather than
creating a user-added row that would shadow the real one with worse guidance, and the duplicate
check runs against the **visible** list so that path is reachable at all.

`RegistryError.builtIn` was deleted rather than left in place: nothing throws it now, and an error
case that cannot happen is the same claim as a control that does nothing.

### Q20 settled — the catalogue is a menu, not a list (2026-09-13)

Three designs preceded this one and all three were elaborations of the same wrong idea: that the
registries Flotilla knows about *are* your list. The owner had to say it three times before it
landed, and the corrections are worth recording because each one looked locally reasonable.

1. **Every known registry, permanently listed.** Ten rows on a fresh install, of which most
   people use two. The Add form's picker was then empty by construction — everything addable was
   already there.
2. **Hideable.** Remove now worked, but a removed registry needed somewhere to come back from.
3. **Hideable with an undo.** A "Put back" picker above the Add picker: a second way to do the
   one thing that form exists for.

The list starts with **Docker Hub and GHCR** — where a host-less reference goes, and the other
one almost everybody already pulls from. Everything else in `KnownRegistry.catalogue` is a menu
item until someone adds it. Adding a known registry brings its host, guidance and links with it;
adding anything else asks for a kind and a host. Removing takes it out of the list, and adding it
again is the same act as adding it the first time. There is no second tier, no hidden set, and no
"put back".

**Definitions are not persisted — hosts are.** A stored row whose host is in the catalogue is
rehydrated from the catalogue on every launch, so improving a registry's wording or fixing a
token URL reaches lists that already exist. Freezing the definition into the plist would mean the
first person to add GHCR keeps that day's text for ever. Only what the catalogue cannot know is
written down: host, kind, chosen name, scheme. The two retired keys from designs 2 and 3 are
actively removed on save — a stale `hiddenRegistries` is a fact about a feature that no longer
exists.

### Q20 finished — the form asks one question at a time, and signs you in (2026-09-13)

Three refinements on the owner's fourth pass, all of them about the same thing: a form should not
ask for what this answer will never need.

**The form opens as one picker.** Registry, and nothing else. Choosing a known registry adds its
server and its guidance; choosing Custom adds a type, a host, a name and a scheme. Showing all of
it up front asked someone adding `mcr.microsoft.com` to read past four fields it will never use —
and past a sign-in for a registry that has no accounts at all, which now says so in a sentence
instead.

**Sign-in happens in the form.** It used to add the registry and send you back to the list to
sign in from a separate sheet: two screens and a context switch for one intention. The credentials
are optional and say so, and a failed sign-in does not undo the add — the registry is genuinely
in the list by then, so the form stays open with the error and the button becomes Sign In rather
than offering to add it twice.

**"Something else" appeared twice on one screen** — once as the way to reach the custom path, and
again as the default answer to the question that path asks. The first is now **Custom**, the
second **Generic or self-hosted**, and the field is **Type** rather than Kind.

## Q21 — A group starts containers together, and `container` has no `--` (settled 2026-09-14)

**Asked:** competitor tools and Docker let you build an app out of several containers — a
database, a cache, a web server, an app process. Can Flotilla do that today?

**Measured first.** Containers on one network reach each other **by IP** and not by name. From a
running container on `default`:

```
ping 192.168.64.24   works, 1.0 ms
ping web             127.0.53.53 — the ICANN collision sentinel, i.e. a public DNS answer
ping vault           bad address
```

`resolv.conf` points at the gateway and that resolver holds no container records.
[apple/container#1809](https://github.com/apple/container/issues/1809) is the open request for
per-network DNS. The Run form's Network field had been promising the opposite — *"containers on
the same network reach each other by name… so an app can talk to a database as `db`"* — which is
a sentence that gets somebody to wire `db` into a connection string and then debug their own app.
Corrected.

**The workaround does not close the gap either.** `sudo container system dns create flotilla`
(run by the owner; it needs an administrator) wires macOS's resolver to the runtime's own DNS
server on `127.0.0.1:2053` — confirmed in `scutil --dns` — but that server answers NXDOMAIN for
containers, including ones started afterwards with `--dns-domain flotilla`. The flag writes
`domain flotilla` into the container's `resolv.conf`; nothing registers a record on the other
side. Not proven further: finishing the proof needs `[dns] domain` in `config.toml` (there is no
CLI write path — `system property` has only `list`) and probably a runtime restart, which would
stop every running container on the machine.

**Proven on 2026-10-06 (`container` 1.5.0): with both halves, it does work.** The half that was
missing is `~/.config/container/config.toml` → `[dns]` `domain = "flotilla"`, then a service restart
(no CLI write path; the restart stops every container). With that and the admin-created resolver:

| From → to | Result |
|---|---|
| Default network → `dns-a.flotilla` or bare `dns-a` | resolves and connects |
| Custom network → bare `dns-b` (same network) | **resolves and connects** — Compose-style |
| Mac → `dns-a.flotilla` | resolves (IPv4) |
| Custom network → `dns-a.flotilla` on *another* network | resolves, connection refused (isolation) |

Apple's `docs/networking.md` warns that bare names on custom networks do not work
(apple/container#1809); on 1.5.0 they do once the domain is configured. Names come back IPv6-first,
and an IPv4-only listener is still reached by name. Gateway wiring (below) remains the fallback for a
Mac with no domain configured.

**What does work, and is worth telling users:** each network's gateway `.1` reaches the host, so
a container finds another container's **published port** there — `192.168.64.1:8080` — and it
works **across isolated networks** (a container on `test3` opened a connection to a container on
`default` that way). The address is stable across recreations, unlike a container IP.

### The decision

A **group** is a saved set of containers that start and stop together: `ContainerGroup` and
`GroupBook` in `FlotillaCore` with the rules and the tests, `GroupStore` for plist-native
persistence under `containerGroups`, a Groups section under the Containers sidebar heading.

It is a **remembered form submission, not an orchestrator**. Start issues the same `container
run` per member the Run form issues for one, in listed order, through the same allowlist — it
adds no command to the boundary. Ruled out, each for its own reason: dependency graphs and health
gating (need a supervisor that outlives the command, and half of one is worse than none), restart
policy (Q18 — Flotilla cannot observe that a container failed), and `docker-compose.yml` import
(it would silently drop three quarters of the file's meaning). `PLAN.md`'s "Compose is not going
to happen" still stands; this is not that.

Rules worth naming: a member **must** be named, because `container run` without `--name` takes a
random id and the group would never find it again; member names are unique across the **whole
book**, because container names are global on this Mac; and nothing about "running" is stored —
state is derived from the live container list every time it is asked.

`GroupMember` is deliberately **not** `Flotillafile.ContainerSpec`, though they convert both ways
so a future import maps onto a group rather than growing a second importer. `ContainerSpec` is a
file format — immutable, version-pinned, parsed from something a stranger may have sent — and it
is withheld from this release precisely because it is not settled.

### `container` has no `--`, anywhere

Building Start found it. `runArguments` appended `--` before the in-container command on the
reasoning that a trailing `--rm` would otherwise be re-parsed as a flag of `container run`. Both
halves of that were wrong:

```
container run --rm --name flagprobe alpine echo --name stolen
→ prints "--name stolen"; the container is named flagprobe      (nothing is re-parsed)

container run --name demo-cache alpine:latest -- sleep 600
→ Error: failed to find target executable --                     (the separator is executed)
```

So **every `container run` carrying a command had always failed** — the Run form's Command field
had never worked once. The identical bug was found and fixed for `exec` in August and the fix was
scoped to `exec` alone. The separator is still required on the way **in**, because without it
`Allowlist` reads a trailing `-la` as an unknown flag and refuses the command; it is now stripped
from the canonical argv for every subcommand, and a test asserts that no canonical command ever
carries one.

The unit tests passed throughout both times, because they check the argv we *build* and not what
the CLI *accepts* — the same family as the nine in `CLAUDE.md`. Previews now render the
**validated** argv rather than the input grammar, so the Run sheet, the group form and the
progress panel can no longer show a token the CLI would refuse.

### Q21 amended — Groups joins the other sections, and a group must not print its own secrets (2026-09-14)

**Parity.** Groups now wears everything the other sections wear: list/cards, hideable columns, a
state filter that hides itself when there is only one state on screen, row selection with a bulk
bar (tag, start, stop, delete), tags beside the name, a row `⋯` menu shared with right-click, and
the recent-activity band. `ActivityKind` grew a sixth case, `.group`, rather than filing groups
under `.container`: a tag keys on kind **and** id, and a group called `shop` and a container
called `shop` are different objects. Group start and stop record their own feed entries, so the
new filter chip is answering something rather than sitting there empty.

**Row actions follow the house arrangement**, at the owner's direction: lifecycle buttons, then
`⋯`, then a divider, then the bin. Edit moved out of a pencil and into the menu — it opens a whole
screen, which is not a one-click action, and a fifth glyph in a table cell reads as a toolbar.

**State moved to where every other table puts it**, also at the owner's direction: a coloured dot
between the checkbox and the name, not a labelled column on the right. A group's state carries a
count that a container's does not, so a partly-running group shows `3/4` beside its dot and every
other state is the bare dot.

**A group must not print its own secrets.** Starting a WordPress group put
`MYSQL_ROOT_PASSWORD=…` and `WORDPRESS_DB_PASSWORD=…` in the progress panel in plain monospace,
where it stayed until dismissed — and went straight into a screenshot. `ValidatedCommand` already
draws the line this needs: `localPreview` is "for showing a person the command **they just
typed**", `auditDescription` shapes free-form values away. The distinguishing test is *audience*,
and for a group the audience is not the person who supplied the values — a group replays what was
saved, possibly weeks ago, from one click on a table row, with nothing else on screen showing it.

So the group progress panel and the group form's rail both use `auditDescription`, and the member
editor keeps `localPreview` because there the env you are looking at is the env you are editing.
The Run sheet keeps it too, for the same reason: you typed those values into the form behind the
panel. This is SEC-03 restated for a surface that did not exist when SEC-03 was written.

**The WordPress group, and what it proves.** Two services, `wp-db` (`mysql:oraclelinux9`) and
`wp-site` (`wordpress:latest`), and the wiring is the whole point: with no DNS between containers,
`WORDPRESS_DB_HOST` is `192.168.64.1:33306` — the network's gateway and the port the database
publishes there. Verified end to end: the site serves at `127.0.0.1:8081`, reaches the install
screen rather than "Error establishing a database connection", and `mysqli_connect` from inside
`wp-site` returns a live handle.

The database publishes on **`192.168.64.1:33306`, not `0.0.0.0:33306`**, and that is the part
worth copying. Measured with a probe container: a port bound to the gateway address is reachable
from other containers and from the host, and refused on the Mac's LAN address. Published on
`0.0.0.0` — which is what a bare `33306:3306` means — a development database is on the office
network. The site itself binds `127.0.0.1` because nothing needs to reach it but this Mac.

### Q21 amended — a group opens, and reaches the menu bar (2026-09-14)

**A group's row expands.** A chevron beside the name reveals the services inside it, each as a
row of its own: the container's state dot, its name, its tags, its image, and Start / Stop / Logs
for that one container. Not `DisclosureTableRow` — that needs parent and child to be the same
type, and a group and a service are not. `GroupRow` carries an optional `service`, the rows are
spliced in `displayedRows`, and only **group** rows are sorted: services keep start order, which
is the one order that means anything. Sorting them alphabetically would put the web tier above
the database it waits for and imply that is what happens.

Service rows are deliberately not selectable. The checkbox drives the bulk bar, and "start 2
groups" meaning one group and somebody else's database is a claim the bar could not make good on.
A service whose container does not exist yet shows a hollow ring rather than a grey dot, and its
name is plain text rather than a link to a page about nothing.

**Groups reach the menu bar**, as a third `MenuKindBox` beside Containers and Machines, with the
same three controls per row. Two differences, both argued rather than inherited: the box is
**hidden when there are no groups**, because a box reading 0/0 on a Mac that has never made one is
furniture — Containers and Machines always have something to count, a group is opt-in. And
`popoverRow` grew an optional `restartable`, defaulting to `running`: a container is up or it is
not, but a group can be half up, and that is precisely when restarting is the useful thing.
`restartGroup` is one operation rather than a stop followed by a start — two calls would give two
progress panels for one intention, and the second would begin from whatever the first left behind.

**A named volume is created owned by root**, measured at `0:0` mode 755. An image whose entrypoint
starts as root and drops privileges — the official mysql and postgres — fixes its own ownership.
`redis:alpine` does not, and the server exits on "Can't open or create append-only dir: Permission
denied". That is how `wp-redis` failed to start, and the failure reads as the *group* being broken
rather than the volume being unwritable, so the Volumes field now says it before you hit it. The
Redis service dropped its volume: an object cache is derived data, and losing it on restart is a
cache behaving correctly rather than a fault to engineer around.

**The WordPress group is four services now** — `wp-db`, `wp-redis`, `wp-site`, `wp-phpmyadmin` —
and every one of them is wired through the gateway, because there is still no DNS. phpMyAdmin
binds `127.0.0.1` and is given `PMA_HOST`/`PMA_PORT` but **no** `PMA_USER`/`PMA_PASSWORD`: a
database admin panel that logs itself in is reachable by anything running on the Mac, and
loopback is not authentication. Redis is reachable from WordPress (`+PONG` over the gateway) but
WordPress does not yet *use* it: the official image ships no `redis` PHP extension, and its
entrypoint only writes `wp-config.php` when one does not already exist, so neither the extension
nor the constants can be added by environment alone. Making it a real object cache needs a built
image, which is a separate decision.

## Q22 — Clusters is a section, and the k8s family is treated as provisional (settled 2026-09-14)

**Asked:** can Flotilla manage Apple's local Kubernetes clusters?

`DECISIONS.md`'s standing rejection of "Kubernetes (or any CRI-based orchestrator)" does not
answer this. That entry rejects Flotilla *becoming* a CRI runtime for the fleet — "a CRI shim +
CNI for per-VM containers on macOS is a multi-year project". `container k8s` is six CLI commands
that boot a kind cluster in a VM, which is the shape of work `machine` already does here.
`research/CONTAINER-UPGRADE.md` had already assessed the family and concluded it should stay out
"unless Kubernetes becomes an explicit product feature"; the owner asking is that condition
being met.

### What is built

An allowlisted family — `create`, `start`, `delete`, `rm`, `list`, `ls`, `load-image`,
`write-config` — a parser, and a **Clusters** section under Virtualisation beside Machines.

**The whole family is `.localOnly`, including the read.** That is the only exception in the table
to "reads are exposed", so it carries its own argument: the command calls itself EXPERIMENTAL and
Apple's `docs/kubernetes.md` does not use the word at all, and a read that enumerates the owner's
clusters is the reconnaissance half of the same surface. The section says so in a band at the top
rather than only in a commit message.

**No Stop.** The CLI has `create`, `start` and `delete` and nothing between, so a Stop button
would have nothing to call. Delete is the only way down, and it destroys the VM.

### Three findings that constrain what any of this can claim

**`k8s list` has no `--format`.** Every other listing offers `json|table|yaml|toml`. This is the
one place in `FlotillaCore` that reads a human interface, and splitting the printed row on
whitespace is not merely fragile — it is silently wrong on the first real cluster. CLUSTER comes
back empty, removing a token; MEMORY is `16384 MB`, adding one. The errors cancel, so a naive
parser gets eight tokens for eight columns and reports NODE holding the role and MEMORY holding
the string `MB`, with nothing thrown. So the header is the authority and rows are sliced at its
offsets, taken from the same output because the CLI recomputes widths per render.

**The CLUSTER column is dead on 1.4.1** — empty with two clusters present, with the cluster's
name printed under NODE. There is no cluster-to-node hierarchy to draw, so the section is a flat
list. If Apple ever populates it, `AppModelClusters` is where the grouping goes.

**`k8s create` writes `~/.kube/config` itself**, at creation time, with no flag to prevent it —
measured, and it contradicts what this session first told the owner. A Flotilla-owned kubeconfig
is an *additional* copy to hand to `KUBECONFIG`, not a way to leave the user's file alone, and
the file it writes has no `current-context`, so `kubectl` against it fails until one is named.
Both facts are in the dialog that offers it, because both are things a user would otherwise
discover by being confused.

### And one bug this section taught

A wrapping `Text` inside an **`HStack`** must not carry `.fixedSize(horizontal: false, vertical:
true)`. This app uses that modifier almost everywhere and it is right almost everywhere — in a
`VStack`, where the width is already decided. In an `HStack` the width is negotiated, so fixing
the vertical axis makes the text report its ideal height for a very narrow proposal. Measured:
the experimental band alone drove the split view from 865pt to 2005pt, pushing every section's
content above the top edge and rendering a blank window.

Worse, **the grown split view is saved**. It came back at 2182pt on the next launch, on every
section including ones that had not changed — which reads as the whole app being broken, and
made the first bisect lie, because the corrupted state survived the change meant to clear it.
Deleting `NSSplitView Subview Frames main, SidebarNavigationSplitView` from the preference domain
is the cure. A window-layout reset is listed as unbuilt in `PLAN.md`; this is the first concrete
argument for it.

## Q23 — Themes change the bar and the background, and controls follow macOS (settled 2026-09-26)

**The owner's design.** A theme changes exactly two things: the window bar and the content
background. There are **four themes, the same four in light and dark: Stripe, Flesh, Cantaloupe and
Canary**, each named after its bar. (A first draft the same day had three light and three dark, with
a Rind theme; the owner replaced it with Stripe and made the sets identical.) The install defaults,
Cantaloupe for light and Flesh for dark, are the look the app already had. The spec, with the
measured contrast for all eight variants, is `design/THEMES.md`.

### The decision

- **Two pickers, not one list.** Auto switches appearance at sunset, so a single "current theme"
  would have to survive being drawn in both. The user picks a light theme and a dark theme; Auto
  moves between the pair. `lightTheme` and `darkTheme` are separate settings keys holding one
  `ThemeName`, and a managed profile can seed or lock either. VS Code's preferred light and dark themes are the precedent.
- **Everything else is fixed per appearance**, the same in every theme: charts, status, tags. So
  there is one set of colours to check in light and one in dark, not one per theme.
- **Controls follow macOS.** Buttons, sidebar and table selection, and focus rings use the **system
  accent**. Links use the **system link colour**. This **reverses** item 11 of `CLAUDE.md`'s settled
  list, which kept the watermelon accent on every control. The owner's reason: the app should behave
  like Finder and System Settings, with the melon on the chrome and the data rather than on every
  button. The `AccentColor` asset is deleted, because an app that declares its own accent can never
  follow the user's.
- **The melon did not leave the data.** The dashboard's memory series and the JSON literal colour
  were drawn in the accent; they now use `Theme.melon` and `Theme.melonText`, the accent's old
  values, so a chart does not change colour when the user changes System Settings.

### Measured, and it shaped the design

- **Full-strength honeydew hides the green status colours:** online 2.5:1 and success 2.1:1, below
  the 3:1 a status mark needs. Stripe's light body is honeydew at 30% over white, `#E5F4DC`, which
  holds 3.6 and 3.0.
- **White bar text failed on every bar:** 2.8:1 on cantaloupe, 2.5:1 at best across the four. The
  ink is seed on all of them.
- **And a bug that predates themes:** the light warning amber `#E5A100` measured 2.1:1 on cream, the
  background the app had always shipped with. It is now `#A87600`, whose worst case, the honeydew
  wash, holds 3.5:1.


### Q23 amended — the window bar shows "Flotilla" alone (2026-09-26)

The owner found the full **melonfleet | Flotilla** lockup heavy on the bar, especially in the seed
ink every theme's bar now uses. The bar now draws `Wordmark(lockup: .appName)`: the plain word.
About and the menu-bar popover keep the full lockup.

A watermelon `o` in "Flotilla" was tried and **rejected** the same day. In the bar's single ink its
four rings merge into a solid dot at 17pt and the word reads "Fl•tilla"; the owner asked for an
ordinary `o`. The variant was deleted rather than kept as an option.

### Q23 amended — six light themes, four dark (2026-10-05)

The owner added two light-only themes on the honeydew wash, **Canary Honeydew** and **Flesh Honeydew**,
from a set of pastel tumblers (saturated lid, pastel body). Dark stays at four: every dark body is
seed, so dark forms would only repeat dark Canary and dark Flesh, and the owner could not think of
more dark combinations.

So the shared `ThemeName` enum is split back into **`LightTheme` (six) and `DarkTheme` (four)**. With
one type, the dark key would have accepted a light-only theme, which a managed profile could set and
nothing could draw. The four shared themes keep their raw values, so stored preferences carry over.
A stored or managed light-only value for dark is refused and falls back to Flesh; three tests hold
that. Measured: Canary over the wash is 1.4:1 bar-to-body, the closest pair in the set, and leans on
the bar's divider.

### Q23 amended again — twelve themes, one background per row (2026-10-05)

The owner, later the same day: **three rows of four**. Cream: Stripe, Flesh, Cantaloupe, Canary.
Honeydew: the same four bars on the wash. Dark: unchanged. That is eight light and four dark.

It changes two existing themes:

- **Stripe moves from the wash to cream.** The old Stripe is now **Stripe Honeydew**. No shipped
  build has themes (they arrived 2026-09-26, after beta 1), so there is no migration code. The one
  saved `stripe`, on the owner's dev Mac, was moved to `stripeHoneydew` by hand.
- **Canary moves from white to cream.** It measures 1.5:1 bar-to-body, between its old 1.6 on white
  and Canary Honeydew's 1.4. Like those, it relies on the bar's divider. White is no longer a body.

**Cantaloupe Honeydew** is new. The four shared raw values are unchanged. The picker is now a fixed
grid of four columns, so each bar sits above its honeydew form, and a test pins that order.
Re-measuring found **success on the wash at 2.95:1**, a hair under 3:1 (previously rounded to 3.0).
That is left as an open question rather than changed here, because it is shared by every theme.

### Q23 amended a third time — the matte finish (2026-10-05)

The owner wanted the theme colours less bright: matte, like anti-glare glass or the powder-coated
tumblers. Five finishes were prototyped on a throwaway branch and captured for Cantaloupe, Stripe
and Flesh in light and dark:

- chroma −15%;
- chroma −30%;
- a static grain;
- chroma −15% with grain;
- a frosted bar.

**Chosen: chroma −15%, no grain.** Every theme's bar and body keep 85% of their OKLCH chroma
(`OKLab.matte`), with lightness and hue unchanged, so contrast moves by 0.06 at most. Bar ink stays
brand seed, and status, chart, tag and link colours are not finished.

- **It is the look, not a setting**, so there is no toggle that would double the themes.
- **Frost was ruled out on measurement:** dark frost put seed ink at 3.3–4.1:1 on the bar, under the
  4.5 the wordmark needs.
- **Grain** cost the status colours a little (3.17 → 3.06) and was not chosen.

The values are tabled in `design/THEMES.md` and pinned by `OKLabTests`.

## Q25 — A missing kernel is detected and offered as a download (settled 2026-10-05)

A fresh `container` install has no kernel. `system status` says `running`, Flotilla said ready, and
every container and machine failed to start until `container system kernel set --recommended` was
run. Found on the new Mac's first install of 1.5.0.

- **Detected from the file**, not from the CLI: `<appRoot>/kernels/default.kernel-<arch>`, using
  the `appRoot` and architecture `system status` reports. `system property list` cannot tell; it
  prints the kernel configuration either way. A status that lacks either value is **not judged**,
  so Flotilla never claims a kernel is gone on evidence it does not have.
- **Its own verdict, `PreflightResult.needsKernel`**, checked after version skew, since a restart is
  the cheaper repair. It is shown like a stopped service: warning colour, not a fault, with a
  **Download Kernel** button on the Dashboard banner and "Install Recommended Kernel" in the
  runtime menu (always present, greyed out otherwise).
- **Progress shows in the banner, not a panel** (the owner): a spinner, the CLI's own line
  naming what it fetches, and the seconds elapsed. There is no percentage, because 1.5.0 prints one
  line and then nothing. A failure stays in the banner, in the CLI's words, with Try Again.
- **Only on a click.** This is the step `system start`'s allowlist row says Flotilla never takes
  *on its own*, and it still never does. It is user-level (files in the user's own Application
  Support folder, no administrator), and it says that it downloads before it does.
- **The allowlist takes `--recommended` and nothing else.** `--tar` (a path or a URL), `--binary`,
  `--digest`, `--arch` and `--force` would each let a caller choose what the host boots.
  `Allowlist.resolve` now matches three-word paths for it, exactly.
- **Flotilla creates an empty `kernels` folder first if there is none.** 1.5.0's `kernel set`
  downloads and unpacks, then fails to move the file into a missing folder with "The file
  “vmlinux-…” doesn't exist", which names the temp file, not the folder. Measured: the same command
  succeeds in 17 s once the empty folder exists. A fresh install has the folder; this is for a Mac
  where someone deleted it.

## Q26 — Registries is a sidebar section, under Images (settled 2026-10-05)

The owner asked for registries to move out of Settings and to work like every other section.
Decisions, all the owner's unless marked:

- **Under Images in the sidebar**, because that is where images come from. **The Settings ▸
  Registries tab is gone**, and nothing about registries stays in Settings. The default registry is
  set from the table (Set as Default), so there are not two controls for one value.
- **The same table setup as every other section:**
  - list and cards, search (name, server, account, tags) and a filter (All, Signed in, Not
    signed in, Sign-in required, Added by you);
  - sortable, hideable columns (Tags, Server, Sign-in, Status, Type);
  - row menus that match the context menu;
  - multi-select with bulk Tag, Sign Out and Remove;
  - the activity band. Registries became their own `ActivityKind` and tag kind, `.registry`.
    Sign-ins used to be filed under `.image`, which put them in the Images band.
- **Each registry says whether signing in is optional or required** (`SignInNeed`: Not needed,
  Optional, Required). For the catalogue this is set per entry. It is *not* `anonymousPullWorks`,
  which marks registries with no private tier and is false for Docker Hub and GHCR, so mapping it
  would have called them "required". Only Red Hat's authenticated registry is required.
- **A required registry is not added until you have signed in.** The button reads "Sign In and
  Add", stays off until both fields are filled, and signs in first, so a wrong password adds
  nothing. Optional ones add on their own, or "Add and Sign In".
- **A hand-added registry asks** ("Signing in is required", on by default). Flotilla makes no
  network request of its own to find out.
- **One embedded form for adding and for managing** (mine): clicking a registry opens it to sign in,
  switch account or sign out. It replaced the Settings pane's sign-in sheet, the last modal among
  the create forms.
- **No sign-in over HTTP** (found testing, 5 October). `container` 1.5.0 refuses a credential
  challenge over plain HTTP, even on `localhost` (measured with a correct password; it worked on
  1.4.1). So an HTTP registry shows "Can't sign in over HTTP" and has no Sign In, and a required
  registry cannot be added over HTTP. The Add form says so once, in place of the sign-in fields.
- **Unchanged from Q20:** a catalogue, not a capability list. The password goes through stdin and
  never argv, and Flotilla stores no credential. A login made in a terminal to a registry that
  isn't in your list still shows, marked "not in your list", with Add to List.

## Q24 — Groups live in the Containers list (settled 2026-10-05)

**The owner's design**, after Docker Desktop's handling of Compose stacks: one list for groups and
containers, with the separate Groups section removed. Eight decisions, made one by one:

1. A grouped container appears **only inside its group**, never also at top level.
2. A group row shows "2 of 3 running" and a **half-filled dot** when some members are running,
   green when all are, and grey when none are. It never uses the warning amber.
3. **Delete on a group row offers both** "Delete Group Only", which keeps its containers as
   standalone rows, and "Delete Group and Containers", which **names every container** it removes.
4. Groups **sort among containers**; a group's members stay together under it, sorted by the same
   column.
5. **"+" became a menu**: Run Container… and New Group…. Both open their usual embedded forms.
6. In **Cards view**, a group is one card with a chip per member.
7. The **menu bar keeps both boxes**, Containers and Groups. Only the main window merged.
8. A **kind filter** (All / Groups / Containers) sits beside the state filter. "Containers only"
   lists every container flat, which is what this screen showed before groups joined it.

The rules for which rows appear and where live in `ContainerListing` (FlotillaCore), under ten
tests. A row is now a container, a group, or a member, with its own sort keys. A group's row id is
namespaced (`group:<id>`); a container's and a member's id is the container name, which stays
unique because a grouped container is never also a standalone row.

**Found on screen, not in the tests:** `GroupState.partial` also covers "none running, but only
some exist", and the first half-dot drew that as half green. The dot and the sort rank now look at
how many members are actually running.

### Q22 amended — `container` 1.5 has no restart, so Start became Recreate (2026-10-05)

`container` 1.5.0 removed `k8s start` (apple/container#2290, merged 2026-09-21). Restarts were
unreliable, especially after the node got a new IP. The 1.5.0 release notes and the tagged
`docs/kubernetes.md` ("Recovering a stopped cluster") both give the same recovery: `k8s delete`,
then `k8s create`. Starting the node container directly is not a substitute, because it skips the
Kubernetes repair, readiness and kubeconfig steps. Research by Iris; every claim above was checked
against GitHub before this was built.

So:

- **Start is gone from Clusters, the allowlist, `ContainerCLI` and `AppModel`.** Default-deny
  means the `k8s start` spec goes with the command, and a test now holds that it is refused.
- **Recreate replaces it**, offered for a cluster that is not running. It is one operation with one
  progress panel: delete, then create with the same name, CPUs and memory. The memory comes back
  from `k8s list`'s `4096 MB` as the flag's `4096M`; anything unparseable falls back to the CLI's
  default rather than sending a value the allowlist would refuse.
- **It always asks, and the confirmation says why it exists** before saying what it costs: there is
  no restart in 1.5, and everything inside the cluster is lost. A custom node image or CNI cannot be
  kept, because nothing this app can read records them; the confirmation says the defaults are used.
- **`--node-image` must name a tag** (apple/container#2271): 1.5.0 refuses an untagged or digest-only
  node image with `invalidArgument` before provisioning, because the tag now also picks the
  Kubernetes version `kubeadm` installs. That needed a new value shape, `taggedImageReference`,
  checked on the last path component so a registry port is not mistaken for a tag. Every other image
  field still accepts an untagged reference.
- **Not done:** `k8s create --cni <path>` (apple/container#2254) is an opportunity, not a fix, and is
  left for later.


## Q27 — DNS is a section, under Networks (settled 2026-10-06)

The owner asked whether Flotilla should have a DNS section, as a competitor does, so users can keep
several local domains for different projects. A proof on `container` 1.5.0 came first (the table in
Q21's section, above): containers resolve each other by bare name on the default network **and on
custom networks**, and this Mac resolves `name.domain`, once **two halves** are in place —

1. **macOS's resolver**: `sudo container system dns create <domain>` writes
   `/etc/resolver/containerization.<domain>`. It needs root.
2. **The runtime naming containers**: `config.toml`'s `[dns] domain`, read when the service starts.
   There is no CLI for it. Only one domain at a time, and only containers created afterwards get names.

Decisions, the owner's unless marked:

- **Under Networks in the sidebar**, with the same table setup as every other section: list and
  cards, search, a filter (All, For containers, Host aliases), hideable columns (Tags, Kind,
  Address, Status), row menus that match the context menu, multi-select delete, tags and the
  activity band. DNS is its own `ActivityKind` and tag kind, `.dns`.
- **Each row shows both halves**, and says plainly when only one is there (mine). A domain
  `config.toml` names with no resolver file is a row, "Containers only — not on this Mac", with
  Set Up on This Mac. The notes above the table offer the missing half.
- **Creating or deleting a domain uses the macOS administrator prompt** — "macOS admin prompt
  (Recommended)". It is never silent, the form's rail shows the exact `sudo container …` command
  first with a Copy button, and several deletions share one prompt. What may run as root is
  narrower than anything else in the app (mine, as a security boundary):
  - only `system dns create|delete`, through the `Allowlist` like every other command, with new
    value shapes `dnsDomain` and `ipv4Address`. All three `dns` specs are local-only.
  - **only the installed `/usr/local/bin/container`, and only while it and its directory are owned
    by root and writable by no one else** (`AdminExecutable`). A symlink is refused, not followed.
    **Never** the configurable `containerBinaryPath`: anything that can write Flotilla's
    preferences could otherwise have its own program run with the owner's password.
  - each argument single-quoted for the shell, the line escaped for AppleScript (`AdminScript`,
    tested), run in-process with `NSAppleScript` so the prompt names Flotilla. Cancel (-128) is not
    an error.
- **"Use for Containers" edits `config.toml` and restarts the runtime, after a clear warning** —
  "Yes, with a clear warning (Recommended)". The dialog says every running container stops (with
  the count), only containers created afterwards get names, the old domain's names stop working,
  and that a network which stops carrying traffic after the restart is fixed by recreating it (the
  fault in `research/CONTAINER-UPGRADE-1.5.0.md`). With the runtime stopped, the file is written
  and nothing restarts.
- **This pulls `config.toml` editing forward from Phase 3** (decision 8, Q7), for this one key.
  `ContainerConfigFile` is not a TOML parser on purpose: it changes the `[dns] domain` line, adds
  it, or removes it, and leaves every other byte as it was — comments, ordering, other tables, and
  a `domain` key in any other table.
- **`.local` is refused** (mine, found writing the form's examples). macOS resolves `.local` with
  Bonjour; a resolver file for it would send every printer, AirPlay and `name.local` lookup to the
  container runtime.
- **A host alias** (`dns create --localhost <ipv4> <domain>`) is offered as the second kind, prefilled
  with Apple's documented example (`host.container.internal`, `203.0.113.113`, an address reserved
  for documentation). It never names containers.

### Q21 amended — Start can wait for a service to be ready (2026-10-06)

Building Suggestions needed it: a stack's app started a second after its database fails, because
the database is still running its first-start setup. The owner chose "start the database, wait
until its port accepts connections, then the rest", and, asked how that squares with Q21's "no
health gating", chose to **amend Q21 narrowly**:

- **A member may name a `readyPort`** — the port *inside* the container, published or not. During
  a Start or Restart **the user clicked**, the next member waits until that port accepts a TCP
  connection at the container's own address (`Readiness`, `TCPProbe`). Measured 6 October: the Mac
  connects to a container's port directly, on a custom network, unpublished; a closed port is
  refused at once, so polling once a second is cheap.
- **Bounded by the command that asked for it.** Up to two minutes; the container list is re-read
  every fifth poll so a service that exits is noticed. Nothing watches afterwards, nothing
  restarts, and if Flotilla quits half way the remaining members simply are not started. The rest
  of Q21 stands: no `depends_on`, no ongoing health checks, no restart policy, no Compose import.
- **It says so when it gives up**, naming the service and port, and says the services after it
  were not started. Live-tested: a Postgres that exits (no password set) is reported as "stopped
  before it accepted connections"; a healthy one releases the next member about a second after
  Postgres logs "ready to accept connections".
- **Ready means a TCP connect.** Right for the official Postgres, MySQL and MariaDB images, which
  run first-start setup with TCP off.
- Skipped after the **last** member, which holds nothing back.

### Q21 amended — a group's passwords live in the Keychain (2026-10-06)

Decided with the owner for Suggestions: stacks generate their passwords, keep them in the
Keychain, and show them on the group with Copy; never in the preferences file or an export.

- **A member's `secretEnv`** names a variable and a secret (`MARIADB_PASSWORD` ← `db-password`).
  Two members naming the same secret is how WordPress and MariaDB agree on a password nobody typed.
  The preferences file stores those names only; the values are generic-password items under
  `dev.melonfleet.Flotilla.group-secret`, keyed by group id (a rename keeps them) and secret name.
- **Read at Start, before anything runs**, and only for members about to be *created* — starting an
  existing container passes no environment. A missing value stops the group cleanly with a message
  saying where to set one. Previews show `NAME=<Keychain: secret>`, and the Start panel's audit
  line hides it as it hides every env value.
- **Generated** as 24 letters and digits (~143 bits): no `@ : / '` to break a `DATABASE_URL` or a
  config file. A new value made on the group screen is written **on Save**, like everything else
  there, and the dialog says a database that already exists keeps its old password.
- **Deleting a group deletes its Keychain items.** Live-tested 6 October: generated, saved,
  started — the container's environment matched the Keychain value, the preferences held zero
  copies of it, and deleting the group removed the item.
- Known, and the same as every env value today: the value reaches `container run` in argv.
- Development builds are ad-hoc signed, so macOS asks once before a rebuilt app reads an item an
  older build wrote. Developer ID builds have a stable identity and do not.

## Q28 — Suggestions: ready-made stacks, created as groups (settled 2026-10-06)

The owner named the feature "Suggestions" (5 October) and settled its shape on 6 October, with
Iris's research (`experiments/stack-research-2026-10-05`). This entry covers Containers; Volumes,
Networks, Machines and Clusters follow.

- **Five stacks, Iris's top five, pinned:** PostgreSQL 18.6 + pgAdmin 9.18, WordPress 7.1 + MariaDB
  12.3, Redis 8.10 + RedisInsight 3.8, MySQL 9.7 + phpMyAdmin 5.2, Prometheus v3.13.4 + Grafana 13.2.
  No nginx. **Every one was created, started and exercised on this Mac before shipping** (6 October),
  and two of the research's assumptions did not survive that:
  - **Prometheus publishes only full versions** — `v3.13` does not exist; `v3.13.4` does.
  - **Redis cannot use a named volume.** A fresh volume holds `lost+found`, so the image's entrypoint
    declines to fix ownership ("Unknown file './lost+found'… Permissions will not be modified") and
    Redis, running as `redis`, cannot write its AOF. So only images that set up their data directory
    as root get a volume (Postgres, MariaDB, MySQL, WordPress); the rest keep data in the container,
    which survives Stop and Start but not Delete, and their notes say so.
  - RedisInsight adds the preset Redis **only after its own terms are accepted in the browser**
    (read in its source). Flotilla does not accept them for you; the note says to.
- **Where:** the Containers "+" menu ("Suggestions…") and the empty Containers list (three quick
  picks and "More…"). An embedded gallery of `ResourceCard`s, then a form per stack.
- **What the form lets you choose** (the owner, 6 October: fields to pre-select, bound to the stack
  once built): the name (the prefix for every container, volume and the network), the network (a new
  `<name>-net`, or an existing one), each web page's port on this Mac (127.0.0.1 only, suggested as
  one nothing uses — containers, groups not running, and anything else listening), and per-stack
  settings with working defaults (database, user, pgAdmin's sign-in email). **The domain is shown,
  not chosen**, because it cannot be per stack: measured 6 October, `container run --dns-domain`
  only sets the container's search domain — the container still registers under the Mac's one
  domain — and it breaks bare names inside that container.
- **Wiring — "names if set up, else gateway"** (the owner's choice). With a domain in use for
  containers, services reach each other by bare name on the stack's network. Without one, each
  database is published on the network's **gateway** (never `0.0.0.0`) on a free port near
  30000 + its own, and the app is pointed there. Both were live-tested: WordPress → `wordpress-db` by
  name; phpMyAdmin → MySQL at `192.168.66.1:33306`, refused on the Mac's LAN address.
- **Creating** pulls missing images first (the step that fails, and the one that leaves nothing
  behind), then makes the network, reads its gateway, plans, creates volumes, generates passwords
  into the Keychain and saves the group with its notes. A failure says which step, and lists exactly
  what was left in place. The stack is **left ready to start**, as decided; Start uses Q21's ready
  wait so each database is up before its app.
- **Bug found building it:** the gallery's description used `fixedSize(vertical:)` and opening the
  screen blanked the whole window — bar, sidebar and all. Same family as "one unbounded child can
  scroll the whole window"; found by bisecting.

### Q28 continued — Suggestions for Volumes, Networks and Clusters (2026-10-06)

Iris's "include" lists, as decided: **Volumes** — PostgreSQL, MySQL/MariaDB and MongoDB data at a
10 GB ceiling (sparse: allocated as used), each card saying where to mount it; **Networks** —
Application, Frontend tier and a Host-only backend (`--internal`, named as Apple names it);
**Clusters** — Starter (2 CPUs, 2 GB), Standard (4, 8 GB) and Disposable (`--rm`), all on the node
image `container` 1.5 itself defaults to, pinned by tag and digest.

- **No new forms.** Each is one create command, so "Use…" opens the section's **own** create form,
  filled in, with the name moved past anything that exists. Everything stays editable, and Back
  from an untouched filled-in form asks nothing. The "+" in each section became a menu (New… and
  Suggestions…), and each empty state offers its suggestions by name, through one shared
  `SuggestionQuickPicks` — Containers uses it too.
- **Cards follow the owner's card rule**: one line of text per row, and every card of a kind has
  the same rows (the volumes' "Older versions" row is "same path" where nothing changed).
- **Live-tested:** the PostgreSQL volume came out at exactly 10 GiB; the backend network as
  `hostOnly`. The Starter cluster's filled-in form was checked but **not created**: a cluster
  writes `~/.kube/config` and may switch kubectl's current context, which is the owner's working
  setup. Its command is the CLI's own default spelled out, and every suggestion's argv is tested
  against the Allowlist.

### Q28 continued — Suggestions for Machines, and a machine's first run (2026-10-06)

As decided: **Alpine 3.22 and AlmaLinux 9 and 10**, each boot-and-login tested on container 1.5.0
before shipping, any failure to be dropped. None was. For each: pulled, created, booted,
`/etc/os-release` read, PID 1 checked (BusyBox init on Alpine, systemd on AlmaLinux), a login shell
opened as the Mac's user in the home directory, stopped, booted again. AlmaLinux is pinned to the
newest dated `-init` builds (`9.8-20261002`, `10.2-20261002`) — Iris's research named older ones.
Alpine 2 CPUs / 2 GB; AlmaLinux 4 / 4 GB (Lima's dev-VM default, as Iris suggested). Stock Ubuntu
and Debian stay out: Apple needs `/sbin/init` in the image.

Same shape as the other sections: "+" ▸ Suggestions…, quick picks in the empty state, and "Use…"
opens New Machine filled in. The machine form's own verified list gained both AlmaLinux builds, and
three texts that said "only Alpine boots" were corrected; a verified AlmaLinux image no longer
draws the "most images do not boot" warning (another AlmaLinux tag still does — it was not booted).

**Found while testing — a machine's first run after create.** `machine create` boots the machine;
on 1.5 the first `machine run` without a terminal then fails ("Operation not supported on socket" /
"…by device") **and stops the machine**, and the next run boots it. Flotilla's Start is only
offered for a stopped machine, so it rarely meets this, but `startMachine` now retries once on
exactly that message (tested). The demo script met it on 5 October and blamed the boot order; its
comment and command are corrected.

## Q29 — A `.flotilla` file: share a group, or export a Mac's configuration (settled 2026-10-06)

The last part of Suggestions (save a group, share it) designed together with the "configuration
export and import" item, as agreed. **A configuration export, not a migration** (the owner,
5 October): the file says what to build; no volume data, image layers or container state move.

The owner's answers, 6 October:

- **One format for both** — a shared group and a whole-Mac export are the same kind of file:
  `ConfigurationFile`, version 2 of the Flotillafile. Version 1 files still read.
- **`.flotilla`**, JSON inside, registered so a double-click opens Flotilla's import review.
- **What an export can hold**, each a checkbox: containers, groups, networks, volumes (as empty
  definitions), machines, clusters, and — of the extras offered — **tags, the registry list and
  DNS domains**. Not Flotilla's own settings.
- **Saving one group:** "Save to File…" on its row menu and group screen, and the full checklist
  under File ▸ Export Configuration…; both write the same format.
- **On import, a name that already exists is decided per item** — skip, rename or replace. Replace
  deletes the existing thing first; for a volume that is its data, so the review screen says so and
  a final confirmation names everything being replaced.

Mine, for the owner to see:

- **Left out, always, and listed on the export screen** (`ConfigurationExport.Omission`): secret
  values (a variable that looks like one is written as a name — the importer asks or generates —
  matching the earlier decision), **folders on this Mac** (a host mount names a path under the
  user's home, and would not exist on the other Mac), the image's own environment and command
  (the CLI reports them merged; only what was chosen on top is written — measured on the demo's
  Postgres), and what the runtime made itself (the `default` network, a cluster's node container,
  group members repeated as containers).
- **Untrusted input, as Flotillafile was:** unknown keys refused at every depth, every value checked
  against the Allowlist's shapes, every list and the file bounded, a host-folder mount refused in a
  file outright. Parsing runs nothing; import is a review the user confirms.
- **Images by reference and digest**, so the importer can pull the same bytes. A network's subnet is
  not exported: the runtime chose it, and on another Mac it may clash.

### Q29 continued — export and import in the app (2026-10-06)

- **Export:** File ▸ Export Configuration… (⇧⌘E) opens an embedded checklist over the selected
  section — **nothing ticked to start, with Select All and Clear All at the top and no per-section
  All/None** (the owner, 6 October) — and a live list of what will be left out in the rail, worked
  out from whatever is ticked — and a group's
  row menu and screen have "Save to File…", which saves the group with its network and the volumes
  it mounts. Both write the same `.flotilla` file.
- **Import:** File ▸ Import Configuration… (⇧⌘I), or a double-click in Finder — the bundle now
  declares `dev.melonfleet.flotilla-configuration` and owns `.flotilla`. The review screen lists
  everything, new or "already on this Mac"; each clash is skip, rename or replace, and Import stays
  off until all are decided. Passwords are generated unless typed. Replace ends in a confirmation
  naming each thing deleted, and "its data is lost" for a volume.
- **Nothing is started.** Containers are created stopped — which needed `container create`, added to
  the Allowlist with exactly `run`'s audited flags less `--detach`, `--rm` and `--progress` (the
  CLI's two option lists diffed on 1.5.0), and local-only. Groups are saved ready to start.
- **Order:** replacements, then pulls (only of images not here), then networks, volumes, machines,
  clusters, containers, groups (passwords into the Keychain), tags (merged by name), registries
  (never a sign-in; the panel says which to sign in to), and DNS last, behind one administrator
  prompt. A failure names the step and exactly what was already built.
- **Live-tested 6 October:** the demo's `storefront` group saved to a file with no `/Users/` path
  and no password in it; a renamed copy opened from Finder straight into its review screen; an
  import with an unpullable image stopped at the pull with nothing built; the corrected import built
  the network, both volumes and the group, and once started its web and API answered on the new
  ports. Its database did not start — the demo's own group record had never carried Postgres's
  settings, so `Scripts/demo-scenario.sh` now writes them (the password as a Keychain secret,
  removed by `down`).
- **Format fixes found by reading a real export:** every list and flag is optional when read (a
  hand-written file need only say what it uses) and omitted when empty; and an omitted host folder
  is described by its destination, never its source path.

### Q28 continued — Suggestions for DNS, and the File menu (2026-10-06)

- **DNS gets Suggestions too** (the owner's choice): `test` and `internal` for container names
  (both reserved — `.test` by RFC 6761, `.internal` by ICANN for private use in 2024 — so neither
  can ever be a real internet domain), and the host alias `host.container.internal` → 203.0.113.113,
  Apple's documented way for a container to reach a service on the Mac. The first two are
  alternatives: one domain at a time names containers, and the gallery says so. "Use…" opens New
  Domain filled in; creating one still goes through the administrator prompt.
- **The File menu caught up** (the owner noticed it had not): New Group… ⌃⌘O, New Cluster… ⌃⌘K,
  New DNS Domain… (no shortcut — ⌃⌘D is the system's Look Up), and File ▸ Suggestions with each
  section's gallery, DNS included. A menu request closes an open Export or Import screen so the
  form it asked for is what shows.

## Q30 — A network can lose its bridge (apple/container#2051), and a subnet can move (settled 2026-10-06)

The morning's "networks break after a service restart" reduced to a known runtime bug:
**apple/container#2051**, open since August, **still present in 1.5.0** (reproduced with its own
steps). Two networks can be handed the same kernel bridge; when one's last container stops, the
bridge goes and the other network has no gateway on the Mac — its containers reach each other but
nothing else, and its published ports are dead though the forwarder listens. Only a runtime restart
recovers it. Full notes: research/CONTAINER-UPGRADE-1.5.0.md. A second finding: network subnets can
move across a restart (`default` and a network made without `--subnet` swapped /24s).

The owner's answers:

- **Comment upstream** — posted on #2051, confirming 1.5.0, the default-network and published-port
  symptom, and the subnet swap.
- **Detect it and offer a restart.** `NetworkHealth.disconnected` (core, tested) flags a network
  that has running containers but whose gateway address is on none of this Mac's interfaces
  (`getifaddrs`); a network with nothing running has no bridge by design and is never flagged, and
  nothing is flagged until both lists have loaded. A banner on Networks and Containers names the
  network, says what it means, links the issue, and offers Restart container with the usual warning.
  Live-tested by triggering the bug: it named exactly the broken network.
- **Pin the subnet for gateway-wired stacks.** Gateway wiring writes the gateway's address into the
  group, so a Suggestions stack created without a DNS domain now gets a network with a fixed
  `--subnet` — the first `192.168.N.0/24` from N = 100 that no network or interface uses — which a
  restart cannot move. Name-wired stacks need no address and are unchanged.

## Q31 — The fleet redesign: navigation and the window bar (settled 2026-10-06)

The owner re-phased the project around fleet mode (PLAN.md, rewritten the same day). Phase A, built:

- **Sidebar: one flat list, thin dividers, no headings** — Overview | Containers, Images,
  Registries, Volumes, Networks, DNS, Machines, Clusters | Hosts | Activity, Logs. Containers first,
  as Docker does: this is a containers application. Supersedes the grouped sidebar (Containers /
  Virtualisation headings) and Activity/Logs at the top.
- **Collapsed to icons by default**, remembered once changed (`@AppStorage("sidebarRailed")`); the
  toggle is a small handle in the middle of the sidebar's edge, not in the window bar.
  `check-defaults.sh` now guards the new default.
- **Overview replaces Dashboard**: fleet numbers only — hosts and their state, totals across hosts,
  what needs attention (runtime down, a disconnected network, containers in an unknown state). It
  loads the lists it counts rather than showing zeros on a fresh launch.
- **Hosts** is new: one card per host — today only This Mac — whose page is the old per-Mac
  dashboard, with Back. Runtime activity now leads there.
- **Window bar** (reverses Q23's "the bar shows Flotilla alone"): the lockup `melonfleet` bold
  (with the watermelon o) | `flotilla` lowercase light, **in white** straight on the bar with a
  faint shadow — the owner tried it on light glass and preferred white. Measured: white alone is
  1.6:1 on the canary bar; the shadow keeps it legible, and canary is the weakest theme for it. The
  links, appearance and settings buttons share one **light glass capsule** (white tint 20%) with a
  soft ink (seed at 72%) instead of near-black, rendered in the light scheme so it is the same on
  every theme.

## Q32 — The DNS helper on every Mac, and Phase B's first decisions (settled 2026-10-07)

**The helper.** The owner asked (7 October) for the Phase D privileged helper on the admin Mac
too, so DNS changes stop asking for the password. Built as `FlotillaDNSHelper`, an
`SMAppService` daemon shipped inside the app and inert until the owner switches it on in
System Settings ▸ Login Items. It amends decision 19 narrowly: root still runs only
`system dns create|delete`, never silently — the approval moves from a password per change to a
one-time install approval plus an in-app confirmation of every change (deletes always confirm
with the helper on; "Set Up on This Mac…" gains a dialog; a form's Save is its own
confirmation). Requests are typed, not argv; the helper re-validates everything as root and
accepts only the same-team, Developer ID-signed app; the app likewise requires the helper's
identity. Unsigned builds, or a declined approval, keep the password prompt. Rejected: a
setuid tool (no caller check), a sudoers rule (a general grant), caching the password (it is
the owner's).

**Phase B.** Exposure starts with reads and lifecycle; registry sign-in is replaced by the admin
Mac sending images (`image save` → stream → `image load`) so credentials never leave it; DNS
becomes per-host zones once the helper runs on hosts. Enrolment is a CID-style fleet key in a
configuration profile, or a one-time code — and either way the owner approves each new host on
the admin Mac. Port 7868. Host mode is a login item in a user session; headless minis use an
auto-login service account until `container` supports a non-GUI launchd domain
(apple/container#2008, #1514). Details in PLAN.md Phase B.

