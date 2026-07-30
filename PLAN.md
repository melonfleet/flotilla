# Flotilla — native macOS fleet manager for Apple `container`

## Context

Apple's `container` is an open-source Swift CLI that runs Linux containers as one
micro-VM each on Apple Silicon. Flotilla is a personal, non-commercial native app
for managing containers on the local Mac and across a small fleet of remote Macs.
Each remote Mac runs the same app in host mode.

Flotilla communicates Swift-to-Swift over Network.framework with mTLS. Bonjour
handles discovery on a flat LAN; manual hostname/IP + port entry is mandatory for
routed or segmented networks. It does not use the macOS `ssh` binary, expose a
generic shell, or attempt to be Kubernetes.

**Status (2026-07-31):** Phase 1 is close to complete and the app is genuinely
usable. `FlotillaCore` has the full CLI surface behind the Q1 `Allowlist` and an
injectable `MountPolicy`, models pinned to real captured output, a settings registry
that now persists, and stats sampling. The app ships as a real signed bundle with the
whole navigation shell, a validated run sheet, and a container detail window.
**183 tests pass on macOS**; the Foundation-only core still builds and tests on Linux
via `Package@swift-6.1.swift`.

See the Phase 1 progress note below for what remains. Phase 2 networking and the
stateful host runtime have not been built — and per `research/ALLOWLIST-AUDIT.md` the
allowlist is **not** yet trustworthy as the complete Phase 2 wire boundary, so that is
a prerequisite rather than a detail.

The scope below is the settled, consolidated plan from `DECISIONS.md`,
`PHASE1.md`, and `research/FEATURES.md`. Earlier phase summaries are superseded.

## Branding and appearance

The approved visual language is the watermelon identity: pink for
brand/selection, green for healthy/running, and a separate semantic error colour.
The menu-bar symbol is monochrome. Liquid Glass belongs on chrome and control
clusters, while data-heavy tables remain opaque.

Appearance is chosen during first run. `Auto` is preselected and follows the
system; light and dark are both first-class. The watermelon accent is the single
accent colour in either appearance.

## Architecture

```text
Flotilla.app  (one app, client/host/both modes)
├── FlotillaCore  (Foundation-only shared spine)
│   ├── Models
│   ├── ContainerCLI
│   ├── ContainerHost
│   │   ├── LocalHost   → Process
│   │   └── RemoteHost  → Phase 2 mTLS connection
│   ├── Allowlist       → permitted subcommands + argument schemas
│   ├── MountPolicy     → allowed host bind-mount roots
│   ├── Settings        → typed registry and managed precedence
│   ├── Diagnostics
│   ├── Wire            → Phase 2 framing/messages
│   └── Transport       → Phase 2 Network.framework/mTLS
├── Client UI
│   ├── MenuBarExtra + main window
│   ├── local and remote hosts through ContainerHost
│   └── table-first aggregate container view
└── Stateful host runtime
    ├── mTLS listener + Bonjour advertisement
    ├── peer/certificate authorization
    ├── persisted policy and per-host settings store
    └── validated local CLI execution
```

Host mode is deliberately **stateful**. Its persisted policy store is required
for per-host settings and, in Phase 4, restart/health loops that continue when the
client laptop disconnects.

Every execution path uses the same boundary:

1. `ContainerCLI` creates an argument array.
2. `Allowlist` validates the subcommand and argument schema; `MountPolicy`
   validates host paths.
3. `LocalHost` executes locally, or `RemoteHost` sends the validated shape over
   the wire.
4. The host validates again before spawning `container`.

The Q1 wire shape is the settled middle path: **CLI args passthrough constrained
by a default-deny subcommand allowlist**. The protocol must also bound frame
length, concurrency, and deadlines. It never accepts an arbitrary command string,
but it does not require a new typed RPC for every CLI operation.

## Tech stack

- Swift 6.2+ and SwiftUI on macOS 26, Apple Silicon only.
- Foundation-only `FlotillaCore`, also buildable/testable with Swift 6.1 on Linux.
- Network.framework for mTLS transport and Bonjour.
- SwiftData for local history. The persisted host policy store is required, but
  its storage implementation is not settled here.
- Swift Charts once Phase 4 has real streaming data.
- Sparkle for unmanaged updates; Jamf for managed minis.
- Keychain for identities and trust material.
- No App Sandbox for v1; use hardened runtime, Developer ID, notarization, and
  minimal entitlements.

## Build phases

### Phase 1 — Local MVP and shared foundation

Phase 1 is the **consolidated** scope, not the old “grid + a few buttons”
one-liner.

Core runtime:

- Decode real `container --format json` for containers, images, stats, system
  status, versions, volumes, and networks where JSON exists.
- Complete lifecycle and image operations through `ContainerCLI`: run, start,
  stop, restart, kill, delete, pull, delete/prune/tag/inspect, plus bounded logs.
- Add volume and network list/create/delete/inspect/prune, and the `system df`
  disk view.
- Keep the allowlisted args-passthrough boundary and `MountPolicy` default-deny
  behavior on every operation.
- Provide numeric snapshot stats in Phase 1; live sparklines wait for Phase 4.
- Read `config.toml`-backed properties in Phase 1; do not edit the file yet.

App and UX:

- Ship a running-first, sortable table as the default container view, with cards
  as an alternate toggle.
- Keep `MenuBarExtra(.window)` shallow and provide a main window for the full
  interface.
- Add search/filtering, multi-select bulk actions, run sheet with live command
  preview, logs/inspect, images, and a combined System surface for volumes and
  networks.
- Implement onboarding and preflight: detect CLI presence/version/service/kernel,
  show inline remediation, and require visible user authorization for package
  installation.
- Support Menu bar / Dock / Both presentation and accessible light/dark UI.

Settings, security, and operations:

- Use the typed settings registry with precedence:
  `locked` → user → managed `defaults` → built-in.
- Represent “appearance not chosen yet” separately from “user chose Auto.”
- Include poll intervals, CLI integration, container defaults, log limits, host
  settings, update channel, diagnostics choice, and full per-category
  notification toggles. Mandatory error notifications remain enabled.
- Establish the security baseline now: hardened-runtime/notarization hygiene,
  minimal entitlements, structured logging with no secrets, and explicit no
  telemetry/account/activation.
- Complete local diagnostics and a previewable, redacted support bundle with no
  upload. Redaction must remove secrets, certificate material, identifiers, and
  absolute user paths.
- Define separate reset semantics for preferences, host/trust state, and window
  layout.

**Current Phase 1 progress (2026-07-31).**

Done: core models (pinned to real captures), local execution spine, allowlist,
mount policy, settings registry with **persistence**, diagnostics components, the
full CLI surface (mutations, volumes, networks, bounded logs, kill, inspect, prune,
tag, `system df`), preflight, and the whole navigation shell — Containers with
sortable/hideable columns, per-row actions, context menus everywhere, bulk actions,
CPU/memory columns, cards with sparklines; Images; Volumes; Networks; Settings; the
run sheet with a validated live command preview; and a container detail window with
Overview / Processes / Logs / Inspect / Configuration.

Also now real rather than declared: appearance, first-run onboarding, auto-refresh,
the menu-bar/Dock setting, and notifications — all four were settings driving
nothing. And there is an **app bundle** (`Scripts/make-app.sh`), which is what
unblocked the last three.

Still unfinished:

- **Diagnostics**: the snapshot, error log and redaction components exist; the
  previewable redacted support-bundle flow does not.
- **Launch at login** (`SMAppService`) — the bundle makes it possible; not wired.
- **Separate reset semantics** for preferences, host/trust state and window layout.
- **`config.toml`** is declared in the registry but not read.
- **About/Privacy view** listing every network destination.
- **⌘K palette** and the `is:`/`image:`/`host:` search grammar.
- **Clickable ports** and detail views for volumes and networks (both are immutable,
  so these are read-only by necessity — there is no `update` command for either).
- **Progress for long operations** (pull has none), and prune previewing what dies.
- **Accessibility passes**: Increase Contrast, Reduce Transparency, Reduce Motion,
  VoiceOver wording.
- **The Xcode project**: hardened runtime, Developer ID, notarization. The bundle
  script is deliberately not this.

Two things that are *not* going to happen, and why, so nobody re-proposes them:
Compose (Apple has no Compose object; building one makes Flotilla an orchestrator)
and a general interactive `exec` in the Phase 2 grammar (it is remote code
execution; see `research/DOCKER-PORTABILITY.md`).

### Phase 2 — Stateful host mode + client mode over mTLS

- Add length-prefixed protocol framing, handshake/version/capability negotiation,
  and explicit request lifecycle.
- Carry CLI argument arrays only inside the Q1 allowlisted boundary. Validate on
  both sides and enforce frame, argument, concurrency, and deadline limits.
- Design client-to-host stdin/resize frames and binary frames now so Phase 4 exec
  and future transfer work do not break deployed protocol versions.
- Build `NWListener`/`NWConnection` mTLS transport, unique Keychain identities,
  two-sided pairing, peer allowlist, immediate revocation, Bonjour discovery, and
  manual host entry.
- Add `RemoteHost` while keeping `ContainerCLI` semantics shared with `LocalHost`.
- Add the persisted host policy/settings store and typed per-host settings
  get/set messages. Mode itself is never remotely switchable.
- Keep host-mode UI minimal: listener state, identity/fingerprint, peers, recent
  commands, and a control to stop accepting connections.
- Acceptance criterion: safe Phase 1 feature parity through a remote host without
  adding per-operation RPC types.

### Phase 3 — Fleet view

- Aggregate containers from local and remote hosts in one table with a Host
  column, grouping, search, staleness, and cached offline data.
- Add fleet sidebar/status rollups, host detail, trust management, host
  tags/groups, and per-host identity/settings overrides.
- Implement adaptive polling; `container` has no event stream.
- Add version-skew warnings, cross-host bulk actions, fan-out image pulls, and
  partial-failure reporting.
- Support safe host/settings import and export without private keys.
- Add validated local `config.toml` editing. Remote editing remains deferred
  unless evidence shows it is necessary.

### Phase 4 — Live streaming + exec + host policy loops

- Add live log/stat streams over persistent connections and render sparklines only
  for visible data.
- Add interactive `container exec` with a real PTY, fresh visible authorization,
  bounded lifetime/concurrency, and no transcript logging by default.
- Implement restart policy and health checks on the **host peer**, backed by its
  persisted policy store, so policies survive client disconnects.
- Add read-only-first file browsing/download and host-aware bind-mount/port
  editing. Upload and broader transfer can follow.

### Phase 5 — Auto-updates

- Integrate Sparkle 2 for unmanaged Macs with HTTPS appcast, Ed25519 artifact
  signatures, Developer ID, notarization, and release verification.
- Separate check/download/install controls and obtain first-run consent for update
  checks.
- Add a host-safe update interruption point: stop new mutations, finish bounded
  work, persist consistent state, relaunch, and re-run preflight.
- Use named-host canaries and an explicit reinstall rollback runbook.
- Jamf, not Sparkle, remains the update authority on managed minis.

### Phase 6 — Jamf / configuration profiles

- Deliver unique per-device identity and managed settings without changing the
  transport.
- Use two managed tiers: `defaults` to seed editable values and `locked` to
  override and disable editing.
- Manage mode, listener/Bonjour settings, trust anchors, peer allowlist, identity
  label, update policy, diagnostics policy, minimum client version, and fleet
  defaults.
- Show effective value, source, validation errors, and lock state in diagnostics.
- Test app-before-profile, profile-before-app, renewal overlap, removal,
  revocation, restart, and segmented-network behavior on staged managed hardware.

## Critical environment constraint — nested virtualization

The development laptop is M2 Max. Running a `container` Linux micro-VM inside a
UTM macOS guest requires nested virtualization unavailable on that host.

- Phase 1 runs natively on the laptop.
- UTM guests can test UI, Bonjour, mTLS, wire framing, and authorization without
  launching real containers.
- Full remote lifecycle tests use a physical Apple Silicon Mac, currently the M1
  Mac mini, as the host peer.
- Manual host entry covers routed/VLAN networks where mDNS cannot cross.

## Verification

- On macOS: `swift build`, `swift test`, then launch with `swift run Flotilla`.
- On Linux/Swift 6.1: `swift build` and `swift test`; SwiftPM selects the portable
  manifest and excludes the SwiftUI app.
- Phase 1: verify local list/run/stop/logs and system features natively against
  the installed `container` CLI.
- Phase 2: verify discovery, manual add, bilateral pairing, allowlist rejection,
  limits, revocation, state persistence, and remote Phase 1 parity.
- Phase 3+: verify aggregate results and stale/offline behavior across multiple
  physical or virtual peers.
- Phase 6: verify both managed tiers and identity/profile lifecycle on a staged
  Jamf-managed mini.
