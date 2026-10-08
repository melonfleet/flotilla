# Apple `container`: a reference for Flotilla

Scope: **`container` 1.0.0**, which is what Flotilla targets and what produced the
fixtures in `Tests/FlotillaCoreTests/Fixtures/*.json`. Every claim below is one of:

- **documented** — stated in Apple's docs at the `1.0.0` tag (linked), or in source at that
  tag (linked with line numbers);
- **observed** — visible in our own fixtures (`Tests/FlotillaCoreTests/Fixtures/*.json`),
  which are real captures from a running `container 1.0.0`;
- **reported** — a claim made in an open GitHub issue against `apple/container`, i.e. a
  maintainer or user's account, not independently confirmed by us;
- **unverified** — I could not confirm it and say explicitly what would confirm it. This
  document has no other category; if a claim isn't tagged one of the first three, treat it
  as unverified.

I do not have a Mac or a `container` install in this environment, so nothing here is
"observed" except by way of the checked-in fixtures. Where the current `main` branch of
`apple/container` disagrees with the `1.0.0` tag, I fetched `1.0.0` explicitly (e.g.
`https://raw.githubusercontent.com/apple/container/1.0.0/docs/command-reference.md`) rather
than `main`, since `main` now reflects `1.2.0` (released 2026-07-29, the most recent of three
releases since 1.0.0: 1.0.0 → 1.1.0 → 1.2.0). I did not audit 1.1.0/1.2.0 changes in depth;
where a 1.0.0→later change is relevant I call it out, sourced from GitHub release notes.

Primary sources used throughout, all pinned to the `1.0.0` tag unless noted:

- [`docs/command-reference.md`](https://github.com/apple/container/blob/1.0.0/docs/command-reference.md) — the full CLI surface (1566 lines, read in full)
- [`docs/technical-overview.md`](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md)
- [`docs/how-to.md`](https://github.com/apple/container/blob/1.0.0/docs/how-to.md) (883 lines, read in full)
- [`docs/container-system-config.md`](https://github.com/apple/container/blob/1.0.0/docs/container-system-config.md) — `config.toml` reference
- [`README.md`](https://github.com/apple/container/blob/1.0.0/README.md)
- Source under `Sources/ContainerCommands/` at the `1.0.0` tag, for cases where the docs are
  silent or where I wanted to confirm behavior against the implementation
- `apple/container` issue tracker (`api.github.com/search/issues`), for gaps and known bugs
- `Tests/FlotillaCoreTests/Fixtures/*.json` in this repo — real `container 1.0.0` captures
- [`apple/swift-argument-parser`](https://github.com/apple/swift-argument-parser) source/docs, to explain one CLI parsing bug precisely

---

## 1. Architecture

**Documented.** `container` does not run a shared daemon the way `dockerd` does. Per
[technical-overview.md](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md):

- Every container gets **its own lightweight VM**, built on the open-source
  [Containerization](https://github.com/apple/containerization) Swift package, using the
  macOS **Virtualization framework**. There is no shared kernel between containers the way
  there is in a Docker daemon's one big Linux VM (on macOS, via Docker Desktop) or literal
  shared-kernel namespaces (on Linux).
- `container-apiserver` is a **launchd-managed launch agent**, started/stopped by
  `container system start` / `container system stop` — not a persistent daemon that survives
  logout. It has no memory of container commands between service starts other than what's
  persisted to disk.
- On start, `container-apiserver` launches XPC helpers: `container-core-images` (image
  management / local content store) and `container-network-vmnet` (virtual networking, via
  the **vmnet** framework). For **each container**, it spawns a separate
  `container-runtime-linux` helper that exposes that one container's management API.
- IPC is XPC throughout, not a REST/gRPC socket the way `dockerd` exposes.
- Registry credentials go through **Keychain**, not a `~/.docker/config.json`-style plaintext
  file (though `container system property list`/`config.toml` do hold non-secret registry
  defaults — see §6).

**What the one-VM-per-container model implies (documented + reasoned from the above):**

- **Start-up cost**: every `container run`/`create` boots a Linux micro-VM via kata's kernel
  (see §6, `[kernel]`), not a `fork()`+namespace-setup the way Docker starts a container. This
  is inherently slower per-container than Docker's model, though the project markets boot
  time as "comparable to containers running in a shared VM" (their words, unverified against
  a stopwatch by us).
- **Resource use**: [technical-overview.md §"Releasing container memory to macOS"](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md#releasing-container-memory-to-macos)
  documents that the macOS Virtualization framework only **partially** supports memory
  ballooning. Memory freed inside a container's Linux VM is **not relinquished to the host**.
  A container started with `--memory 16g` may show only 2 GiB used in Activity Monitor, and
  that allocation is not given back until the container is restarted. This is a real,
  documented, currently-unaddressed limitation — worth surfacing in Flotilla's resource UI
  (e.g. "host memory reclaimed on restart," not "host memory freed on idle").
- **Networking**: each container is a full VM with its own interface on a vmnet network (see
  §7); there's no shared-kernel bridge/veth model to reason about the way there is on Linux
  Docker.
- **Nested virtualization**: this is *not* discussed by Apple's docs as a general constraint
  on `container` itself — it's specific to Flotilla's own dev environment (M2 Max laptop,
  UTM macOS guest can't nest virtualize `container`'s micro-VMs), already documented in
  `CLAUDE.md`. Separately, `container` has a **feature** called `--virtualization` that
  exposes virtualization capabilities *inside* a container so that guest can itself run VMs;
  that requires **M3 or newer** silicon and a specially-configured guest kernel — see §8. Do
  not conflate the two: one is "can `container` run at all inside our nested dev VM," the
  other is "can a container's own guest run a VM."

**macOS 15 vs 26** (documented, [technical-overview.md](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md#macos-15-limitations)):
`container` targets **macOS 26**. It *can* run on macOS 15 but with real functional gaps that
Apple says they won't fix:
- No container-to-container networking at all (each container is isolated even on the same
  network).
- No `container network` commands — multiple networks aren't supported; `--network` on
  `run`/`create` errors out.
- A race between the network XPC helper and vmnet can leave containers with **no network
  access at all** on first boot, because vmnet's subnet and the network helper's assumed
  subnet can disagree — see [troubleshooting.md#all-networking-fails-on-macos-15](https://github.com/apple/container/blob/main/docs/troubleshooting.md) (unverified — I could not fetch `troubleshooting.md` at the `1.0.0` tag; it may not have existed yet at that tag. **Unverified**: whether this file existed at 1.0.0).

Flotilla's own environment note in `CLAUDE.md` says development is on macOS 26, so the macOS
15 gaps are almost certainly moot for this project, but worth knowing if a support-bundle
ever comes in from an older Mac.

---

## 2. The complete CLI surface (`container` 1.0.0)

This is the full command tree as documented at the `1.0.0` tag, cross-checked in places
against source. I've flagged every gotcha the task asked about and any others I found by
reading the actual `@Argument`/`@Flag`/`@Option` declarations, not just prose docs.

### 2.1 Core lifecycle (`container run` / `build`)

**`container run [<options>] <image> [<arguments>...]`** — documented in full at
[command-reference.md#container-run](https://github.com/apple/container/blob/1.0.0/docs/command-reference.md#container-run).
Full flag set (this is exhaustive, not our old abbreviated list):

- Process: `-e/--env`, `--env-file`, `--gid`, `-i/--interactive`, `-t/--tty`, `-u/--user`,
  `--uid`, `--ulimit`, `-w/--workdir/--cwd`
- Resources: `-c/--cpus`, `-m/--memory`
- Management: `-a/--arch` (default `arm64`), `--cap-add`, `--cap-drop`, `--cidfile`,
  `-d/--detach`, `--dns`, `--dns-domain`, `--dns-option`, `--dns-search`, `--entrypoint`,
  `--init`, `--init-image`, `-k/--kernel`, `-l/--label`, `--mount`, `--name`, `--network`,
  `--no-dns`, `--os` (default `linux`), `-p/--publish`, `--platform`, `--publish-socket`,
  `--read-only`, `--rm/--remove`, `--rosetta`, `--runtime` (default `container-runtime-linux`),
  `--ssh`, `--shm-size`, `--tmpfs`, `-v/--volume`, `--virtualization`
- Registry: `--scheme` (`http`/`https`/`auto`, default `auto`)
- Progress: `--progress` (`auto|none|ansi|plain|color`)
- Image fetch: `--max-concurrent-downloads` (default `3`)

One flag I could **not** find in this doc despite it being called out in the `1.0.0` release
notes: [release notes for 1.0.0](https://github.com/apple/container/releases/tag/1.0.0) list
*"Add `--stop-signal` option for `container run`"* citing
[apple/container#1581](https://github.com/apple/container/issues/1581). It does not appear
anywhere in `docs/command-reference.md` at the `1.0.0` tag, nor did I find it in
`Sources/ContainerCommands/Container/ContainerRun.swift` at that tag. **Unverified**: whether
`--stop-signal` shipped as documented in 1.0.0, was reverted, or landed under a different
name. Confirm with `container run --help` on the actual Mac before relying on it.

`container create [<options>] <image> [<arguments>...]` takes the identical flag set to `run`
minus `-d/--detach` semantics (it just doesn't start), and leaves the container stopped.

**`container build [<options>] [<context-dir>]`** is a **top-level command** — see §9,
correction 1: our own `reference/container-cli.md` currently mislabels this as
`container image build`. It doesn't exist under `container image` at all.

`container` **does** use BuildKit for builds — the task brief's speculative Docker-gap list
asked "no BuildKit-equivalent?"; that assumption is wrong and should not carry forward. Per
[technical-overview.md](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md)
and [container-system-config.md `[build]`](https://github.com/apple/container/blob/1.0.0/docs/container-system-config.md#build):
`container build` spins up a builder VM running `container-builder-shim`, image
`ghcr.io/apple/container-builder-shim/builder:<tag>`, which wraps BuildKit. Flags: `-a/--arch`
(repeatable, for multi-arch builds), `--build-arg`, `-c/--cpus` (default `2`), `--dns*`,
`-f/--file`, `-l/--label`, `-m/--memory` (default `2048MB`), `--no-cache`,
`-o/--output type=<oci|tar|local>[,dest=]` (default `type=oci`), `--os`, `--platform`,
`--progress`, `--pull`, `-q/--quiet`, `--secret id=<key>[,env=<VAR>|,src=<path>]`, `-t/--tag`
(repeatable), `--target`, `--vsock-port` (default `8088`). Default file lookup order:
`Dockerfile`, then `Containerfile`.

Builder lifecycle is a **separate command group**: `container builder start|status|stop|delete`.
`start` takes `-c/--cpus` (default `2`), `-m/--memory` (default `2048MB`), and DNS flags.
`status --format json` gives machine-readable builder state.

### 2.2 Container management

| Command | Key flags | Gotchas |
|---|---|---|
| `container start <id>` | `-a/--attach`, `-i/--interactive` | |
| `container stop [<ids>...]` | `-a/--all`, `-s/--signal` (default `SIGTERM`), `-t/--time` (default `5`) | |
| `container kill [<ids>...]` | `-a/--all`, `-s/--signal` (default **`KILL`**) | **No `--time`/`-t` flag exists at all** — confirmed in source: [`ContainerKill.swift:37`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Container/ContainerKill.swift#L37), `var signal: String = "KILL"`. `stop` sends `SIGTERM` by default and waits; `kill` sends `KILL` by default and doesn't. |
| `container delete`/`rm [<ids>...]` | `-a/--all`, `-f/--force` | |
| `container list`/`ls` | `-a/--all`, `--format`, `-q/--quiet` | Running-only by default |
| `container exec <id> <args>...` | `-d/--detach`, `-e/--env`, `--env-file`, `--gid`, `-i`, `-t`, `-u/--user`, `--uid`, `-w/--workdir` | **See §2.5 — `--` separator bug, confirmed in source, not just folklore.** |
| `container export [-o <out>] <id>` | `-o/--output` (stdout if omitted) | **Container must already be stopped.** Doc: "The container must be stopped before exporting." Our reference doc doesn't currently note this constraint — see §9. |
| `container logs <id>` | `--boot`, `-f/--follow`, `-n <n>` | `--boot` shows the VM boot + `vminitd` log, not app stdout |
| `container inspect <ids>...` | none — always JSON, no `--format` | Returns a JSON **array**, one element per id, confirmed both in docs and our fixture (§4) |
| `container stats [<ids>...]` | `--format`, `--no-stream` | Interactive `top`-style by default; `--no-stream` for one snapshot |
| `container copy`/`cp <src> <dst>` | none | One side must be `container_id:path` |
| `container prune` | none | **Top-level**, not `container container prune` — confirmed correct in our existing notes |

There is **no `container restart` command** — confirmed by reading the full command reference;
the "Container Management" group is `create, start, stop, kill, delete, list, exec, export,
logs, inspect, stats, copy, prune`, nothing else. To restart, you `stop` then `start`
yourself. See §5 for how this compares to Docker.

### 2.3 Image management

`container image list/ls`, `pull`, `push`, `save`, `load`, `tag`, `delete/rm`, `prune`,
`inspect`. Notable specifics beyond our old summary:

- `image save [-a/--arch] [--os] -o/--output <path> [--platform] <references>...` — **takes
  multiple references** into a single tar, and `--output` is a required flag (not bracketed
  as optional in the usage grammar), unlike our old note which implied a single `<ref>`.
- `image load -i/--input <path> [-f/--force]` — `--force` ("Load images even if invalid
  member files are detected") wasn't in our old notes.
- `image prune [-a/--all]` — default only removes **dangling** (untagged) images; `-a` removes
  all images unreferenced by any container.
- There is **no `container image build`** — see §2.1 and §9.
- There is **no `container commit`** (turning a running container into an image) anywhere in
  the CLI — confirmed absent from the full command reference. This is a real Docker gap not
  in the task's original candidate list; see §5.

### 2.4 Network / volume / registry / system / machine

**Network** (macOS 26+ only — see §1): `create`, `delete/rm`, `prune`, `list/ls`, `inspect`.
`network create <name> [--internal] [--label] [--option] [--plugin <plugin>]
[--subnet <cidr>] [--subnet-v6 <cidr>]` — our old notes omit `--plugin` (default
`container-network-vmnet`) and `--subnet-v6` entirely; see correction in §9. **There is no
`network connect`/`disconnect`** — a running container's networks are fixed at
`create`/`run` time; you cannot attach/detach a live container from a network the way
`docker network connect` allows. Confirmed absent from the full command reference.

**Volume**: `create`, `delete/rm`, `prune`, `list/ls`, `inspect`. `volume create <name>
[--label] [--opt key=value] [-s <size>]`. Driver options for the (only) `local` driver:
`size=<value>` and `journal=<ordered|writeback|journal>[:<size>]`. Anonymous volumes
(`-v /path` with no source, or `--mount type=volume,dst=/path`) get UUID names
(`anon-{uuid}`) and — unlike Docker — **do not auto-delete with `--rm`**; this is called out
explicitly in the docs as a Docker-behavior divergence. See §8.

**Registry**: `login [--scheme] [--password-stdin] [-u/--username] <server>`, `logout
<server>`, `list [--format]`. Credentials go to Keychain (§1), not a config file.

**System**: `start`, `stop`, `status`, `version`, `logs`, `df`, `dns create/delete/list`,
`kernel set`, `property list`. Two format-support exceptions worth knowing precisely (I read
every `--format` line in the doc to build this):
- `container machine list` supports only `json`/`table` — **no `yaml`/`toml`**, unlike every
  other `--format`-bearing command.
- `container system property list` supports only `json`/`toml`, **defaulting to `toml`** — no
  `table`/`yaml`.
- Every other `--format`-bearing command (`list`, `stats`, `builder status`, `image list`,
  `network list`, `volume list`, `registry list`, `system status`, `system version`,
  `system df`, `system dns list`) supports the full `json|table|yaml|toml` set, default
  `table`.
- All `inspect` subcommands (`container`, `image`, `network`, `volume`, `machine`) take **no
  `--format` flag at all** — confirmed "No options." in the doc for every one — they always
  emit JSON.

`system start` flags: `-a/--app-root`, `--install-root`, `--log-root`,
`--enable-kernel-install`/`--disable-kernel-install`, `--timeout`. `system stop` takes
`-p/--prefix` (default `com.apple.container.`) to target a differently-prefixed launchd
namespace — not previously in our notes. `system dns create`/`delete` **require sudo**
(documented explicitly). `system kernel set` flags: `--arch` (`amd64`/`arm64`, default
`arm64`), `--binary`, `--force`, `--recommended`, `--tar`.

**`container machine` (aka `container m`)** — see §9, correction 2: this is **not** "the host
VM/runtime," and our own notes currently mischaracterize it that way. It's a separate,
additive feature: a **persistent, general-purpose Linux dev environment** booted from a
regular OCI image (any image with `/sbin/init`), auto-provisioned with a user matching your
host account and passwordless sudo, home directory mounted read-write by default. It exists
alongside the ephemeral per-container micro-VMs, not as infrastructure underneath them.
Subcommands: `create`, `run`, `list/ls`, `inspect`, `set`, `set-default`, `logs`, `stop`,
`delete/rm`. `container machine create <image> [-n/--name] [--set-default] [--no-boot]
[--cpus] [--memory] [--home-mount ro|rw|none]`. `machine run [-n/--name] [-d/--detach] [--root]
[<executable>] [<arguments>...]` opens an interactive login shell if no command is given.

### 2.5 The `exec --` bug — root-caused, not just observed

The task brief states `exec` "rejects a `--` separator (it treats `--` as the executable and
fails)." I confirmed this precisely, at the source level, rather than taking it on faith:

- [`ContainerExec.swift:43`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Container/ContainerExec.swift#L43):
  `@Argument(parsing: .captureForPassthrough, help: "New process arguments") var arguments: [String]`
- [`ContainerExec.swift:56`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Container/ContainerExec.swift#L56):
  `config.executable = arguments.first!`
- Swift ArgumentParser's own doc comment for `.captureForPassthrough`
  ([`Argument.swift`](https://github.com/apple/swift-argument-parser/blob/main/Sources/ArgumentParser/Parsable%20Properties/Argument.swift), lines ~286–295)
  states explicitly: *"With the `captureForPassthrough` parsing strategy, the `--` terminator
  is included in the captured values,"* with a worked example showing `-- --other` producing
  `["--", "--other"]` in the captured array — the leading `--` is **not** stripped.

So `container exec <id> -- ls -la` parses `arguments` as `["--", "ls", "-la"]`, and
`arguments.first!` — `"--"` — becomes the executable `container` tries to run inside the
container, which fails (there's no binary literally named `--`). This is a genuine CLI
footgun, not user error: any script that defensively writes `exec <id> -- <cmd>` (a normal,
idiomatic habit for guarding against a command that looks like a flag) will break.

**Why doesn't this happen for `container machine run -- <cmd>`?** The documented example
[`container machine run -n my-machine -- cat /proc/cpuinfo`](https://github.com/apple/container/blob/1.0.0/docs/command-reference.md#container-machine-run)
and the how-to's [`container machine run -n my-machine -- nproc`](https://github.com/apple/container/blob/1.0.0/docs/how-to.md#manage-container-machines)
both use `--` successfully. The structural difference: `MachineRun` declares a plain,
non-array `@Argument var executable: String?` ([`MachineRun.swift:51`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Machine/MachineRun.swift#L51))
*before* its own `captureForPassthrough` `arguments` array
([`MachineRun.swift:54`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Machine/MachineRun.swift#L54)).
A leading `--` in front of an ordinary (non-array) positional is consumed as a normal
end-of-options terminator by ArgumentParser and stripped before that positional is filled, so
`executable` becomes `cat` and only `/proc/cpuinfo` reaches the passthrough array. `exec` has
no such intermediate plain positional between `containerId` and the passthrough `arguments`
array, so the `--` lands directly in the array it is never stripped from.

**Unverified**: whether `container run <image> -- <args>` and `container create <image> --
<args>` have the *same* footgun as `exec`, or whether they behave like `machine run` because
`<image>` is *also* an ordinary non-array positional before their passthrough `arguments`
array ([`ContainerRun.swift:62`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerCommands/Container/ContainerRun.swift#L62),
same pattern as `MachineRun`). Structurally, `run`/`create` look like `machine run`
(plain positional, then passthrough array), which suggests `--` is *safe* there and the bug
is specific to `exec`'s "id immediately followed by passthrough array" shape — but I have not
run either command to confirm, and ArgumentParser's exact stripping rule for a `--` sitting
between two different positional argument declarations is not something I could pin down
from the doc comment alone. **What would confirm it**: literally running
`container run --rm alpine -- echo -- hi` on the Mac and checking whether `echo` receives
`--` and `hi` or fails the way `exec` does. Do not assume `run`/`create` are safe until tested.

---

## 3. JSON output survey

Format support is covered exhaustively in §2.4. What each payload actually contains, cross-
checked against our own fixtures (all real `container 1.0.0` captures):

### `container inspect` / `container ls --format json`

Both are keyed off the same underlying container resource shape. Confirmed from
[`Tests/FlotillaCoreTests/Fixtures/inspect-container.json`](../Tests/FlotillaCoreTests/Fixtures/inspect-container.json)
and [`containers.json`](../Tests/FlotillaCoreTests/Fixtures/containers.json):

- **Top-level is a JSON array**, even for a single container. `container inspect web-demo`
  returns `[ { ... } ]`, one element. This applies to `container image inspect`,
  `network inspect`, `volume inspect`, `machine inspect` too — confirmed same shape in
  [`inspect-image.json`](../Tests/FlotillaCoreTests/Fixtures/inspect-image.json) (not
  independently confirmed for network/volume/machine inspect — we have no fixture for those,
  **unverified** beyond the doc's "No options" / implicit-JSON framing).
- `id` (top-level) and `configuration.id` are **the same string as the container's name** —
  e.g. both are `"web-demo"` in our fixture. There is no separate short-hash id the way Docker
  gives you a name *and* a hex container ID; the name **is** the id. Confirmed identically in
  every container fixture we have (`flotilla-probe-test`, `web-demo`, `flotilla-portprobe`,
  `range-demo`, `no-ports`).
- Structure: `configuration` (the full launch spec: image descriptor+reference, `initProcess`
  executable/args/env/user/cwd, `resources` (`cpus`, `memoryInBytes`, `cpuOverhead`),
  `networks[]`, `publishedPorts[]` (`containerPort`, `hostAddress`, `hostPort`, `proto`,
  `count`), `mounts[]`, `capAdd`/`capDrop`, `dns`, `platform`, `readOnly`, `rosetta`,
  `runtimeHandler`, `ssh`, `sysctls`, `useInit`, `virtualization`) plus a top-level `status`
  (`state`, `startedDate`, `networks[]` with live `ipv4Address`/`ipv4Gateway`/`ipv6Address`/
  `macAddress`/`hostname`/`mtu`).
- Note [`how-to.md`](https://github.com/apple/container/blob/1.0.0/docs/how-to.md#get-container-or-image-details)'s
  own worked `jq` example shows a **different, flatter shape** (`status` as a bare string,
  `address` instead of `ipv4Address`, `hostname` at top level of the network entry with a
  trailing dot) than what our fixtures show. This looks like the docs' example predates the
  "Cleaned up structured (JSON, YAML, TOML) output shape" breaking change called out in the
  [1.0.0 release notes](https://github.com/apple/container/releases/tag/1.0.0) (citing
  [#1656](https://github.com/apple/container/pull/1656)). **Trust the fixtures over the
  how-to.md prose example** — the fixtures are real 1.0.0 captures; the how-to snippet may be
  stale relative to that same release. Flag for the app owner: `how-to.md`'s JSON example is not
  reliable for schema purposes.

### `container image list` / `image inspect`

From [`images.json`](../Tests/FlotillaCoreTests/Fixtures/images.json) and
[`inspect-image.json`](../Tests/FlotillaCoreTests/Fixtures/inspect-image.json): top-level
array; each entry has `configuration` (`creationDate`, `descriptor` with `digest`/
`mediaType`/`size`, `name`), `id` (== the manifest digest, **not** the same as `container`
ids — images use their content digest as id, containers use their given name), and
`variants[]` (per-platform: `digest`, `platform`, `size`, and for `inspect`, the full OCI
`config` blob with `Cmd`, `Env`, `WorkingDir`, `history`, `rootfs.diff_ids`).

### `container stats --format json`

From [`stats.json`](../Tests/FlotillaCoreTests/Fixtures/stats.json): flat array, one object
per container — `id`, `cpuUsageUsec`, `memoryUsageBytes`, `memoryLimitBytes`,
`networkRxBytes`, `networkTxBytes`, `blockReadBytes`, `blockWriteBytes`, `numProcesses`. Note
this is **cumulative CPU microseconds**, not a percentage — the human-readable `Cpu %` shown
in `container stats`'s table/interactive mode (per
[how-to.md](https://github.com/apple/container/blob/1.0.0/docs/how-to.md#monitor-container-resource-usage))
must be computed client-side from successive `cpuUsageUsec` deltas; `--no-stream --format
json` gives you one raw sample, not a rate.

### `container system df --format json`

From [`system-df.json`](../Tests/FlotillaCoreTests/Fixtures/system-df.json): `containers`,
`images`, `volumes`, each with `total`, `active`, `sizeInBytes`, `reclaimable`. No `build
cache` category the way `docker system df` reports build cache usage separately — consistent
with there being no unified `docker system prune`-style cache GC either (§5).

### `container system version --format json`

From [`version.json`](../Tests/FlotillaCoreTests/Fixtures/version.json): array of one or two
entries (`container` CLI always; `container-apiserver` only if it responds to a health
check) — `appName`, `buildType`, `commit`, `version`. Matches
[command-reference.md](https://github.com/apple/container/blob/1.0.0/docs/command-reference.md#container-system-version)'s
documented shape exactly, including the apiserver's `version` field being a full sentence
rather than a bare semver.

### `container system status`

Our [`system-status.json`](../Tests/FlotillaCoreTests/Fixtures/system-status.json) fixture
(non-array, single object: `status`, `appRoot`, `installRoot`, `apiServer*`) does **not**
match the `--format json` array-of-components shape documented for `system version` — it's a
distinct payload with its own shape, not to be confused with `version`. `appRoot` in the
fixture is `/Users/user/Library/Application Support/com.apple.container/` (username
redacted in the fixture) and `installRoot` is `/usr/local/` — i.e. **state lives under
`~/Library/Application Support/com.apple.container/`** by default, executables under
`/usr/local/`, both overridable via `system start --app-root`/`--install-root`.

### `container network list` / `volume list`

[`networks.json`](../Tests/FlotillaCoreTests/Fixtures/networks.json): `id`, `state`, `mode`
(`"nat"`), `subnet`, `gateway`, `labels`. [`volumes.json`](../Tests/FlotillaCoreTests/Fixtures/volumes.json):
`name`, `format` (`"ext4"`), `source` (host path under
`/var/lib/container/volumes/<name>/_data`), `createdAt`, `sizeInBytes`, `labels`, `options`.

### Ports: `containers-ports.json`

Confirms `publishedPorts[]` entries have a `count` field for **port ranges** — our
`range-demo` fixture entry shows `containerPort: 7000, hostPort: 7000, count: 3, proto: "udp"`,
i.e. a single `publishedPorts` entry can represent a contiguous range of `count` ports
starting at `containerPort`/`hostPort`, not one entry per port. Worth getting right in
Flotilla's port-range rendering.

### Not fixture-covered — unverified schemas

We have **no fixtures** for `container registry list`, `network inspect`, `volume inspect`,
`machine list`/`inspect`, `builder status --format json`, or `system dns list`. Their field
names are **unverified** beyond whatever prose the docs give (which for most of these is just
"No options" / "Format of the output"). Do not hand-write decoders for these against assumed
field names — capture real output first, the way the existing fixtures were captured.

---

## 4. What Docker has that `container` does not

Every item below is **reported/confirmed via the issue tracker or an explicit doc statement**,
not assumed. I searched `apple/container` issues for each candidate in the task brief plus a
few I found by reading the full CLI surface.

| Docker feature | Status in `container` 1.0.0 | Evidence |
|---|---|---|
| `docker compose` | **Missing.** Open feature request, and a separate in-progress community PR to add a `container-compose` subcommand — not merged as of 1.0.0. | [#1846](https://github.com/apple/container/issues/1846) "[Request]: Add container compose"; [#1736](https://github.com/apple/container/pull/1736) "Add container-compose: docker-compose compatibility layer" (open PR). A third-party standalone tool, [`Mcrich23/Container-Compose`](https://github.com/Mcrich23/Container-Compose), exists outside the main project. |
| Swarm / orchestration | **Missing**, and apparently not even requested — zero issue-tracker hits for "swarm". Not on any near-term roadmap I could find. | Search performed, no results. |
| BuildKit-equivalent | **Present**, not missing — `container build` *is* BuildKit-backed (see §2.1). The task brief's speculative list was wrong here; don't carry that assumption forward. | [container-system-config.md `[build]`](https://github.com/apple/container/blob/1.0.0/docs/container-system-config.md#build), [technical-overview.md](https://github.com/apple/container/blob/1.0.0/docs/technical-overview.md) |
| Registry mirror config | **Missing.** No mirror config; separately, no way to mark a registry insecure/HTTP either — both open. | [#669](https://github.com/apple/container/issues/669) "[Request]: Support a mirror config for the vminit image" (open); [#1768](https://github.com/apple/container/issues/1768) "Add insecure registry configuration for pull/push/login" (open) |
| Health checks | **Missing.** No `HEALTHCHECK`-equivalent config, runtime observer, or CLI surface. | [#1918](https://github.com/apple/container/issues/1918) "[Request]: Container healthcheck support — configuration, runtime observer, API, and CLI" (open); [#1502](https://github.com/apple/container/issues/1502) "[Request]: Reserve HealthStatus enum + health field on ContainerSnapshot" (open); [#440](https://github.com/apple/container/issues/440) "Native builder parser support HEALTHCHECK instruction" (open) |
| Restart policies | **Missing.** | [#1258](https://github.com/apple/container/issues/1258) "Add support for container restart policy" (open) — matches `CLAUDE.md`'s existing plan that Flotilla self-implements restart/health in Phase 4 |
| `docker top` | **Missing** as a dedicated subcommand — no `container top`. `container stats`'s `Pids` count is the closest native signal; nothing per-process. | Confirmed absent by reading the full command reference; no issue found requesting it specifically either. |
| `docker restart` | **Missing** as a single command — no `container restart`; you must `stop` then `start`. | Confirmed absent by reading the full command reference (§2.2). |
| `docker commit` | **Missing** — no way to snapshot a running/stopped container's filesystem into a new image via the CLI (`export` gives you a tar of the rootfs, not an image). | Confirmed absent by reading the full command reference (§2.3). |
| `docker network connect`/`disconnect` | **Missing** — a container's networks are fixed at `create`/`run` time. | Confirmed absent by reading the full command reference (§2.4). |
| `docker system prune` (unified) | **Missing** — pruning is per-resource only (`container prune`, `image prune`, `volume prune`, `network prune`); no single command that reaps all of them plus build cache together. | Confirmed absent by reading the full command reference. |
| `--add-host` (static `/etc/hosts` entries) | **Missing.** | [#1563](https://github.com/apple/container/issues/1563) "Add --add-host flag for static /etc/hosts entries" (open) |
| Container-name DNS discovery between containers on the same network | **Missing** — containers on the same user-defined network **are** reachable by IP, but a peer's bare name does not resolve (`NXDOMAIN`) unless you globally configure `container system dns create <domain>` (host-wide, not per-network, and itself limited — see §7). This is the closest thing to Docker's embedded per-network DNS, and it's meaningfully weaker. | [#1809](https://github.com/apple/container/issues/1809) "[Request]: First-class container-to-container DNS discovery on custom networks" (open) — includes a reproduced transcript on `container 1.0.0` showing exactly this |
| Named build contexts (`--build-context`) | **Missing.** | [#1930](https://github.com/apple/container/issues/1930) "[Request]: Support Docker/BuildKit named build contexts in container build" (open) |
| Build-time SSH agent forwarding | **Missing** for `RUN` steps during `container build` (runtime `--ssh` on `container run` *is* supported, per §2, but that's a different mechanism/timing). | [#1472](https://github.com/apple/container/issues/1472) "[Request]: RUN commands in container build that require ssh agent access" (open) |
| GPU passthrough | **Missing**, requested. Caveat: Docker Desktop for Mac doesn't have real GPU passthrough either, so this isn't a clean `container`-specific gap — it's a macOS-virtualization-wide gap both projects share. | [#1511](https://github.com/apple/container/issues/1511) "[Request] Add --gpus GPU passthrough support to container run/create" (open) |

---

## 5. Configuration

Covered in detail by [`container-system-config.md`](https://github.com/apple/container/blob/1.0.0/docs/container-system-config.md),
which I read in full. Source of truth per that doc:
[`Sources/ContainerPersistence/ContainerSystemConfig.swift`](https://github.com/apple/container/blob/1.0.0/Sources/ContainerPersistence/ContainerSystemConfig.swift)
(not independently fetched by us — doc-confirmed, not source-confirmed).

- File: `~/.config/container/config.toml`. All top-level sections optional; missing sections
  fall back to defaults wholesale (not per-key merge — an entire section is either present or
  defaulted).
- Sections: `[build]` (builder VM `rosetta`/`cpus`/`memory`/`image`), `[container]` (default
  `cpus`=4/`memory`="1g" for `run`/`create` when unspecified), `[dns]` (`domain`, appended to
  container hostnames, e.g. `my-web-server` → `my-web-server.test`), `[kernel]`
  (`binaryPath`, `url` — kernel is **kata-containers**' kernel, currently pinned to
  `6.18.15-186`/kata release `3.28.0` per the doc's shown default, which the doc itself warns
  changes release to release), `[network]` (default `subnet`/`subnetv6` for new networks),
  `[registry]` (`domain`, default `docker.io` when a reference omits a registry host),
  `[vminit]` (`image`, the `vminitd` boot image), and `[plugin.<id>]` (plugin-defined, opaque
  to core).
- `MemorySize` values are **binary** (powers of 1024) regardless of whether the TOML author
  writes `kb`/`mb`/`gb` — i.e. `"2g"` means 2 GiB, not 2×10⁹ bytes, and is normalized to
  `"2gb"` on write.
- **Breaking change in 1.0.0** (release notes): the old `container system property get/set`
  subcommands were **removed**; UserDefaults-backed properties were replaced wholesale by this
  TOML file, with `container system property list` as the only remaining read path (no CLI
  write path documented — you edit `config.toml` directly). Cite:
  [1.0.0 release notes](https://github.com/apple/container/releases/tag/1.0.0),
  [#1425](https://github.com/apple/container/pull/1425) "Move to TOML configuration for defaults".
  If Flotilla's `PHASE1.md`/`FEATURES.md` scope assumed a `system property set` CLI path
  exists, that assumption needs checking against this.
- Sample real output (from the how-to doc, presented as illustrative, **not** one of our own
  fixtures — we have no `system property list` fixture):
  ```toml
  [build]
  cpus = 2
  memory = "2048mb"
  rosetta = true
  image = "ghcr.io/apple/container-builder-shim/builder:0.12.0"
  [container]
  cpus = 4
  memory = "1gb"
  [dns]
  domain = "test"
  ```

---

## 6. Networking

- Default network `default` is a **vmnet** NAT network, created on `container system start`.
  Confirmed by our own [`networks.json`](../Tests/FlotillaCoreTests/Fixtures/networks.json)
  fixture: `mode: "nat"`, `subnet: "192.168.64.0/24"`.
- **Custom networks** (macOS 26+ only, §1): `container network create <name> [--internal]
  [--subnet <cidr>] [--subnet-v6 <cidr>] [--plugin container-network-vmnet] [--label]
  [--option]`. Networks are **mutually isolated** — a container on `foo` cannot reach a
  container on `default` or another custom network at all (documented, and matches the vmnet
  isolation model). `--internal` further restricts a network to host-only (no outbound).
- **Container-to-container on the same network**: reachable **by IP**, confirmed by
  [#1809](https://github.com/apple/container/issues/1809)'s reproduced transcript, but **not
  by bare container name** — no embedded per-network DNS the way Docker's user-defined
  bridge networks give you. See §4 for the gap and the documented (partial) workaround.
- **DNS domain workaround**: `sudo container system dns create <domain> [--localhost <ip>]`
  registers a **host-wide** local DNS domain (needs sudo), so a container named
  `my-web-server` becomes resolvable at `my-web-server.<domain>` from other containers *and*
  from the host. This is orthogonal to, and doesn't replace, per-network service discovery.
  Documented caveats, stated explicitly as `[!IMPORTANT]` in how-to.md: creating a localhost
  domain **disables Apple Private Relay**, and the underlying packet-filter rule **is removed
  on every host restart** (i.e. this isn't a "set once" configuration — Flotilla's UI should
  probably surface that it needs re-applying after a reboot if we ever expose this).
- **Published ports**: `-p/--publish [host-ip:]host-port:container-port[/protocol]`, protocol
  `tcp`/`udp`, case-insensitive. If a container has multiple networks, published ports forward
  to the **first** network's interface only (documented explicitly). Port ranges are
  supported and represented in JSON via a `count` field on a single `publishedPorts` entry,
  not one entry per port — confirmed in our
  [`containers-ports.json`](../Tests/FlotillaCoreTests/Fixtures/containers-ports.json) fixture
  (§3).
- **IPv6**: fully dual-stack — containers get both `ipv4Address` and `ipv6Address` (confirmed
  in every container fixture we have), and `--publish '[::1]:8080:8000'`-style IPv6 loopback
  publishing is documented and demonstrated.
- **MAC addresses**: settable via `--network default,mac=XX:XX:XX:XX:XX:XX`; auto-generated
  addresses have their first nibble forced to `f` to reduce collision risk with user-chosen
  ones — a nice detail if Flotilla ever needs to distinguish "user set this" from "we
  generated this" heuristically (though there's no explicit "was this auto-generated" field
  in the JSON — this would have to be inferred from the nibble, not read from a flag).
- **Accessing a host service from a container**: same `system dns create --localhost <ip>`
  mechanism as above, pointed at a documentation/private IP range, with the same Private
  Relay caveat.
- **`--ssh`**: forwards the macOS SSH agent socket into the container
  (`--volume "$SSH_AUTH_SOCK:/run/host-services/ssh-auth.sock" --env
  SSH_AUTH_SOCK=...`-equivalent), and — a nice detail — the mount target is kept in sync
  across host `SSH_AUTH_SOCK` changes (e.g. host log-out/log-in) without restarting the
  container, per the docs.

---

## 7. Volumes and mounts

- Two equivalent syntaxes on `run`/`create`: `-v/--volume host:container` (colon-separated,
  Docker-style) and `--mount type=<>,source=<>,target=<>[,readonly]` (comma `key=value`,
  closer to Docker's `--mount`).
- Named volumes: `container volume create <name> [--label] [--opt size=<n>] [--opt
  journal=<mode>[:<size>]] [-s <size>]`. Only driver is `local`, backed by an **ext4** loop
  filesystem file per volume — confirmed by our
  [`volumes.json`](../Tests/FlotillaCoreTests/Fixtures/volumes.json) fixture
  (`"format":"ext4"`, `"source":"/var/lib/container/volumes/<name>/_data"`). Journal mode
  trades safety for performance (`writeback` fastest/least-safe, `journal` safest/slowest,
  `ordered` is the kernel default and the documented "good balance").
- **Anonymous volumes**: created implicitly via `-v /container/path` (no host source) or
  `--mount type=volume,dst=/path`, named `anon-{uuid}`. **Do not** auto-delete with `--rm` —
  called out explicitly in the docs as a deliberate divergence from Docker, where anonymous
  volumes *do* get swept on `--rm`. Manual `volume delete`/`prune` required. This is a real
  operational trap for anyone porting Docker muscle memory, worth a UI nudge in Flotilla
  (e.g. surfacing orphaned `anon-*` volumes prominently).
- **Bind-mount security shape — this is the one place the docs are silent, and worth being
  explicit that it's silent.** I found **no documented restriction** on which host paths
  `container run -v`/`--mount` can bind-mount. The CLI accepts any path the invoking user can
  read/write; there's no allowlist, no macOS-entitlement-style prompt for "Full Disk Access"
  equivalent for a container's bind mount, and no per-path confirmation flow described
  anywhere in `command-reference.md` or `how-to.md`. **This is presumably why Flotilla built
  its own `MountPolicy`** (per `CLAUDE.md`'s architecture section) — `container` itself
  enforces no host-path boundary; whatever protection exists has to be client-side, in
  Flotilla, before the command is ever issued. I want to be precise about the epistemic status
  here: this is an **absence of a documented restriction**, not a confirmed "no restriction
  exists" — I have not run `container` against, say, `/System` or another user's home
  directory to see whether some other layer (macOS TCC, sandboxing on the `container-runtime-linux`
  helper process, etc.) blocks it regardless of what the CLI itself permits.
  **Unverified**: whether any OS-level layer outside `container`'s own CLI validation
  restricts bind-mount targets. What would confirm it: attempting a mount of a
  TCC-protected path (e.g. `~/Desktop` without granting Terminal Full Disk Access) on a real
  Mac and observing whether it's silently empty, permission-denied, or works fine.
- `--read-only` mounts the container's **root filesystem** read-only (distinct from per-mount
  `readonly` on an individual `-v`/`--mount` entry, which is also independently supported).
- `--tmpfs <path>` and `--shm-size <size>` (for `/dev/shm`) are both supported, separate flags.

---

## 8. Other capability notes worth having on file

- **Linux capabilities**: containers start with a specific restricted default set —
  `CAP_AUDIT_WRITE, CAP_CHOWN, CAP_DAC_OVERRIDE, CAP_FOWNER, CAP_FSETID, CAP_KILL, CAP_MKNOD,
  CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_SETFCAP, CAP_SETGID, CAP_SETPCAP, CAP_SETUID,
  CAP_SYS_CHROOT` — documented verbatim in how-to.md. `--cap-add`/`--cap-drop` accept names
  with or without the `CAP_` prefix, case-insensitively, and `ALL` as a shorthand; **adds are
  applied after drops**, so `--cap-drop ALL --cap-add ALL` nets out to "all capabilities,"
  documented explicitly as intentional ordering.
- **`--virtualization`**: exposes nested-virtualization capability to the guest, gated on
  **M3-or-newer** silicon plus a guest kernel built with specific virtualization config —
  Apple links a known-good kernel config
  ([`containerization` kernel config](https://github.com/apple/containerization/blob/0.5.0/kernel/config-arm64#L602)).
  Do not conflate with the *unrelated* "can `container` itself run inside our nested UTM dev
  VM" constraint already documented in `CLAUDE.md` (§1 above).
- **`--init`**: runs a proper init process for zombie-reaping/signal-forwarding.
  **`--init-image`**: lets you swap in a custom init image entirely, e.g. for eBPF setup or
  boot-time debugging — this is a more general customization hook than Docker's `--init`
  offers (Docker's is a fixed `tini`-equivalent, not swappable).
- **Multi-arch / Rosetta**: `--arch`/`--os`/`--platform` on `run`/`build`/`pull`/`push`, with
  `--rosetta` enabling x86_64-under-Rosetta translation for `amd64` images on Apple Silicon.
  `[build].rosetta` in `config.toml` controls whether the **builder VM itself** uses Rosetta
  for non-native build steps — can be disabled to force pure-arm64 builds, documented as a way
  to guarantee no x86_64 emulation sneaks into a build.

---

## 9. Corrections to `Flotilla/reference/container-cli.md`

I did not edit that file — this is the list for the app owner to reconcile, per the brief.

1. **`container image build` doesn't exist — it's `container build`, a top-level Core
   Command, not a subcommand of `container image`.** Current text: `` container image build
   *(top-level `container build`)` `` — the parenthetical hedge is backwards; there is no
   `image build` at all to be an alias *of*. `container build` stands entirely on its own,
   documented under "Core Commands" alongside `container run`, not under "Image Management."
   See §2.1, §2.3.

2. **The description of `container machine` is wrong, not just thin.** Current text:
   *"The `machine` subcommands manage the host VM/runtime — Flotilla mostly ignores these
   except possibly surfacing `machine list`."* This mischaracterizes what `machine` is.
   `container` has no single "host VM/runtime" to manage in the first place — each regular
   container already gets its own micro-VM (§1); there's no shared host VM sitting underneath
   that `machine` could be exposing. `container machine` is a distinct, additive feature: a
   **persistent, general-purpose Linux dev environment** created from an ordinary OCI image
   (any image containing `/sbin/init`), auto-provisioned with a host-matching user and
   passwordless sudo, meant to feel like "an extension of your Mac" (Apple's own framing).
   It's closer in spirit to a lightweight Vagrant/UTM box than to internal runtime plumbing.
   See §2.4 for the full command surface. This matters for scoping: whether Flotilla should
   expose `machine` commands is a product question about whether we want to manage users'
   general-purpose dev VMs, not a question about internal runtime visibility.

3. **`exec` needs an explicit warning about the `--` bug**, not just an accurate flag list.
   Our current entry (`` container exec [flags] <id> <cmd> — `-i`, `-t`, `-e`, `-u`, `-w`,
   `-d`. ``) is flag-accurate but omits the one thing about `exec` most likely to bite an
   implementer: `container exec <id> -- <cmd>` silently fails because `--` becomes the literal
   executable string. Root-caused with source citations in §2.5. Any code that builds `exec`
   argv for Flotilla must never emit a bare `--` as the first token after the container id.

4. **`export` needs its stopped-container precondition noted.** Current text: `` container
   export -o <tar> <id> — export rootfs. `` doesn't mention that *the container must already
   be stopped* — confirmed in the command reference's own description. Attempting to export a
   running container should be expected to fail, not silently do something partial.

5. **Minor flag omissions worth folding in while reconciling** (not wrong, just incomplete —
   listed together since they're low-severity): `network create` is missing `--plugin` and
   `--subnet-v6`; `image save` doesn't note it accepts multiple `<references>` and that
   `--output` is required; `image load` is missing `-f/--force`; `system stop` is missing
   `-p/--prefix`. All confirmed in §2.

6. **One thing to *flag*, not correct**, since I can't confirm it either way: the `1.0.0`
   release notes claim a `--stop-signal` flag was added to `container run` in this release
   (§2.1), but it's absent from `docs/command-reference.md` at the `1.0.0` tag and from
   `ContainerRun.swift` at that tag as far as I could search. If Flotilla's command-building
   code ever assumes `--stop-signal` exists, verify with `container run --help` on real
   hardware before shipping it.

---

## 10. Biggest open gaps in this document

Things I could not verify and would need real hardware or a fresh capture to close, gathered
in one place:

- Exact JSON schemas for `registry list`, `network inspect`, `volume inspect`, `machine
  list`/`inspect`, `builder status --format json`, `system dns list` — no fixtures exist for
  any of these (§3).
- Whether `container run`/`create ... -- <args>` share `exec`'s `--`-swallowing bug or behave
  like `machine run` (§2.5) — I have a structural argument for "probably safe" but did not run
  it.
- Whether `--stop-signal` actually shipped on `container run` in 1.0.0 as the release notes
  claim (§2.1, §9.6).
- Whether any OS-level layer beyond `container`'s own CLI restricts bind-mount host paths
  (§7) — I found no *documented* restriction, which is different from confirming none exists.
- Whether `docs/troubleshooting.md` (referenced by `technical-overview.md`) existed at the
  `1.0.0` tag — I could not fetch it there (§1).
- Everything about `1.1.0`/`1.2.0` deltas beyond the release-notes headline bullets — I did
  not audit either release's docs/source in the depth I gave `1.0.0`, since Flotilla targets
  `1.0.0`. Worth a follow-up pass if/when Flotilla bumps its target version.
