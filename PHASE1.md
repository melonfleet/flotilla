# Flotilla — Phase 1 build contract

Scope approved 2026-07-27 (see `DECISIONS.md` → "Proposal review — settled 2026-07-27"
and `research/FEATURES.md`). This file is the working contract; `DECISIONS.md` is the
authority if anything here conflicts.

## The split (and why)

`FlotillaCore` imports **only `Foundation`** — no SwiftUI/AppKit/Network.framework — so it
**builds and tests on Linux**. `Package@swift-6.1.swift` exists for exactly this. That means
the core owner and the CLI owner write core code **and verify it themselves** (`swift build`, `swift test`);
they are not coding blind. the app owner owns everything macOS-only.

| Owner | Area | Verifiable by them? |
|---|---|---|
| **the core owner** | Settings registry, new models, diagnostics/support-bundle | ✅ Linux |
| **the CLI owner** | CLI surface (mutations, volumes, networks, logs), the allowlist, preflight | ✅ Linux |
| **the app owner** | SwiftUI shell, Xcode project, MenuBarExtra, table UI, signing | macOS only |
| **the review** | Review + tests | review is platform-free |

**Hard rule for the core owner and the CLI owner: `FlotillaCore` stays UI-free and Foundation-only.** Do not
`import SwiftUI`, `AppKit`, `Network`, or anything Apple-only — it breaks the Linux build
that lets you verify your own work.

## What already exists (extend, don't duplicate)
- `Models.swift` — `Container`, `ContainerImage`, `ContainerStats`, `SystemStatus`,
  `VersionComponent`, `Descriptor`, `Platform`. These decode **real `container` 1.0.0 JSON**,
  pinned by fixtures in `Tests/FlotillaCoreTests/Fixtures/*.json`. Don't break them.
- `ContainerCLI.swift` — **read-only** today: `listContainers`, `listImages`, `stats`,
  `systemStatus`, `versions`.
- `ContainerHost.swift` — the `ContainerHost` protocol + `LocalHost` (runs args via Process),
  and `CommandResult`. This is the spine; the UI never cares if a host is local or remote.
- `reference/container-cli.md` — the full `container` command surface. **Read it before
  inventing commands.**

---

## the CLI owner — CLI surface, allowlist, preflight

### 1. `Allowlist.swift` — the Q1 security boundary (do this FIRST)
`DECISIONS.md` Q1: the middle path. The host accepts **args passthrough constrained by a
subcommand allowlist** — never an arbitrary command string, never a generic remote shell.
Build it as pure, table-driven, heavily-tested logic:
- An enum/table of permitted `container` subcommands (`args[0]`, plus second-level where
  relevant e.g. `image pull`), each with an argument schema: which flags are allowed, which
  take values, value shape (identifier / image ref / port / path / duration), and whether the
  operation mutates.
- `validate(_ args: [String]) -> Result<ValidatedCommand, AllowlistError>` — rejects unknown
  subcommands, unknown/malformed flags, shell metacharacters, path traversal, absurd lengths,
  and anything not on the list. **Default deny.**
- Limits: max arg count, max total length. (Concurrency/deadline live at the transport layer
  in Phase 2 — just leave the hooks.)
- This is the thing that stops a compromised client running arbitrary commands on a mini, so
  test it adversarially: injection attempts, `--flag=value` vs `--flag value`, `--`, empty
  args, unicode lookalikes.

### 2. Extend `ContainerCLI` with the Phase 1 operations
All must route through `ContainerHost.run` and go through `Allowlist.validate` first.
- **Containers:** `start`, `stop` (with timeout), `restart`, `delete/rm` (with force), `run`
  (image, name, ports, env, volumes, detach).
- **Images:** `pull`, `delete/rm`, (`list` exists).
- **Volumes:** list, create, delete. **Networks:** list, create, delete.
- **Logs:** fetch logs for a container (with a line limit / follow flag — follow itself is
  Phase 4 streaming, so Phase 1 is a bounded fetch).
Decode `--format json` where the CLI offers it; where it doesn't, parse defensively and add a
fixture. **Add a fixture + test for every new decode path** — that's the pattern the repo
already uses.

### 3. `Preflight.swift`
Detect whether `container` is installed, resolve its path, parse its version, and compare
against a declared minimum. Return a typed result (`ok` / `missing` / `tooOld(found:need:)` /
`unusable(reason:)`). **Do not** implement the guided install — that's the app owner's (it needs user
authorisation and the system installer; see `DECISIONS.md`: never silent/privileged).

---

## the core owner — settings registry, models, diagnostics

### 1. `Settings/` — the typed registry with two-tier precedence (do this FIRST)
`DECISIONS.md` Q4: **two-tier `defaults` + `locked`**, adopted now because retrofitting
precedence later means rewriting every accessor.
- A **typed key registry**: each setting declared once with its key string, type, default
  value, and whether it is managed-overridable. No stringly-typed lookups scattered around.
- **Precedence, highest wins:** `locked` (managed, immutable — UI must show it as locked and
  not let the user edit it) → user value → `defaults` (managed-provided seed the user *may*
  change) → built-in default.
- An `isLocked(key)` query so the UI can render the padlock/disabled state.
- Reading managed values: model the shape of a macOS managed-preferences domain
  (`/Library/Managed Preferences/dev.melonfleet.Flotilla.plist`) but keep the **source
  injectable** so it tests on Linux — a protocol with a real implementation later and a
  fake in tests. Do NOT call `CFPreferences`/`UserDefaults` from Foundation-only code.
- Export / import / reset-to-defaults.
- Seed the registry with the Phase 1 settings from `research/preferences-settings.md`:
  appearance (see below), poll intervals, notification categories, host port, log line cap,
  update channel, diagnostics opt-in.
- **Appearance** (`DECISIONS.md`): values `auto|light|dark`, chosen at **first run**, `auto`
  pre-selected. Represent "not yet chosen" distinctly from "chose auto" so onboarding knows.

### 2. New models (same style as `Models.swift`, `Codable` + `Sendable`)
`Volume`, `Network`, `LogLine`/`LogChunk`, `NotificationCategory` (+ per-category enabled
state), and a `PreflightResult` type the CLI owner can return. Add fixtures where they decode CLI JSON.

### 3. Diagnostics + support bundle
- A diagnostics snapshot: app version, OS, `container` version, preflight result, host
  inventory summary, recent error log, settings **with secrets and identifiers redacted**.
- Assemble a support bundle (the structure + redaction + serialisation — the actual file
  write/zip on macOS is the app owner's). **Redaction is the important part: no tokens, no cert
  material, no absolute user paths.** Test that redaction actually removes them.

---

## Both of you
- **Write tests as you go and run them**: `swift build && swift test` in the repo root. You
  have a working Linux toolchain — a change isn't done until its tests pass.
- Keep `FlotillaCore` Foundation-only (see hard rule above).
- Match the existing code's idioms; keep types `Sendable`.
- **Do NOT run git** — the app owner reviews, commits and pushes.
- Don't edit each other's files. the core owner: `Settings/`, `Models.swift`, `Diagnostics/`.
  the CLI owner: `Allowlist.swift`, `ContainerCLI.swift`, `Preflight.swift`. Shared files
  (`ContainerHost.swift`, `Package*.swift`) are the app owner's.
- Report what you built, what your tests cover, and anything in this contract that turned out
  to be wrong or under-specified.
