# Flotilla — AI workflow (two assistants)

> **Archived 2026-07-27, and redacted before publication.** Superseded; see `archive/README.md`.
> Credential-manager specifics have been generalised on purpose — this file is tracked.

Two assistants work this repo. Their roles are split by what each can actually do
in *this* project, not by generic preference.

## The environment reality (drives everything)

- **Claude Code** runs **locally on the Mac** → full access: builds with Swift/Xcode,
  runs Apple `container`, signs commits through the credential manager, sees the real macOS 26 environment
  and the project memory/context.
- **ChatGPT Codex** comes in two forms:
  - **Codex cloud** (web/async agent) runs in a **Linux sandbox** → **cannot** build
    SwiftUI/macOS, cannot compile `Network.framework` code, cannot run Apple
    `container`. Good only for work that doesn't need to compile against the macOS SDK.
  - **Codex CLI** runs **locally on the Mac** → *can* build/test like Claude.

**Rule of thumb:** anything that must compile against the macOS SDK or run `container`
is **Claude or Codex CLI (local)** — never Codex cloud.

## Roles

### Claude Code — lead architect & integrator
Owns the things that need judgment, the real environment, or cross-cutting reach:
- Architecture, the plan, and scoping tasks for Codex.
- macOS/Apple-framework code: `Network.framework` mTLS transport, Bonjour, the
  SwiftUI app (MenuBarExtra, Liquid Glass), `container` integration.
- Security, signing and release infrastructure.
- Final review and merge; anything requiring real hardware or the project memory.

### ChatGPT Codex — implementation workhorse & second reviewer
Best at well-scoped, self-contained tasks that Claude specs out:
- `FlotillaCore` **pure logic**: models, CLI arg builders, JSON decoders, the
  scheduler/health logic, helpers.
- **Unit tests** against the captured fixtures in `Tests/.../Fixtures/`.
- Refactors, boilerplate, docstrings, small isolated modules.
- **Independent code review** — a different model catches different bugs.
- Run as **parallel async tasks** (Codex cloud) for drafting/reviewing that doesn't
  need to compile; use **Codex CLI locally** when the task must build/test.

## How they hand off

Use **GitHub PRs** as the interface:
1. Claude (or you) writes a small, isolated task spec (a GitHub issue).
2. Codex implements on a branch → opens a PR.
3. Claude reviews on the Mac (builds/tests it) → requests changes or merges.
4. Reverse also works: Claude implements, Codex reviews the PR.

Keep tasks **small and non-overlapping** so two agents don't collide in the same
files. Assign one owner per area at a time.

## Guardrails

- **Don't give Codex cloud** UI/transport/`container` tasks it can't compile — it'll
  produce plausible-but-unverified code. Those go to Claude or Codex CLI (local).
- **Signing:** the sandboxed agent's commits cannot reach the credential manager, so they'll be unsigned/
  unverified. Prefer Codex **CLI locally** for anything that commits, or have Claude/
  you sign on merge (squash-merge re-signs with the local key).
- Every merged commit on `main` should end up **Verified** (signed through the credential manager).

## Quick split (cheat sheet)

| Task | Who |
|------|-----|
| Architecture, planning, task specs | Claude |
| Network.framework / mTLS / Bonjour | Claude |
| SwiftUI app, MenuBarExtra, Liquid Glass | Claude |
| `container` integration, preflight, signing/infra | Claude |
| FlotillaCore pure logic + unit tests | Codex (CLI local to compile) |
| Refactors, boilerplate, docstrings | Codex |
| Second-opinion code review | either reviews the other |
