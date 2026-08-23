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
- **SSH key in 1Password, not on disk:** the melonfleet ed25519 key lives only in
  1Password (Development vault), served via the 1Password SSH agent (Touch ID).
  Rejected leaving an unencrypted key on disk.
- **Commit signing via 1Password** (`op-ssh-sign`, SSH-format) → commits show
  Verified. Rejected GPG (heavier) and unsigned commits.
- **Two-account separation:** SSH host alias `github-melonfleet` + per-host
  `IdentityFile <pub>` + `IdentitiesOnly`, and `agent.toml` whitelisting both the
  Personal (other account) and Development (melonfleet) vaults.

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
  palette.
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
  position) and fully typed per-operation RPCs (the review's position).
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

Machine/VM management is the market's #1 gap (~13 of ~19 products), and the core owner warned that the
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
- **Sequence the gap list against security cost, not market frequency.** the core owner's ranking is
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

### Q14 amended after independent review (the review, 2026-08-19)

the review reviewed the first implementation and returned "the capability concept is sound, but this
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
