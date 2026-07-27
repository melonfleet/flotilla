<p align="center">
  <img src="design/flotilla-logo.png" width="120" alt="Flotilla logo">
</p>

<h1 align="center">Flotilla</h1>

<p align="center">
  A native macOS app for managing Apple's <code>container</code> containers on the
  local machine <strong>and</strong> across a fleet of remote Macs.
</p>

Flotilla is a personal, non-commercial fleet console for Apple Silicon Macs. It
wraps the `container` CLI instead of linking the Containerization framework, and
uses one shared core for local and eventual remote hosts. The product is
table-first: the primary view is a cross-host container table, with a shallow
menu-bar surface for status and quick access.

Remote communication is designed around Network.framework, mTLS, Bonjour
discovery, and manual host entry for routed networks. It is not an SSH wrapper,
generic remote shell, or Kubernetes-style orchestrator.

## Current status

The repository contains working Swift code, not a starter kit.

- `FlotillaCore` is a substantial, Foundation-only library. It includes the
  `ContainerHost`/`LocalHost` execution spine, real `container` JSON models,
  read-only `ContainerCLI` operations, the Q1 subcommand `Allowlist`,
  `MountPolicy`, a typed settings registry with managed `defaults` and `locked`
  precedence, and diagnostics/redaction components.
- The macOS SwiftUI executable has a `MenuBarExtra`, main window, and table-first
  cross-host container view.
- **29 tests pass on macOS.** Fixtures cover real `container` JSON; the allowlist
  and mount-policy boundary have adversarial coverage.
- The portable core also builds and tests on Linux with Swift 6.1 via
  `Package@swift-6.1.swift`. The SwiftUI app is intentionally absent from that
  manifest.

Phase 1 is not complete. Still unfinished are the remaining `ContainerCLI`
operations (mutations, volumes, networks, and bounded logs), preflight, settings
tests, and the complete diagnostics/support-bundle flow. The Phase 2 wire
transport, mTLS host/client runtime, and persisted host policy store are also
future work.

The current build contract and ownership live in `PHASE1.md`. Settled product and
security choices live in `DECISIONS.md`; the phase-ordered scope is consolidated
in `research/FEATURES.md`.

## Repository layout

```text
Flotilla/
├── README.md
├── CLAUDE.md                     auto-loaded project steering
├── DECISIONS.md                  settled choices and rejected alternatives
├── PHASE1.md                     current build contract and ownership
├── PLAN.md                       six-phase implementation plan
├── Package.swift                 macOS package, including the SwiftUI app
├── Package@swift-6.1.swift       portable Linux core/test manifest
├── Sources/
│   ├── Flotilla/                 MenuBarExtra, main window, cross-host table
│   ├── FlotillaCore/
│   │   ├── Settings/             typed registry and managed precedence
│   │   ├── Diagnostics/          snapshots, error log, redaction
│   │   ├── Allowlist.swift       constrained CLI-argument boundary
│   │   ├── MountPolicy.swift     host-path policy
│   │   ├── ContainerCLI.swift
│   │   ├── ContainerHost.swift
│   │   └── Models.swift
│   └── flotilla-probe/           live `container` JSON probe
├── Tests/FlotillaCoreTests/      model, allowlist, and mount-policy tests
├── reference/                    implementation references
├── design/                       brand assets, specifications, and mockups
├── docs/                         laptop setup notes
└── research/                     consolidated feature and background research
```

There is not yet an Xcode project. The app currently builds as the `Flotilla`
SwiftPM executable; an Xcode project becomes necessary when app-bundle metadata,
`LSUIElement`, signing, and distribution are added.

## Build and test

### macOS

Requirements: Apple Silicon, macOS 26, and a Swift 6.2-or-newer toolchain.
The unit tests use captured fixtures and do not require `container` to be
installed.

```sh
swift build
swift test
swift run Flotilla
```

With Apple's `container` CLI installed, the probe can exercise the live JSON
surface:

```sh
swift run flotilla-probe
```

### Linux

Use a Swift 6.1 toolchain. SwiftPM selects `Package@swift-6.1.swift`, which exposes
only the Foundation-based core, probe, and tests:

```sh
swift build
swift test
```

The SwiftUI app is macOS-only and is not expected to build on Linux.

## The one-line pitch

Flotilla is a native local container manager plus a fleet: the same app will run
in stateful host mode on remote Macs, while a client aggregates and controls them
over a Swift-to-Swift mTLS connection.

Personal, non-commercial. No AI agents are part of the app itself.
