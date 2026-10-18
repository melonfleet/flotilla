# Volume setup — 18 October 2026

Kamal's decided scope supersedes Iris's open questions: one root-directory chown,
no recursion, no seeding, and idempotent retries of pending operations.

`volumeOwner` is optional **per volume**, in both `container.volumes` and
`stack.services[].volumes`. No schema bump is required. For example:

```json
{"suffix":"data","path":"/var/lib/grafana","volumeOwner":{"uid":472,"gid":0}}
```

UID and GID must be JSON integers in 0…2147483647. Absence retains the previous
behavior. The presence of `volumeOwner` specifies the only supported setup policy:
chown the freshly created volume root once, retrying pending work. It cannot select
a helper, executable, flags, shell or seeding operation.

The built-in catalogue in this checkout contains Grafana, Prometheus and pgAdmin
(`pgadmin`, corresponding to the external library's `pgadmin4`). Their Suggestions
containers and stack services now declare volumes and the tested owners. The
other five recipes live in the separate library, not this mirror. The companion
`volume-owner-library.json` supplies all eight recipes' volume fragments for its
maintainer to merge into the tested entries without changing images or test claims.
Filebrowser's two volumes each carry the same pair. code-server, InvoiceNinja and
Ghost are unchanged. Jupyter's health check needs `/api` instead of `/hub/health`;
that separate library correction has deliberately not been made here.

The Run form carries policy only for its original image and unchanged suggested
mounts. It explicitly creates missing owned volumes; an existing volume is never
initialized merely because a recipe requests it. Stack creation records pending
ownership while creating volumes; Start initializes them before starting members.
Group Start and ordinary Run also resume matching pending receipts. Greta's drafts
retain their previous storage policy because they do not carry ownership metadata.

Creation writes `dev.melonfleet.flotilla.init=pending:<uid>:<gid>` and a unique
`dev.melonfleet.flotilla.init-operation` label. An atomic app state file,
`Application Support/dev.melonfleet.Flotilla/volume-setup.json`, records intent
before creation and `done:<uid>:<gid>` after successful foreground helper exit.
It is keyed by host identity (local or the peer fingerprint), volume and image,
and the operation label must still match before retrying. A replaced volume,
an imported volume, or a label without the app's own receipt cannot authorize setup.
A failed or disconnected helper leaves pending state; another start retries it.
The original creation label remains pending: completion in app state is authoritative.

The fallback to app state follows Iris's inspected 1.5.0 volume implementation:
there is no volume label-update operation. This VM reports container CLI 1.5.0,
but `container volume help` fails with “Operation not permitted” and
`container volume --help` only prints top-level help; label mutation has not been
live-tested here. State for remote volumes is held by this admin app under each
peer fingerprint, not synchronized between different admin Macs. Losing state
never turns a labeled existing volume into a fresh one.

All execution goes through ContainerCLI and its existing Allowlist, MountPolicy
and WirePolicy. The fixed request is:

```text
container run --rm -v NAME:/mnt docker.io/library/busybox@sha256:DIGEST chown UID:GID /mnt
```

The established Allowlist canonicalizes `-v` to `--volume`; its input-only `--`
separator is removed before execution. There is no shell, `-R`, host path, extra
mount, new flag, new wire command, package install or macOS administrator action.
The per-store lock prevents overlapping helper calls in this app. Progress says
“Setting up <volume> for <image>…”.

**Andy must fill `Allowlist.volumeSetupBusyboxDigestAndyMustFillFromRealPull` in
`Sources/FlotillaCore/Allowlist.swift` before shipping.** Put the 64 lowercase hex
digits from a real BusyBox pull/inspect there, and live-test the pinned helper and
recipes. The VM denies `container image inspect docker.io/library/busybox` with
“Operation not permitted”; registry metadata lookup failed because registry DNS
was unavailable. The constant is intentionally empty, and setup fails before
creating an owned volume rather than using a tag or an invented digest. Test pins
are explicitly synthetic and only enter through an internal test initializer.

Core tests exercise decoding/validation, the exact canonical helper argv and
remote policy, existing/untracked volume exclusion, pending → done receipts,
retry after failure/relaunch, host/image isolation, name replacement, deferred
stack initialization, metadata propagation, and a missing-pin refusal.

Validation on this mirror:

- `swift build` passes using `--build-system native --disable-sandbox`, with
  `TMPDIR`, Clang/Swift module caches and the SwiftPM cache redirected into `/tmp`
  because the default caches and swiftbuild temporary directory are sandbox-denied.
- `swift test --skip-build --no-parallel --filter FlotillaCoreTests`: 1,090 tests pass.
- Full `swift test --skip-build --no-parallel`: 1,148 tests, 34 failures, all the
  expected VM Keychain errors. No other failures. Parallel runs also exposed
  existing timing-sensitive runner checks; the serial final runs pass those checks.
- All eleven `Scripts/check-*.sh` pass, including `check-blocking.sh`.
- `git diff --check` and the patch's reverse-apply check pass. Nothing is committed.
  The sandbox denies writing `.git/index`; `git add -N` and `git diff` were instead
  run with a temporary index and object directory in `/tmp` to include new files
  in `/Users/example/out/volume-init.patch`. The real repository index is untouched.
