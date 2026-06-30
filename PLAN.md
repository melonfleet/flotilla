# Flotilla — native macOS fleet manager for Apple `container`

## Context

Apple shipped `container` (WWDC 2025): an open-source Swift CLI that runs Linux
containers as one micro-VM each on Apple Silicon. The existing native GUI in this
space — `tdeverx/contained-app` — is **local-only** and explicitly has **no remote
host support**. The user has a personal fleet (4 Mac Studios + 4 Mac minis, all
Apple Silicon M1+) and wants a **personal, non-commercial** menu-bar app that:

- Manages containers on the **local** machine, and
- Manages containers on **remote Macs** in the fleet, where each remote Mac runs
  the same app in **host mode**.
- Communicates **Swift-to-Swift over the network** (no reliance on the macOS
  `ssh` binary), authenticated with **mTLS certificate identities** ("key list"),
  with **Bonjour** discovery on the LAN.
- Later: onboard the physical Jamf-managed Mac minis via **configuration
  profiles** delivering the identity cert + mode/trust settings — no code change,
  since the transport is already cert-based.

Working name: **Flotilla**. This is a personal Swift learning/utility project, not
a business venture.

**Status (2026-06-30):** repo live + private at `melonfleet/flotilla`; SwiftPM
scaffold builds and tests green; `FlotillaCore` models decode real `container` 1.0.0
JSON; watermelon branding done; GitHub security/1Password-signing set up. Next:
Phase 1 app layer. Build workflow with ChatGPT Codex is in `docs/AI-WORKFLOW.md`.

**Branding:** icon is a flotilla of three white sails over a **watermelon slice**
— pink flesh field, green rind base, white pith line, black seeds (playful, personal,
and distinct from Docker's blue whale). Built as a layered **Liquid Glass** app icon
on macOS 26, with a monochrome three-sails template for the menu-bar extra. The
watermelon palette carries into the UI: **pink = brand/selection**, **green =
healthy/running**. Full spec in `design/branding.md`.

## Architecture

```
Flotilla.app  (one app, two runtime modes — menu-bar extra + main window)
├── FlotillaCore  (SwiftPM library, no UI)   ← shared spine, both modes link it
│   ├── Models           Codable: Container, Image, Host, Stats, Event
│   ├── ContainerCLI     wraps `container … --format json` via Process
│   ├── ContainerHost    protocol: run(args) / stream(args)
│   │     ├── LocalHost   → Process (container CLI on this Mac)
│   │     └── RemoteHost  → NWConnection (mTLS) to a host-mode peer
│   └── Wire             Codable request/response + length-prefixed framing
│
├── Host mode runtime
│   ├── NWListener + NWProtocolTLS (mTLS), advertises via Bonjour
│   ├── Authorizes peer by cert fingerprint allowlist ("key list")
│   └── On request → runs container CLI locally, streams stdout/stderr/exit
│
└── Client mode runtime (UI)
    ├── Bonjour browser → discovered hosts
    ├── RemoteHost per fleet member; LocalHost for this Mac
    └── SwiftUI: menu-bar extra + NavigationSplitView main window
```

Design decisions (settled during discovery):

- **Shell out to the `container` CLI and decode `--format json`** — do NOT link
  the Containerization framework. `contained-app` validates this: robust across
  CLI churn, easy to verify. JSON output confirmed available.
- **CLI bootstrap/preflight.** On launch (local and host mode), detect whether
  `container` is installed and check its version. If missing/outdated, offer a
  one-click guided install that downloads the latest signed `.pkg` from the
  `apple/container` GitHub releases and runs it via the system installer **with
  user authorization** — never a silent privileged install (the pkg drops a
  launchd service and needs admin).
- **Network.framework + mTLS**, not the system `ssh` binary and not gRPC. Pure
  Apple, no third-party deps, and certificate identities map 1:1 onto the future
  Jamf/config-profile onboarding path.
- **Two ways to add hosts:** (a) **Bonjour** auto-discovery on the flat LAN, and
  (b) **manual entry** by hostname/IP + port. Manual is mandatory, not optional —
  mDNS does not cross subnets/VLANs, so routed/segmented networks require it.
- **One app, two modes** — host mode is the same binary running headless-ish, not
  a separate daemon. Mode chosen in UI now; profile-delivered later.
- **No Kubernetes.** For ~8 nodes, "orchestration" = fleet view + per-host
  run/stop + (later) self-implemented restart/health. Note `container` has no
  native `--restart`/healthcheck — those are implemented in-app if wanted.

## Tech stack

- Swift 6.2+, SwiftUI, SwiftPM two-target package (mirror `contained-app`'s
  `Core` lib + app split).
- **Liquid Glass** SwiftUI materials (`glassEffect` et al.) — macOS 26-only target,
  so use the real design language, not faux cards.
- Network.framework (`NWListener`/`NWConnection`/`NWProtocolTLS`/`sec_*`).
- **Sparkle** for auto-updates, with an appcast feed hosted on GitHub releases.
- SwiftData for local history; Swift Charts for sparklines/stats.
- `MenuBarExtra` scene + `NavigationSplitView` main window; ⌘K command palette.
- Identities/allowlist in Keychain. Self-signed certs generated in-app now;
  Jamf-delivered later.

## Build phases

**Phase 1 — Local MVP (chip-independent, build first).**
`FlotillaCore` with `Models`, `ContainerCLI` (run + JSON decode), `ContainerHost`
protocol, `LocalHost`. SwiftUI menu-bar app: container grid (the mockup), images
list, run/stop/restart/remove, logs view. Goal: a working local manager.

**Phase 2 — Host mode + client mode over mTLS.**
`Wire` message types + framing. Host runtime: `NWListener` + mTLS + Bonjour
advertise + fingerprint allowlist. Client runtime: Bonjour browse + manual
host-add (hostname/IP + port) + `RemoteHost`. Manual cert pinning UI. Test client
(laptop) ↔ host (physical M1 Mac mini).

**Phase 3 — Fleet view.**
Multiple host-mode peers, aggregate dashboard, per-host status dots + counts
(as in mockup), host onboarding/trust management.

**Phase 4 — Live streaming + exec.**
Switch log/stat streaming to a persistent `NWConnection` channel; `container exec`
interactive terminal tab. Consider self-run restart/health here.

**Phase 5 — Auto-updates (before Jamf, for the unmanaged fleet).**
Integrate Sparkle; publish releases + an appcast feed on GitHub so dev machines
and unmanaged hosts self-update. Sign/notarize the app. (Managed minis later get
updates via Jamf instead.)

**Phase 6 — Jamf / configuration profiles.**
Replace manual cert + mode setup with profile-delivered identity (Keychain) +
managed settings (mode, trust anchors, allowlist) on the physical Mac minis.

## Critical files (to create)

- `Package.swift` — two targets: `FlotillaCore` (lib), `Flotilla` (executable).
- `Sources/FlotillaCore/Models/*.swift` — Codable models matching `container`
  JSON output.
- `Sources/FlotillaCore/ContainerCLI.swift` — Process wrapper, JSON decoding.
- `Sources/FlotillaCore/ContainerHost.swift` — protocol + `LocalHost`.
- `Sources/FlotillaCore/Wire.swift` — request/response + length-prefix framing.
- `Sources/FlotillaCore/Transport/{Listener,Connection,TLSIdentity}.swift` —
  Network.framework + mTLS + Bonjour (Phase 2).
- `Sources/Flotilla/App.swift` — `MenuBarExtra` + main window scenes.
- `Sources/Flotilla/Views/*` — fleet sidebar, container grid, detail tabs.

## ⚠️ Test-plan constraint — nested virtualization (dev laptop is M2 Max, macOS 26.5.1)

`container` boots a Linux micro-VM per container. Running it **inside a UTM macOS
guest** is nested virtualization, supported only on **M3+** hosts. The dev laptop
is **M2 Max** → no nested virtualization. Concretely:

- **Phase 1 local MVP runs natively on the laptop** — it's Apple Silicon on macOS
  26, so `container` works directly. No VM needed for local development/testing.
- The **comms/UI layer** (Bonjour, mTLS, Wire protocol, host/client modes) is
  testable in UTM macOS VMs on the M2 — networking and discovery don't need the
  inner Linux VM.
- **Launching real containers inside a UTM guest will fail on the M2.** So
  full-stack remote tests (host mode actually spinning up a container) run against
  the **physical M1 Mac mini** as the host — it runs `container` natively, no
  nesting. Pattern: laptop = client, M1 mini = host-mode peer.

### Two network test topologies

- **Isolated (transport/auth):** two macOS VMs on a UTM **host-only/internal**
  network. Exercises Bonjour discovery + mTLS handshake + allowlist rejection on a
  clean switch (mDNS works across the virtual switch; real container launch will
  fail — expected, this validates networking only).
- **Bridged (real cross-machine):** switch VMs to **bridged**, or use the physical
  M1 mini, so the laptop and fleet Macs share L2. Tests real discovery and the
  full container lifecycle. The routed/VLAN case (no mDNS) is what manual host-add
  covers.

## Verification

- Phase 1: build with `swift build`; launch app; confirm local containers/images
  list, run/stop/logs against `container` running **natively on the M2 Max
  laptop** (macOS 26 — no VM needed).
- Phase 2 (networking layer): stand up host mode in a UTM macOS VM on the laptop;
  from the laptop client, discover it via Bonjour, complete mTLS handshake (reject
  an un-allowlisted cert), and round-trip a `container ls`. Real container
  spin-up in that VM will fail (no nested virt) — that's expected; this step
  validates discovery/transport/auth only.
- Phase 2/3 (full stack): point the laptop client at a **physical Mac mini/Studio**
  running host mode and verify real run/stop/logs end to end.
- Phase 3+: onboard multiple VM hosts; confirm aggregate fleet view matches each
  host's local `container ls`.
- Phase 6: install a configuration profile on a Jamf-managed mini; confirm the
  app picks up identity + mode/trust from the profile with no manual setup.
