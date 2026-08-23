# Message to the app owner from Grok — Combined Flotilla audit

**From:** Grok (Cursor Grok 4.6)  
**To:** the app owner (Claude Opus 5)  
**When:** Thursday, 20 August 2026, 4:29 PM (UTC+3) · `2026-08-20 16:29 +03:00`  
**Workspace:** `Flotilla/` (repository-relative)  
**App:** Flotilla (Phase 1 local MVP under `Flotilla/`)

This brief **supersedes** the two separate the app owner handoffs as the work queue. It merges Grok’s Flotilla audit and ChatGPT’s Flotilla audit into one operational sequence. Keep the original briefs on disk; do not overwrite them. Open the HTML catalogues for evidence before you patch.

---

## Mission

1. **Verify first.** Open the cited files. Confirm each finding is still true in the current tree. Mark **confirmed**, **already-fixed**, **false positive**, or **residual**. Do not change code for a finding you have not re-checked.
2. **Then implement** confirmed items in the wave order below. Prefer the smallest correct fix. Match existing Flotilla style.
3. **Do not commit** unless the human explicitly asks. Do not push. Do not invent branding. Do not change unrelated apps (Trellis, other melonfleet products).
4. **Do not implement Phase 2 transport or a listener.** Disable lying Host UI; do not open a socket to make Host mode “true.”

This is an instruction set, not gospel. Detail, quotes, and charts live in the two HTML reports and the comparison.

---

## Source of truth

| Artifact | Path |
|---|---|
| This combined queue (use this) | `Flotilla/independent audits/message-to-andy-from-grok-combined-flotilla-audit-2026-08-20-1629.md` |
| Comparison (why the waves look like this) | `Flotilla/independent audits/AUDIT-COMPARISON-GROK-VS-CHATGPT.md` |
| Grok HTML catalogue (54 IDs) | `Flotilla/independent audits/flotilla-audit-report.html` |
| Grok the app owner handoff (superseded as queue) | `Flotilla/independent audits/message-to-andy-from-grok-flotilla-audit.md` |
| ChatGPT HTML catalogue (F-01–F-14, G-01–G-06) | `Flotilla/independent audits/audit-report-2026-08-20.html` |
| ChatGPT the app owner handoff (superseded as queue) | `Flotilla/independent audits/MESSAGE-TO-ANDY-FROM-CHATGPT-FLOTILLA-AUDIT-2026-08-20.md` |

IDs to keep: Grok `SEC-*` / `GAP-*` / `UI-*` / `RED-*` and ChatGPT `F-*` / `G-*`. When an issue appears in both, cite **both** IDs in your notes and patches so we can go back to either report.

Grok pass: ~15:51 +03. ChatGPT pass: ~14:43 +03 (about 68 minutes earlier). This file merges both.

---

## Executive snapshot

**Headline:** Flotilla is a real local container console. The executor still has unbounded pipes and unenforced timeouts. The settings UI over-promises the fleet.

**No live critical remote issue.** Phase 2 remote transport is not implemented (`RemoteHost` is a protocol comment, not a type). There is no listener. Settings that *imply* a fleet host exists today are High for product honesty, not Critical.

The two audits overlap on the spine and disagree on week-one order and some severities. **Do not run two different week-one plans.** Use the waves below. Where they disagree, the severity the app owner should treat for this queue is called out in the merged index and in each wave.

**Core that is working (do not tear down):** argv via `Process.arguments` (not `/bin/sh`); allowlist default-deny with `WirePolicy` / `Exposure`; `MountPolicy` separate from grammar; support bundles fail closed; 307 FlotillaCore tests; `Theme.swift` quotes `design/brand/BRAND.md`. Pink is brand, never an error colour. Keep `FlotillaCore` Foundation-only.

ChatGPT ran `swift test --disable-sandbox` (307 passed) and inspected a built bundle (`flags=adhoc · TeamIdentifier=not set`). Grok catalogued FEATURES.md/PLAN.md gaps, mockup-vs-app UI, and list-chrome forks. Each found live issues the other missed. Treat them as complementary.

---

## Working rules

1. **Re-verify every finding in code before changing anything.** Open the cited file. Grep for consumers of the setting or type. If the audit says “never read,” prove it with a repo-wide search of `Sources/` (not docs). If a consumer exists now, mark **already-fixed** and skip.
2. **Do not write exploits, PoCs, or attack procedures.** Security work is impact + remediation only. Fail closed. No PATH-lookup demos, no payload samples. A **regression test helper** that fills stdout and stderr pipes (ChatGPT `F-02`) is allowed; that is a test, not an exploit. Do not use a destructive container command for it.
3. **Prefer the smallest correct fix.** Match existing Flotilla naming, Theme tokens, and file layout. Do not invent a new design system. Do not change Trellis or other apps.
4. **Confirm vs residual vs already-fixed vs false positive.** Residual means “not live today, but a launch gate.” Do not “fix” residual Phase 2 by opening a listener. Document or harden the local gate only.
5. **Preserve pre-existing dirty work.** Capture `git status --short` before you edit. ChatGPT recorded modified `Sources/Flotilla/AppModel.swift` and `Sources/Flotilla/FlotillaApp.swift` at its handoff. Assume those contain human work. Understand the diff before overlapping. Never discard it. Keep your changes narrowly scoped and identify which changes were yours.
6. **Suggested verification method:**
   - Open the evidence file from the matching HTML card (Grok and/or ChatGPT).
   - Grep `Sources/` for the setting key, type name, or API (`SettingsKeys.*`, `SMAppService`, `Sparkle`, `NWListener`, `confirmDestructiveActions`, `confirmBulkActions`, `inspectVolume`, `ResourceListControls`, `readDataToEndOfFile`, `timeoutHint`).
   - For inert settings: find the `SettingRow` / registry declaration, then find **zero** production reads besides persist/load.
   - For UI: compare the cited view against the shared primitive (`ResourceListControls`, `ResourceCard`, `Theme.raisedSurface`).
   - For tests: count `@Test` in `Tests/FlotillaCoreTests` vs any app target in both Package manifests. Re-run `swift test --disable-sandbox` before editing and after each wave that touches `FlotillaCore`.
7. **Do not implement Phase 2 transport** as part of this queue. See Residual gate and Out of scope.
8. **Escalate instead of guessing** when a change would alter a documented security invariant, allowlist policy, bind-address/plugin policy, signing identities, user-data migration, telemetry, or pre-existing dirty files. Document the decision, options, and your recommendation.

Do not weaken default-deny, mount validation, wire exposure, or exec restrictions to make a test pass. Do not introduce arbitrary shell execution.

---

## How to treat disagreements (this queue)

| Topic | Grok said | ChatGPT said | **Treat as** |
|---|---|---|---|
| Pipe deadlock / unbounded stdout+stderr | Missed | `F-02` High | **High** — Wave 0 first |
| Timeout not enforced | `SEC-04` Medium locally | `F-01` High | **High for Wave 0** (hung local child + Phase 2 gate) |
| Host-mode lying UI | `GAP-01` High | `F-07` Medium | **High** — Wave 2 honesty |
| Delete confirmation split | `SEC-02` Medium / `SEC-06` Low | `F-03` High | **High** — one coordinator, Wave 1 |
| Docs lag (README “29 tests”) | `GAP-09` High | `F-12` Low | **Medium** — do cheaply in Wave 3; do not skip; do not block Wave 0 |
| List chrome duplication | `RED-01`/`RED-02` High | `F-13` Low | **High** — Wave 4 |
| `auditDescription` secrets | `SEC-03` live Medium (previews leak today) | `F-04` Medium “future audit records” | **Live Medium** — Wave 1; structural redaction now |

---

## Combined work order

Mark each ID as you go: `still true` / `already-fixed` / `false positive` / `residual`. Then follow the instruction.

---

### Wave 0 — Executor (ChatGPT-first; Grok missed pipes)

Harden `LocalHost` before anything that looks like a fleet UI. A later listener must not inherit an unbounded runner. Do **not** open a listener in this wave.

#### F-02 — High — Sequential stdout-then-stderr drain / unbounded buffers

ChatGPT-only as a named finding. Grok cited `ContainerHost.swift` for timeouts and absolute-path launch and never named the drain order. Comparison re-checked: still true at `ContainerHost.swift:61–64` (`run` → `readDataToEndOfFile()` stdout → stderr → `waitUntilExit()`).

- **Verify:** `Sources/FlotillaCore/ContainerHost.swift` `LocalHost.run`. Confirm stdout is drained to EOF **then** stderr **then** `waitUntilExit()`. Confirm both streams accumulate without a byte ceiling.
- **Still true looks like:** sequential `readDataToEndOfFile()` on stdout before stderr; `CommandResult` holds full buffers.
- **If confirmed:** Drain stdout and stderr concurrently while the process runs (readability handlers or async bytes). Apply explicit per-stream and aggregate byte limits. Define truncation behavior and surface it on `CommandResult`. Do not retain unlimited output in memory. Timeout and cancellation (`F-01` / `G-05`) must still work while either stream is busy. Add tests for large stdout, large stderr, simultaneous output, truncation, timeout, and cancellation. Use a controlled test helper that fills both pipes; do not use a destructive container command.
- **Depends on:** nothing. Do this first.
- **IDs:** `F-02` (no Grok twin).

#### F-01 / SEC-04 — High for Wave 0 — `timeoutHint` is calculated then discarded

ChatGPT High; Grok Medium locally and High only as a Phase 2 gate. For this queue: **High**, now. A hung `container` child occupies a detached task; cancelling a polling task does not terminate the child.

- **Verify:** `Sources/FlotillaCore/Allowlist.swift` `CommandSpec.timeoutHint` / `ValidatedCommand`. `ContainerCLI.swift` ~183–198. `ContainerHost.swift` `LocalHost.run`: `process.run()` then `waitUntilExit()` with no terminate path.
- **Still true looks like:** timeout metadata exists on the spec and is not applied at the process boundary.
- **If confirmed:** Carry a typed execution policy/envelope across Allowlist → ContainerCLI → LocalHost. Enforce a hard monotonic deadline at the process boundary, not only in UI state. Terminate then kill; reap timed-out or cancelled process trees. Bound concurrent child processes and define queue behavior. Return typed timeout/cancellation/limit errors suitable for honest UI. Add deterministic tests for completion, timeout, cancellation, and concurrency saturation.
- **Depends on:** do with `F-02` in the same runner change if possible. Required **before any listener** (`SEC-12` / `F-06`). Do not open a `RemoteHost` to “use” timeouts.
- **IDs:** `F-01` = `SEC-04`.

#### SEC-01 — Medium (Wave 0) — `/usr/bin/env` fallback; two sites

Grok named `TerminalTab.swift` only. Comparison found a second copy in `MachineDetailView.swift` (~316–319) that **neither** original report listed as a pair. Fail both closed.

- **Verify:** `Sources/Flotilla/TerminalTab.swift` — candidates `/usr/local/bin` and `/opt/homebrew/bin`, then `?? "/usr/bin/env"`. `Sources/Flotilla/MachineDetailView.swift` ~319. Compare `LocalHost` in `ContainerHost.swift`, which documents why PATH lookup was removed. Grep `Sources/` for `"/usr/bin/env"` and other PATH fallbacks.
- **Still true looks like:** `?? "/usr/bin/env"` still present in either file.
- **If confirmed:** Reuse `Preflight.locateBinary("container")` at **both** sites. Fail closed with a visible error. Do not exec `env`. Do not demonstrate a PATH-prepended binary.
- **Depends on:** nothing. Do in Wave 0 with the executor work; it is the same class of process-boundary honesty.
- **IDs:** `SEC-01` (ChatGPT missed). Second site has no dedicated ID — treat it as part of `SEC-01`.

#### G-05 — Streaming / cancellation as execution, not only progress UI

ChatGPT product gap. Grok’s `GAP-12` is pull/build **progress UI**, not runner streaming. Do not confuse them.

- **Verify:** Follow-mode is repeated bounded fetch, not a stream. Cancellation of a Swift `Task` does not currently own the child (`F-01`).
- **If confirmed (Wave 0 slice):** While fixing `F-01`/`F-02`, make cancellation and output budgets real at `LocalHost`. Durable streaming UI can wait. Do **not** treat a prettier pull spinner as G-05.
- **Depends on:** `F-01` / `F-02`. Full streaming API is later; the process-boundary contract is this week.
- **IDs:** `G-05` (related: `F-01`, `F-02`; not `GAP-12`).

---

### Wave 1 — Confirmation + secrets

One delete policy. Redact argv **now** (previews leak today). Extra confirm for `home-mount=rw`.

#### F-03 / SEC-02 / SEC-06 — High — Shared delete coordinator

ChatGPT High; Grok Medium + Low. **Treat as High.** One coordinator, not two confirmation policies.

- **Verify:** Trace every destructive entry point: row trash, context menus, detail headers, cards, bulk, keyboard; containers, machines, images, volumes, networks. `ContainersView.actions(for:)` / context-menu Delete → `perform(.delete)` with no confirm read. `VolumesView.requestDelete` and `ImagesView` honour `confirmDestructiveActions`. `confirmBulkActions` is declared in `SettingsRegistry.swift` / rendered in `SettingsView.swift` and unread in bulk flows. Machines also ignore the destructive preference (ChatGPT `F-03` evidence: `MachinesView.swift` ~140–155).
- **Still true looks like:** container context-menu Delete has no confirm; `confirmBulkActions` has no production read besides persist/load.
- **If confirmed:** One `AppModel.requestDelete` (or equivalent) coordinator for all entry points. Apply the same confirmation semantics regardless of resource and entry point. Make **both** settings effective, or remove a setting if the product decision is that confirmation is mandatory — escalate that choice rather than guessing. Present target name, action, consequence, and bulk count. Prevent double submission while an operation is in progress. Add unit tests for the policy matrix and representative UI tests when an app target exists (`GAP-08` / `F-09`).
- **Depends on:** do `SEC-02` and `SEC-06` in the same change. Do not split two confirmation policies.
- **IDs:** `F-03` = `SEC-02` + `SEC-06`.

#### SEC-03 / F-04 — Live Medium — Redact `auditDescription`

Grok: live (run/build **previews** join argv today). ChatGPT title: “Future audit records.” Same structural fix. **Treat as live Medium**, not “wait for host-side audit logs.”

- **Verify:** `Sources/FlotillaCore/Allowlist.swift` `ValidatedCommand.auditDescription` joins argv. Used as audit string **and** in run/build previews. Check `--env`, `--env=`, `--build-arg`, and any other secret-bearing flags. Trace logging and support-bundle consumers.
- **If confirmed:** Structural redaction of sensitive flag values at the `ValidatedCommand` type, not at each logger. Prefer an allowlist of safe-to-log fields over a growing secret denylist. Never rely only on downstream free-text redaction. Test separated and `--flag=value` forms, mixed casing where applicable, malformed input, and multiple secrets. Verify support bundles cannot restore or bypass the redaction.
- **Depends on:** do before any host-side audit log (`SEC-12` / `GAP-16`). Local previews also leak today.
- **IDs:** `SEC-03` = `F-04`.

#### SEC-09 — Medium — Extra confirm for `home-mount=rw`

Grok-only as a named finding.

- **Verify:** Allowlist accepts `home-mount=ro|rw|none` on machine create/set. Wire marks machine mutations `localOnly`.
- **If confirmed:** Extra local confirmation for `rw`. Keep `Exposure.localOnly`. Do not relax Q14. Never expose machine delete/run/set-default or rw home-mount remotely.
- **Depends on:** confirmation coordinator (`F-03` / `SEC-02`) is a natural hook. Do in Wave 1 while that coordinator is open.
- **IDs:** `SEC-09` (no ChatGPT twin).

---

### Wave 2 — Honesty pass on Settings

Disable or annotate until a real consumer exists. Do **not** implement a listener to make Host mode “true.” Host-mode lying UI is **High** (Grok), even though ChatGPT scored the inert-settings cluster Medium (`F-07`).

#### GAP-01 / F-07 — High — Host/Client/Both, listen port, Bonjour, Keychain label, `containerBinaryPath`

- **Verify:** `Sources/Flotilla/SettingsView.swift` `networkPane` — Mode Client/Host/Both, listen port, Bonjour, identity Keychain label. `Sources/Flotilla/AppModel.swift` always constructs `LocalHost()`. Grep `Sources/` for `NWListener`, Bonjour advertising, Keychain identity — both audits found none. `containerBinaryPath` persists; AppModel uses preflight lookup, not the setting.
- **Still true looks like:** Host segmented control is enabled; AppModel never reads mode to start a listener; Binary path field is ignored at runtime.
- **If confirmed:** Disable with “Not in this build” copy, or remove actionability. Same treatment for listen port, Bonjour, and identity label. Wire `containerBinaryPath` into a validated resolver **or** stop showing it as an override. Add a registry test that every user-editable setting has a production consumer (pairs with `GAP-08` / `F-09`).
- **Depends on:** nothing. Blocks honest fleet UX. Do **not** depend on implementing Phase 2.
- **IDs:** `GAP-01` ⊂ `F-07` (ChatGPT also folds Sparkle + binary path into `F-07`).

#### GAP-04 — High — Launch at login: wire `SMAppService` or disable

ChatGPT `F-07` list does **not** name this control. Grok does. Comparison re-checked: only a `SettingRow` in `SettingsView.swift`; no `import ServiceManagement`.

- **Verify:** `SettingsKeys.launchAtLogin` summary names `SMAppService`. Grep `Sources/` for `SMAppService` / `register(` — should be registry string only.
- **Still true looks like:** toggle persists; no `SMAppService.mainApp.register()`.
- **If confirmed:** Call `SMAppService.mainApp.register()` / `unregister()` on toggle. Enable the control only when running from a bundle (`make-app.sh` already produces one). If you cannot wire it this pass, disable the toggle with “Not in this build” rather than leaving a lying switch.
- **Depends on:** Wave 2 honesty.
- **IDs:** `GAP-04` (folded into spirit of `F-07`, not named there).

#### GAP-05 — Medium — Sparkle: hide until Phase 5

- **Verify:** `SettingsView` `updatesPane` keys `automaticUpdateChecks`, `automaticallyDownloadUpdates`, `updateChannel`. `Package.swift` has no Sparkle. `AboutView` already marks Sparkle as Phase 5.
- **If confirmed:** Hide until Phase 5, or show a static “Updates are not in this build” row. Do **not** add Sparkle in this queue unless the human asks (`G-02` / `F-08`).
- **Depends on:** honesty of the Updates pane. Implementation of Sparkle is out of scope.
- **IDs:** `GAP-05` ⊂ `F-07`; release integrity is `F-08` / `G-02` in Wave 5.

#### GAP-02 — High — Jamf: do not imply MDM lock until `StaticManagedPreferences`

Grok-only as a named High. ChatGPT did not catalogue it.

- **Verify:** `Sources/FlotillaCore/Settings/SettingsStore.swift` defaults to `UnmanagedPreferences()`. `ManagedPreferences.swift` has no macOS reader in the app target. AppModel comment that managed source is wired once the app reads it for real.
- **Still true looks like:** `managed: any ManagedPreferencesSource = UnmanagedPreferences()` and no `/Library/Managed Preferences/` snapshot at launch.
- **If confirmed:** Snapshot `/Library/Managed Preferences/dev.melonfleet.Flotilla.plist` at launch into `StaticManagedPreferences` **or**, until that exists, do not imply MDM lock in the UI (no padlock theatre). Padlock UI cannot work until the reader exists.
- **Depends on:** honesty of locked rows; pairs with a settings-consumer test (`GAP-08`).
- **IDs:** `GAP-02` (no ChatGPT twin). Required before any listener (`SEC-12`).

#### F-11 — Low — Menu bar / Dock / Both collapse (two behaviors, three labels)

ChatGPT-only. Comparison re-checked: `FlotillaApp.swift` ~53–82, 235–242; `dock` and `both` both map to `.regular`; menu-bar-only still opens a window via `.defaultLaunchBehavior(.presented)`.

- **Verify:** Three labels, two effective `NSApplication.ActivationPolicy` behaviors; menu-bar-only still presents a window at launch.
- **If confirmed:** Until the scene can be truly hidden, offer “Dock + menu bar” and “Menu bar” only, with a note that the window opens at launch. Restore three choices only when each can be tested as a distinct state. Test launch, activation, window restoration, and preference changes.
- **Depends on:** Wave 2 honesty — same class of lying control. Preserve pre-existing edits in `FlotillaApp.swift`.
- **IDs:** `F-11` (no Grok twin).

---

### Wave 3 — Phase 1 UX contract (Grok catalogue)

Do these after the executor, confirmation, and honesty pass. Docs are **Medium** in this queue (cheap; do not skip; not blocking Wave 0).

#### GAP-03 / GAP-18 — High / Medium — Guided install and kernel remediation

- **Verify:** `Sources/FlotillaCore/Preflight.swift` header: guided install and kernel-install detection are **not this file’s job**. `FEATURES.md` §2.2 marks both `[core]`. `OnboardingView` is appearance-only.
- **If confirmed:** Download Apple pkg, hand to installer with user auth; `kernel set --recommended` button; non-trapping Continue anyway. Keep the appearance step; add a preflight card (`GAP-18`).
- **Depends on:** honest errors until this ships.
- **IDs:** `GAP-03`, `GAP-18`.

#### GAP-06 — High — Volume and network inspect are allowlisted but unwired

- **Verify:** Allowlist has `volume inspect` / `network inspect`. `ContainerCLI` has no `inspectVolume` / `inspectNetwork`. No detail views. `PLAN.md` still lists them unfinished.
- **If confirmed:** Add CLI methods + fixtures; read-only detail panes mirroring container inspect. Do not add new grammar; wire the existing specs.
- **IDs:** `GAP-06`.

#### UI-03 — High — Images, volumes, networks empty states have no primary action

- **Verify:** `VolumesView` / `ImagesView` / `NetworksView` `ContentUnavailableView` without `actions:`. `ContainersView` has Run a Container…; `MachinesView` has Create.
- **If confirmed:** Add `actions:` Pull / Create matching the toolbar CTA. Do with `UI-04`.
- **IDs:** `UI-03`.

#### UI-04 — High — Filtered-empty Images/Volumes/Networks render a blank table

- **Verify:** Empty checks use `model.images.isEmpty` (etc.), not `displayedImages.isEmpty`. Containers and Machines already handle filtered-empty with Clear filters.
- **If confirmed:** `loaded && displayed.isEmpty && !model.isEmpty` → “No matches” + Clear filters.
- **IDs:** `UI-04`.

#### UI-01 — High — Table state is a colour-only dot

- **Verify:** `ContainersView` table: `TableColumn` with `Circle().fill(container.stateColor)` — “Dot only.” `design-ux.md` requires dot + SF Symbol + text. Cards show a caption; the table does not.
- **If confirmed:** Shared `StatusBadge`: 8pt dot + symbol + capitalized CLI state. Use in Containers and Machines tables. Can share a file with `RED-01` if you are already there; otherwise a small shared view is enough.
- **IDs:** `UI-01`.

#### GAP-09 / F-12 — Medium (this queue) — Docs lag

Grok High; ChatGPT Low. **Treat as Medium:** do cheaply in Wave 3 so onboarding stops lying; do not skip; do not block Wave 0.

- **Verify:** README: “29 tests pass”, “read-only ContainerCLI operations”; claims that mutations/volumes/networks/logs/preflight/support bundles are unfinished and that app-bundle metadata is absent. `PHASE1.md`: ContainerCLI is read-only today. Actual: 307 tests and full mutations in `ContainerCLI.swift`; `make-app.sh` produces a bundle. Stale comments after embedded-navigation reversal.
- **If confirmed:** Rewrite status blocks to August 2026 reality. Keep `PHASE1.md` as history with a banner, or replace it. Do once Wave 2 is underway so docs stop lying about Host mode too. Update documentation only after verifying current behavior.
- **IDs:** `GAP-09` = `F-12`.

#### GAP-08 / F-09 — App tests

Grok High; ChatGPT Medium. Do **after** Waves 0–2 so the consumer map tests the honesty pass and the confirmation coordinator. ChatGPT: do not broad-refactor list chrome (`Wave 4`) until this coverage exists.

- **Verify:** Both Package manifests expose only `FlotillaCoreTests`. 307 core tests, 0 app tests. `MachineTests.swift`: 3 decode tests.
- **If confirmed:** Smallest maintainable app test target: settings consumer map (every user-editable key is read by production code), confirmation coordinator policy matrix, a few navigation/error states. If an Xcode project/runner is required, keep Swift Package tests working and document both commands.
- **IDs:** `GAP-08` = `F-09`.

#### Compact queue (remaining Grok gaps) — verify with the same method

Work these when the matching file is already open, or after the High Wave 3 items. `UI-05` may ride with `GAP-07`.

| ID | Verify | If confirmed, do |
|---|---|---|
| **GAP-07** | `ContainersView` free text + Running/Stopped filter; no `is:` / `image:` / `host:` tokens; no ⌘K in `Sources/` | Token parser + segmented All/Running/Stopped that writes into the field. Palette is pure UI. Related: `UI-05`. ChatGPT `G-06` covers palette/i18n at a coarser grain — do not block Wave 0 on localization. |
| **GAP-10** | `DECISIONS.md` Q7 vs no system property list call in `ContainerCLI` | Read-only panel from `system property list --format json`. |
| **GAP-11** | `RunOptions` omit `--init`, `--rosetta`, `--read-only`, `--label`, `--shm-size`, `--tmpfs`, `--mount` | Extend `RunOptions` + `RunSheetView` per captured `container run --help`. |
| **GAP-12** | Images pull dismisses immediately; `BuildImageView` is a spinner | Collapsible log + cancel; one progress component. This is **progress UI**, not `G-05` streaming. |
| **GAP-13** | `ContainerCLI` has `pruneVolumes` / `Networks` / `Containers`; only image prune-with-preview is in the UI | Per-section prune with the same preview-before-destroy pattern. Honour the Wave 1 confirmation coordinator. |
| **GAP-15** | PLAN.md still lists Increase Contrast / Reduce Transparency / Reduce Motion / VoiceOver unfinished | Checklist pass against FEATURES.md §2.2; `StatusBadge` in tables (`UI-01`). |
| **GAP-16** | `Logger` only in SettingsPersistence + Notifier | OSLog categories on CLI failures and preflight. Never env or argv secrets (`SEC-03` / `F-04`). |
| **GAP-17** | `MachineTests.swift`: 3 tests vs 68 allowlist tests | Mirror container adversarial tests for machine create/set/delete at production `ExecPolicy`. |

**Also named, not blocking Wave 0:** `GAP-14` / `G-03` — activity/metrics are in-memory. SwiftData or a JSON log, **or** label the pane “this session.” Do after the executor is honest (`G-03`: after execution hardening).

---

### Wave 4 — Shared list/detail chrome

**Treat as High** per Grok (`RED-01` / `RED-02` / `UI-02`), not Low as ChatGPT `F-13`. ChatGPT’s instruction still applies: refactor **after** regression coverage (`GAP-08` / `F-09`) exists. Prefer extracting policy and reusable components; do not split files solely to improve line counts.

#### RED-01 / F-13 — High — Containers and Machines skip `ResourceListControls`

- **Verify:** `Sources/Flotilla/ResourceListControls.swift` exists so five files would not drift. Volumes/Images/Networks use it. `ContainersView` and `MachinesView` still inline `columnsButton` / `filterButton` / presentation picker (popover width 200 vs 210 already drifted).
- **If confirmed:** Extend `ResourceListControls` for typed state filters; delete the private copies. Use `ResourcePresentation` everywhere (`RED-03`) in the same change.
- **IDs:** `RED-01` ⊂ `F-13`.

#### RED-02 / F-13 — High — Embedded detail navigation is duplicated

- **Verify:** `ContainersView` and `MachinesView` both implement `DetailTarget`, back button, stepper over filtered list, glass action cluster, unavailable fallback (~120 lines each).
- **If confirmed:** Extract `EmbeddedDetailNavigator<Item, Detail>`.
- **Depends on:** after or with `RED-01` while those files are open.
- **IDs:** `RED-02` ⊂ `F-13`.

#### UI-02 — High — Three incompatible card surfaces

- **Verify:** `ResourceCard`: `Theme.raisedSurface` + hairline, radius 9, padding 11. `ContainerCard`: `.quaternary.opacity(0.4)`, radius 10, no stroke. `MachinesView.machineCard`: `.quaternary.opacity(0.30)`, radius 9.
- **If confirmed:** `ThemedCard` modifier from `Theme.raisedSurface` + `Theme.hairline`; migrate all three. Do not invent new colours. Honeydew wash shows through quaternary cards; mockup cards are opaque. `RED-06`: machine cards should use `ResourceCard`. `ContainerCard` may keep sparkline/metrics but must use the same surface.
- **IDs:** `UI-02` (ChatGPT did not score visual-system cards).

#### Then RED-03–10 and UI-05–12

| ID | If still true |
|---|---|
| **RED-03** | Use `ResourcePresentation` everywhere. Do with `RED-01`. |
| **RED-04** | `ResourceListShell(state:refresh:toolbar:content:)`. After `RED-01`. |
| **RED-05** | `InspectPanel` parameterized by command string and loader. |
| **RED-06** | `ResourceCard` inside `ResourceCardGrid` for machines. With `UI-02`. |
| **RED-07** | Private `refreshResource` helper in `AppModel`; keep public names. Preserve pre-existing `AppModel.swift` edits. |
| **RED-08** | Delete dead `@State private var search` in `ImagesView` and `NetworksView` (reads use `ui.search`). Cheap; do when in those files. |
| **RED-09** | `TestSupport.swift` for copied `fixture()`; point inspect decode at `inspect-container.json`. |
| **RED-10** | Rename `WindowChromeControls.swift` to `WindowToolbarControls.swift` (no type of that name). |
| **UI-05** | Segmented control beside search, or tokens as chips. Prefer with `GAP-07` in Wave 3. |
| **UI-06** | Detail/dashboard panels: `Theme.raisedSurface` + `Theme.hairline`, not `.background.secondary`. |
| **UI-07** | `Sparkline(color: Theme.online)` default; per-context override. Dashboard CPU already uses `Theme.rind`. |
| **UI-08** | Move Wordmark ink/rule/cream onto Theme; Wordmark reads tokens. Do not fetch Google Fonts. |
| **UI-09** | Bulk bar: `Theme.accentTint` background + `Theme.accentText` count. Pink is allowed here. |
| **UI-10** | First published port as a `Theme.accentText` button. |
| **UI-11** | `Theme.statusDotSize = 8`; one stderr colour; sentence-case copy table. |
| **UI-12** | Replace `Flotilla/design/branding.md` palette table with a pointer to `design/brand/BRAND.md` + `Theme.swift`. Do not copy old mac.css greens into Theme. |

---

### Wave 5 — Packaging / release (ChatGPT-only as findings)

Do not surprise-sandbox. Document distribution as Phase 5. Do not add Sparkle until the feed exists.

#### F-10 — Medium — Untagged `git describe` → invalid `CFBundleShortVersionString`

- **Verify:** `Scripts/make-app.sh` ~70–73, 124–132. ChatGPT inspected a built plist: `CFBundleShortVersionString = d8ba884`.
- **If confirmed:** Separate human-facing semantic version from build identifier/commit metadata. Require a SemVer tag for release builds; use `0.0.0` (or similar dotted placeholder) for untagged development marketing versions; put commit identity in `CFBundleVersion` or a custom key. Fail the release script if either value violates its declared format.
- **IDs:** `F-10` (Grok did not inspect the built plist).

#### F-14 — Low — `actool` best-effort → system blue accent

- **Verify:** `Scripts/make-app.sh` ~94–117, 138–140. If `actool` fails, packaging continues without `NSAccentColorName`; AppKit accent can silently revert to system blue while SwiftUI tint stays watermelon.
- **If confirmed:** Fail **release** builds when the asset catalog cannot compile; retain a documented development fallback if needed. Verify the built asset and plist key as a packaging assertion.
- **IDs:** `F-14`.

#### F-08 / SEC-11 / G-02 — Medium finding, Info sandbox — Ad-hoc sign / no Team ID / hardened runtime

ChatGPT inspected a built bundle: `flags=adhoc · TeamIdentifier=not set`. Grok `SEC-11` is Info: no App Sandbox is **intentional** for v1 (`DECISIONS.md` Q9).

- **If confirmed:** Create a reproducible release checklist that distinguishes development builds from release artifacts. Track Developer ID, hardened runtime, notarization/stapling, and a verified update channel as **Phase 5**. Do **not** add Sparkle UI until the dependency, feed signing, update verification, and rollback exist (`GAP-05`). Credentials stay outside the repository. **Do not sandbox the app as a surprise fix.**
- **IDs:** `F-08` = release integrity; `SEC-11` = intentional no-sandbox; `G-02` = signed/updating distribution gap.

#### G-04 — Named gap — Private registry login / Keychain lifecycle

- **Not this week unless the human asks.** Pull and build exist; login/logout and credential lifecycle do not. Passwords must avoid argv, live in Keychain, and reach the CLI through a reviewed input mechanism. Produce a short design note if asked; do not implement a password-on-argv path.
- **IDs:** `G-04` (Grok never listed this gap).

---

### Residual gate — do not implement

#### SEC-12 / F-06 / G-01 — High residual / Medium Phase 2 blocker — No listener

- **Verify:** No `RemoteHost`, `NWListener`, Bonjour advertising, or Keychain mTLS identity in `Sources/`. `DECISIONS.md` Q14: `timeoutHint` enforces nothing until Wave 0; `run --publish` and `volume --opt` / `network --plugin` need host-owned policy, not grammar.
- **Still true looks like:** transport types absent; Host mode UI still present (`GAP-01` / `F-07`).
- **If confirmed:** **Do not open a listener.** No `RemoteHost`, no Bonjour advertising, no mTLS identity until **all** of these exist: timeouts + concurrency (`F-01` / `SEC-04`), publish/interface policy, opaque driver default-deny, redaction (`SEC-03` / `F-04`), managed prefs actually loaded (`GAP-02`). Record as a launch gate. Implementation of the wire is **out of scope** for this handoff.
- **IDs:** `SEC-12` ⊃ `F-06` + `G-01`. ChatGPT scored `F-06` Medium (not live); Grok scored the cluster High residual. **Do not implement either way.**

#### SEC-05 / F-05 — Medium residual — Mount-path TOCTOU

- Keep roots narrow; require existing inputs (done for build). Document residual. Do **not** claim path policy is race-free. Repeating `realpath` immediately before launch does not fully close it. Defense-in-depth where practical; preserve default-deny.

#### SEC-10 — Low residual — SwiftTerm parses PTY output

- Pin the version, watch advisories, keep exec on allowlisted argv. Not XSS; no web surface. ChatGPT did not mention this.

---

## Merged finding index

Every ID from both audits. “Queue sev” is what the app owner should treat this item as **in this work order**. When they disagree, both originals are listed.

### Security / executor / confirmation

| Grok | ChatGPT | Same issue? | Grok sev | ChatGPT sev | **Queue sev** | Wave |
|---|---|---|---|---|---|---|
| — | **F-02** | ChatGPT-only (Grok miss) | — | High | **High** | 0 |
| **SEC-04** | **F-01** | Yes — `timeoutHint` discarded | Medium | High | **High** | 0 |
| **SEC-01** | — | Grok-only; **also** `MachineDetailView.swift` | Medium | — | Medium | 0 |
| — | **G-05** | Execution streaming/cancel (not `GAP-12`) | — | Gap | Execution slice | 0 |
| **SEC-02** + **SEC-06** | **F-03** | Yes — delete policy split | Medium + Low | High | **High** | 1 |
| **SEC-03** | **F-04** | Yes — `auditDescription` argv | Medium (live) | Medium (“future”) | **Live Medium** | 1 |
| **SEC-09** | — | Grok-only — `home-mount=rw` | Medium | — | Medium | 1 |
| **SEC-07** | — | `flotilla-probe` `dumpRaw` | Low | — | Low | Later |
| **SEC-08** | — | Live `ErrorLog` unredacted | Low | — | Low | Later |
| **SEC-11** | **F-08** (related) | No sandbox vs ad-hoc **distribution** | Info (intentional) | Medium | Phase 5; do not surprise-sandbox | 5 / residual |
| **SEC-05** | **F-05** | Yes — mount TOCTOU | Medium residual | Medium residual | Residual | Gate |
| **SEC-10** | — | SwiftTerm PTY | Low residual | — | Residual | Gate |
| **SEC-12** | **F-06** + **G-01** | Yes — Phase 2 policy / no transport | High residual | Medium + gap | **Do not implement** | Gate |

### Settings honesty / product gaps

| Grok | ChatGPT | Same issue? | Grok sev | ChatGPT sev | **Queue sev** | Wave |
|---|---|---|---|---|---|---|
| **GAP-01** | **F-07** (part) | Host/Client/Both, port, Bonjour, identity; binary path | High | Medium | **High** | 2 |
| **GAP-04** | (inside `F-07` unnamed) | Launch at login / `SMAppService` | High | — | **High** | 2 |
| **GAP-05** | **F-07** / **G-02** | Sparkle toggles vs no Sparkle | Medium | Medium / gap | Hide UI now | 2 |
| **GAP-02** | — | Jamf / `UnmanagedPreferences()` | High | — | **High** (honesty) | 2 |
| — | **F-11** | Menu bar / Dock / Both collapse | — | Low | Low | 2 |
| **GAP-03** + **GAP-18** | — | Guided install / appearance-only onboarding | High + Medium | — | High | 3 |
| **GAP-06** | — | Volume/network inspect unwired | High | — | High | 3 |
| **GAP-08** | **F-09** | No app/UI tests | High | Medium | After Waves 0–2 | 3 |
| **GAP-09** | **F-12** | Stale README / 29 tests | High | Low | **Medium** | 3 |
| **GAP-07** | **G-06** (part) | Search grammar / ⌘K | Medium | Gap | Compact | 3 |
| **GAP-10** | — | `system property list` / config.toml | Medium | — | Compact | 3 |
| **GAP-11** | — | Run sheet missing flags | Medium | — | Compact | 3 |
| **GAP-12** | (not `G-05`) | Pull/build progress **UI** | Medium | — | Compact | 3 |
| **GAP-13** | — | Prune in CLI, not UI | Medium | — | Compact | 3 |
| **GAP-14** | **G-03** | Activity/metrics in-memory | Medium | Gap | After executor | 3+ |
| **GAP-15** | — | A11y labels, not a pass | Medium | — | Compact | 3 |
| **GAP-16** | — | Structured OSLog almost unused | Medium | — | Compact | 3 |
| **GAP-17** | — | Machine allowlist tests decode-only | Medium | — | Compact | 3 |
| **GAP-19** | **G-06** (part) | i18n | Low | Gap | Later | Later |
| **GAP-20** | — | Column layout session-only | Low | — | Later | Later |
| — | **G-04** | Private registry login / Keychain | — | Gap | Named; not this week | 5 |
| — | **G-02** | Signed notarized updating distro | — | Gap | Phase 5 | 5 |

### UI / redundancy / packaging

| Grok | ChatGPT | Same issue? | Grok sev | ChatGPT sev | **Queue sev** | Wave |
|---|---|---|---|---|---|---|
| **UI-01** | — | Colour-only state dots | High | — | High | 3 |
| **UI-03** | — | Empty-state CTAs | High | — | High | 3 |
| **UI-04** | — | Filtered-empty blank table | High | — | High | 3 |
| **RED-01** + **RED-02** + **UI-02** | **F-13** | List/detail chrome fork | High | Low | **High** | 4 |
| **RED-03**–**RED-07** | ⊂ **F-13** | Presentation ×3, list shell, inspect chrome, cards, refresh | Medium | Low | Medium after High chrome | 4 |
| **RED-08**–**RED-10** | — | Dead search, copied `fixture()`, filename | Low | — | Low | 4 |
| **UI-05**–**UI-10** | — | Filter chrome, surfaces, sparkline, Wordmark, bulk bar, ports | Medium | — | Medium | 3–4 |
| **UI-11**–**UI-12** | — | Token drift; stale `branding.md` | Low | — | Low | 4 |
| — | **F-10** | Untagged `git describe` version | — | Medium | Medium | 5 |
| — | **F-14** | `actool` best-effort blue accent | — | Low | Low | 5 |

**Counts for orientation (do not re-litigate):** Grok 54 IDs (13 High confirmed, 28 Medium, 11 Low, 1 Info `SEC-11`, 1 High residual `SEC-12`). ChatGPT 14 findings (3 High, 7 Medium, 4 Low; 0 Critical) + 6 product gaps. Overlap is the spine; unique High for this queue from ChatGPT is `F-02`; unique High honesty/UX catalogue is Grok.

---

## Low / info — later (do not prioritize over Waves 0–2)

| ID | If still true |
|---|---|
| **SEC-07** | Keep `flotilla-probe` out of the release app, or route `dumpRaw` through `ContainerCLI.execute`. |
| **SEC-08** | Optional pattern redaction on `ErrorLog.record()`, or document that diagnostics stay off on shared accounts. Support bundles already fail closed. |
| **SEC-11** (Info) | Intentional: no App Sandbox for v1 (`DECISIONS.md` Q9). Track Developer ID / hardened runtime / least-entitlements in Phase 5. Do not treat missing sandbox as an accidental hole. |
| **GAP-19** / **G-06** | `String(localized:)` when freezing copy. Keyboard-first navigation after the UI contract settles. Not a Phase 1 blocker. |
| **GAP-20** | Persist column customization + sidebar width in the UI-state store. |

---

## Do not do yet / out of scope

- **Do not implement Phase 2 transport.** No `RemoteHost`, `NWListener`, Bonjour advertising, pairing, or Keychain mTLS identity until `SEC-12` / `F-06` gates are designed and the human asks. Disable lying Host UI instead (`GAP-01` / `F-07`).
- **Do not write exploits, PoCs, fuzzers, or attack procedures.**
- **Do not add Sparkle** unless asked (`GAP-05` / `G-02` / Phase 5).
- **Do not sandbox the app** as a surprise fix (`SEC-11` is intentional for v1).
- **Do not invent branding** or change Trellis / other melonfleet apps. Canonical tokens: workspace `design/brand/BRAND.md` and Flotilla `Theme.swift`.
- **Do not claim MountPolicy is race-free** (`SEC-05` / `F-05` residual).
- **Do not implement `G-04` private-registry login** this week unless asked.
- **Do not commit** unless the human asks.
- **Do not overwrite** `message-to-andy-from-grok-flotilla-audit.md` or `MESSAGE-TO-ANDY-FROM-CHATGPT-FLOTILLA-AUDIT-2026-08-20.md`. This file is the combined queue.

Audit out of scope (do not expand into): live hostile testing, dependency CVE scanning, VoiceOver session, clean-Mac notarization / Developer ID material (no Xcode project in-tree). ChatGPT’s baseline did run tests and inspect a built bundle; Grok’s did not. Re-run tests yourself.

---

## File index (start here)

Paths relative to `Flotilla/` unless noted.

| Path | Why |
|---|---|
| `Sources/FlotillaCore/ContainerHost.swift` | **Wave 0:** `F-02` sequential drain; `F-01` / `SEC-04` no timeout; absolute-path launch |
| `Sources/FlotillaCore/Allowlist.swift` | `timeoutHint`; `auditDescription` (`SEC-03` / `F-04`); exposure; inspect grammar (`GAP-06`) |
| `Sources/FlotillaCore/ContainerCLI.swift` | Timeout discarded in the call chain; mutations exist (docs lie) |
| `Sources/Flotilla/TerminalTab.swift` | `SEC-01` PATH fallback |
| `Sources/Flotilla/MachineDetailView.swift` | **Second** `SEC-01` `/usr/bin/env` site (~319) |
| `Sources/FlotillaCore/Preflight.swift` | `locateBinary("container")` to reuse; install/kernel out of scope (`GAP-03`) |
| `Sources/Flotilla/ContainersView.swift` | Delete without confirm (`F-03` / `SEC-02`); colour-only state; private Presentation; `RED-01`/`RED-02` |
| `Sources/Flotilla/MachinesView.swift` | Destructive preference ignored; duplicated navigator; `SEC-09` home-mount UI |
| `Sources/Flotilla/SettingsView.swift` | Host mode, launch-at-login, updates, confirm toggles (`GAP-01`/`GAP-04`/`GAP-05` / `F-07`) |
| `Sources/FlotillaCore/Settings/SettingsStore.swift` | Default `UnmanagedPreferences()` (`GAP-02`) |
| `Sources/Flotilla/AppModel.swift` | LocalHost-only CLI; preserve dirty work |
| `Sources/Flotilla/FlotillaApp.swift` | `F-11` Menu bar/Dock/Both; preserve dirty work |
| `Sources/Flotilla/ResourceListControls.swift` | Shared toolbar Containers/Machines skip (`RED-01`) |
| `Sources/Flotilla/ContainerCard.swift` | Quaternary card surface (`UI-02`) |
| `Sources/Flotilla/Theme.swift` | Canonical tokens |
| `Sources/FlotillaCore/MountPolicy.swift` | `SEC-05` / `F-05` TOCTOU documented |
| `Scripts/make-app.sh` | `F-10` version; `F-14` actool; `F-08` ad-hoc sign |
| `README.md`, `PHASE1.md` | Stale “29 tests” / read-only CLI (`GAP-09` / `F-12`) |
| `research/ALLOWLIST-AUDIT.md` | Publish/driver residual (`F-06` / `SEC-12`) |
| `Package.swift` | No Sparkle; FlotillaCoreTests only (`GAP-08` / `F-09` / `GAP-05`) |
| `CLAUDE.md`, `DECISIONS.md` | Read before editing (ChatGPT required) |

---

## Sign-off

the app owner — this file is the work queue. It replaces the two separate briefs for sequencing only; the HTML catalogues remain the evidence. ChatGPT’s earlier pass (~14:43 +03) is merged with Grok’s (~15:51 +03). Verify, then work Waves 0–5. Leave the wire unimplemented. If a finding is already gone, say so and move on.

— Grok (Cursor Grok 4.6)  
Thursday, 20 August 2026, 4:29 PM (UTC+3)  
`2026-08-20 16:29 +03:00`
