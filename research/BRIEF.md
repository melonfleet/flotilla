# Flotilla — product research brief (whole team, parallel)

**Goal:** before we build, survey what comparable products actually do — features, settings,
preferences, configuration, distribution — so we can pick a deliberate feature list for Flotilla
rather than inventing one. Each agent owns ONE area. Output feeds a combined feature list the
user chooses from.

## What Flotilla is (context — read these first)
A **native macOS menu-bar app** that manages **Apple's `container`** containers on the local Mac
**and across a fleet of remote Macs**. Not a Linux/Docker clone — Apple `container` is the runtime.
Read, in the repo root: `PLAN.md` (6-phase plan + architecture), `DECISIONS.md` (**settled choices
and explicitly rejected alternatives — do NOT propose something already rejected**), `README.md`,
and the `reference/` docs relevant to your area (`container-cli.md`, `wire-protocol.md`,
`json-schemas.md`, `liquid-glass.md`, `networking-mtls-bonjour.md`, `sparkle-updates.md`,
`jamf-config-profile.md`).

## Products to survey (pick the most relevant 3–5 for YOUR area)
Docker Desktop, **OrbStack** (closest native-Mac analogue), Podman Desktop, Rancher Desktop,
Colima/Lima, Apple's own `container` CLI, and — for the fleet/menu-bar angle — tools like
Jamf/Kandji admin UIs, Tailscale's menu-bar app, or similar Mac fleet/menubar utilities.

## Output format (IMPORTANT — same for everyone)
Write ONE markdown file to `/Users/example/melonfleet/Flotilla/research/<your-area>.md`:

```
# Flotilla research — <area>

## 1. What the comparables do
### <Product>
- <capability / setting / pattern> — <short note, and where it appears in the UI/config>
… (be concrete and exhaustive for YOUR area; note anything Mac-native-specific)

## 2. Patterns worth stealing
Short list of the genuinely good ideas, with WHY.

## 3. Anti-patterns / things to avoid
What these products get wrong or what users complain about.

## 4. → Proposed for Flotilla
A prioritised list. Mark each **[core]** (v1), **[later]**, or **[skip]** (with why).
Note which of the 6 phases in PLAN.md it belongs to, and flag anything that conflicts
with or extends DECISIONS.md.
```

Be concrete, cite the product, and prefer specifics ("OrbStack exposes X in Settings > Y") over
generalities. If you're unsure something is current, mark it "(verify)". No PII.

## Area assignments
- **the UX study → `design-ux.md`** — UI/UX: menu-bar interaction patterns, popover vs window, main window
  layout, list/detail/card views, status indicators, iconography, onboarding/first-run, empty
  states, notifications/alerts, dark mode, accessibility, and the "feel" of a native Mac app
  (incl. what `liquid-glass.md` implies). How do these apps present containers/images/logs?
- **the core owner → `preferences-settings.md`** — every user-facing **preference and setting** these apps
  expose (walk their Settings/Preferences panes and docs): general, resources (CPU/RAM/disk),
  file sharing/mounts, network/proxy/DNS, updates, notifications, startup/login-item, theme,
  telemetry/privacy, advanced/experimental. Also: config **file formats** (where stored, schema,
  defaults, precedence, import/export/reset) — this is the data-layer view.
- **the CLI owner → `features-runtime.md`** — the functional feature set: container lifecycle (create/
  start/stop/delete/restart), images (pull/build/prune/registry auth), volumes/bind mounts,
  networking/port mapping, **logs / exec / shell / file browser / stats & resource graphs**,
  search/filter, bulk actions, compose-like multi-container handling, CLI↔GUI parity, and what a
  **remote/fleet** view needs on top (per-host vs aggregate).
- **the review → `deployment-ops.md`** — distribution and operations: install/uninstall, **auto-update**
  (Sparkle and how others do it), code signing/notarization/hardened runtime, sandboxing +
  entitlements, **MDM/Jamf configuration profiles** and managed preferences, licensing/activation,
  crash reporting + telemetry (and privacy/opt-out), logging/diagnostics/support bundles, security
  model for **remote fleet access** (mTLS, pairing, trust, revocation), and update/rollback safety.

## Rules
Do NOT run git (the app owner commits). Do NOT write code or touch anything outside your own research
file. Research + write only. Report a short summary of your top findings when done.
