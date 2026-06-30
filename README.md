<p align="center">
  <img src="design/flotilla-logo.png" width="120" alt="Flotilla logo">
</p>

<h1 align="center">Flotilla</h1>

<p align="center">
  A native macOS menu-bar app to manage Apple's <code>container</code> containers on the
  local machine <strong>and</strong> across a fleet of remote Macs — a personal summer project.
</p>

This folder is a **portable starter kit**. It contains no Swift code yet — it's the
plan, design, and prompts you carry to the laptop to begin building with Claude Code
on a fresh account.

## What's here

**Status:** repo live + private at `melonfleet/flotilla`; scaffold builds + tests
green; watermelon branding; security/signing set up. New Mac? → `docs/LAPTOP-SETUP.md`.

```
Flotilla/
├── README.md            this file
├── CLAUDE.md            steering doc (auto-loaded by Claude Code)
├── PLAN.md              full 6-phase implementation plan
├── DECISIONS.md         settled choices + rejected alternatives
├── PROMPTS.md           paste-ready kickoff prompts per phase
├── LICENSE             personal, all rights reserved
├── Package.swift        compilable SwiftPM scaffold
├── Sources/
│   ├── FlotillaCore/    ContainerHost, LocalHost, ContainerCLI, Models
│   └── flotilla-probe/  dumps real `container` JSON (Phase 1 step 1)
├── Tests/FlotillaCoreTests/
├── docs/
│   ├── LAPTOP-SETUP.md             bring-up on a new Mac
│   └── AI-WORKFLOW.md              Claude + ChatGPT Codex roles
├── scripts/
│   └── setup-mac.sh                one-shot local SSH/signing config
├── reference/           pre-researched API docs (read before each phase)
│   ├── json-schemas.md             real captured container 1.0.0 JSON
│   ├── container-cli.md            full CLI command surface
│   ├── networking-mtls-bonjour.md  Network.framework + mTLS + Bonjour
│   ├── wire-protocol.md            message framing + data model spec
│   ├── liquid-glass.md             macOS 26 glass APIs
│   ├── sparkle-updates.md          GitHub appcast auto-update
│   └── jamf-config-profile.md      managed onboarding
└── design/
    ├── branding.md                 watermelon palette + roles
    ├── dashboard-mockup.html       standalone fleet dashboard mockup
    ├── icon-app.svg                watermelon-slice app icon
    ├── icon-menubar.svg            monochrome menu-bar template
    ├── flotilla-logo.png           README logo (rendered)
    └── melonfleet-avatar.{svg,png} account avatar source
```

## How to start on the laptop

1. Copy the whole `~/melonfleet/` folder to the laptop (this project lives at `~/melonfleet/Flotilla`).
2. Open the project in Claude Code: `cd ~/melonfleet/Flotilla && claude`.
3. Claude reads `CLAUDE.md` automatically. Paste the **Phase 0** prompt from
   `PROMPTS.md` to confirm the scaffold builds (`swift build` / `swift test`), then
   the **Phase 1** prompt to start the local MVP.
4. With `container` installed, `swift run flotilla-probe` dumps the real JSON used
   to finalize the models.
5. Open `design/dashboard-mockup.html` in a browser for the target UI; open the
   SVGs in Preview for the icon.

> The scaffold **builds and passes tests** (validated on macOS 26 / Swift 6.3), and
> the models decode real `container` 1.0.0 JSON (fixtures in `Tests/`). So Phase 0
> and Phase 1's data layer are already done — the laptop starts at the UI.

## The one-line pitch

`contained-app` is a great local-only GUI for Apple `container`. Flotilla is *that,
plus a fleet*: each remote Mac runs the same app in **host mode**, and a **client**
on your laptop discovers and drives them over a Swift-to-Swift mTLS connection
(no `ssh` binary). Hardware: 4 Mac Studios + 4 Mac minis, all Apple Silicon.

Personal, non-commercial. No AI agents involved in the app itself.
