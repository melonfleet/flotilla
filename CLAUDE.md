# Flotilla — project guide for Claude Code

You are helping build **Flotilla**, a native macOS app that manages Apple's
`container` CLI on the local machine and across a fleet of remote Apple Silicon
Macs.

This is a **personal, non-commercial** project. Read `DECISIONS.md` before changing
product or security direction, `PHASE1.md` for the current build contract and
ownership, `research/FEATURES.md` for the consolidated phase-ordered scope, and
`PLAN.md` for the six-phase roadmap. Settled decisions are not open design
questions.

## Project status (2026-07-27)

- `FlotillaCore` is real and substantial, not a scaffold. It is Foundation-only
  and contains:
  - real `container` JSON models and fixtures;
  - `ContainerHost`, `LocalHost`, and `CommandResult`;
  - the currently read-only `ContainerCLI`;
  - the Q1 `Allowlist` and host-path `MountPolicy` security boundary;
  - a typed settings registry implementing managed `defaults` + `locked`
    precedence;
  - diagnostics snapshot, error-log, and redaction components.
- The macOS SwiftPM package includes a SwiftUI `Flotilla` executable with a
  `MenuBarExtra`, main window, and table-first cross-host container view.
- **29 tests pass on macOS.**
- `FlotillaCore` also builds and tests on Linux with Swift 6.1 through
  `Package@swift-6.1.swift`. Keep the portable core Foundation-only so backend and
  data work remains independently verifiable.
- Phase 1 remains in progress. Unfinished work includes `ContainerCLI` mutations,
  volumes, networks and bounded logs; `Preflight`; settings tests; and the complete
  diagnostics/support-bundle flow.
- Phase 2 networking is not implemented yet: there is no `Wire`, `RemoteHost`,
  Network.framework transport, mTLS listener, Bonjour browser/advertiser, or
  persisted host policy store in the current source tree.
- Branding is the approved watermelon visual language. Light and dark appearances
  are both first-class.

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
