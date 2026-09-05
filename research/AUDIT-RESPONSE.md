# Response to the independent audit of 2026-08-20

Tracks remediation of `independent-flotilla-audit-2026-08-20-1629.md`. Findings were re-verified
in the tree before being accepted — several were real, one class was overstated, and the
disagreements are recorded here rather than quietly dropped.

**Naming collision, on purpose flagged:** `GAP-PLAN.md` numbers *feature* waves. The waves below
are **audit-remediation** waves and are unrelated. Do not read "Wave 2" in one as the other.

## Wave 0 — the live hang risk. **Done, 2026-08-23.**

Full rationale in DECISIONS.md Q15; lessons in CLAUDE.md.

- **F-02 sequential pipe drain → deadlock.** Confirmed. Now concurrent, with a 4 MiB per-stream
  ceiling; past the ceiling output is read and discarded, because stopping the read is what
  re-creates the deadlock. Truncation is reported on `CommandResult`, not swallowed.
- **F-01 no deadline.** Confirmed — `timeoutHint` was assigned and never read. Now carried from
  `ValidatedCommand` into `LocalHost` and enforced with terminate → grace → `SIGKILL`, throwing
  `ContainerCLIError.timedOut`. Spec values were audited first; enforcing an unread field would
  otherwise have killed `image pull`.
- **A bug the fix's own test found:** a grandchild inherits the pipe, so a child's exit does not
  guarantee EOF. Hence `drainGrace` and `Sink.abandon()`.
- **SEC-01 two `?? "/usr/bin/env"` sites.** Confirmed, both removed; one
  `AppModel.containerExecutable` on `Preflight.locateBinary`, returning `nil` with callers that
  say so.
- Removed `stats(noStream:)` — its only reachable outcome was failure.
- 9 new tests in `LocalHostRunnerTests`, driving `/bin/sh` through an injected resolver (not an
  allowlist widening — `LocalHost` is built directly and nothing crosses `Allowlist`). 318 pass.

**Not fixed, not claimed:** `Task` cancellation still does not reach the child — it now dies at
its deadline rather than never, but cooperative cancellation needs the async API (Phase 4). The
ceiling is per stream per invocation, not a budget across the `aggregatedLogs` fan-out.

## Wave 1 — destructive-action integrity. **Done, 2026-08-23.** (DECISIONS.md Q17)

- **One coordinator.** `DeletePolicy` in `FlotillaCore` — pure, tested, and in Core precisely because
  the app target has no test target. All five screens defer to it; the three private copies of
  `requestDelete` are gone and the two screens with none now have one.
- **`confirmBulkActions` deleted**, bulk confirmation mandatory. It had no consumer, so mandatory is
  what already shipped.
- **Found while doing it, and not in the audit:** `ContainersView`'s context menu deleted a container
  with **no confirmation at all**. Fixed.
- **Correction to the audit's framing:** Containers and Machines ignoring `confirmDestructiveActions`
  meant they confirmed *unconditionally* — a setting that was a no-op on two of five screens, not a
  path that skipped confirmation. Both now honour it, and the Settings summary names all five kinds.
- **SEC-03 structural redaction.** `auditDescription` is now built by the validator from the argv
  **and the spec**, so a value is identified by its position in a grammar rather than by looking
  secret. Flag and operand *names* survive; `envAssignment`, `keyValue`, the four host-path shapes and
  the whole trailing command do not. `ValueShape.carriesFreeFormData` is an exhaustive switch, so a
  new shape must be classified before it compiles. The full argv is still available as
  `localPreview` for the build and machine forms — a preview that renders the `--build-arg` you just
  typed as `<keyValue>` is useless, and distinguishing the two by **audience** is the only way both
  are right. Stated cost: an audit line no longer says *which* path was mounted.
- **`machine set home-mount=rw` confirms on escalation only.** See Q17 for why "whenever rw is
  selected" would have been the wrong trigger, and for the two bugs building it exposed.

## Wave 2 — honesty about settings. **Done, 2026-08-23.** (DECISIONS.md Q16)

11 of 26 keys were read by nothing. Four were wired (`launchAtLogin` via `SMAppService`,
`autoStartContainerService`, `containerBinaryPath`, and the two container defaults, which needed CPU
and memory fields the run sheet never had). Eight are marked `.notBuilt(reason:)`: their controls are
disabled, state what is missing, and are **withheld from the MDM payload** — an administrator
pushing `hostListenPort` to a fleet would otherwise believe they had configured a listener.

`Scripts/check-settings-consumers.sh` now fails the build if an `.available` key has no consumer, or
if a `.notBuilt` key acquires one. It was verified by deliberately unwiring `launchAtLogin` and
watching it fail. Its one exception is declared and narrow: the diagnostics snapshot may read `mode`,
because reporting a preference back to whoever set it is a mirror, not a consumer.

Decisions taken as instructed: `SMAppService` wired now; the Dock/menu-bar picker replaced by a
**Show Dock icon** toggle defaulting to on, with the menu bar always shown.

## Wave 3 — docs and empty states. **Done, 2026-08-23.**

- **README** "Current status" rewritten. It claimed 29 tests (335) and a read-only `ContainerCLI`
  (mutations, volumes, networks, machines and bounded logs all shipped), and listed as unfinished
  several things that exist. It now also carries an explicit **what is not built** section, because a
  Settings screen is a poor place to discover that.
- **PHASE1.md dated** rather than rewritten. It is the original work contract and its value is the
  record of who was asked to build what; a status note at the top says the inventory is historical.
- **UI-03 / UI-04 fixed** in Images, Volumes and Networks. All three tested `model.<collection>
  .isEmpty` rather than the *displayed* list, so narrowing a filter to nothing rendered an empty table
  with no message and no way to see which control had hidden the rows. They now match the Containers
  pattern, with a primary action when genuinely empty and Clear Filter when not.
- **GAP-06 wired.** `volume inspect` and `network inspect` were allowlisted from the start with no
  method able to call them. `inspectVolume`/`inspectNetwork` decode into the **existing** models —
  verified against the live CLI, both subcommands return the same shape as their `ls` — plus a shared
  `InspectSheet` reusing the container and machine inspector rather than a third dialect of it. No new
  grammar; fixtures captured from the real CLI.
- **UI-01 closed as won't-do**, per instruction, and recorded **at the code** as well as here so the
  next review finds the reasoning where it applies. The accessibility objection is answered without
  widening the column: `.help` and `.accessibilityLabel` both carry the CLI's state string, so the
  state is not encoded in colour alone.

## Wave 4 — deferred, deliberately

`ResourceListControls` for Containers/Machines, `EmbeddedDetailNavigator`, card surfaces. These are
refactors of the least-tested layer in the project. Wave 0 is the argument for waiting: the one
boundary with no tests is where the deadlock lived. The prerequisite is an app-layer test target, not
more resolve.

Two invariants that would otherwise need those tests are enforced by script instead —
`Scripts/check-defaults.sh` and `Scripts/check-settings-consumers.sh`, both run by `make-app.sh`.

## Wave 5 — packaging. **Done, 2026-08-23.**

Version stamping and `actool` were already in `make-app.sh` from an earlier session; the remaining
bug was real and only visible in a repo with **no tags**. `git describe --tags --always` falls back to
a bare commit hash, so the bundle carried `CFBundleShortVersionString = be83e91` and
`CFBundleVersion = be83e91-dirty` — and Apple's rule for the latter is one to three period-separated
integers. Now: the tag (or `0.0.0`) for the marketing string, `git rev-list --count HEAD` for the
build number, and the git description in its own `FLGitDescribe` key, which the diagnostics snapshot
appends so a support bundle still names the exact commit. This stopped being cosmetic the moment
login items started going through `SMAppService`, which is LaunchServices' opinion of the bundle.

Signing is still **ad-hoc**, and `make-app.sh` now says so on every build: no Team ID, fine locally,
not distributable, and a reason `SMAppService` registration can be refused after a rebuild. Real
signing needs a Developer ID and is the user's call, not a script's.

## Not verified by me, and why

Synthetic clicks require Accessibility trust this process does not have (`AXIsProcessTrusted()` is
false), so nothing below could be driven from here. Everything else in these waves was verified by
`swift test` (335 passing), by the real `container` CLI, or by launching the built bundle and reading
its state from disk.

- The container terminal and machine console opening a shell (Wave 0's `containerExecutable` change).
- The `home-mount=rw` confirmation dialog appearing on escalation.
- The Settings rows: the disabled not-yet-available controls, the login-item status caption, and the
  binary-path explanation.
- The new empty states and the volume/network Inspect sheet.

## Standing refusals

Unchanged and not negotiable by a future audit's enthusiasm: no Phase 2 transport and no listener;
no exploits or PoCs; no Sparkle; no sandboxing the app as a surprise fix; no claim that
`MountPolicy` is race-free.
