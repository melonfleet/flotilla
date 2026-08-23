# Message to the app owner — Combined Independent Flotilla Audit

**To:** the app owner (Claude Opus 5)  
**From:** ChatGPT, synthesizing the independent ChatGPT and Grok audits  
**Generated:** 2026-08-20 16:28:57 +03 (UTC+0300)  
**Project:** Flotilla  
**Workspace:** `Flotilla/` (repository-relative)

## Source material

- [ChatGPT audit](./audit-report-2026-08-20.html)
- [Original ChatGPT handoff](./MESSAGE-TO-ANDY-FROM-CHATGPT-FLOTILLA-AUDIT-2026-08-20.md)
- [Grok audit](./flotilla-audit-report.html)
- [Original Grok handoff](./message-to-andy-from-grok-flotilla-audit.md)

This is the consolidated execution brief. Use the two HTML reports for the full evidence, quotations, illustrations, and original scoring. This document reconciles their overlap, retains findings unique to either review, and replaces their competing work sequences with one risk-ordered queue.

## Mission

Independently verify the combined audit against the current tree, correct false or superseded claims, and implement confirmed recommendations in the order below. The reports are evidence-backed hypotheses, not gospel.

The desired outcome is a Flotilla build that:

1. Executes local CLI processes with bounded time, memory, output, and concurrency.
2. Cannot silently bypass destructive-action policy.
3. Does not expose secrets through command descriptions, logs, previews, or support bundles.
4. Presents only settings and behaviors that actually work.
5. Has regression coverage at the policy, AppModel, UI, and accessibility boundaries.
6. Is explicit about the difference between a development bundle and a distributable release.
7. Preserves the current default-deny architecture and keeps remote transport closed until its security gate is approved.

## Non-negotiable working rules

1. Read `CLAUDE.md`, `DECISIONS.md`, `PHASE1.md`, relevant research/decision records, and both HTML audits before editing.
2. Verify every finding in current production code. Mark it **confirmed**, **partially confirmed**, **already fixed**, **false positive**, or **deferred by decision**.
3. Reproduce the baseline before attributing failures to your work. The audits observed 307 passing `FlotillaCore` tests with `swift test --disable-sandbox`.
4. Keep `FlotillaCore` Foundation-only.
5. Preserve default-deny validation, `WirePolicy`/`Exposure`, `MountPolicy`, and `ExecPolicy` boundaries.
6. Never introduce arbitrary shell execution. Continue to launch typed argv through `Process.arguments`.
7. Do not implement `RemoteHost`, a listener, Bonjour advertising, pairing, or mTLS transport in this queue. Phase 2 remains gated.
8. Do not weaken policy to make tests pass. Test fixtures must be based on real CLI output and record their source.
9. Do not add Sparkle, telemetry, external services, signing material, or a network dependency without explicit approval.
10. Do not commit or push unless the human explicitly asks.
11. Keep changes inside Flotilla. Do not modify other melonfleet products.
12. Make small, reviewable changes. Each behavioral fix should carry its regression evidence.

## Protect the current working tree

At synthesis time, `git status --short` showed:

```text
 M Sources/Flotilla/AppModel.swift
 M Sources/Flotilla/FlotillaApp.swift
 D docs/LAPTOP-SETUP.md
?? "independent audits/"
```

The modified Swift files are pre-existing user work. The deleted documentation path and untracked audit directory appear to reflect the user’s file reorganization. Inspect the diffs and new locations before editing or staging. Do not restore, delete, overwrite, or reformat those changes as collateral work.

## How the audits were reconciled

The ChatGPT audit grouped the project into 14 findings plus 6 product gaps. The Grok audit divided similar concerns into 54 security, product, UI, and redundancy findings. The larger count does not mean 40 additional vulnerabilities: many are finer-grained UI/backlog items or splits of a single ChatGPT theme.

Use the priority assigned in this brief instead of comparing the original severity counts directly:

- **P0:** current execution, data-loss, or secret-handling risk; fix first.
- **P1:** settings truthfulness, policy coverage, testability, and release correctness.
- **P2:** incomplete Phase 1 workflows and significant accessibility/UX defects.
- **P3:** UI consistency, refactoring, polish, and deferred product expansion.
- **Gate:** must be designed and approved before a future feature can ship; do not implement the gated feature now.

Grok’s report describes “53 confirmed + 1 residual cluster,” but its catalogue marks `SEC-05`, `SEC-10`, and `SEC-12` as residual. Treat the individual catalogue status as authoritative and independently re-check all three.

---

## P0 — Bound and secure local execution

### P0.1 — Concurrent pipe drainage and output budgets

**Source:** ChatGPT `F-02`; not a standalone Grok finding.

Verify whether `LocalHost` drains stdout to EOF before draining stderr and whether either stream is accumulated without explicit byte limits. Demonstrate the behavior with a controlled test helper that writes to both pipes; do not use destructive container operations.

If confirmed:

- Drain stdout and stderr concurrently while the child runs.
- Set explicit per-stream and aggregate byte limits.
- Define whether output is rejected, truncated, streamed, or spilled; expose truncation to callers.
- Avoid retaining unlimited output in memory.
- Ensure a full stderr pipe cannot block a parent waiting on stdout.
- Cover large stdout, large stderr, simultaneous output, output truncation, timeout, and cancellation.

Completion requires a regression test that would hang or exceed its budget under the old implementation and terminates deterministically under the new one.

### P0.2 — Typed execution envelope, deadlines, cancellation, and concurrency

**Sources:** ChatGPT `F-01`; Grok `SEC-04`; prerequisite in Grok `SEC-12`.

Trace execution from `Allowlist`/`CommandSpec` through `ValidatedCommand` and `ContainerCLI` into `LocalHost`. Verify whether `timeoutHint` is discarded and whether a process can run indefinitely.

If confirmed:

- Carry a typed execution envelope through the complete call path.
- Include command policy, deadline, output budget, cancellation identity, and exposure context.
- Enforce the deadline at the process boundary.
- Terminate and reap timed-out or cancelled children safely; account for child process groups where platform APIs allow it.
- Bound concurrent child processes and define queue/saturation behavior.
- Return typed timeout, cancellation, truncation, launch, and saturation errors.
- Test normal completion, launch failure, non-zero exit, deadline, cancellation, simultaneous output, and concurrency saturation.

Do not claim completion if only the UI stops waiting while the process remains alive.

### P0.3 — Remove TerminalTab PATH fallback

**Source:** Grok `SEC-01`; absent from the ChatGPT catalogue.

Verify whether `TerminalTab` falls back to `/usr/bin/env` when the two hardcoded `container` paths are absent, while `LocalHost` deliberately uses an absolute executable path.

If confirmed, use the same validated binary resolver as preflight/execution and fail closed with a visible error. Do not use `env`, PATH lookup, a shell, or a user-editable raw executable without validation. Test standard install locations, missing binary, non-executable file, and any supported override.

### P0.4 — One destructive-action policy

**Sources:** ChatGPT `F-03`; Grok `SEC-02`, `SEC-06`, and related `SEC-09`.

Enumerate every destructive entry point across containers, machines, images, volumes, networks, detail views, cards, tables, context menus, keyboard actions, and bulk actions. Verify the reported direct container context-menu delete and unread `confirmBulkActions` setting.

If confirmed:

- Route destructive requests through one policy-aware coordinator.
- Apply identical semantics regardless of entry point or presentation.
- Make `confirmDestructiveActions` and `confirmBulkActions` effective, or remove a setting if the approved product decision requires mandatory confirmation.
- Include target name, action, consequence, and item count in confirmation copy.
- Disable double submission while an operation is pending.
- Consider an additional explicit grant warning for `home-mount=rw` while preserving its `localOnly` exposure.
- Test the complete single/bulk, setting-on/off, resource/action matrix plus representative UI entry points.

### P0.5 — Structural secret redaction

**Sources:** ChatGPT `F-04`; Grok `SEC-03`, `SEC-08`, and logging implications in `GAP-16`.

Verify whether `ValidatedCommand.auditDescription` joins raw arguments and whether `--env`, `--env=`, `--build-arg`, tokens, passwords, registry data, identity material, paths, or future secret-bearing flags can enter previews, live logs, audit records, or support bundles.

If confirmed:

- Redact structured arguments before joining or formatting them.
- Prefer an allowlist of safe audit fields over an expanding secret denylist.
- Cover separate-value and `--flag=value` forms, malformed arguments, repeated values, and mixed safe/secret fields.
- Decide whether `ErrorLog.record()` also needs pattern redaction or stricter diagnostic documentation.
- Preserve the support bundle’s independent fail-closed audit pass.
- Verify that no downstream formatter can reconstruct a redacted value.

### P0.6 — Keep development utilities outside the release boundary

**Source:** Grok `SEC-07`.

Verify whether `flotilla-probe` invokes `host.run(args)` without `Allowlist`. If it remains a development tool, ensure it is excluded from release packaging. If it is user-facing, route it through the same validated execution path. Do not broaden the production API to accommodate raw probe commands.

---

## P1 — Make settings, tests, and release artifacts truthful

### P1.1 — Audit every visible setting for a production consumer

**Sources:** ChatGPT `F-07`; Grok `GAP-01`, `GAP-02`, `GAP-04`, `GAP-05`; ChatGPT `F-11` for presentation behavior.

Build a registry-to-consumer matrix for every user-editable setting. For each setting, identify its renderer, persistence path, managed-preference behavior, and production runtime consumer. A persisted value is not a consumer.

Specifically verify:

- Container binary path override.
- Client/Host/Both mode.
- Listen address/port.
- Bonjour advertising.
- Identity/Keychain label.
- Jamf/managed preference loading and locked-row behavior.
- Launch at login through `SMAppService`.
- Automatic update checks, downloads, and update channel.
- Menu bar, Dock, and Both presentation choices.
- Confirmation settings covered in P0.4.

For every inert control, choose one approved state:

1. Wire it completely and test the observable effect.
2. Disable it with clear “Not available in this build” copy.
3. Remove or feature-flag it until the runtime exists.

Do not implement a network listener merely to make Host mode truthful. Managed preferences should be snapshotted from the approved macOS domain only after confirming the documented enterprise decision and precedence rules. Launch-at-login must surface `SMAppService` errors and should only be active in an appropriate app bundle.

For presentation mode, either implement three distinct launch/activation/restoration behaviors or reduce the choices to the states the app can reliably provide.

### P1.2 — Add AppModel, UI, accessibility, and policy regression coverage

**Sources:** ChatGPT `F-09`; Grok `GAP-08`, `GAP-15`, `GAP-17`, and UI accessibility implications.

Confirm that only `FlotillaCoreTests` exist and that machine policy tests are primarily decoding tests.

Add the smallest maintainable test architecture that covers:

- The settings registry-to-consumer matrix.
- Destructive confirmation policy.
- AppModel success, stale, failure, timeout, and cancellation states.
- Production `ExecPolicy` for machine create/set/delete and filesystem grants.
- Major navigation and first-run paths.
- List/cards parity for important actions.
- Filtered-empty and true-empty behavior.
- Keyboard reachability, focus order, VoiceOver labels, state expressed in words, contrast, reduced transparency, and reduced motion.
- Menu bar/Dock launch behavior.

Keep Swift Package tests working. If an Xcode UI-test target is necessary, document both test commands and use deterministic fixtures rather than a developer’s live container state.

### P1.3 — Correct version and distribution semantics

**Sources:** ChatGPT `F-08`, `F-10`, `G-02`; Grok `SEC-11` and `GAP-05` context.

Verify the package script, built Info.plist, signature, runtime flags, entitlements, and release documentation.

If confirmed:

- Keep a dotted human-facing version in `CFBundleShortVersionString`.
- Put a monotonically appropriate build identifier in `CFBundleVersion` and commit metadata in a separate field if useful.
- Reject malformed release versions in packaging checks.
- Clearly label ad-hoc builds as development artifacts.
- Define the future release pipeline: Xcode archive, minimal entitlements, hardened runtime, Developer ID signing for nested code, notarization, stapling, Gatekeeper verification, and clean-Mac launch.
- Treat the lack of App Sandbox as the documented v1 decision, not an accidental vulnerability; still maintain a least-entitlements inventory.
- Do not add Sparkle until update signing, appcast integrity, rollout, canary, and rollback are designed.
- Keep credentials and signing material outside the repository.

### P1.4 — Make brand assets deterministic in release builds

**Sources:** ChatGPT `F-14`; related Grok `UI-08`, `UI-12`.

Verify whether failed asset-catalog compilation only warns and allows an AppKit build to fall back to the default blue accent.

If confirmed:

- Fail release packaging when required assets cannot compile or the expected plist/catalog entries are absent.
- A documented warning-only fallback may remain for development builds.
- Keep `design/brand/BRAND.md` and `Theme.swift` authoritative.
- Move hardcoded wordmark colors onto shared semantic tokens.
- Replace stale Flotilla-local palette documentation with pointers to the canonical source.
- Add a packaging test that inspects the compiled artifact.

### P1.5 — Bring documentation in line with verified behavior

**Sources:** ChatGPT `F-12`; Grok `GAP-09`, `UI-12`.

Verify claims such as “29 tests,” read-only `ContainerCLI`, missing app bundles, incomplete feature lists, and stale paths/comments. Update documentation after behavior is verified. Preserve historical decision records with a clearly dated/superseded banner rather than silently rewriting history.

Create one canonical “what ships now” status page and link older plans to it. Avoid duplicating brand palettes or live feature inventories across multiple files.

---

## P2 — Complete the most important Phase 1 workflows

These are product gaps, not equivalent to exploitable security vulnerabilities. Verify them against the current approved Phase 1 scope before implementation.

### P2.1 — Guided install and kernel remediation

**Sources:** Grok `GAP-03`, `GAP-18`.

Confirm whether first-run onboarding only selects appearance and whether missing CLI/kernel requirements lead to text-only failure states. If this remains approved Phase 1 scope, add a non-trapping preflight flow with explicit status, safe remediation, retry, and “Continue anyway.” Downloading or installing Apple packages is an external and privileged workflow; require approval before adding it and verify origin/signature rather than trusting a URL.

### P2.2 — Volume and network inspection

**Source:** Grok `GAP-06`.

Verify that inspect grammar is allowlisted but `ContainerCLI` and UI do not expose volume/network inspection. If confirmed and in scope, add typed CLI methods based on captured fixtures and read-only detail panels. Do not invent new grammar when the allowlist already provides the operation.

### P2.3 — Search grammar, visible filters, and command navigation

**Sources:** Grok `GAP-07`, `UI-05`; part of ChatGPT `G-06`.

Verify missing `is:`, `image:`, and `host:` search tokens, hidden filter state, and absence of keyboard-first command navigation. Establish one query model shared by search text, filter controls, and any future command palette. Do not implement `host:` as if remote hosts currently exist; local-only behavior must be explicit.

### P2.4 — Runtime properties and run-sheet completeness

**Sources:** Grok `GAP-10`, `GAP-11`.

Verify the Phase 1 decision for reading `system property list`/`config.toml` and compare `RunOptions` against a captured version-matched `container run --help`. Add only flags supported by the target runtime and reviewed by the allowlist. High-impact filesystem/network flags require clear summaries and policy tests.

### P2.5 — Long-operation progress, cancellation, and pruning

**Sources:** Grok `GAP-12`, `GAP-13`; ChatGPT `G-05`.

Verify whether pull/build dismiss or show only an indeterminate spinner and whether container/volume/network prune exists below the UI. Build progress and cancellation on the P0 process-ownership design; do not create a second execution path. All prune operations need preview-before-destroy behavior and the centralized confirmation coordinator.

### P2.6 — Honest activity history and structured diagnostics

**Sources:** ChatGPT `G-03`; Grok `GAP-14`, `GAP-16`.

Verify whether activity and metrics are bounded in memory and reset at exit. Either label them “this session” or design persistence with retention, privacy, migration, and downsampling rules. Add structured OSLog categories only after P0.5; never log secret-bearing argv or environment values.

### P2.7 — Private registry credential lifecycle

**Source:** ChatGPT `G-04`; not a dedicated Grok finding.

Before adding registry login/logout, design how credentials avoid argv, enter the CLI through a reviewed input channel, live in Keychain, rotate, revoke, and are excluded from logs/support bundles. Do not implement private-registry authentication as an ordinary text setting.

### P2.8 — Localization, column persistence, and first-class keyboard use

**Sources:** ChatGPT `G-06`; Grok `GAP-19`, `GAP-20`, and accessibility work in `GAP-15`.

Confirm whether localization is intentionally deferred until copy stabilizes. When approved, move frozen copy toward String Catalog/localized APIs. Persist column/sidebar state in the UI-state store without mixing it with managed product settings. Keyboard-first navigation and state announcements should be addressed earlier than full localization when accessibility requires them.

---

## P2/P3 — Resolve observable UI inconsistencies

Verify each item in both table and card presentation, light/dark/Auto appearance, the minimum supported window size, increased contrast, and reduced transparency/motion.

| Source | Reported inconsistency | Required direction if confirmed |
|---|---|---|
| Grok `UI-01` | Container/machine state represented by a color-only dot | Shared status badge with text and/or symbol; color is supplementary. |
| Grok `UI-02` | Resource, container, and machine cards use incompatible surfaces | One themed surface/hairline primitive; retain domain-specific content. |
| Grok `UI-03` | Image, volume, and network empty states lack their primary action | Add the same safe primary action exposed by the toolbar. |
| Grok `UI-04` | Filtered-empty resource lists can render a blank table | Distinguish true empty, no matches, loading, stale, and failure states; provide Clear filters. |
| Grok `UI-05` | Active filter is hidden in a popover | Make state visible and synchronize it with the query model. |
| Grok `UI-06` | Detail/dashboard panels bypass brand surfaces | Use semantic Theme surfaces and hairlines. |
| Grok `UI-07` | Sparklines use unrelated system gray | Use a semantic metric/status token with contextual override. |
| Grok `UI-08` | Wordmark hardcodes colors | Read semantic values from Theme/canonical brand tokens. |
| Grok `UI-09` | Bulk-selection bar ignores the approved accent tint | Use the existing selection tokens; pink remains brand/selection, never error. |
| Grok `UI-10` | Published ports are not actionable in the table | Offer a safe, accessible Open action for a clearly resolved local URL. |
| Grok `UI-11` | Dot sizes, stderr colors, and sentence case drift | Normalize through tokens/copy rules; do not confuse stderr with fatal state. |
| Grok `UI-12` | Local branding document contradicts Theme | Remove duplicate palette data and point to canonical sources. |
| ChatGPT `F-11` | Menu bar/Dock/Both labels exceed actual behavior | Implement distinct tested states or reduce the option set. |
| ChatGPT `F-03` / Grok `SEC-02` | Destructive behavior changes with click target | Resolve through the P0.4 coordinator, not view-specific patches. |

Do not score visual polish as equivalent to process safety. Within this table, prioritize accessibility, empty/failure truthfulness, and destructive behavior before color/token cleanup.

---

## P3 — Reduce duplication after behavior is covered

**Sources:** ChatGPT `F-13`; Grok `RED-01` through `RED-10`.

Line count alone is not a defect. Add coverage before extraction, and consolidate shared behavior rather than forcing unrelated domain models into a generic abstraction.

Verify and address in this order:

1. **`RED-01`: Shared list controls.** Extend `ResourceListControls` for typed filters and use it in Containers and Machines.
2. **`RED-03`: Presentation enum duplication.** Use `ResourcePresentation` consistently while doing the list-control work.
3. **`RED-02`: Embedded detail navigation.** Extract back/stepper/filter/unavailable mechanics only after navigation tests exist.
4. **`RED-04`: List shell boilerplate.** Consolidate load state, alerts, refresh, activity, confirmation, and truthful empty/failure rendering.
5. **`RED-05`: Inspect panel chrome.** Share filter/copy/reload/presentation mechanics without merging container- and machine-specific loaders.
6. **`RED-06`: Machine cards.** Reuse the card grid/surface/action contract while preserving machine semantics.
7. **`RED-07`: AppModel refresh helpers.** Consolidate repeated volume/network/image loading behavior without obscuring typed public APIs.
8. **`RED-08`: Dead search state.** Remove only after repo-wide verification that it is unread.
9. **`RED-09`: Test fixture helpers.** Create shared test support and ensure inspect tests use the correct inspect fixture.
10. **`RED-10`: Misnamed toolbar file.** Rename only as a clean, isolated change with references updated.

Also reassess the large reported files (`Allowlist`, `ContainerDetailView`, `AppModel`, `ContainersView`, and `MachinesView`). Split files when it clarifies ownership or makes testing possible, not simply to reduce line counts.

---

## Gate — Do not open the Phase 2 fleet boundary

**Sources:** ChatGPT `F-05`, `F-06`, `G-01`, `G-04`, `G-05`; Grok `SEC-05`, `SEC-10`, `SEC-12`, `GAP-01`, `GAP-02`.

There is no live remote listener today, so these are launch gates rather than current remote exploits. Do not implement transport as part of this handoff.

Before any `RemoteHost`, listener, Bonjour advertisement, or pairing UI can ship, produce an approved design covering:

- Host-owned allowed bind interfaces and published-port ranges.
- Port conflicts and the policy for `0.0.0.0`, loopback, and privileged ports.
- Default-deny volume/network driver and plugin-option namespaces.
- Capability negotiation and versioned wire framing.
- Per-peer authentication, authorization, request concurrency, rate limits, deadlines, cancellation, frame limits, and output budgets.
- mTLS enrollment, identity generation, Keychain storage, rotation, revocation, recovery, and managed-policy precedence.
- Audit privacy, redacted structured records, retention, and operator visibility.
- Permanent `localOnly` treatment for machine mutations and read-write home grants unless a separately approved policy says otherwise.
- Mount-path authorization’s TOCTOU limitation. Repeating `realpath` does not make a string-based CLI handoff race-free.
- Dependency review for any untrusted terminal/output renderer.
- Threat model, abuse cases, migration, rollback, and independent security review.

The Phase 2 design must build on the P0 runner; it must not create a parallel unbounded executor.

---

## Complete source-ID coverage

Use this checklist to ensure no item from either report disappears during consolidation.

### ChatGPT catalogue

- `F-01` → P0.2
- `F-02` → P0.1
- `F-03` → P0.4
- `F-04` → P0.5
- `F-05` → Phase 2 Gate
- `F-06` → Phase 2 Gate
- `F-07` → P1.1
- `F-08` → P1.3
- `F-09` → P1.2
- `F-10` → P1.3
- `F-11` → P1.1 and UI table
- `F-12` → P1.5
- `F-13` → P3
- `F-14` → P1.4
- `G-01` remote fleet transport → Phase 2 Gate
- `G-02` signed/notarized/updating distribution → P1.3
- `G-03` persistent activity and metrics → P2.6
- `G-04` private registry authentication → P2.7
- `G-05` streaming and durable cancellation → P0.1/P0.2/P2.5
- `G-06` localization and keyboard navigation → P1.2/P2.3/P2.8

### Grok security catalogue

- `SEC-01` → P0.3
- `SEC-02` → P0.4
- `SEC-03` → P0.5
- `SEC-04` → P0.2
- `SEC-05` → Phase 2 Gate
- `SEC-06` → P0.4
- `SEC-07` → P0.6
- `SEC-08` → P0.5
- `SEC-09` → P0.4 and Phase 2 Gate
- `SEC-10` → Phase 2 Gate
- `SEC-11` → P1.3
- `SEC-12` → Phase 2 Gate

### Grok product-gap catalogue

- `GAP-01`, `GAP-02`, `GAP-04`, `GAP-05` → P1.1
- `GAP-03`, `GAP-18` → P2.1
- `GAP-06` → P2.2
- `GAP-07` → P2.3
- `GAP-08`, `GAP-15`, `GAP-17` → P1.2
- `GAP-09` → P1.5
- `GAP-10`, `GAP-11` → P2.4
- `GAP-12`, `GAP-13` → P2.5
- `GAP-14`, `GAP-16` → P2.6
- `GAP-19`, `GAP-20` → P2.8

### Grok UI and redundancy catalogues

- `UI-01` through `UI-12` → P2/P3 UI table
- `RED-01` through `RED-10` → P3

---

## Verification standard for every patch

For each change, record:

- Source audit ID(s).
- Current disposition and evidence: paths, symbols, searches, and tests.
- Root cause and the boundary where enforcement belongs.
- Files changed, including any overlap with pre-existing user modifications.
- Regression test that fails before the fix where feasible.
- Focused test result and full suite result.
- Development app build/package result.
- Manual UI, keyboard, and accessibility checks when automation is insufficient.
- Review of logs, previews, and support bundle for secret leakage.
- New dependencies, entitlements, privacy effects, migrations, or external requirements.
- Residual risk and compensating control.

Do not mark a finding complete because code moved, a UI control disappeared, or a task stopped awaiting a child process. Completion requires correct boundary enforcement and observable regression evidence.

## Stop and escalate instead of guessing

Request a product/security decision before:

- Changing a documented allowlist, exposure, mount, or exec invariant.
- Selecting remote interface, plugin, enrollment, identity, or revocation policy.
- Adding a listener, discovery, pairing, telemetry, network dependency, or update framework.
- Downloading/installing privileged software.
- Using signing identities, notarization credentials, or update keys.
- Migrating or deleting user data.
- Overwriting the existing `AppModel.swift` or `FlotillaApp.swift` work.
- Reversing the user’s audit-directory/document move.
- Making destructive confirmation less strict.

State the exact decision, available options, security/UX implications, and your recommendation.

## Required implementation sequence

Unless verification changes the risk picture:

1. P0.1 concurrent output handling and budgets.
2. P0.2 deadlines, cancellation, cleanup, and concurrency.
3. P0.3 terminal binary resolution.
4. P0.4 destructive-action coordinator.
5. P0.5 structured redaction; P0.6 release boundary for probe.
6. P1.1 settings-consumer audit and honesty pass.
7. P1.2 tests for the new boundaries and critical UI behavior.
8. P1.3/P1.4 version, distribution, and asset correctness.
9. P1.5 documentation.
10. P2 workflows and accessibility in approved Phase 1 scope.
11. P3 UI consolidation and refactoring.
12. Phase 2 design review only; no transport implementation.

Do not allow lower-risk UI refactoring to delay the P0 runner and confirmation work.

## Required final handoff

Return one Markdown report using this structure:

```markdown
# Flotilla Combined Audit Verification and Remediation Report

## Environment and baseline
- Commit/worktree state:
- Pre-existing changes protected:
- Toolchain:
- Baseline test/build commands and results:

## Finding disposition
| Source ID | Combined priority | Status | Evidence | Action |
|---|---|---|---|---|

## Changes implemented
### Change title
- IDs addressed:
- Root cause:
- Files changed:
- Security/UX effect:
- Regression coverage:

## Verification results
- Focused tests:
- Complete Swift suite:
- App build/package checks:
- Manual UI/accessibility checks:
- Log/preview/support-bundle privacy checks:

## Findings corrected or rejected
- ID:
- Why the audit claim was incomplete, superseded, or false:
- Evidence:

## Decisions required
- Decision:
- Options and implications:
- Recommendation:

## Residual risks and deferred work
- Risk:
- Reason deferred:
- Compensating control:
- Recommended milestone:

## Next three actions
1.
2.
3.
```

Clearly distinguish verified facts, inferences, completed work, and proposals. Include exact commands with concise output summaries. Do not claim VoiceOver, notarization, dependency-CVE, remote penetration, or destructive live-operation coverage unless it was actually performed and documented.

## Preserve what is already strong

The combined audits agree that Flotilla already has a substantial core. Preserve:

- Shell-free argv execution.
- Default-deny command specifications and exposure policy.
- Separate mount and exec policy boundaries.
- Support-bundle fail-closed redaction and independent audit.
- Honest loading, stale, empty, and failure states where already implemented.
- Centralized Theme and reusable UI primitives.
- The local-only nature of the current product while the fleet boundary remains unbuilt.

the app owner: verify first, then execute the queue in operational-risk order. If a finding is already fixed or conflicts with an approved decision, document the evidence and move on. Leave the remote wire closed.
