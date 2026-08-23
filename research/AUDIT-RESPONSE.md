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

## Wave 1 — destructive-action integrity

- One delete coordinator. Containers and machines never read `confirmDestructiveActions` today.
- **Delete `confirmBulkActions` and make bulk confirmation mandatory** (my recommendation, taken):
  a preference whose "off" position means "destroy several things without asking" is a setting for
  a mistake, and it multiplies the paths a delete can take.
- SEC-03 structural redaction of `auditDescription` — it joins the whole argv, `--env` values
  included. Wave 0 has already established the pattern (`LocalHost.summarise`); this replaces it
  with a structural projection rather than a prefix rule.
- Extra confirmation for `machine set home-mount=rw`.

## Wave 2 — honesty about settings that do nothing

The audit's strongest theme, and it was right: several user-editable settings have no production
consumer. Each either gets wired or gets disabled with a visible reason — no third option.

- **`SMAppService` for launch at login: wire it now** (decided).
- **Replace the Dock/menu-bar picker with a "Show Dock icon" toggle, default on; the menu bar is
  always shown** (decided).
- Disable or annotate: Host mode, listen port, Bonjour, Keychain label, `containerBinaryPath`,
  Sparkle. Note `containerBinaryPath` now has a natural consumer in
  `AppModel.containerExecutable` — wiring it is a real option, not just disabling it.
- Jamf/managed-prefs honesty.
- A registry test asserting every user-editable setting has a production consumer, so this class
  of drift fails the suite instead of an audit.

## Wave 3 — docs and empty states

- README says "29 tests" and describes a read-only CLI. Both stale.
- UI-03 / UI-04 empty states; volume and network inspect.
- **UI-01: won't-do** — the dot-only status indicator stays (decided). Recorded so it is not
  re-raised by the next audit.

## Wave 4 — deferred until app-layer tests exist

`ResourceListControls` for Containers/Machines, `EmbeddedDetailNavigator`, card surfaces. These are
refactors of the least-tested layer in the project; doing them before there are app tests trades a
working UI for a tidier one. Wave 0 is the argument: the one boundary with no tests is where the
deadlock lived.

## Wave 5 — packaging

`make-app.sh` version stamping, `actool`, signing.

## Standing refusals

Unchanged and not negotiable by a future audit's enthusiasm: no Phase 2 transport and no listener;
no exploits or PoCs; no Sparkle; no sandboxing the app as a surprise fix; no claim that
`MountPolicy` is race-free.
