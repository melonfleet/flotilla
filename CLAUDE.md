# Flotilla — project guide for Claude Code

You are helping build **Flotilla**, a native macOS menu-bar app that manages Apple's
`container` (the WWDC 2025 Swift CLI that runs Linux containers as one micro-VM each
on Apple Silicon) on the **local** machine and across a **fleet of remote Macs**.

This is a **personal, non-commercial** project. Read `PLAN.md` for the full design,
`DECISIONS.md` for settled choices (don't relitigate), and `PROMPTS.md` for
phase-by-phase kickoff prompts.

## What already exists in this folder

- A **SwiftPM scaffold that builds and passes tests** — validated on macOS 26 with
  Swift 6.3 (`.macOS(.v26)` confirmed valid). `Package.swift` defines library
  `FlotillaCore` + executable `flotilla-probe` + tests with `ContainerHost`/
  `LocalHost`, `ContainerCLI`, and **models that decode real `container` 1.0.0
  output**. So Phase 0 (scaffold builds) and Phase 1 step 1 (models match the real
  JSON schema) are already done.
- **Real JSON, pinned by tests** — `Tests/FlotillaCoreTests/Fixtures/*.json` are
  live captures from `container` 1.0.0; `swift test` decodes them (6 tests green).
  `swift run flotilla-probe` round-trips against a live install.
- **`reference/`** — pre-researched docs so you don't have to re-fetch:
  `json-schemas.md` (the real captured schemas), `container-cli.md` (full command
  surface), `networking-mtls-bonjour.md`, `wire-protocol.md`, `liquid-glass.md`,
  `sparkle-updates.md`, `jamf-config-profile.md`. Read the relevant one per phase.

## What we're building (essence)

- One app, **two runtime modes**:
  - **Client mode** (the laptop): SwiftUI UI, discovers and drives remote hosts.
  - **Host mode** (each fleet Mac): runs headless-ish, listens for the client, and
    executes `container` commands locally.
- They talk **Swift-to-Swift over the network** using **Network.framework + mTLS**
  (NOT the macOS `ssh` binary, NOT gRPC). Cert identities = the "key list".
- **Bonjour** discovery on the flat LAN, plus **manual host-add by hostname/IP +
  port** (required — mDNS doesn't cross subnets/VLANs).

## Architecture (target)

```
Flotilla.app
├── FlotillaCore  (SwiftPM library, no UI)  ← shared by both modes
│   ├── Models           Codable: Container, Image, Host, Stats, Event
│   ├── ContainerCLI     wraps `container … --format json` via Process
│   ├── ContainerHost    protocol: run(args) / stream(args)
│   │     ├── LocalHost   → Process (container CLI on this Mac)
│   │     └── RemoteHost  → NWConnection (mTLS) to a host-mode peer
│   ├── Wire             Codable request/response + length-prefixed framing
│   └── Transport/       NWListener, NWConnection, TLSIdentity (Phase 2+)
├── Host mode runtime    NWListener + mTLS + Bonjour advertise + cert allowlist
└── Client mode (UI)     MenuBarExtra + NavigationSplitView; Bonjour browse + manual add
```

The `ContainerHost` protocol is the spine: the UI never cares whether a host is
`LocalHost` (Process) or `RemoteHost` (mTLS connection).

## Hard rules / decisions (do not relitigate)

- **Shell out to the `container` CLI and decode `--format json`.** Do NOT link the
  Containerization framework — too fragile while the CLI is young. JSON output is
  available and is the integration surface.
- **CLI bootstrap/preflight.** On launch, detect if `container` is installed and
  check its version. If missing/outdated, offer a guided install that downloads the
  latest signed `.pkg` from `apple/container` GitHub releases and runs it via the
  system installer **with user authorization**. Never silent/privileged auto-install.
- **Network.framework + mTLS** for all remote comms. No `ssh`. No third-party
  networking deps.
- **macOS 26 (Tahoe) only**, Apple Silicon only. Use real **Liquid Glass** SwiftUI
  materials (`glassEffect` etc.), not faux cards.
- **No Kubernetes.** For ~8 nodes, orchestration = fleet view + per-host run/stop +
  (later) self-implemented restart/health (`container` has no native `--restart` or
  healthcheck).
- **Swift 6.2+, SwiftUI, SwiftPM two-target package** (`FlotillaCore` lib + `Flotilla`
  executable), mirroring the structure of `tdeverx/contained-app`.

## Tooling

- **Sparkle** for auto-updates, appcast hosted on GitHub releases (Phase 5).
- **SwiftData** for local history; **Swift Charts** for sparklines/stats.
- Keychain for identities + the cert-fingerprint allowlist.

## Build & run

```sh
swift build                 # build FlotillaCore + flotilla-probe
swift run flotilla-probe    # Phase 1 step 1: dump real container JSON, check models
swift test                  # run the test target
# The SwiftUI app target moves to an Xcode project in Phase 1 (MenuBarExtra,
# Liquid Glass, app bundle, signing all want Xcode rather than `swift run`).
```

## ⚠️ Critical environment constraint — nested virtualization

`container` boots a Linux micro-VM per container. The dev laptop is **M2 Max
(macOS 26.5.1)** → **no nested virtualization** (that needs M3+).

- **Local development runs natively on the laptop** — `container` works directly,
  no VM needed.
- The **networking/UI layer** is testable in UTM macOS VMs on the M2.
- **Launching real containers inside a UTM guest will fail on the M2.** Full-stack
  remote tests use the **physical M1 Mac mini** as the host (runs `container`
  natively). Pattern: laptop = client, M1 mini = host-mode peer.

Network test topologies:
- **Isolated:** two macOS VMs on a UTM host-only network → exercises Bonjour + mTLS
  + allowlist rejection (real container launch fails — expected).
- **Bridged / physical:** bridged VMs or the M1 mini → real discovery + full
  container lifecycle.

## Reference

- Apple `container`: https://github.com/apple/container (CLI + signed pkg releases)
- Apple Containerization framework: https://github.com/apple/containerization
- Inspiration (local-only, **PolyForm Noncommercial** license — read for ideas,
  do not copy code): https://github.com/tdeverx/contained-app

## Working style

- Build phase by phase (see `PLAN.md`). Phase 1 (local MVP) is chip-independent and
  comes first. Get the CLI-wrapping + JSON decoding solid before the network layer.
- Match the surrounding code's idioms. Keep `FlotillaCore` UI-free.
- This is a learning project — explain non-obvious Swift/Network.framework choices
  briefly as you go.
