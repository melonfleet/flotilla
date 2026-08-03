# Gap implementation plan

Ordered from `research/COMPETITORS.md`'s twelve ranked gaps, re-sequenced on the owner's
instruction: **containers and Docker-adjacent work first, virtual machines last.**

the core owner's ranking is by *market frequency*. This one is by frequency × feasibility × security
cost, because every new subcommand family is new grammar facing a remote caller in Phase 2.
Every feasibility claim below was checked against the live CLI on 2026-08-02, not against
docs — `reference/cli-help/` is the authority and docs have been wrong repeatedly.

## Already shipped

- **⑥ Container filesystem browsing and file copy** — done 2026-08-02. `FilesTab`, built on
  `exec … ls -la` for listing and `container copy` for both directions.

## Now

- **Dashboard** (not in the core owner's list; the owner saw Orchard's and wants one). Pure presentation
  over data already fetched. No new CLI surface, no allowlist change, no security cost —
  which is exactly why it goes first.

## Dashboard v2 — matching Orchard's, and it is mostly retention not plumbing

the owner shared a screenshot of Orchard's dashboard (2026-08-02). Assessed against
`container stats --format json`, which returns **eight fields per container**:
`cpuUsageUsec`, `memoryUsageBytes`, `memoryLimitBytes`, `networkRxBytes`,
`networkTxBytes`, `blockReadBytes`, `blockWriteBytes`, `numProcesses`.

`ContainerStats` in `Models.swift` **already decodes all eight**. `StatsSampler.HistoryPoint`
retains only `cpuPercent` and `memoryUsageBytes` and discards the other six. So this is
largely a retention-and-charting job, not new integration — no new CLI surface, no allowlist
grammar, same zero security cost as v1.

Feasible immediately:

- **Stat row with fractions** (`18/19`, `19/30`). `system df` already returns `active` and
  `total` per category; v1 shows only sizes.
- **Memory as "used of limit" with a limit line.** `memoryLimitBytes` is decoded and unused.
- **Network ↓/↑ and Disk R/W rates.** Both counters are cumulative, so rates come from the
  delta between samples over wall clock — exactly the technique `cpuUsageUsec` already uses,
  and the same reason a single sample is meaningless.
- **Per-container utilisation table**, every column including **PIDs** (`numProcesses`).
- **"N cores reserved"** — sum of `configuration.resources.cpus`.
- **5m and 15m ranges** — raise `historyLimit`, currently 40 points (~3.3 min at a 5s poll).

Needs a decision — **history depth**:

- 1h at 5s is 720 points per container; fine.
- **24h is 17,280 points per container** — roughly 17 MB for twenty containers, and **lost on
  restart**. Options: persist it, downsample (5s for recent, 1-minute averages beyond), or
  label it honestly as "since launch". Recommendation: downsample and tell the truth on the
  axis. A 24h button that silently shows forty minutes is the kind of readout this project
  keeps deleting.

### Host metrics — a correction

An earlier version of this section claimed the CPU tile could only ever read "CPU, all
containers", on the grounds that `container stats` has no host-wide figure. **That was wrong,
and the owner caught it.** The premise was right and the conclusion did not follow: `container
stats` indeed has no host figure, but a native Mac app does not need it to — the OS will tell
you directly, which is where Activity Monitor gets its numbers.

Verified on this Mac 2026-08-02, all four working with **no entitlement and no network**:

| Metric | Source | Measured |
|---|---|---|
| Host CPU % | `host_statistics(HOST_CPU_LOAD_INFO)` tick counters, delta over wall clock | 21.0% busy (user 17.1, system 3.8) |
| Physical cores | `ProcessInfo.processorCount` | 12 |
| Host memory | `host_statistics64(HOST_VM_INFO64)` + `sysctl hw.memsize` | 65.74 GB of 68.72 GB |
| Host network ↓↑ | `getifaddrs` → `if_data.ifi_ibytes/ifi_obytes`, delta | 1.3 / 1.1 KB/s |

**Host disk I/O is the one still unverified.** It needs IOKit
(`IOBlockStorageDriver` statistics) rather than a one-line syscall, and it was not proven —
so treat it as unverified until it is, rather than assuming it comes free with the rest.

Two consequences:

1. **Show both, labelled distinctly.** Host CPU answers "is my Mac struggling?"; container CPU
   answers "which container is doing it?". They are different questions and neither substitutes
   for the other. What must never happen is summed container CPU presented as machine CPU.
2. **The host sampler lives in the app target, not `FlotillaCore`.** `host_statistics` and
   `getifaddrs` are Darwin-only, and the core stays Foundation-only so the VM agents can keep
   verifying their own work on Linux. Same rule that puts `Theme.swift` and the AppKit shims
   in `Sources/Flotilla`.

Also worth noting from the screenshot: "70 cores reserved" on a machine with far fewer physical
cores is the sum of container *allocations*, i.e. over-commit — not a core count. Ours should
distinguish physical cores from reserved ones, or it repeats their ambiguity.

## Wave 1 — the CLI fully backs these, and none of them widen the wire boundary much

1. **⑦ Aggregated multi-container logs.** `logs` is already allowlisted and already fetched
   per container; aggregation, interleaving and per-container colour are in-app. **No new
   grammar at all**, which makes it the cheapest real feature on the list.
2. **⑨ Command palette / keyboard-first navigation.** Pure UI. Zero CLI, zero allowlist.
   Self-contained enough to do in one pass, and it makes everything else faster to reach.
3. **③ Image building from a Dockerfile.** `container build [<options>] [<context-dir>]`
   exists (verified). New `CommandSpec` needed, and the **build context is a host path**, so
   `MountPolicy` governs it exactly as bind mounts and `copy` endpoints do.
4. **⑤ Registry authentication.** `container registry login|logout|list` exists (verified).
   **The password must never reach argv** — anything on a command line is visible to `ps`.
   Credentials go to the Keychain and the CLI is fed by stdin or a token reference. This is
   the first gap where getting it wrong is a security bug rather than a bad feature.

## Wave 2 — still containers, but each needs a decision before code

5. **⑩ Docker Hub / registry search.** **The CLI has no `search` subcommand** (verified).
   Implementing it means Flotilla making a direct HTTPS call to a registry API — which
   contradicts the no-phone-home promise and the About page that enumerates every network
   destination. Needs an explicit decision and an About-page change, or it should be dropped.
   Do not slip it in.
6. **② Docker Compose.** **Apple `container` has no compose support whatsoever** (verified:
   zero mentions in `--help`). This is not a wiring job — it is implementing an orchestrator:
   dependency ordering, per-project networks, volume lifecycles, health gating, teardown.
   Recommended scope: read-only **import** of a compose file into pre-filled run forms, so
   the user still presses the button. A full engine is a project, not a feature.
7. **④ Notarised, signed, auto-updating distribution.** Not a feature — a release gate. Needs
   the Xcode project, a Developer ID and Sparkle. Sequence with Phase 5 packaging, not here.
   Note `COMPETITORS.md`: several competitors are *not* notarised and one cannot self-update
   as a result, so shipping this is a genuine differentiator.
8. **⑫ Localisation.** Mechanical but touches every string in the app. Do it once the UI has
   stopped moving, or it is done twice.

## Wave 3 — beyond containers

9. **⑧ MCP server / AI-agent surface.** Exposing Flotilla's operations to an agent means a
   second caller for the allowlist — closer in spirit to Phase 2's wire boundary than to a
   UI feature, and it should reuse that boundary rather than grow a parallel one.
10. **⑪ Local AI model integration.** Two products, both novel. Revisit once there is
    evidence anyone wants it.

## Wave 4 — virtual machines

11. **① Machine / VM management.** the core owner's #1 by market frequency (~13 of ~19 products) and
    deliberately last here on the owner's sequencing.
    **The CLI surface is complete** — `container machine create|delete|inspect|list|logs|run|
    set|set-default|stop`, including `machine set -n <name> cpus=4 memory=8G home-mount=ro`
    and an interactive `machine run` (verified 2026-08-02). So this needs **no XPC**; see the
    2026-08-02 entry in `DECISIONS.md`.
    Security note: `home-mount` is a filesystem grant and `machine create` is a new grammar
    family. Both face a remote caller in Phase 2. Audit against `reference/cli-help/`.

    **Shipped 2026-08-03**, ahead of the sequencing above, because the owner asked for it directly.
    A full section: list/cards, state filter, hideable columns, row actions, create form, and an
    embedded detail with Overview / Shell / Logs / Settings / Inspect.

    The claim above that "the CLI surface is complete" was true of the *leaves* and wrong about
    the *grammars*. Building against it surfaced four bugs — `machine run` missing from the
    Allowlist entirely, no `machine start` leaf, a bare `machine run` that fails after booting
    because it wants a PTY, and `--home-mount` spelled differently on `create` than on `set`.
    See the addendum in `research/MACHINES-SPEC.md`; do not trust a leaf inventory as evidence
    that the grammar is known.

    Also learned: **almost no image boots as a machine.** Alpine does; Ubuntu, Debian, Fedora and
    BusyBox each pull, create a record, and then fail to start — permanently, and holding the
    default if they were first. That constrains the feature more than any of the above.

## Standing caveat

Adding subcommand families enlarges the Phase 2 attack surface. the review's verdict in
`research/ALLOWLIST-AUDIT.md` still stands: the `Allowlist` is not yet trustworthy as the
complete wire boundary. Sequence against that audit, not against market frequency.
