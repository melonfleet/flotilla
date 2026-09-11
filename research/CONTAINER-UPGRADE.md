# Apple `container` 1.0.0 → 1.4.1

**Research date:** 2026-09-11  
**Flotilla baseline:** `container CLI version 1.0.0 (build: release, commit: ee848e3)`  
**Latest release:** 1.4.1, released 2026-09-09  
**Distance:** six intermediate releases, or seven newer releases when 1.4.1 is included

## Evidence and limits

This report uses Apple's official GitHub release notes, the linked merged pull requests for CLI-
and schema-sensitive changes, the command reference at tags `1.0.0` and `1.4.1`, and Flotilla's
current allowlist, models, fixtures, and `research/UPSTREAM-GAPS.md`.

The requested unauthenticated REST calls were attempted, but this execution environment could
not resolve `api.github.com`; it was **not** a GitHub rate-limit response. The browser-backed
reader could read the same official rendered release bodies and linked PRs, but the complete
`1.0.0...1.4.1` REST compare payload remained unavailable. Therefore this report does not claim
that no undocumented CLI or payload change exists: where the releases, tagged documentation, and
linked PRs do not establish a fact, it says **unconfirmed**.

Primary index: [Apple `container` releases](https://github.com/apple/container/releases).

## Versions

| Version | Release date | Tag commit | Position |
|---|---:|---|---|
| [1.4.1](https://github.com/apple/container/releases/tag/1.4.1) | 2026-09-09 | `9a8917c` | latest |
| [1.3.1](https://github.com/apple/container/releases/tag/1.3.1) | 2026-08-29 | `a9a62e2` | intermediate |
| [1.3.0](https://github.com/apple/container/releases/tag/1.3.0) | 2026-08-24 | `d6de569` | intermediate |
| [1.2.2](https://github.com/apple/container/releases/tag/1.2.2) | 2026-08-08 | `0190097` | intermediate |
| [1.2.1](https://github.com/apple/container/releases/tag/1.2.1) | 2026-08-07 | `0d111be` | intermediate |
| [1.2.0](https://github.com/apple/container/releases/tag/1.2.0) | 2026-07-29 | `6e65319` | intermediate |
| [1.1.0](https://github.com/apple/container/releases/tag/1.1.0) | 2026-07-06 | `5973b9c` | intermediate |
| [1.0.0](https://github.com/apple/container/releases/tag/1.0.0) | 2026-06-09 | `ee848e3` | Flotilla baseline |

There was no 1.4.0 release; Apple discarded that tag and says 1.4.1 contains every change since
1.3.1.

## Changelog digest (newest first)

### 1.4.1 — 2026-09-09

- Added `container clean`, which trims unused filesystem space in running containers and their
  writable named-volume mounts. Its follow-up fix skips read-only root filesystems/mounts and
  aggregates per-path failures instead of stopping at the first one.
- Replaced the structured payload of `container system status` with a richer nested view covering
  client, host, server, paths, and container/image resource counts.
- The shared JSON renderer no longer escapes `/` as `\/`; `machine list --format json` now also
  uses that renderer while retaining ISO-8601 date encoding.
- Updated Containerization to 0.45.0 and fixed two security issues: OCI-layout symlink escape and
  Unix-socket path-length handling.

### 1.3.1 — 2026-08-29

- Updated Containerization to 0.42.0 for six disclosed security fixes: unchecked container IDs,
  OCI digest/path traversal, OCI-layout symlink host reads, registry-auth realm validation, and
  two crafted-image unpacking crashes.
- Fixed the source field produced for `--mount type=tmpfs`.
- Added an upstream `container` skill; this is tooling/documentation, not a Flotilla CLI feature.

### 1.3.0 — 2026-08-24

- **Breaking CLI change:** removed registry scheme `auto`; the default is now HTTPS. The release
  notes mark this as applying to image operations.
- Changed the default Kata kernel to the 3.32.0 debug build.
- Stopped applying the default OCI `maskedPaths` and `readonlyPaths` to container machines.
- Fixed tmpfs path processing and added validation around volume disk-usage identifiers.

### 1.2.2 — 2026-08-08

- Fixed release-package installation of the experimental `container k8s` plugin.
- Refactored Kubernetes plugin resource management and fixed a username/UID integration-test
  flake. No Flotilla core command or payload change is documented.

### 1.2.1 — 2026-08-07

- Added the experimental `container k8s` command family.
- Changed `container export` so a running container can be exported: the command automatically
  takes a runtime snapshot; no new `--live` flag is required.
- Added `container build --ssh default`.
- Added `container run`/`container create` flags `--read-only-path` and `--masked-path`.
- Adjusted guest overcommit and `max_map_count` defaults and added a readiness signal to the
  directory watcher.

### 1.2.0 — 2026-07-29

- Added repeatable `--kernel-arg <arg>` to `container run` and `container create`; user arguments
  override built-in kernel-command-line defaults by key.
- Fixed a builder-start race and increased the XPC timeout for machine API operations.
- Fixed five security issues involving image environment inheritance, unbounded pre-connect port
  buffering, build-context symlink disclosure (including resolved paths in JSON), and archive
  extraction permissions.
- Added kernel-archive integrity verification, including
  `container system kernel set --digest <digest>`, and further validation for image environments,
  build contexts, port forwarding, and plugin names.

### 1.1.0 — 2026-07-06

- Added nested virtualization and custom kernels for container machines.
- Made Unix-domain-socket mounts work for non-root containers and fixed `container copy` with a
  relative host source path.
- Made the default network refresh from system configuration and removed crash-prone force
  unwraps in process I/O and default-network handling.
- Graceful-stop failures are now logged instead of silently discarded; parser capacity hints are
  a small implementation-level performance improvement.

## What matters to Flotilla

### New commands and grammar Flotilla could expose

Every entry below is currently rejected by the default-deny table in
`Sources/FlotillaCore/Allowlist.swift` unless stated otherwise.

| Upstream addition | Exact CLI grammar | Flotilla touch point | Assessment |
|---|---|---|---|
| Reclaim space inside a running container | `container clean <container-id>...` (no command-specific flags) | New `CommandSpec`; `ContainerCLI`; a row/detail cleanup action in `ContainersView` / `ContainerDetailView` | Useful. It complements host-side `prune`/`system df` by trimming allocated ext4 images without deleting the container. It mutates guest filesystems and should be local-only or confirmation-gated over the wire. |
| Machine nested virtualization/custom kernel | `container machine create --virtualization --kernel <path> ...`; `container machine set virtualization=true|false kernel=<path>` (`kernel=` clears it) | Existing machine-create and machine-set specs; new closed value shapes; `MachineFormView`; `Flotillafile` only if declarative support is wanted | Niche but real. `--kernel` crosses host-path policy, and both settings materially widen the VM's capability, so neither should be added as a generic string. |
| Custom container kernel arguments | Repeatable `container run --kernel-arg <arg>` and `container create --kernel-arg <arg>` | Existing `run` spec and `RunSheetView`; `create` is not currently allowlisted | Expert-only and security-sensitive. Values are arbitrary boot configuration and need a dedicated bounded/repeatable shape, not `.keyValue` by assumption. |
| SSH-forwarded builds | `container build --ssh default` (only `default` is supported) | Existing build spec; `BuildImageView`; build execution options | Useful for private Git dependencies. It exposes the owner's SSH agent to the build, so it needs an explicit local-only/consent decision and a closed value set. |
| Extra path hardening | Repeatable `container run --read-only-path <path>` and `--masked-path <path>`; the same flags exist on `container create` | Existing `run` spec and `RunSheetView`; `create` is not allowlisted | Useful for hardened workloads. Each is a path **inside** the guest; `NONE` has special clearing semantics and must be modeled explicitly. |
| Verify a custom kernel archive | `container system kernel set --digest <digest>`; required when `--tar <tar>` is a remote URL | A new flag on the deliberately excluded `system kernel set` family | Sensible supply-chain hardening, but not a reason to expose this high-impact host mutation. If the family is ever admitted, `--digest` should be mandatory alongside remote `--tar` and constrained to a recognized digest form. |
| Experimental local Kubernetes | `k8s create` (`--name`, `--node-image`, `--rm`, `--cpus`, `--memory`, `--scheme`, `--max-concurrent-downloads`); `k8s start` (`--name`); `k8s delete`/`rm` (`--name`); `k8s list`/`ls`; `k8s load-image` (`--name`, `--platform`, image operand); `k8s write-config` (`--name`, `--kubeconfig`) | A wholly new allowlist family and UI feature, plus kubeconfig host-file policy | Not a small extension. Apple labels the family experimental and its commands modify kubeconfig, so it should remain out of Flotilla's current container/machine management surface unless Kubernetes becomes an explicit product feature. |

`container export` is not a new subcommand: it already existed in 1.0.0 and Flotilla deliberately
excluded it as a host-write/exfiltration surface. Its new live-container behavior makes it more
useful, but the existing security rationale still applies. If reconsidered, its exact flag is
`-o, --output <path>` and the stdout tar-stream form also needs a bounded-output design.

### Changed or removed behavior that could break Flotilla

1. **`system status` JSON was replaced (confirmed, highest risk).** The 1.0.0 fixture is flat:
   `status`, `apiServerAppName`, `apiServerBuild`, `apiServerCommit`, `apiServerVersion`,
   `appRoot`, and `installRoot`. In 1.4.1 the payload keeps top-level `status` but nests new
   `client`, `host`, `server`, `paths`, and `resources` objects; daemon-sourced objects may be
   omitted when the server is unavailable. `server.version` is now the bare version rather than
   the old composed version/build/commit sentence.

   `SystemStatus.status` will still decode, because Swift ignores unknown keys, so preflight's
   running check should survive. The old optional `apiServerVersion`, `appRoot`, and `installRoot`
   properties will silently decode as `nil`, however. This touches
   `Tests/FlotillaCoreTests/Fixtures/system-status.json`, `SystemStatus` in `Models.swift`,
   `ContainerCLI.systemStatus()`, preflight, and diagnostics. The upstream PR explicitly says the
   stopped/unregistered non-zero exit-code contract is unchanged.

2. **Registry `auto` was removed and the default became HTTPS (confirmed by the 1.3.0 release,
   exact breadth partly unconfirmed).** Flotilla does not allow or emit `--scheme`, so there is no
   renamed allowlist token to fix. The behavioral default still matters: `image pull`, and any
   implicit pull performed by `run`, `build`, or `machine create`, can no longer auto-downgrade a
   loopback/private registry to HTTP. Existing users of an HTTP development registry may fail
   even though Flotilla's argv is unchanged. The release says "image operations"; the tagged
   1.4.1 command-reference text still documents stale `auto` values, so the complete affected
   command list is **unconfirmed** until 1.4.1 leaf help is captured.

3. **All rendered JSON changes textually (confirmed) but not semantically.** `/` is no longer
   emitted as `\/`, and `machine list` moved to the common renderer. Foundation's JSON decoder
   treats both forms identically, so this should not break model decoding. It will make raw text
   and golden fixtures differ, including paths, image references, and URLs. The release documents
   no other list/inspect schema rewrite beyond `system status`; absence of undocumented field or
   type changes is **unconfirmed** without live 1.4.1 recapture.

4. **`export` now works while a container is running (confirmed).** Flotilla currently exposes
   neither the command nor its output, so this cannot break it. A future implementation must not
   retain the old "stopped only" assumption.

5. **Machine configuration grew (confirmed command grammar; inspect JSON impact unconfirmed).**
   `machine create` gained `--virtualization` and `--kernel`; `machine set` gained
   `virtualization=` and `kernel=` settings. The current `machineSetting` validator accepts only
   `cpus`, `memory`, and `home-mount`, correctly denying the new values today. Whether
   `machine list` or `machine inspect` serializes new fields for these settings is not stated in
   the release notes; recapture both fixtures before changing `ContainerMachine`.

6. **No other changed exit code is confirmed.** In particular, 1.4.1 explicitly preserves
   `system status`'s non-zero result for stopped/unregistered services. Error wording and numeric
   exit codes for every other Flotilla leaf remain **unconfirmed** until the live smoke matrix is
   rerun.

Apple's repository states that CLI stability is guaranteed only within a patch series. Moving
from 1.0.x to 1.4.x crosses four minor-version boundaries, so release-note silence is not a safe
compatibility guarantee.

### The five documented upstream limits

| `UPSTREAM-GAPS.md` item | 1.4.1 result | Consequence |
|---|---|---|
| 1. A machine cannot join a network | **Unchanged (confirmed command surface).** `machine create` still has no `--network`, and no later machine command attaches one. | No network picker in `MachineFormView`. |
| 2. A machine cannot mount a named volume or host path | **Unchanged (confirmed command surface).** Machine creation still offers only `--home-mount`; the new `--kernel` path is a boot-kernel choice, not a mount. | No volume/mount field in `MachineFormView`. |
| 3. Networks and volumes are creation-time only for containers | **Unchanged (confirmed command surface).** `network` still has create/delete/prune/list/inspect only; there is no `network connect`/`disconnect`, volume attach/detach, or equivalent container-update command. | Keep these controls in `RunSheetView`; no post-create attach action. |
| 4. A machine is not where containers run | **Unchanged at the CLI surface.** `run`/`create` still has no machine selector, and the new machine flags only configure persistent machines. The full internal topology was not re-measured on 1.4.1, so implementation-level continuity is **unconfirmed**. | Do not present machines as container hosts. |
| 5. `machine set-default` behavior is undocumented | **Behavior clarified; leaf-help change unconfirmed.** Apple's tagged reference says it selects the machine used by commands whose machine ID is optional; it does not choose where ordinary containers run. That sentence is also present in the tagged 1.0.0 reference, while Flotilla's captured 1.0.0 leaf help lacks it. Without live 1.4.1 `machine set-default --help`, whether the help gap itself closed is **unconfirmed**. | Flotilla can cite the official behavior in `Machines.md` and the row action's help text, but should not claim the CLI's leaf help improved until recapture. |

The first three product-blocking capability gaps remain; none of the new networking, mount, or
Kubernetes work supplies post-creation network/volume attachment or makes persistent machines the
container execution target.

### Performance and reliability for a polling GUI

- Flotilla's hot loop is `container ls` every five seconds and `stats` on its own interval; every
  sixth container tick it refreshes machines, images, volumes, and networks. No release reports a
  measured `ls`, `stats`, or structured-output speedup. The 1.1 parser capacity hints are likely
  positive but are unquantified.
- The 1.2.0 machine-XPC timeout increase directly reduces false machine-operation timeouts, and
  the builder-start race fix should reduce intermittent build failures. Default-network refresh,
  directory-watcher readiness, safer process I/O, and removed default-network force unwraps are
  useful reliability improvements around repeated refresh/action cycles.
- The port-forward buffering fix bounds memory before a guest connection is established; that is
  both a security and long-running-GUI reliability improvement.
- `system status` is richer and now performs resource-count work (container and image listing)
  when the daemon is available. Flotilla uses it for preflight, not its periodic five-second poll,
  so the extra work should not affect the normal polling loop. Do not add it to that loop without
  measuring it.
- `system df` accounting fixes mentioned around the 1.0 line predate the 1.0.0 baseline and are
  not an upgrade benefit. No claim is made that disk-usage collection became cheaper.

## Recommendation

**Upgrade to 1.4.1 now, but treat recapture as the upgrade gate rather than assuming 1.0.0
compatibility.** Thirteen disclosed security fixes across 1.2.0, 1.3.1, and 1.4.1 outweigh the
small migration cost. The known breaking points are manageable: adapt/review the `system status`
model after seeing a real 1.4.1 payload, test HTTP/private-registry behavior, and keep every new
command/flag denied until its security and value shape is designed. Do not expose experimental
`k8s` incidentally.

### Fixtures to recapture on a clean 1.4.1 installation

Recapture all 16 existing fixtures because the common JSON renderer changed and because the
complete compare payload was unavailable. The schema-critical ones are marked first.

- **Schema-critical:** `system-status.json`, `machine-inspect.json`, `machines.json`.
- **Core/list/inspect:** `containers.json`, `containers-ports.json`, `inspect-container.json`,
  `images.json`, `inspect-image.json`, `networks.json`, `inspect-network.json`, `volumes.json`,
  `inspect-volume.json`.
- **Metrics/system:** `stats.json`, `system-df.json`, `version.json`.
- **Text protocol:** `pull-progress.txt`.

For each JSON fixture, compare key names, nesting, required-vs-optional presence, value types,
date/unit conventions, array-vs-object top level, and stopped/empty-resource cases. Re-run the
explicit stopped-service `system status` capture as well as the running one, because 1.4.1 omits
daemon-sourced sections in that state.

### CLI-help files to recapture

Replace the `1.0.0` suffix with `1.4.1` and recapture **all 51 existing files**, grouped exactly
as follows:

- Root: `container--1.4.1-help.txt`, `container-1.4.1-help.txt`.
- Container/core leaves: `container-{build,copy,delete,exec,inspect,kill,list,logs,ls,prune,rm,run,start,stats,stop}-1.4.1-help.txt`.
- Image leaves: `container-image-{delete,inspect,list,prune,pull,rm,tag}-1.4.1-help.txt`.
- Machine parent/leaves: `container-machine-1.4.1-help.txt` and
  `container-machine-{create,delete,inspect,list,logs,run,set,set-default,stop}-1.4.1-help.txt`.
- Network leaves: `container-network-{create,delete,inspect,list,prune,rm}-1.4.1-help.txt`.
- System parent/leaves: `container-system-1.4.1-help.txt` and
  `container-system-{df,start,status,version}-1.4.1-help.txt`.
- Volume leaves: `container-volume-{create,delete,inspect,list,prune,rm}-1.4.1-help.txt`.

Add candidate-audit captures for `container-clean-1.4.1-help.txt`,
`container-export-1.4.1-help.txt`, `container-create-1.4.1-help.txt`, and
`container-system-kernel-set-1.4.1-help.txt`. If Kubernetes becomes in scope, also capture
`container-k8s-1.4.1-help.txt` and each of its six canonical leaves: `create`, `start`, `delete`,
`list`, `load-image`, and `write-config` (aliases `rm` and `ls` should be verified too).

The recapture review should diff every accepted `CommandSpec` for long/short spellings,
repeatability, operands, defaults, allowed enumerations, and aliases; separately smoke-test
success and failure exit codes for every command Flotilla actually invokes.

## Source links for the compatibility-sensitive findings

- [`container` 1.4.1 command reference](https://github.com/apple/container/blob/1.4.1/docs/command-reference.md)
  and [1.0.0 command reference](https://github.com/apple/container/blob/1.0.0/docs/command-reference.md)
- [`system status` payload redesign PR #1769](https://github.com/apple/container/pull/1769)
- [JSON slash-rendering PR #2205](https://github.com/apple/container/pull/2205)
- [machine nested-virtualization/custom-kernel PR #1742](https://github.com/apple/container/pull/1742)
- [repeatable `--kernel-arg` PR #1744](https://github.com/apple/container/pull/1744)
- [`run`/`create` path-hardening PR #2069](https://github.com/apple/container/pull/2069)
- [live-container export PR #1630](https://github.com/apple/container/pull/1630)
- [`container clean` PR #1949](https://github.com/apple/container/pull/1949) and
  [read-only mount fix PR #2228](https://github.com/apple/container/pull/2228)

---

## Verification pass — 2026-09-12

Iris wrote the report above without network access to `api.github.com` and marked several
findings **unconfirmed** for that reason. Those calls succeed from this session, so the
compatibility-sensitive claims were checked against primary sources: the releases API, and the
`command-reference.md` and Swift sources at tags `1.0.0` and `1.4.1`.

**Confirmed as written.** The release list and dates, all eight versions, no 1.4.0. The documented
command surface gains exactly two things: `container clean` (no command-specific flags) and six
`container k8s` leaves. Gaps 1–4 in `UPSTREAM-GAPS.md` are unchanged at the CLI surface —
`machine create` still has no `--network` and no mount option of any kind, there is still no
`container network connect`, and `run` still has no machine selector. `machine set` gained
`virtualization=<bool>` and `kernel=`, which the `machineSetting` closed set correctly refuses
today.

**A complete flag-level diff of every documented command** (1.0.0 → 1.4.1, ignoring
`--debug`/`--help`/`--version`) is shorter than the report implies:

| Command | Change |
|---|---|
| `container build` | `+ --ssh` |
| `container run`, `container create` | `+ --masked-path --read-only-path` |
| `container machine create` | `+ --kernel --virtualization` |
| `container system kernel set` | `+ --digest` |

Nothing was removed from any command Flotilla invokes. **No flag that Flotilla emits today
changed spelling, arity or value shape**, which is the fact the allowlist actually depends on and
the one the report could not establish.

### Two corrections

1. **`--kernel-arg` does not exist in the 1.4.1 reference.** The table above lists "repeatable
   `container run --kernel-arg <arg>`" as available grammar, taken from the 1.2.0 release notes.
   The string `kernel-arg` does not appear anywhere in `command-reference.md` at tag 1.4.1, and
   the flag diff finds it on neither `run` nor `create`. Treat it as not present until a live
   `--help` says otherwise; it should not be planned against.

2. **`--scheme auto` — the docs and the release notes disagreed, and the binary settled it.**
   The tagged 1.4.1 reference still reads `values: http, https, auto; default: auto`, exactly as
   1.0.0 does. The installed 1.4.1 says otherwise:

   ```
   --scheme <scheme>  Scheme to use when connecting to the container
                      registry. One of (http, https) (default: https)
   ```

   So the release note was right and the tagged reference is stale — which is the whole argument
   for capturing leaf help from the binary rather than reading the repository's documentation.

   **Consequence, and it is a real one.** Flotilla emits no `--scheme`, so the allowlist needed no
   rename; but that also means Flotilla can no longer pull from a plain-HTTP registry *at all*,
   where 1.0.0 would silently downgrade. Anyone running a loopback or private HTTP registry loses
   image pulls through the app with no way to ask for HTTP. Adding `--scheme` to the `image pull`
   spec as a closed `http|https` set would restore it; that is a decision, not an oversight, and
   it should be taken deliberately — sending credentials or image layers over plaintext is
   exactly the kind of thing a default-deny table exists to make somebody choose.

### The `system status` redesign is real, and it breaks nothing here

Read from source rather than release notes. `StatusPayload` at 1.4.1:

```swift
status: String
client: ClientInfo?        // version, build, commit, appName
server: ServerInfo?        // version, build, commit, appName
host: HostInfo?            // architecture, operatingSystem, cpus
paths: PathInfo?           // appRoot, installRoot, logRoot?
resources: ResourceCounts? // containersTotal, containersRunning, images?
```

`SystemStatus` in `Models.swift` declares `status`, `apiServerVersion?`, `appRoot?` and
`installRoot?`. On 1.4.1 `status` still decodes and the other three become `nil` — their values
moved to `server.version`, `paths.appRoot` and `paths.installRoot`.

**And nothing reads them.** `Preflight` uses only `status`/`isRunning`; `flotilla-probe` prints
only `status.status`; the diagnostics snapshot has an `apiServerVersion` field of its own that is
never filled from this type. So the report's highest-risk item costs a fixture refresh and the
deletion of three dead properties — or wiring them to the new nested paths, if the version and
roots are wanted after all. It is not a decode break and preflight cannot regress.

The stopped/unregistered contract is unchanged in source: both versions
`Application.exit(withError: ExitCode(1))`, and 1.4.1 renders `status: "unregistered"` before
doing so.

### Upgrade performed — 2026-09-12

Installed from Apple's signed, notarised `container-1.4.1-installer-signed.pkg` (`Developer ID
Installer: Apple Inc. - Containerization`, UPBK2H6LZM). What the upgrade actually found:

**The one thing no release note mentions: the service must be restarted, or nothing works.**
After installing, `container system status` reported `running`, every already-running container
kept running, and **every new container and machine failed to start** with

```
no available interface strategy for network default, plugin=container-network-vmnet variant=nil
```

`container system stop && container system start` fixed it completely. The cause is visible in
the new payload and only there: `client.version` was `1.4.1` while `server.version` was still
`container-apiserver version 1.0.0` — the old daemon and its network plugins were still resident.
`Fixtures/system-status-version-skew.json` is that state, captured. Flotilla now detects it
(`SystemStatus.hasVersionSkew` → `PreflightResult.needsRestart`) and offers the restart, which
turns an inexplicable failure into a sentence and a button. That detection is only possible
*because* the payload was redesigned, so the upgrade's riskiest change paid for itself.

**Fixtures:** all 14 machine-capturable ones recaptured with `Scripts/capture-fixtures.sh`. A
shape diff of every one — key paths and value types, array indices collapsed — found exactly one
genuine schema change, `system-status`, which was already handled. Everything else that looked
like a change was a different subject: the old set described one purpose-made container and two
networks, the new one describes a real fleet. `image list` does now embed each variant's full
`config`, which is payload growth rather than a schema break and is worth remembering before
anyone puts `image list` in a polling loop.

**Gaps:** all six re-run against the binary. All hold. Two footnotes: a booted machine now takes
an address on the *container* subnet rather than its own, and `machine set-default --help` still
explains nothing even though the tagged reference does.

**Tests:** 378 green. The assertions that broke were all naming the old fixtures' subjects by
array position; they name them by id now, so the next recapture is a two-line change rather than
forty.

### What still needs the real binary

Everything the report lists under recapture, for the reason it gives — CLI stability is only
promised within a patch series and four minor boundaries are being crossed. But the gate is
narrower than "all 51 help files are suspect": the flag diff above is primary-source evidence
that the *documented* grammar Flotilla uses did not move. Recapture is to catch what the docs do
not say — undocumented payload fields, the `auto` contradiction, and exit codes.

Priority order for a 1.4.1 smoke: `system status` (running and stopped), `machine list` and
`machine inspect` (new settings may serialize), then the remaining list/inspect fixtures for the
`\/` rendering change, then `image pull` against an HTTP registry.
