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

## Licensing note

`tdeverx/contained-app` is **PolyForm Noncommercial 1.0.0** — fine to read for
ideas and for personal non-commercial use, but don't copy its code into anything
commercial. Learn the patterns; write our own.
