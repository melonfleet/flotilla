# Flotilla — kickoff prompts

Paste these into Claude Code on the laptop, one phase at a time. `CLAUDE.md` is
loaded automatically when you open the folder, so each prompt can stay short — the
full context lives there and in `PLAN.md`.

Work phase by phase. Don't start a phase until the previous one builds and runs.

---

## Phase 0 — Verify the scaffold (already built green)

The scaffold already **builds and passes tests** (validated on macOS 26 / Swift 6.3).
Just re-confirm on the laptop:

```
Read CLAUDE.md, PLAN.md, and DECISIONS.md. Run `swift build` and `swift test` to
confirm green on this machine, then `swift run flotilla-probe` to round-trip against
the local `container`. If anything fails, fix without changing the architecture.
```

## Phase 1 — Local MVP

```
Implement Phase 1 from PLAN.md (local-only MVP). Read reference/json-schemas.md and
reference/container-cli.md first.

The data layer is already done and tested: FlotillaCore's models decode real
container 1.0.0 JSON (fixtures in Tests/), and ContainerCLI has list/stats/status/
version + lifecycle. Re-run `swift run flotilla-probe` to confirm the installed CLI
version still matches; adjust models only if the schema drifted.

Step 1 — finish FlotillaCore: add any missing reads (networks, volumes, logs,
exec), a streaming logs API, and the CLI bootstrap/preflight from CLAUDE.md (detect
+ version-check `container`; if the service is "unregistered" offer to install the
kernel via `container system kernel set --recommended` then `container system
start`; offer guided install if the binary is missing — never silent).

Step 2 — build the app target in Xcode: MenuBarExtra + NavigationSplitView, a
container grid matching design/dashboard-mockup.html, an images list, and
run/stop/restart/remove + a logs view. Use real Liquid Glass (reference/
liquid-glass.md) for chrome only, not the data cards. Drive the UI off ContainerCLI
+ LocalHost.
```

## Phase 2 — Host mode + client mode over mTLS

```
Implement Phase 2 from PLAN.md. Read reference/networking-mtls-bonjour.md and
reference/wire-protocol.md first. Add the Wire message types with length-prefixed
framing in FlotillaCore, then the Transport layer on Network.framework:
NWListener + NWProtocolTLS for host mode (mTLS, Bonjour advertise, authorize
peers by cert-fingerprint allowlist), and NWConnection for RemoteHost on the
client. Add a UI mode switch (client/host), Bonjour browsing, manual host-add by
hostname/IP + port, and a manual cert-pinning UI. Generate self-signed identities
in-app and store identities + the allowlist in the Keychain.

Test target: laptop = client, physical M1 Mac mini = host (it runs `container`
natively). For isolated transport tests I can also run two macOS VMs in UTM on a
host-only network — design the code so I can point the client at either.
```

## Phase 3 — Fleet view

```
Implement Phase 3 from PLAN.md: aggregate fleet dashboard across multiple
host-mode peers — per-host status dots + container counts as in
design/dashboard-mockup.html — plus host onboarding and trust management.
```

## Phase 4 — Live streaming + exec

```
Implement Phase 4 from PLAN.md: move log/stat streaming to a persistent
NWConnection channel, add a `container exec` interactive terminal tab, and
consider self-run restart/health (the CLI has none).
```

## Phase 5 — Auto-updates

```
Implement Phase 5 from PLAN.md: integrate Sparkle with an appcast feed hosted on
GitHub releases so dev machines and unmanaged hosts self-update. Set up app
signing + notarization for the .app bundle.
```

## Phase 6 — Jamf / configuration profiles

```
Implement Phase 6 from PLAN.md: replace the manual cert + mode setup with
configuration-profile-delivered settings — identity cert in the Keychain, plus
managed mode/trust-anchors/allowlist — so Jamf-managed Mac minis onboard with no
manual steps. The transport already uses cert identities, so this should be a
config/source change, not a protocol change.
```

---

## Design regeneration prompts (optional)

If you want to regenerate or iterate the visuals with Claude (uses the visualize
tool):

### Dashboard mockup

```
Create a full-width mockup of the Flotilla main window in Claude Design System
style: a macOS app window with a menu-bar-extra header (traffic lights + "Flotilla"
+ search/⌘K + "N hosts online" status), a left sidebar listing fleet hosts with
online/offline dots and per-host container counts plus a Mode section (client,
mTLS key count), and a main pane with a "Containers" header (Run / Pull image
buttons) and a responsive grid of container cards. Each card: app icon, name,
"host · image", a CPU sparkline, a status badge (running/stopped), and "cpu% ·
mem". Show containers spread across multiple hosts. Teal/blue/coral accents.
```

### App icon — three sails

```
Design a macOS app icon as an SVG in a 120x120 squircle (rx ~27): a teal field
(#0F6E56) with three white/mint triangular sails of varying heights (a flotilla),
sitting on a subtle mint wave line near the bottom. Flat, no gradients. Also
produce a monochrome menu-bar template version (small, single color via
currentColor) of just the three sails.
```
