# Independent audit comparison — Grok vs ChatGPT

**Date of this comparison:** 20 August 2026  
**Workspace:** `Flotilla/` (repository-relative)  
**Directory:** `Flotilla/independent audits/` (lowercase; not “Independent Audit”)

This file is a side-by-side of two independent Flotilla audits produced the same day. It does not change application code.

---

## Artifacts

### Grok (Cursor Grok 4.6) — ~15:51 +03

| File | Path |
|---|---|
| HTML catalogue | `Flotilla/independent audits/flotilla-audit-report.html` |
| the app owner handoff | `Flotilla/independent audits/message-to-andy-from-grok-flotilla-audit.md` |
| Canvas (same 54 IDs) | Local editor artifact; intentionally omitted from the repository record |

Headline: *“Flotilla is a real local container console with a settings UI that over-promises the fleet.”*

### ChatGPT — ~14:43 +03 (about 68 minutes earlier)

| File | Path |
|---|---|
| HTML catalogue | `Flotilla/independent audits/audit-report-2026-08-20.html` |
| the app owner handoff | `Flotilla/independent audits/MESSAGE-TO-ANDY-FROM-CHATGPT-FLOTILLA-AUDIT-2026-08-20.md` |

Headline: *“Flotilla is capable—but not yet fleet-ready.”* Verdict: *safe for continued local development; not ready for remote-host or public distribution.*

`LAPTOP-SETUP.md` in the same folder is unrelated laptop bootstrap, not an audit.

**Verdict of this comparison:** **Partially overlapping.** Same spine (strong allowlist, no live remote attack surface, inert settings, delete-policy split, timeout not enforced, Phase 2 must not open yet). Different grain, different severity scale, and each found live issues the other missed.

---

## Scope and methodology

| | Grok | ChatGPT |
|---|---|---|
| Method | Static review of `Sources/Flotilla` (54 files), `Sources/FlotillaCore`, tests, product docs, mockups vs SwiftUI, brand tokens | Static review **plus** `swift test --disable-sandbox` (307 passed), packaging-script inspection, **built bundle** plist/codesign (`flags=adhoc · TeamIdentifier=not set`), visual HTML review |
| Grain | 54 IDs across SEC / GAP / UI / RED | 14 findings (F-01–F-14) + 6 product gaps (G-01–G-06) |
| Counts | 13 High confirmed, 28 Medium, 11 Low, 1 Info (`SEC-11`), 1 High residual (`SEC-12`) | 3 High, 7 Medium, 4 Low; 0 Critical |
| Out of scope (both) | Live hostile testing, CVE scan, VoiceOver session, clean-Mac notarization | Same, plus ChatGPT explicitly did not do those |
| Independence | HTML says prior `audit-report-2026-08-20.html` was **not copied** | Produced first; notes working tree already had `AppModel.swift` / `FlotillaApp.swift` modified |

Grok counted `@Test` functions. ChatGPT actually ran the suite and measured ~21,607 production / 4,791 test Swift lines.

---

## Shared conclusions (the overlap)

1. **No live critical remote issue.** Phase 2 transport is absent (`RemoteHost` is a protocol comment). Do not open a listener yet.
2. **Allowlist / argv / MountPolicy / WirePolicy / support-bundle fail-closed are the real spine.** Do not tear them down.
3. **307 FlotillaCore tests, 0 app/UI test target.** (`GAP-08` / `F-09`)
4. **Inert settings look operational:** Host/Client/Both, listen port, Bonjour, identity Keychain label, Sparkle toggles, `containerBinaryPath`. (`GAP-01`/`GAP-05` / `F-07`)
5. **Container context-menu Delete bypasses confirmation;** images/volumes/networks honour `confirmDestructiveActions`; `confirmBulkActions` is unread. (`SEC-02`/`SEC-06` / `F-03`)
6. **`timeoutHint` is calculated then discarded** at `LocalHost.run` / `waitUntilExit()`. (`SEC-04` / `F-01`)
7. **`auditDescription` joins `--env` / `--build-arg` verbatim.** (`SEC-03` / `F-04`)
8. **Mount-path TOCTOU is a known residual**, not fully closable by repeating `realpath`. (`SEC-05` / `F-05`)
9. **Publish `0.0.0.0` and opaque volume/network plugin options are Phase 2 gates**, not live bugs. (`SEC-12` / `F-06`)
10. **README/PHASE1 still describe a much smaller product** (“29 tests”, read-only CLI). (`GAP-09` / `F-12`)
11. **List/detail chrome is duplicated** across Containers/Machines (presentation enums, embedded navigator, delete mechanics). (`RED-01`/`RED-02` / `F-13`)
12. **Activity/metrics are in-memory.** (`GAP-14` / `G-03`)
13. **No Sparkle / no distribution signing** for public release. (`GAP-05`/`SEC-11` / `F-08`/`G-02`)
14. **Both tell the app owner: verify first, do not implement Phase 2 transport, do not write exploits.**

---

## Grok-only findings

Issues ChatGPT did not catalogue (or only buried as a one-line gap, not a finding).

### Security

- **`SEC-01` Medium** — `TerminalTab.swift` falls back to `/usr/bin/env` after `/usr/local/bin` and `/opt/homebrew/bin`. This undoes `LocalHost`’s absolute-path hardening. **Still in tree.** Same fallback also exists in `MachineDetailView.swift:316–319` (Grok cited only TerminalTab).
- **`SEC-07` Low** — `flotilla-probe` `dumpRaw` calls `cli.host.run(args)` without Allowlist.
- **`SEC-08` Low** — live `ErrorLog` stores messages unredacted; redaction is at snapshot time.
- **`SEC-09` Medium** — local `home-mount=rw` is a filesystem grant; keep `Exposure.localOnly`.
- **`SEC-10` Low residual** — SwiftTerm parses PTY output.
- **`SEC-11` Info** — no App Sandbox; intentional per `DECISIONS.md` Q9.

### Gaps ChatGPT omitted or folded away

- **`GAP-02` High** — Jamf / managed preference tier never injected (`UnmanagedPreferences()`).
- **`GAP-03` High** — guided install + kernel remediation missing; onboarding is appearance-only (`GAP-18`).
- **`GAP-04` High** — Launch at login toggle; no `SMAppService` call (ChatGPT F-07 list does **not** name this control).
- **`GAP-06` High** — volume/network inspect allowlisted but no `inspectVolume`/`inspectNetwork` / no detail UI.
- **`GAP-07` Medium** — search grammar / ⌘K palette absent.
- **`GAP-10` Medium** — `system property list` / `config.toml` not read.
- **`GAP-11` Medium** — run sheet missing `--init`, `--rosetta`, `--read-only`, `--label`, `--shm-size`, `--tmpfs`, `--mount`.
- **`GAP-12` Medium** — pull/build have no progress sheet.
- **`GAP-13` Medium** — volume/network/container prune in CLI, not UI.
- **`GAP-15` Medium** — accessibility is labels, not a pass.
- **`GAP-16` Medium** — structured OSLog almost unused.
- **`GAP-17` Medium** — machine allowlist tests are decode-only (3 vs 68).
- **`GAP-19`/`GAP-20` Low** — i18n; column layout session-only.

### UI (ChatGPT’s UI section is behavioral, not visual-system)

- **`UI-01` High** — table state is a colour-only dot.
- **`UI-02` High** — three incompatible card surfaces.
- **`UI-03` High** — images/volumes/networks empty states have no primary action.
- **`UI-04` High** — filtered-empty Images/Volumes/Networks render a blank table.
- **`UI-05`–`UI-12`** — filter popover vs mockup segmented control; system surfaces in detail; grey sparklines; Wordmark hardcoded hex; bulk bar not accent tint; ports column not clickable; token drift; stale `design/branding.md`.

### Redundancy (ChatGPT collapsed this to Low `F-13`)

- **`RED-01`/`RED-02` High** — skip `ResourceListControls`; duplicated embedded detail navigator.
- **`RED-03`–`RED-07` Medium** — Presentation enum ×3; list-shell boilerplate ×5; inspect tab chrome; machine cards vs `ResourceCard`; triplicated AppModel refresh.
- **`RED-08`–`RED-10` Low** — dead `@State search`; copied `fixture()`; `WindowChromeControls.swift` names no such type.

---

## ChatGPT-only findings

Issues Grok did not catalogue (or only implied inside a residual cluster).

- **`F-02` High** — sequential pipe draining can deadlock; output is unbounded in memory. `LocalHost.run` does `readDataToEndOfFile()` on stdout **then** stderr **then** `waitUntilExit()` (`ContainerHost.swift:61–64`). **Still in tree.** Grok cited this file for timeouts and absolute-path launch and never named the drain order.
- **`F-10` Medium** — untagged `git describe` writes `CFBundleShortVersionString = d8ba884` (`make-app.sh:70–73, 130`). Grok did not inspect the built plist.
- **`F-11` Low** — Menu bar / Dock / Both presents three choices, two behaviors: `dock` and `both` both map to `.regular`; menu-bar-only still opens a window via `.defaultLaunchBehavior(.presented)` (`FlotillaApp.swift:53–82, 235–242`).
- **`F-14` Low** — `actool` failure is best-effort; AppKit accent can silently revert to system blue (`make-app.sh:101–117`).
- **`F-08` Medium** (as a finding, not just Phase 5 note) — ad-hoc sign, no TeamIdentifier, no hardened runtime/notarization; ChatGPT **inspected a built bundle**. Grok put notarization out of scope (`SEC-11` tracks it as Info/Phase 5).
- **`G-04`** — private registry login/logout / Keychain credential lifecycle (Grok never listed this gap).
- **`G-05`** — follow-mode is bounded refetch, not streaming; durable cancellation across the process boundary (tied to F-01/F-02). Grok’s `GAP-12` is pull/build progress UI, not runner streaming.

ChatGPT also preserved pre-existing dirty files (`AppModel.swift`, `FlotillaApp.swift`) as a handoff constraint Grok did not mention.

---

## Severity / framing disagreements (same issue, different rank)

| Topic | Grok | ChatGPT |
|---|---|---|
| Timeout not enforced | **`SEC-04` Medium** (local “harmless-ish”; High only as Phase 2 gate inside `SEC-12`) | **`F-01` High** — first work item; Phase 2 blocker **and** local hung-child problem |
| Pipe deadlock / unbounded stdout+stderr | Not a finding | **`F-02` High** — Wave 0 item 2 |
| Delete confirmation split | **`SEC-02` Medium** (in top five) | **`F-03` High** |
| Inert Host/network/Sparkle settings | **`GAP-01`/`GAP-04` High**, **`GAP-05` Medium** — top issue | **`F-07` Medium** |
| Stale README / 29 tests | **`GAP-09` High** | **`F-12` Low** |
| No UI tests | **`GAP-08` High** | **`F-09` Medium** |
| Duplicated list/detail chrome | **`RED-01`/`RED-02` High** | **`F-13` Low** (“refactor after tests”) |
| Audit argv secrets | **`SEC-03` Medium confirmed now** (run/build **previews leak today**) | **`F-04` Medium “future audit records”** / Phase 2 |
| Remote publish/plugin policy | Folded into **`SEC-12` High residual** | **`F-06` Medium** Phase 2 blocker |
| Missing Sparkle / signing | Honesty-of-UI (`GAP-05`) vs intentional-no-sandbox (`SEC-11` Info) | Release-integrity finding (`F-08`) + gap `G-02` |

---

## Contradictions (one says X, the other says not-X)

Few hard contradictions. The important ones:

1. **What to do first.** ChatGPT Wave 0 is *execution envelope + concurrent drains + confirmation + redaction*. Grok Wave 1 is *disable lying Host/login/Sparkle settings*; local security seams are Wave 2; timeout is “if capacity allows.” They would send the app owner to different files in week one.
2. **Is `auditDescription` a live leak or a future leak?** Grok: live (previews). ChatGPT title: “Future audit records.” Both recommend the same structural redaction.
3. **Is timeout a current High availability bug?** ChatGPT yes. Grok: Medium locally, High only when a listener exists. Code supports both framings; ChatGPT is stricter about hung local processes.
4. **No disagreement** on “there is no listener today” vs “Host mode UI implies one.” Both treat that as honesty, not a live remote CVE. Grok scores the UI High; ChatGPT Medium.

Not contradictions: ChatGPT’s 14 vs Grok’s 54 (grain), or ChatGPT omitting visual UI IDs (scope).

---

## Residual vs live

| Item | Grok | ChatGPT |
|---|---|---|
| Phase 2 transport | Residual cluster **`SEC-12` High** — do not implement | Gap **`G-01`** + policy **`F-06`** — do not implement |
| TOCTOU | Residual **`SEC-05` Medium** | Known residual **`F-05` Medium** |
| SwiftTerm | Residual **`SEC-10` Low** | Not mentioned |
| Timeouts / pipes | Live Medium (`SEC-04` only timeouts) | Live **High** (`F-01`, `F-02`) |
| Host mode UI | Live High honesty (`GAP-01`) | Live Medium (`F-07`) |
| App Sandbox missing | Info, **intentional** | Not scored as a hole; `F-08` is distribution integrity |

---

## Phase 2 / listener / Host mode

**Aligned:** no `NWListener`, no Bonjour advertising, no Keychain mTLS identity, no `RemoteHost` type. Do not open a listener to make Host mode “true.” Gate on timeouts, publish/interface policy, opaque-driver default-deny, audit redaction, identity lifecycle.

**Different:** Grok’s first instruction is *disable the Host control*. ChatGPT’s first instruction is *harden `LocalHost` so a later listener cannot inherit an unbounded executor* — then disable/wire inert settings in Wave 1. ChatGPT is stronger on the executor; Grok is stronger on not shipping a fleet-looking Settings pane this week.

---

## Security vs UI vs gaps vs redundancy coverage

- **ChatGPT** is a **security/reliability/release** audit with a thin UI-behavior layer (confirmation, inert settings, menu-bar modes, a11y-unverified). Visual system, empty states, mockup parity, and list-chrome forks are mostly absent.
- **Grok** is a **product catalogue**: security seams + FEATURES.md/PLAN.md gaps + mockup-vs-Theme UI + redundancy IDs. It is weaker on process I/O, packaging, and the built binary.

---

## Code spot-checks where they disagree or one is unique

Checked in the current tree; no application code changed.

| Claim | Result |
|---|---|
| ChatGPT `F-02` sequential stdout-then-stderr drain | **Confirmed** `ContainerHost.swift:61–64` |
| Grok `SEC-01` `/usr/bin/env` in TerminalTab | **Confirmed** `TerminalTab.swift:379`; **second site** `MachineDetailView.swift:319` not in either report |
| ChatGPT `F-11` dock/both collapse; menu-bar window still presented | **Confirmed** `FlotillaApp.swift:57–59, 235–242` |
| ChatGPT `F-10` short version from `git describe` | **Confirmed** `make-app.sh:70–73` |
| ChatGPT `F-14` actool best-effort | **Confirmed** `make-app.sh:101–117` |
| Grok `GAP-04` no `SMAppService` | **Confirmed** only a `SettingRow` in `SettingsView.swift:267`; no `import ServiceManagement` |
| Grok pipe deadlock | **Miss** — Grok under-claimed `LocalHost` |

---

## Which audit is stronger where

**ChatGPT is stronger on:** the process boundary (`F-01`/`F-02` — especially pipe deadlock), release/packaging (`F-08`/`F-10`/`F-14` plus a real codesign/plist inspection), running the test suite, presentation-mode collapse (`F-11`), private-registry gap (`G-04`), streaming/cancellation as an execution problem (`G-05`), and a tighter “verify then patch” handoff (disposition table, preserve dirty files, escalate instead of guessing).

**Grok is stronger on:** FEATURES.md/PLAN.md contract gaps (install/kernel, inspect, prune, run flags, Jamf, launch-at-login), mockup-vs-app UI (colour-only state, empty/filtered-empty, card surfaces), the `ResourceListControls` fork as High not Low, PATH fallback in the terminal (`SEC-01`), probe/ErrorLog/home-mount/SwiftTerm, and a work queue the app owner can tick by ID.

**Grok should have caught (ChatGPT did):** sequential pipe deadlock and unbounded `CommandResult` buffers; invalid marketing version; actool silent blue accent; Menu bar/Dock/Both collapse; private registry auth as a named gap.

**ChatGPT should have caught (Grok did):** `/usr/bin/env` terminal fallback (and neither caught `MachineDetailView`); Jamf unmanaged default; launch-at-login inert `SMAppService`; volume/network inspect unwired; colour-only table dots; empty/filtered-empty defects; launch-at-login and Host-mode as High honesty if the Settings pane is treated as a ship surface.

---

## Practical read for the app owner

Treat them as complementary, not competing. Merge order if executing:

1. ChatGPT Wave 0 executor (`F-01`/`F-02`) + Grok `SEC-01` PATH fail-closed (both terminal sites).
2. Shared confirmation coordinator (`F-03` / `SEC-02`/`SEC-06`).
3. Grok honesty pass on Host/login/Sparkle/Jamf (`GAP-01`/`GAP-02`/`GAP-04`/`GAP-05` / `F-07`).
4. Redact `auditDescription` (`SEC-03` / `F-04`).
5. Then Grok Phase 1 UX (`GAP-03`/`GAP-06`/`UI-03`/`UI-04`) and shared list chrome (`RED-01`/`RED-02`).
6. Do not implement the listener. Gate on ChatGPT `F-06` + Grok `SEC-12`.
