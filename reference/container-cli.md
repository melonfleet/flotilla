# `container` CLI reference (for Flotilla)

Authoritative source: https://github.com/apple/container/blob/main/docs/command-reference.md
Captured here so the laptop doesn't have to re-fetch. **Verify field names against
real `--format json` output on first run** (that's what `flotilla-probe` is for) —
this lists commands/flags, not the exact JSON schema.

Requires macOS 26, Apple Silicon. Binary + helper scripts install under
`/usr/local/bin` (`update-container.sh`, `uninstall-container.sh`). Install = signed
`.pkg` from GitHub releases (needs admin).

## Commands that emit JSON (Flotilla's read surface)

All take `--format <json|table|yaml|toml>` (default `table`):

| Command | Flotilla use |
|---------|--------------|
| `container ls --all --format json` | list containers (alias of `list`) |
| `container image list --format json` | list local images |
| `container stats --format json [--no-stream]` | resource usage; `--no-stream` = one snapshot |
| `container system status --format json` | is the service up |
| `container system version --format json` | CLI + API server versions |
| `container system df --format json` | disk usage |
| `container network list --format json` | networks |
| `container volume list --format json` | volumes |
| `container registry list --format json` | logged-in registries |
| `container builder status --format json` | BuildKit builder state |

`container inspect <id>` and `container image inspect <ref>` emit detailed JSON (no
`--format` flag needed — already JSON).

## Lifecycle (write actions)

- `container run [flags] <image> [cmd]` — `-d/--detach`, `-i`, `-t`, `--name`,
  `-e/--env`, `-p/--publish`, `-v/--volume`, `--mount`, `-c/--cpus`, `-m/--memory`,
  `--network`, `-k/--kernel`, `--init`. Progress: `--progress auto|none|ansi|plain|color`.
- `container create [flags] <image>` — stage without starting (same run-like flags).
- `container start <id>` — `-a/--attach`, `-i`.
- `container stop <id>` — `-a/--all`, `-s/--signal` (SIGTERM), `-t/--time` (5s).
- `container kill <id>` — `-a/--all`, `-s/--signal` (KILL).
- `container delete|rm <id>` — `-a/--all`, `-f/--force`.
- `container exec [flags] <id> <cmd>` — `-i`, `-t`, `-e`, `-u`, `-w`, `-d`.
  **Never emit a bare `--` before the command.** `container exec web -- ps` fails with
  `failed to find target executable --`: the separator is taken as the program name.
  Unlike `run`, which requires it. Flotilla's `Allowlist` accepts `--` on input for
  unambiguous parsing and strips it from the executed argv.
- `container logs <id>` — `-f/--follow`, `-n <lines>`, `--boot`.
- `container cp <src> <id>:/path` (and reverse) — file transfer.
- `container prune` — remove stopped containers.
- `container export -o <tar> <id>` — export rootfs. **The container must be stopped**;
  on a running one it fails with `invalidState: "container is not stopped"` (verified).

## Images

- `container image pull <ref>` — `--platform`, `--arch`, `--os`,
  `--max-concurrent-downloads` (3), `--progress …`.
- `container image push <ref>` — `--progress …`.
- `container build` — a **top-level** command, not a subcommand of `container image`.
  There is no `container image build` at all (verified: it falls through to `image`
  help). Flags: `-f/--file`, `-t/--tag`,
  `--build-arg`, `--target`, `--no-cache`, `--pull`, `-o/--output type=oci|tar|local`,
  `-c/--cpus` (2), `-m/--memory` (2048MB).
- `container image tag <src> <dst>`
- `container image save -o <tar> <ref>` / `container image load -i <tar>`
- `container image delete|rm <ref>` — `-a`, `-f`; `container image prune [-a]`

## Registry / network / volume / builder / system

- `container registry login [--username … --password-stdin --scheme]`,
  `registry logout`, `registry list --format json`.
- `container network create [--internal --subnet … --label … --option …]`,
  `network delete|rm [-a]`, `network list --format json`, `network inspect`,
  `network prune`. (Networks need macOS 26+.)
- `container volume create [-s <size> --opt size=… --opt journal=… --label …]`,
  `volume delete|rm [-a]`, `volume list --format json`, `volume inspect`, `volume prune`.
- `container builder start|status|stop|delete` (`status --format json`).
- `container system start|stop|status|version|df|logs`,
  `system dns create|delete|list`, `system kernel set`, `system property list`.
  - `system start` flags: `--app-root`, `--install-root`, `--log-root`,
    `--enable/disable-kernel-install`, `--timeout`.
  - `system logs` — `-f/--follow`, `--last <m|h|d>` (5m).

## Notes for Flotilla

- **No native `--restart` or healthcheck** — Flotilla implements restart/health
  itself (Phase 4) by watching `ls`/`inspect`/`stats`.
- The **API service** (`container system start`) must be running for commands to
  work — Flotilla's preflight should check `container system status` and offer to
  start it.
- **`container machine` is not host-runtime plumbing.** There is no shared host VM to
  manage — every container already gets its own micro-VM. `machine` is an additive
  feature: a persistent, general-purpose Linux dev environment built from any OCI image
  containing `/sbin/init`, with a host-matching user and passwordless sudo. Closer to a
  lightweight Vagrant box than to internal plumbing. Whether Flotilla surfaces it is a
  product question about managing users' dev VMs, not a runtime-visibility one.

## `container run` flags — verified against 1.0.0 on real hardware (2026-07-30)

Present: `--init --mount --rosetta --arch --platform --cpus --memory --network --publish
--volume --env --rm --detach`.

**Absent: `--stop-signal`.** The 1.0.0 release notes claim it was added, but it is not in
`container run --help`, not in `docs/command-reference.md` at the 1.0.0 tag, and not in
`ContainerRun.swift` at that tag. `research/FEATURES.md` lists it in the run-sheet scope —
that scope line is wrong and the run sheet must not offer it.
