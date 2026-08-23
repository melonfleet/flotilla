# Message to the app owner from Grok — Flotilla audit

**From:** Grok (Cursor Grok 4.6)  
**To:** the app owner (Claude Opus 5)  
**When:** Thursday, 20 August 2026, 3:51 PM (UTC+3) · `2026-08-20 15:51 +03:00`  
**Workspace:** `Flotilla/` (repository-relative)  
**App:** Flotilla (Phase 1 local MVP under `Flotilla/`)

This is an operational brief. Treat the audit as a work queue to **re-check**, then execute — not as gospel.

---

## Mission

1. **Verify first.** Open the cited files. Confirm each finding is still true in the current tree. Mark **confirmed**, **already-fixed**, or **false positive**. Do not change code for a finding you have not re-checked.
2. **Then implement** confirmed items in the order below. Prefer the smallest correct fix. Match existing Flotilla style.
3. **Do not commit** unless the human explicitly asks. Do not push. Do not invent branding. Do not change unrelated apps (Trellis, other melonfleet products).

Detail, quotes, and charts live in the HTML. This file is the instruction set.

---

## Source of truth

| Artifact | Path |
|---|---|
| HTML report (full catalogue, evidence, quotes, recs) | `Flotilla/docs/flotilla-audit-report.html` |
| Canvas (same 54 IDs, recommended sequence) | Local editor artifact; intentionally omitted from the repository record |
| Prior HTML (do not copy; independent pass) | `Flotilla/audit-report-2026-08-20.html` |

Open the HTML for any finding before you patch it. IDs are `SEC-*`, `GAP-*`, `UI-*`, `RED-*`.

---

## Executive snapshot

**Headline:** Flotilla is a real local container console with a settings UI that over-promises the fleet.

| Count | What |
|---|---|
| **54** | Findings (53 confirmed + 1 residual cluster) |
| **13** | High · confirmed current issues |
| **28** | Medium |
| **11** | Low |
| **1** | Info (`SEC-11`) |
| **1** | High residual (`SEC-12`) |

**No live critical remote issue.** Phase 2 remote transport is not implemented (`RemoteHost` is a protocol comment, not a type). There is no listener. Settings that *imply* a fleet host exists today are High for product honesty, not Critical.

**Core that is working (do not tear down):** argv via `Process.arguments` (not `/bin/sh`); allowlist default-deny with `WirePolicy` / `Exposure`; `MountPolicy` separate from grammar; support bundles fail closed; 307 FlotillaCore tests; `Theme.swift` quotes `design/brand/BRAND.md`. Pink is brand, never an error colour.

---

## Working rules

1. **Re-verify every finding in code before changing anything.** Open the cited file. Grep for consumers of the setting or type. If the audit says “never read,” prove it with a repo-wide search of `Sources/` (not docs). If a consumer exists now, mark **already-fixed** and skip.
2. **Do not write exploits, PoCs, or attack procedures.** Security work is impact + remediation only. Fail closed. No PATH-lookup demos, no payload samples.
3. **Prefer the smallest correct fix.** Match existing Flotilla naming, Theme tokens, and file layout. Do not invent a new design system. Do not change Trellis or other apps.
4. **Confirm vs residual vs already-fixed.** Residual means “not live today, but a launch gate.” Do not “fix” residual Phase 2 by opening a listener. Document or harden the local gate only.
5. **Suggested verification method:**
   - Open the evidence file from the HTML card.
   - Grep `Sources/` for the setting key, type name, or API (`SettingsKeys.*`, `SMAppService`, `Sparkle`, `NWListener`, `confirmDestructiveActions`, `confirmBulkActions`, `inspectVolume`, `ResourceListControls`).
   - For inert settings: find the `SettingRow` / registry declaration, then find **zero** production reads besides persist/load.
   - For UI: compare the cited view against the shared primitive (`ResourceListControls`, `ResourceCard`, `Theme.raisedSurface`).
   - For tests: count `@Test` in `Tests/FlotillaCoreTests` vs any app target in both Package manifests.
6. **Do not implement Phase 2 transport** as part of this queue. See Out of scope.

---

## Top five (work these first)

These are the audit’s ranked issues. Map to IDs below.

1. **Inert security-adjacent settings** — Host/Client/Both, listen port, Bonjour, Keychain label, launch-at-login, Sparkle. Also `containerBinaryPath` (persists with no runtime consumer). IDs: `GAP-01`, `GAP-02`, `GAP-04`, `GAP-05`.
2. **Terminal tab undoes PATH hardening** — `LocalHost` launches `container` by absolute path on purpose; `TerminalTab` falls back to `/usr/bin/env`. ID: `SEC-01`.
3. **Delete confirmation is not one policy** — context-menu Delete skips `confirmDestructiveActions`; `confirmBulkActions` is unread. IDs: `SEC-02`, `SEC-06`.
4. **Phase 1 UX still open** — no guided install/kernel remediation; volume/network inspect allowlisted but unwired; empty states. IDs: `GAP-03`, `GAP-06`, `UI-03`, plus `UI-04` / `UI-01`.
5. **List chrome is forked** — Containers/Machines skip `ResourceListControls`; colour-only state dots. IDs: `RED-01`, `UI-01`, then `RED-02` / `UI-02`.

Suggested sequence after verification: **honesty pass → local security seams → Phase 1 UX → shared list/detail chrome → docs + one app test target.** Gate any future listener on `SEC-12`. Do not start `SEC-12` implementation now.

---

## Work queue

Mark each ID as you go: `still true` / `already-fixed` / `false positive`. Then follow the instruction.

### Wave 1 — Honesty pass on Settings (this week)

Disable or annotate until a real consumer exists. Do **not** implement a listener to make Host mode “true.”

#### GAP-01 — High — Host mode settings are editable with no listener

- **Verify:** `Sources/Flotilla/SettingsView.swift` `networkPane` — Mode Client/Host/Both, listen port, Bonjour, identity Keychain label. `Sources/Flotilla/AppModel.swift` always constructs `LocalHost()`. Grep `Sources/` for `NWListener`, Bonjour, Keychain identity — audit found none.
- **Still true looks like:** Host segmented control is enabled; AppModel never reads mode to start a listener.
- **If confirmed:** Disable with “Not in this build” copy, or remove actionability. Do not ship an actionable Host control first. Same treatment for listen port, Bonjour, and identity label.
- **Also check:** `containerBinaryPath` — wire into `LocalHost` or stop showing it as an override (recommendation 1; no dedicated ID).
- **Depends on:** nothing. Blocks honest fleet UX. Do **not** depend on implementing Phase 2.

#### GAP-02 — High — Jamf / managed preference tier is never injected

- **Verify:** `Sources/FlotillaCore/Settings/SettingsStore.swift` defaults to `UnmanagedPreferences()`. `ManagedPreferences.swift` has no macOS reader in the app target. AppModel comment that managed source is wired once the app reads it for real.
- **Still true looks like:** `managed: any ManagedPreferencesSource = UnmanagedPreferences()` and no `/Library/Managed Preferences/` snapshot at launch.
- **If confirmed:** Snapshot `/Library/Managed Preferences/dev.melonfleet.Flotilla.plist` at launch into `StaticManagedPreferences`. Padlock UI cannot work until this exists. Until then, do not imply MDM lock in the UI.
- **Depends on:** honesty of locked rows; pairs with a settings-consumer test (`GAP-08`).

#### GAP-04 — High — Launch at login toggle has no SMAppService call

- **Verify:** `SettingsKeys.launchAtLogin` summary names `SMAppService`. Grep `Sources/` for `SMAppService` / `register(` — audit found only the registry string.
- **Still true looks like:** toggle persists; no `import ServiceManagement` / `SMAppService.mainApp.register()`.
- **If confirmed:** Call `SMAppService.mainApp.register()` / `unregister()` on toggle. Enable the control only when running from a bundle (`make-app.sh` already produces one).
- **Depends on:** Wave 1 honesty — if you cannot wire it this pass, disable the toggle with “Not in this build” rather than leaving a lying switch.

#### GAP-05 — Medium (in top five) — Updates pane has no Sparkle

- **Verify:** `SettingsView` `updatesPane` keys `automaticUpdateChecks`, `automaticallyDownloadUpdates`, `updateChannel`. `Package.swift` has no Sparkle. `AboutView` marks Sparkle as Phase 5.
- **If confirmed:** Hide until Phase 5, or show a static “Updates are not in this build” row. Do not add Sparkle in this queue unless the human asks.

---

### Wave 2 — Close the two local security seams

#### SEC-01 — Medium (in top five) — Terminal tab falls back to `/usr/bin/env`

- **Verify:** `Sources/Flotilla/TerminalTab.swift` — candidates `/usr/local/bin` and `/opt/homebrew/bin`, then `?? "/usr/bin/env"`. Compare `Sources/FlotillaCore/ContainerHost.swift` / LocalHost, which documents why PATH lookup was removed.
- **Still true looks like:** `?? "/usr/bin/env"` still present.
- **If confirmed:** Reuse `Preflight.locateBinary("container")`. Fail closed with a visible error. Do not exec `env`.
- **Depends on:** nothing. Do this immediately after (or with) Wave 1.

#### SEC-02 — Medium (in top five) — Container Delete bypasses `confirmDestructiveActions`

- **Verify:** `ContainersView.actions(for:)` calls `perform(.delete)` directly. `VolumesView.requestDelete` and `ImagesView` honour the setting.
- **Still true looks like:** context-menu `Button("Delete")` → `model.perform(.delete, on:)` with no confirm read.
- **If confirmed:** One `AppModel.requestDelete` coordinator for row trash, context menu, cards, bulk, and keyboard.
- **Depends on:** do `SEC-06` in the same coordinator. Do not split two confirmation policies.

#### SEC-06 — Low — `confirmBulkActions` is never read

- **Verify:** Declared in `SettingsRegistry.swift`, rendered in `SettingsView.swift`. No consumer in ContainersView bulk flows.
- **If confirmed:** Wire through the same coordinator as `SEC-02`.
- **Depends on:** `SEC-02`. Same PR if possible.

#### SEC-03 — Medium — `auditDescription` records `--env` and `--build-arg` verbatim

- **Verify:** `Sources/FlotillaCore/Allowlist.swift` `ValidatedCommand.auditDescription` joins argv. Used as audit string and in run/build previews.
- **If confirmed:** Structural redaction of sensitive flag values at the `ValidatedCommand` type, not at each logger.
- **Depends on:** do before any host-side audit log (`SEC-12` / `GAP-16`). Local previews also leak today.

#### SEC-04 — Medium — `timeoutHint` is not enforced at execution

- **Verify:** `CommandSpec.timeoutHint` documented unenforced. `LocalHost.run` is `process.run()` then `waitUntilExit()` with no terminate path.
- **If confirmed:** Enforce `timeoutHint` in `LocalHost` (terminate + structured error). Required **before any listener** (`SEC-12`). Safe and useful locally; do it in Wave 2 if capacity allows, else before Phase 2.
- **Depends on:** `SEC-12` gate. Do not open a `RemoteHost` to “use” timeouts.

#### SEC-09 — Medium — Local machine `home-mount=rw` is a filesystem grant

- **Verify:** Allowlist accepts `home-mount=ro|rw|none` on machine create/set. Wire marks machine mutations `localOnly`.
- **If confirmed:** Extra local confirmation for `rw`. Keep `Exposure.localOnly`. Do not relax Q14. Never expose machine delete/run/set-default or rw home-mount remotely.
- **Depends on:** confirmation coordinator (`SEC-02`) is a natural hook.

---

### Wave 3 — Finish the Phase 1 UX contract

#### GAP-03 — High — Guided install and kernel remediation are missing

- **Verify:** `Sources/FlotillaCore/Preflight.swift` header: guided install and kernel-install detection are **not this file’s job**. `FEATURES.md` §2.2 marks both `[core]`. `OnboardingView` is appearance-only.
- **If confirmed:** Download Apple pkg, hand to installer with user auth; `kernel set --recommended` button; non-trapping Continue anyway.
- **Depends on:** `GAP-18` (keep appearance step; add preflight card). Honest errors until this ships.

#### GAP-06 — High — Volume and network inspect are allowlisted but unwired

- **Verify:** Allowlist has `volume inspect` / `network inspect`. `ContainerCLI` has no `inspectVolume` / `inspectNetwork`. No detail views. `PLAN.md` still lists them unfinished. `NetworksView` notes inspect exists in the CLI; UI never calls it.
- **If confirmed:** Add CLI methods + fixtures; read-only detail panes mirroring container inspect.
- **Depends on:** allowlist specs already exist — do not add new grammar; wire the existing specs.

#### UI-03 — High — Images, volumes, networks empty states have no primary action

- **Verify:** `VolumesView` / `ImagesView` / `NetworksView` `ContentUnavailableView` without `actions:`. `ContainersView` has Run a Container…; `MachinesView` has Create.
- **If confirmed:** Add `actions:` Pull / Create matching the toolbar CTA.
- **Depends on:** none. Small. Do with `UI-04`.

#### UI-04 — High — Filtered-empty Images/Volumes/Networks render a blank table

- **Verify:** Empty checks use `model.images.isEmpty` (etc.), not `displayedImages.isEmpty`. Containers and Machines already handle filtered-empty with Clear filters.
- **If confirmed:** `loaded && displayed.isEmpty && !model.isEmpty` → “No matches” + Clear filters.
- **Depends on:** none. Same views as `UI-03`.

#### UI-01 — High — Table state is a colour-only dot

- **Verify:** `ContainersView` table: `TableColumn` with `Circle().fill(container.stateColor)` — “Dot only.” `design-ux.md` requires dot + SF Symbol + text. Cards show a caption; the table does not.
- **If confirmed:** Shared `StatusBadge`: 8pt dot + symbol + capitalized CLI state. Use in Containers and Machines tables.
- **Depends on:** list-chrome work (`RED-01`) if you are already in those files; otherwise a small shared view is enough.

#### GAP-08 — High — No UI or AppModel tests

- **Verify:** Both Package manifests expose only `FlotillaCoreTests`. 307 core tests, 0 app tests. `MachineTests.swift`: 3 decode tests.
- **If confirmed:** App test target: settings consumer map (every user-editable key is read by production code), confirmation coordinator, a few view snapshots. This is how inert toggles survive.
- **Depends on:** after Wave 1–2 so the consumer map tests the honesty pass. Recommendation 6.

#### GAP-09 — High — README and PHASE1.md describe a much smaller product

- **Verify:** README: “29 tests pass”, “read-only ContainerCLI operations”. `PHASE1.md`: ContainerCLI is read-only today. Actual: 307 tests and full mutations in `ContainerCLI.swift`.
- **If confirmed:** Rewrite status blocks to August 2026 reality. Keep `PHASE1.md` as history with a banner, or replace it.
- **Depends on:** none. Cheap. Do once Wave 1 is underway so docs stop lying about Host mode too.

---

### Wave 4 — Collapse list/detail chrome

Do this as one theme. UI inconsistency and redundancy are the same root.

#### RED-01 — High — Containers and Machines skip `ResourceListControls`

- **Verify:** `Sources/Flotilla/ResourceListControls.swift` exists so five files would not drift. Volumes/Images/Networks use it. `ContainersView` and `MachinesView` still inline `columnsButton` / `filterButton` / presentation picker (popover width 200 vs 210 already drifted).
- **If confirmed:** Extend `ResourceListControls` for typed state filters; delete the private copies.
- **Depends on:** `RED-03` (use `ResourcePresentation` everywhere) in the same change.

#### RED-02 — High — Embedded detail navigation is duplicated

- **Verify:** `ContainersView` (~71–265) and `MachinesView` (~619–710) both implement `DetailTarget`, back button, stepper over filtered list, glass action cluster, unavailable fallback (~120 lines each).
- **If confirmed:** Extract `EmbeddedDetailNavigator<Item, Detail>`.
- **Depends on:** after or with `RED-01` while those files are open.

#### UI-02 — High — Three incompatible card surfaces

- **Verify:** `ResourceCard`: `Theme.raisedSurface` + hairline, radius 9, padding 11. `ContainerCard`: `.quaternary.opacity(0.4)`, radius 10, no stroke. `MachinesView.machineCard`: `.quaternary.opacity(0.30)`, radius 9.
- **If confirmed:** `ThemedCard` modifier from `Theme.raisedSurface` + `Theme.hairline`; migrate all three. Do not invent new colours. Honeydew wash shows through quaternary cards; mockup cards are opaque.
- **Depends on:** `RED-06` (machine cards should use `ResourceCard`). `ContainerCard` may keep sparkline/metrics but must use the same surface.

---

### Residual high — SEC-12 (do not implement Phase 2)

#### SEC-12 — High — Residual — Phase 2 residual cluster — do not open a listener yet

- **Verify:** No `RemoteHost`, `NWListener`, Bonjour, or Keychain identity in `Sources/`. `DECISIONS.md` Q14: `timeoutHint` enforces nothing; `run --publish` and `volume --opt` / `network --plugin` need host-owned policy, not grammar.
- **Still true looks like:** transport types absent; Host mode UI still present (`GAP-01`).
- **If confirmed:** **Do not open a listener.** Record this as a launch gate. Phase 2 requires: timeouts + concurrency (`SEC-04`), publish/interface policy, default-deny opaque driver options, response redaction (`SEC-03`), mTLS identity lifecycle, managed prefs actually loaded (`GAP-02`).
- **Depends on:** Waves 1–2 locally. Implementation of the wire is **out of scope** for this handoff.

Related residuals (do not treat as live remote bugs):

- **SEC-05** (Medium, residual) — Mount-path TOCTOU. Keep roots narrow; require existing inputs (done for build). Document residual; do not claim path policy is race-free.
- **SEC-10** (Low, residual) — SwiftTerm parses PTY output. Pin version, watch advisories, keep exec on allowlisted argv. Not XSS; no web surface.

---

### Medium — compact queue (after highs / with related waves)

Work these when the matching file is already open, or after Waves 1–4. Verify with the same method.

| ID | Verify | If confirmed, do |
|---|---|---|
| **GAP-07** | `ContainersView` free text + Running/Stopped filter; no `is:` / `image:` / `host:` tokens; no ⌘K in `Sources/` | Token parser + segmented All/Running/Stopped that writes into the field. Palette is pure UI. Related: `UI-05`. |
| **GAP-10** | `DECISIONS.md` Q7 vs no system property list call in `ContainerCLI` | Read-only panel from `system property list --format json`. |
| **GAP-11** | `RunOptions` omit `--init`, `--rosetta`, `--read-only`, `--label`, `--shm-size`, `--tmpfs`, `--mount` | Extend `RunOptions` + `RunSheetView` per captured `container run --help`. |
| **GAP-12** | Images pull dismisses immediately; `BuildImageView` is a spinner | Collapsible log + cancel; one progress component. |
| **GAP-13** | `ContainerCLI` has `pruneVolumes` / `Networks` / `Containers`; only image prune-with-preview is in the UI | Per-section prune with the same preview-before-destroy pattern. Honour `SEC-02` confirmation. |
| **GAP-14** | `AppModel` events are a bounded array; no SwiftData in `Sources/` | SwiftData or a JSON log, **or** label the pane “this session”. |
| **GAP-15** | PLAN.md still lists Increase Contrast / Reduce Transparency / Reduce Motion / VoiceOver unfinished | Checklist pass against FEATURES.md §2.2; `StatusBadge` in tables (`UI-01`). |
| **GAP-16** | `Logger` only in SettingsPersistence + Notifier | OSLog categories on CLI failures and preflight. Never env or argv secrets (`SEC-03`). |
| **GAP-17** | `MachineTests.swift`: 3 tests vs 68 allowlist tests | Mirror container adversarial tests for machine create/set/delete at production `ExecPolicy`. |
| **GAP-18** | `OnboardingView.swift` appearance-only vs mockup preflight rail | Keep appearance step; add preflight card with Continue anyway (`GAP-03`). |
| **UI-05** | Filter is an icon popover; mockup is inline All/Running/Stopped writing `is:running` | Segmented control beside search, or tokens as chips. Do with `GAP-07`. |
| **UI-06** | `ContainerDetailView` / `MachineDetailView`: `.background.secondary` + `.separator` | Same `Theme.raisedSurface` + `Theme.hairline` as dashboard tiles. |
| **UI-07** | `Sparkline.swift` strokes `.secondary`; dashboard CPU uses `Theme.rind` | `Sparkline(color: Theme.online)` default; per-context override. |
| **UI-08** | `Wordmark.swift` hardcodes hex; `Theme.swift` claims BRAND.md | Move ink/rule/cream onto Theme; Wordmark reads tokens. Do not fetch Google Fonts. |
| **UI-09** | Containers bulk bar `.quaternary.opacity(0.3)` | `Theme.accentTint` background + `Theme.accentText` count. Pink is allowed here. |
| **UI-10** | Ports column is `Text(c.portSummary)`; detail has Open | First published port as a `Theme.accentText` button. |
| **RED-03** | `ResourcePresentation` plus two private `Presentation` enums | Use `ResourcePresentation` everywhere. Do with `RED-01`. |
| **RED-04** | Same alert / LoadState / ActivityStrip / confirmationDialog × 5 sections | `ResourceListShell(state:refresh:toolbar:content:)`. After `RED-01`. |
| **RED-05** | `InspectTab` vs `MachineInspectTab` duplicate toolbar/filter/Copy/Reload | `InspectPanel` parameterized by command string and loader. |
| **RED-06** | `MachinesView.machineCard` ~383–450 vs `ResourceCard.swift` | `ResourceCard` inside `ResourceCardGrid` for machines. With `UI-02`. |
| **RED-07** | `AppModel.swift` ~712–830 `refreshVolumes` / `Networks` / `Images` triplicated | Private `refreshResource` helper; keep public names. |

---

### Low / info — later (do not prioritize over highs)

| ID | If still true |
|---|---|
| **SEC-07** | Keep `flotilla-probe` out of the release app, or route `dumpRaw` through `ContainerCLI.execute`. |
| **SEC-08** | Optional pattern redaction on `ErrorLog.record()`, or document that diagnostics stay off on shared accounts. Support bundles already fail closed. |
| **SEC-11** (Info) | Intentional: no App Sandbox for v1 (`DECISIONS.md` Q9). Track Developer ID / hardened runtime / least-entitlements in Phase 5. Do not treat missing sandbox as an accidental hole. |
| **GAP-19** | `String(localized:)` when freezing copy. Not a Phase 1 blocker. |
| **GAP-20** | Persist column customization + sidebar width in the UI-state store. |
| **UI-11** | `Theme.statusDotSize = 8`; one stderr colour; sentence-case copy table. |
| **UI-12** | Replace `Flotilla/design/branding.md` palette table with a pointer to `design/brand/BRAND.md` + `Theme.swift`. Do not copy old mac.css greens into Theme. |
| **RED-08** | Delete dead `@State private var search` in `ImagesView` and `NetworksView` (reads use `ui.search`). Cheap; do when in those files. |
| **RED-09** | `TestSupport.swift` for copied `fixture()`; point inspect decode at `inspect-container.json`. |
| **RED-10** | Rename `WindowChromeControls.swift` to `WindowToolbarControls.swift` (no type of that name). |

---

## Do not do yet / out of scope

- **Do not implement Phase 2 transport.** No `RemoteHost`, `NWListener`, Bonjour advertising, pairing, or Keychain mTLS identity until `SEC-12` gates are designed and the human asks. Disable lying Host UI instead (`GAP-01`).
- **Do not write exploits, PoCs, fuzzers, or attack procedures.**
- **Do not add Sparkle** unless asked (`GAP-05` / Phase 5).
- **Do not sandbox the app** as a surprise fix (`SEC-11` is intentional for v1).
- **Do not invent branding** or change Trellis / other melonfleet apps. Canonical tokens: workspace `design/brand/BRAND.md` and Flotilla `Theme.swift`.
- **Do not claim MountPolicy is race-free** (`SEC-05` residual).
- **Do not commit** unless the human asks.
- **Do not change Flotilla application code as part of writing this brief** — that constraint applied to Grok. You (the app owner) *should* change application code after verification.

Audit out of scope (do not expand into): live hostile testing, dependency CVE scanning, notarization / Developer ID material (no Xcode project in-tree).

---

## File index (start here)

| Path | Why |
|---|---|
| `Sources/Flotilla/TerminalTab.swift` | `SEC-01` PATH fallback |
| `Sources/FlotillaCore/ContainerHost.swift` | Absolute-path launch; no timeout |
| `Sources/FlotillaCore/Allowlist.swift` | `auditDescription`; `timeoutHint`; exposure |
| `Sources/FlotillaCore/MountPolicy.swift` | `SEC-05` TOCTOU documented |
| `Sources/Flotilla/ContainersView.swift` | Delete without confirm; colour-only state; private Presentation |
| `Sources/Flotilla/SettingsView.swift` | Host mode, launch-at-login, updates UI |
| `Sources/FlotillaCore/Settings/SettingsStore.swift` | Default `UnmanagedPreferences()` |
| `Sources/Flotilla/AppModel.swift` | LocalHost-only CLI |
| `Sources/FlotillaCore/Preflight.swift` | Install/kernel explicitly out of scope |
| `Sources/Flotilla/ResourceListControls.swift` | Shared toolbar Containers/Machines skip |
| `Sources/Flotilla/ContainerCard.swift` | Quaternary card surface |
| `Sources/Flotilla/Theme.swift` | Canonical tokens |
| `README.md`, `PHASE1.md` | Stale “29 tests” / read-only CLI |
| `research/ALLOWLIST-AUDIT.md` | Publish/driver residual |

---

## Sign-off

the app owner — verify, then work Waves 1–4. Leave the wire unimplemented. If a finding is already gone, say so and move on.

— Grok (Cursor Grok 4.6)  
Thursday, 20 August 2026, 3:51 PM (UTC+3)  
`2026-08-20 15:51 +03:00`
