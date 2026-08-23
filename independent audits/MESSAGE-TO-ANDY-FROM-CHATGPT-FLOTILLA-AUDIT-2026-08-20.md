# Message to the app owner — Flotilla Audit

**Recipient:** the app owner (Claude Opus 5)  
**Generated:** 2026-08-20 14:43:04 +03 (UTC+0300)  
**Project:** Flotilla  
**Audit report:** [audit-report-2026-08-20.html](./audit-report-2026-08-20.html)

## Mission

Independently verify the Flotilla audit, correct any inaccurate findings, and implement the validated recommendations in risk order. Treat the HTML report as a set of hypotheses supported by an initial static review, build/test run, and visual inspection—not as unquestionable ground truth.

Your priorities are:

1. Prevent unsafe, unbounded, or misleading command execution.
2. Make destructive-action behavior consistent and enforce the related settings.
3. Prevent sensitive command arguments from entering logs or support bundles.
4. Remove or clearly disable UI controls that imply unavailable functionality.
5. Add regression coverage before broad refactoring.
6. Preserve the project's security boundaries and documented product decisions.

## Read Before Editing

Read the repository guidance and decision records in full, especially:

- `CLAUDE.md`
- `DECISIONS.md`
- `PHASE1.md`
- The complete HTML audit linked above
- Relevant source and test files for every finding you investigate

Do not weaken default-deny behavior, mount validation, wire exposure rules, or exec restrictions to make a test pass. Keep `FlotillaCore` Foundation-only. Do not introduce arbitrary shell execution, especially across a future remote connection. When fixtures are needed, derive them from real CLI output and document their origin.

## Protect Existing Work

Before making changes, capture `git status --short` and review the current diff. At handoff time, the working tree already contained:

- Modified: `Sources/Flotilla/AppModel.swift`
- Modified: `Sources/Flotilla/FlotillaApp.swift`
- Untracked: `audit-report-2026-08-20.html`

Assume the modified Swift files contain pre-existing user work. Preserve it, understand it before editing overlapping areas, and never discard or overwrite it. Keep your changes narrowly scoped and identify which changes were yours in the final report.

## Baseline to Reproduce

The initial audit recorded:

- 14 findings: 3 high, 7 medium, and 4 low; no critical findings.
- 6 major product gaps.
- 307 passing Swift tests using `swift test --disable-sandbox`.
- Approximately 21,607 production Swift lines and 4,791 test lines.

Re-run the test suite before editing. Record the command, commit/worktree state, test count, failures, warnings, and environment. If your baseline differs, explain why before attributing a regression to your changes.

## Phase 1 — Independently Verify the Findings

For every item below, mark it **confirmed**, **partially confirmed**, **not reproducible**, or **superseded**. Provide file paths, symbols, tests, and concise reasoning. Do not change code until you understand the full call path and existing tests.

### High priority

#### F-01 — Execution limits are calculated but not enforced

Trace command execution from `Allowlist` through `ContainerCLI` to `LocalHost`. Verify whether `timeoutHint` or an equivalent execution budget is discarded and whether launched processes have real deadlines, cancellation, and concurrency limits.

Acceptance criteria if confirmed:

- Carry a typed execution policy/envelope across the entire call chain.
- Enforce a hard deadline at the process boundary, not only in UI state.
- Terminate and reap timed-out or cancelled process trees safely.
- Bound concurrent child processes and define queue behavior.
- Return typed timeout/cancellation/limit errors suitable for honest UI states.
- Add deterministic tests for completion, timeout, cancellation, and concurrency saturation.

#### F-02 — Sequential pipe draining can deadlock and output is unbounded

Inspect whether `LocalHost` drains stdout to EOF before stderr. Demonstrate the risk with a controlled test helper that fills both pipes; do not use a destructive container command.

Acceptance criteria if confirmed:

- Drain stdout and stderr concurrently while the process runs.
- Apply explicit per-stream and aggregate byte limits.
- Define truncation behavior and surface it to callers.
- Avoid retaining unlimited output in memory.
- Ensure timeout and cancellation still work while either stream is busy.
- Add tests for large stdout, large stderr, simultaneous output, truncation, timeout, and cancellation.

#### F-03 — Destructive confirmation behavior is inconsistent

Trace every destructive entry point: row actions, context menus, detail views, bulk actions, images, volumes, networks, containers, and machines. Verify whether container context-menu deletion bypasses confirmation and whether `confirmDestructiveActions` and `confirmBulkActions` are consistently honored.

Acceptance criteria if confirmed:

- Route destructive operations through one coordinator or one clearly shared policy.
- Apply the same confirmation semantics regardless of entry point.
- Make both settings effective, or remove them if the product decision is that confirmation is mandatory.
- Present the target name, action, consequence, and bulk count clearly.
- Prevent double submission while an operation is in progress.
- Add unit tests for the policy matrix and UI tests for representative entry points.

### Medium priority

#### F-04 — Audit descriptions may expose secrets

Inspect `ValidatedCommand.auditDescription` and every logging/support-bundle consumer. Verify handling of `--env`, `--env=`, `--build-arg`, registry credentials, tokens, passwords, and future secret-bearing flags.

Acceptance criteria if confirmed:

- Redact from structured command arguments before joining or formatting them.
- Prefer an allowlist of safe-to-log fields over a growing secret denylist.
- Never rely only on downstream free-text redaction.
- Test separated and `--flag=value` forms, mixed casing where applicable, malformed input, and multiple secrets.
- Verify support bundles cannot restore or bypass the redaction.

#### F-05 — Mount validation has a symlink time-of-check/time-of-use window

Re-evaluate `MountPolicy` from validation through actual process launch. Determine whether a mount path or ancestor can change after validation. Document what can be fixed in Phase 1 and what requires descriptor-based or privileged platform support.

Do not claim this is fully solved by repeating `realpath` immediately before launch. Add defense-in-depth where practical, preserve the default-deny policy, and record residual risk explicitly.

#### F-06 — Remote-mode command policy is unresolved

Confirm that future remote execution would permit or insufficiently constrain host-wide publishing such as `--publish 0.0.0.0` and opaque volume/network plugin options. Treat this as a Phase 2 security gate, not a reason to loosen Phase 1 validation.

Before implementing `RemoteHost`, define and test:

- Allowed bind addresses and port ranges.
- Host-specific policy ownership and enforcement location.
- Volume/network driver and plugin-option policy.
- Request budgets, output limits, deadlines, cancellation, and concurrency.
- Audit privacy, enrollment, revocation, and capability negotiation.

#### F-07 — Future or inert settings appear operational

Verify whether binary-path settings, Host mode, host/port fields, Bonjour, identity controls, and update controls actually affect behavior. For every inert control, choose one of three honest states: wire it fully, disable it with explanatory copy, or remove it until the feature ships.

Do not leave editable controls that silently do nothing. Add tests for settings that remain visible.

#### F-08 — Release hardening and update integrity are absent

Inspect packaging and signing scripts. Confirm whether builds are only ad-hoc signed and whether hardened runtime, Developer ID signing, notarization, stapling, and a verified update channel are absent.

Create a reproducible release checklist or CI path that distinguishes development builds from release artifacts. Do not add Sparkle UI until the dependency, feed signing, update verification, and rollback behavior exist. Credentials must remain outside the repository.

#### F-09 — UI and accessibility regression coverage is absent

Confirm the package only tests `FlotillaCore` and lacks SwiftUI/UI/accessibility coverage. Add the smallest maintainable test layer that protects the destructive-action matrix, settings truthfulness, important navigation, keyboard behavior, accessibility labels, and critical error states.

If an Xcode project/runner is required, keep Swift Package tests working and document both test commands.

#### F-10 — Bundle marketing version is not a valid semantic version

Verify whether `CFBundleShortVersionString` receives the git hash `d8ba884` or another non-dotted identifier. Separate the human-facing semantic version from the build identifier/commit metadata. Add a packaging assertion that rejects invalid release version values.

### Low priority

#### F-11 — Presentation choices collapse to fewer behaviors

Verify whether Menu Bar, Dock, and Both produce only two effective behaviors and whether menu-bar-only mode still opens a window. Either implement three distinct, predictable modes or reduce the choices and wording to match reality. Test launch, activation, window restoration, and preference changes.

#### F-12 — Documentation contradicts the product

Reconcile the README and source comments with the current product. The audit observed references to 29 tests, claims that implemented features are missing, claims that no app bundle exists, and stale paths/comments. Update documentation only after verifying current behavior and commands.

#### F-13 — Large files and duplicated UI mechanics

Re-measure and inspect the reported large files: `Allowlist`, `ContainerDetailView`, `AppModel`, `ContainersView`, and `MachinesView`. Look specifically for repeated detail headers, steppers, presentation logic, and deletion mechanics.

Refactor only after regression tests cover behavior. Prefer extracting policy and reusable components with clear ownership; do not split files solely to improve line counts.

#### F-14 — Brand assets can fail silently

Verify whether asset-catalog compilation is best-effort and whether the AppKit accent color can silently revert to blue. Make missing or invalid Melonfleet brand assets a release-build failure while retaining a documented development fallback if needed.

## Phase 2 — Validate the Product Gaps

Confirm the status of each gap and identify prerequisites rather than building speculative architecture:

1. **Remote transport:** no completed mTLS transport, pairing/enrollment, revocation, host policy store, or `RemoteHost`.
2. **Release pipeline:** no complete Xcode/Developer ID/hardened-runtime/notarization/Sparkle flow.
3. **Activity and metrics:** no durable persistence, history, or trend storage.
4. **Private registries:** no complete registry authentication and Keychain-backed credential lifecycle.
5. **Streaming and cancellation:** no true streaming output with durable cancellation across the execution boundary.
6. **Localization and keyboard navigation:** no complete localization or keyboard-first navigation strategy.

For each confirmed gap, produce a short design note containing scope, threat model, dependencies, migration impact, acceptance criteria, and tests. Do not implement Phase 2 remote execution until the F-06 policy gate is approved.

## Recommended Work Order

Use small, reviewable changes. Each change should include its tests and documentation.

### Wave 0 — Immediate safety and truthfulness

1. Introduce and enforce the typed execution envelope.
2. Drain process pipes concurrently; add output caps, deadlines, cancellation, and concurrency control.
3. Centralize destructive-action confirmation and enforce both settings consistently.
4. Redact structured command data before it reaches audit text or support bundles.

### Wave 1 — Product consistency and release correctness

1. Wire, disable, or remove inert settings.
2. Make presentation choices match actual behavior.
3. Add UI/accessibility regression coverage.
4. Correct bundle version semantics and add release assertions.
5. Make required brand assets mandatory for release builds.
6. Bring the README and source documentation in line with verified behavior.
7. Refactor duplicated UI mechanics only after coverage exists.

### Wave 2 — Phase 2 security gate

1. Resolve publish-address and plugin-option policies.
2. Design mTLS enrollment, identity storage, rotation, and revocation using Keychain-backed secrets.
3. Define host-specific capabilities, budgets, deadlines, output limits, and audit privacy.
4. Revisit the mount TOCTOU boundary and document residual risk.
5. Only then implement discovery and `RemoteHost` incrementally.

## Verification Standard for Every Change

For each patch:

- State the finding it addresses and the verified root cause.
- Add a regression test that fails before the fix where feasible.
- Run the focused tests and the complete Swift suite.
- Build the development app/bundle using the documented path.
- Manually exercise affected UI flows when automation cannot cover them.
- Check keyboard focus and accessibility labels for changed controls.
- Review logs and support-bundle output for secret leakage.
- Record any new dependency, entitlement, privacy impact, or migration.
- Keep error states explicit; never present stale data as current success.

Do not report a finding as resolved merely because code was rearranged or a UI control was hidden. Resolution requires enforcement at the correct boundary plus regression evidence.

## Stop and Escalate Instead of Guessing

Pause and request a product/security decision when work requires:

- Changing a documented security invariant or allowlist policy.
- Selecting remote bind-address, plugin, enrollment, or revocation policy.
- Signing identities, notarization credentials, update-signing keys, or external services.
- Migrating or deleting user data.
- Adding a network dependency or telemetry.
- Overwriting pre-existing work in the modified Swift files.
- Making a UX choice that changes destructive-action guarantees.

Document the exact decision needed, available options, security implications, and your recommendation.

## Preserve the Existing Strengths

Do not regress the controls the initial review found valuable:

- Default-deny command validation with the existing allowlist/spec model.
- `WirePolicy`, `MountPolicy`, and `ExecPolicy` boundaries.
- Support-bundle redaction followed by an independent audit pass.
- Honest loading, empty, stale, and failure states.
- Centralized theme and reusable control patterns such as `IconActionButton` and `SectionToolbar`.

## Required Final Handoff

Return a Markdown report with this structure:

```markdown
# Flotilla Audit Verification and Remediation Report

## Environment and Baseline
- Commit/worktree state:
- Toolchain:
- Baseline test command and result:

## Finding Disposition
| ID | Status | Evidence | Action |
|---|---|---|---|
| F-01 | Confirmed / Partial / Not reproducible / Superseded | Paths, symbols, tests | Fix or rationale |

## Changes Implemented
- Change:
- Files:
- Security/UX effect:
- Regression tests:

## Verification Results
- Focused tests:
- Full suite:
- Build/package checks:
- Manual UI/accessibility checks:
- Log/support-bundle privacy checks:

## Decisions Required
- Decision, options, implications, recommendation:

## Residual Risks and Deferred Work
- Risk:
- Why deferred:
- Compensating control:
- Recommended owner/milestone:
```

Include exact commands and concise output summaries. Clearly distinguish verified facts, inferences, completed changes, and proposed work. End with the next three highest-value actions.

## Audit Scope Caveat

The initial audit was based on static source inspection, local build/test execution, and visual review of the generated HTML report. It did not include live destructive container operations, a remote-host penetration test, a full VoiceOver session, a clean-Mac notarization test, or an online dependency vulnerability scan. Do not imply those areas were verified unless you perform and document them.
