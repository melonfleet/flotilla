# Docker Desktop capability portability to Flotilla

**Date:** 2026-07-30  
**Conclusion:** Flotilla should borrow a small number of Docker Desktop's workflow
conveniences, not try to reproduce Docker Desktop. The realistic additions are thin,
auditable UI over commands Apple already provides. The strongest five are image push,
runtime-service diagnostics, volume relationship/safe-cleanup views, an explicit Rosetta
run option, and a reduced unified log workspace. Compose, Kubernetes, pause/resume,
shared-VM tuning, Docker Debug, extensions, and Scout-style vulnerability management
should stay out.

## Inputs, evidence, and limits

`research/docker-desktop.md` and `research/apple-container.md` did **not** exist when this
review was written, so this is an independent review using Docker's product documentation,
Apple's current `container` documentation, `research/FEATURES.md`, and `PLAN.md`. Revisit
the Docker Desktop coverage and the Apple-support column when the CLI owner's and the core owner's studies
land; in particular, cross-check whether they found a supported volume data-transfer API
or a stable machine-readable service-log format.

This is documented behaviour, not observed behaviour. `container` cannot be run in the
author's VM. The command documentation describes the current branch rather than every
installed release, so Flotilla should capability-negotiate commands rather than infer
support from an app version ([Apple command-reference notice](https://github.com/apple/container/blob/main/docs/command-reference.md)).

The test for portability here is deliberately strict:

- **Yes** means a documented `container` command or output is sufficient and Flotilla is
  principally adding presentation, validation, or aggregation.
- **Partially** means a useful reduced workflow is possible, but Docker Desktop's
  semantics require client-side aggregation, a helper container, external software, or a
  broader security grant.
- **No** means there is no backing runtime primitive, or the feature belongs to Docker's
  daemon/cloud/product ecosystem rather than an OCI container manager.
- Effort is incremental product effort: **S** about a day, **M** a few days, **L** a week
  or more. It assumes the relevant planned wire/streaming foundation already exists.

Apple's architecture matters more than superficial CLI similarity. `container` creates a
lightweight VM for each container, rather than putting all containers in one shared Linux
VM. Its API server separately manages images and networks, while a runtime helper manages
each container ([Apple technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md)).
That makes shared-daemon controls and cheap helper-container tricks poor fits even where
they could be imitated.

## Scope already covered

The following are not recommendations because Flotilla already has them: container table
and actions, bulk actions, run sheet and command preview, bounded logs with boot logs,
inspect, images, volumes, networks, disk usage, snapshot CPU/memory and sparklines,
notifications, and the app bundle.

The following are also excluded from the ranking because they are already planned: build
UI, registry login, save/load/export, the command palette, the host-grouped fleet view,
interactive exec and live streaming, auto-update, restart/health policy, and read-only
file browsing. Where Docker Desktop exposes one of these, the existing Flotilla plan is
the answer; it is not a newly discovered port.

## Candidate capability review

### Practical ports

| Candidate | What Docker Desktop concretely does | Can Apple `container` support it? | Effort | Value | Verdict |
|---|---|---|---:|---|---|
| **Push an image from the Images view** | A local image row can be tagged as needed and pushed to Docker Hub; the Images view also shows push progress. | **Yes.** `container image push` is documented for any image reference, with platform selection and progress modes; `image tag` is also native ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-image-push)). Flotilla should say “registry,” not “Docker Hub.” | S locally; M with Phase 2 progress streaming | High for developers publishing builds and for feeding a registry used by the fleet; occasional for run-only users. | **Port it.** Add Push after registry login, reuse the long-operation sheet, and never imply a Docker account is required. |
| **Runtime service health and logs** | Docker Desktop exposes status, diagnostics, and backend logs for troubleshooting, and can collect a diagnostic bundle ([Docker troubleshooting](https://docs.docker.com/desktop/troubleshoot-and-support/troubleshoot/)). | **Yes, reduced.** Apple documents `container system status`, version, `system logs --last/--follow`, and `system df` ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-system-logs)). This is runtime evidence, not arbitrary host logging. | S for snapshot; M for follow/filter and support-bundle integration | Medium-high: rarely used, but often the fastest route to an answer when the runtime is broken, especially on a remote mini. | **Port it.** Add a Runtime section to diagnostics with status/version, recent service logs, copy/save, and explicit redaction. Do not build a general macOS log browser. |
| **Volume “in use by” relationships and safe cleanup preview** | Docker's volume detail shows attached containers, image, port, mount target, stored size, and usage state; volume lists can filter used/unused ([Docker Volumes view](https://docs.docker.com/desktop/use-desktop/volumes/)). | **Yes for relationships, partially for exact size.** Apple documents JSON inspection for volumes and containers plus `system df`; Flotilla can correlate the two inventories without starting anything ([volume reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-volume-inspect)). The documented `system df` output is aggregate by resource class, so per-volume byte size is not confirmed. | S–M | Medium-high for anyone pruning persistent data; frequent enough because deleting the wrong volume is irreversible. | **Port a reduced version.** Show referenced/unreferenced, consumers, and mount targets; preview prune from a fresh inventory. Label per-volume size unavailable unless a physical-Mac fixture proves it. |
| **Rosetta/architecture compatibility control** | On Apple Silicon, Docker Desktop can enable Rosetta for amd64 emulation and lets users select platforms for images ([Docker settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)). | **Yes, with different scope.** Apple exposes `--arch`, `--platform`, and `--rosetta` on each `container run`/`create`, and platform flags on pull ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-run)). Per-container is a better match than Docker's shared-VM setting. | S | Medium for Apple-Silicon developers who still encounter amd64-only images; near-zero for arm64-only fleets. | **Port it.** Put an Architecture selector and conditional “Use Rosetta” toggle in Advanced Run options, validate the combination, and keep arm64/default out of the way. |
| **Unified searchable logs workspace** | Docker Desktop's Logs view merges live output from containers and builds, supports exact/regex search, container filters, saved presets, wrapping/timestamps, and filtered export ([Docker Logs view](https://docs.docker.com/desktop/use-desktop/logs/)). | **Partially.** Apple can follow a container's logs and tail a bounded number of lines, but the command takes one container ID; Flotilla must merge streams and assign host/container/timestamp metadata itself ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-logs)). This must wait for planned Phase 4 streaming and only subscribe to selected sources. | M locally; L fleet-wide | Medium-high for diagnosing interacting services across hosts; low for users running one container. | **Port a reduced version after Phase 4.** Container logs only, selected sources only, bounded buffer, text search, and export. Omit build logs and Compose filters; cap concurrent streams. |
| **Duplicate a container into an editable run form** | Docker Desktop can copy a `docker run` command for reuse/modification from a container. | **Partially.** `container inspect` returns JSON and `create` accepts the run options, so Flotilla can pre-fill fields it understands ([container inspect](https://github.com/apple/container/blob/main/docs/command-reference.md#container-inspect)). The documentation does not promise a lossless inverse from inspect JSON to original CLI arguments. | M | Medium for iterative local development; low for immutable production-like fleet workloads. | **Port a reduced version, sixth priority.** Call it “Duplicate…,” show the generated preview, require a new name, and visibly flag unsupported/unreconstructed settings. Do not claim to reproduce the original command byte-for-byte. |
| **Image usage/dependency detail** | Docker's Images view shows whether an image is in use and lets users inspect metadata, layers, packages, and base-image relationships ([Docker Images view](https://docs.docker.com/desktop/use-desktop/images/)). | **Yes for use and OCI metadata; partial for layers/base history.** `image inspect` returns JSON and container inspect/list data can be correlated ([image reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-image-inspect)). The public command reference does not document an image-history command. | S for usage; M if current JSON fixtures prove useful layer metadata | Medium: improves safe deletion and answers which containers need an update. | **Port a reduced version.** Add “used by” and digest/config details. Do not promise Docker-style layer history, packages, or base-image inference without fixtures. |

### Tempting, but not worth porting now

| Candidate | What Docker Desktop concretely does | Can Apple `container` support it? | Effort | Value | Verdict |
|---|---|---|---:|---|---|
| **Volume browse, clone, empty, export/import, scheduled backup** | Docker Desktop browses volume files and can clone, empty, export/import, and schedule exports; some operations stop and restart consumers ([Docker Volumes view](https://docs.docker.com/desktop/use-desktop/volumes/)). | **Partially, with an unverified helper workflow.** Apple documents create/list/inspect/delete/prune, but no volume copy/export/import command. A purpose-built helper container could mount volumes and archive data, but that adds an image dependency, a micro-VM boot, arbitrary init arguments, quiescing rules, and remote binary transfer. `cp` only works with a running container ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-copy-cp)). | L | High for stateful users, but correctness matters more than convenience; crash-consistent backup cannot be assumed. | **Do not port yet.** First prove clone and restore on a physical Mac, including permissions, xattrs, sparse files, a volume referenced by a stopped container, failure recovery, and database consistency. Reconsider a local manual backup only; no scheduler or cloud destinations. |
| **Image packages, SBOM, CVEs, and remediation** | Docker Scout analyzes an image, builds an SBOM, matches it to a changing advisory database, and presents vulnerabilities and upgrade advice ([Docker Scout image detail](https://docs.docker.com/scout/explore/image-details-view/)). | **Not natively.** Apple can inspect or save an OCI image, but documents no package/SBOM/CVE engine. An external scanner could consume an archive, but bundling a scanner and continuously updated vulnerability database is a separate security product, not a `container` UI. | L and permanent operational work | Potentially high, but orthogonal to a small fleet manager and dangerous if stale or incomplete. | **Do not port.** At most, later offer “Reveal saved image” for a user-chosen external scanner; do not own vulnerability verdicts. |
| **Open in VS Code / dev-container integration** | A container action opens the workload in VS Code. | **Partially at best.** Flotilla can reveal a host bind-mount path, but VS Code's Docker integrations expect Docker/Dev Container protocols that Apple `container` does not provide. General exec/file transport is also deliberately gated. | M–L | Low; IDE users can open their source tree directly. | **Do not port.** “Reveal bind source in Finder” is the honest reduced action and belongs with planned mount inspection, not as an IDE integration. |
| **Global image/registry marketplace search** | Docker Desktop searches local and Hub images, shows organization repositories, and pulls from the result. | **No as a runtime feature.** Apple can pull an exact OCI reference from standard registries, but provides no registry catalogue/search primitive ([Apple README](https://github.com/apple/container/blob/main/README.md)). Registry-specific HTTP APIs would create account, pagination, rate-limit, and vendor UX. | L | Low: users generally know the image reference; pull-by-reference covers the operational need. | **Do not port.** Keep a registry-neutral reference field and useful validation errors. |
| **Resource Saver / pause the engine when idle** | Docker Desktop stops its shared Linux VM after an idle interval and wakes it for work, reducing host use ([Docker Resource Saver](https://docs.docker.com/desktop/use-desktop/resource-saver/)). | **No equivalent is needed.** Apple has no shared workload VM: every container has its own VM, while the API server is a launch agent. Stopping running containers to imitate idleness would change workloads, not save transparent overhead ([Apple technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md)). | M for a misleading imitation | Low, with high surprise and data-loss risk. | **Do not port.** Show honest per-container resource use; never auto-stop user workloads. |
| **Shared-VM CPU, RAM, swap, disk, VMM, and file-sharing settings** | Docker Desktop sizes and configures the single Linux VM, selects its VMM, and chooses host directories/file-sharing implementation ([Docker settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)). | **No.** There is no shared workload VM to size. Apple exposes CPU/memory/mount choices per container; Flotilla already puts those in defaults/run configuration. | — | None; the controls would not map to anything real. | **Do not port.** Do not fabricate a Docker-shaped Resources pane. |
| **Pause/resume and live resource update** | Container quick actions pause/resume processes; Docker can update limits on an existing container. | **No.** Apple's current command reference has start/stop/kill/delete but no pause, resume, or update command. Per-run CPU/memory exists, but no documented mutation command. | — | Pause can be convenient, but a stop/start substitution changes semantics. | **Do not port.** Disable nothing and fake nothing; absence is more honest than a differently behaving button. |
| **Terminal tab / arbitrary exec** | Docker Desktop opens an interactive shell in a running container; Docker Debug can add a toolbox even to shell-less images ([Docker Containers view](https://docs.docker.com/desktop/use-desktop/container/)). | **Runtime yes; Flotilla security boundary no, by default.** Apple supports interactive/TTY `container exec`, but Flotilla's remotely exposable grammar currently permits only `ps -o pid,comm,args`. A terminal is a remote-code-execution capability, not a missing tab. | L including PTY, authorization, limits, revocation, and audit design | High for developers; unacceptable if silently added to Phase 2's normal remote command surface. | **Do not straight-port.** Keep the planned Phase 4 feature as a separately authorized security mode with fresh user action, target identity, bounded sessions/concurrency, and no transcript logging. Docker Debug's injected toolbox is out. |
| **Full writable container/volume file manager** | Docker Desktop browses running or stopped container files, edits and deletes them, and drag-drops files both ways. | **Partially.** Apple `cp` uploads/downloads only while a container is running; a stopped container can only be exported as a whole filesystem archive. Directory discovery would require broader exec (`ls`/`stat`), which exceeds today's allowlist ([command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-copy-cp)). | L, especially remote | Medium, but writes to live container roots are hard to audit and easy to misuse. | **Do not port the full feature.** Retain the already-planned read-only-first Phase 4 browser/download design. No editor/delete/drag-upload until a separate threat review approves precise operations. |

### Capabilities to reject outright

| Candidate | What Docker Desktop concretely does | Can Apple `container` support it? | Effort | Value | Verdict |
|---|---|---|---:|---|---|
| **Compose applications/stacks** | Groups services from Compose YAML; runs `up`/`down`, dependency ordering, grouped logs, and stack-level actions. | **No.** Apple has no Compose object, dependency model, or stack lifecycle. Implementing it would make Flotilla an orchestrator and require owning YAML semantics, reconciliation, partial failure, and rollback. | L, realistically many weeks | High to Compose users, but it changes the product and attack surface. | **Do not port.** No Compose import and no YAML surface; users can create ordinary Flotilla run templates directly. |
| **Swarm and Kubernetes views** | Docker Desktop can provision and manage a local Kubernetes cluster; Docker tooling also understands Swarm services/stacks ([Docker Kubernetes view](https://docs.docker.com/desktop/use-desktop/kubernetes/)). | **No.** Apple's CLI is not a CRI runtime and exposes no cluster or swarm control plane. Running control-plane containers by hand is not equivalent to integration. | L, unbounded | Low for Flotilla's small-Mac fleet purpose; specialist tools already exist. | **Do not port.** No orchestration layer and no YAML. |
| **Extensions marketplace** | Installs third-party UI/backend extensions which can access the Docker Engine, host files, and native binaries ([Docker Extensions](https://docs.docker.com/extensions/)). | **No native ecosystem, and a poor security fit.** Flotilla has a narrow allowlist and mTLS remote surface; an extension API would deliberately punch through both. | L plus permanent review/compatibility burden | Low for a personal tool; risk is very high. | **Do not port.** Build the few justified native workflows directly. |
| **Docker Debug toolbox** | Attaches a tool-rich debugging environment to slim or distroless containers without modifying the image. | **No documented Apple analogue.** General `exec` requires tools already present in the target; injecting a side toolbox would require filesystem/process namespace machinery not exposed by `container`. | L / unverified | Useful to specialists, but narrower than an ordinary terminal. | **Do not port.** Re-evaluate only if Apple documents an explicit debug/toolbox primitive. |
| **Docker Model Runner and embedded AI assistant** | Downloads/runs AI models through Docker-specific services and lets an assistant act on Docker workflows. | **No relevant `container` primitive.** An OCI model image is not the Docker Model Runner service, and an assistant authorized to execute fleet operations would radically expand risk. | L | Low for Flotilla's job. | **Do not port.** This is product expansion, not container management. |
| **Accounts, licensing, cloud control plane, telemetry, announcements, surveys, in-app notification centre** | Docker Desktop signs users into Docker services, gates features/subscriptions, reports usage, and retains product notifications. | **Technically buildable but not runtime-portable and contrary to scope.** None is needed to operate Apple `container`. | L and ongoing service operation | Negative for a personal, no-account fleet manager. | **Do not port.** Keep local OS notifications for actionable runtime events and the explicit no-telemetry promise. |

## Recommended implementation order

This order is for **new portability work only**. It must not displace completion of Phase 1
or the already approved phase roadmap.

1. **Image push.** It is a direct, documented primitive, closes the build→registry→fleet
   workflow, and has little product invention. Implement after registry login and reuse
   progress/error infrastructure.
2. **Runtime-service diagnostics.** `system status/version/logs` are direct and useful on
   every host. Folding recent runtime logs into the planned redacted support bundle yields
   disproportionate troubleshooting value for small effort.
3. **Volume relationships and safe cleanup.** This makes the already-built volume UI safer
   without moving data or starting helper VMs. Fresh correlation and an exact prune preview
   are more valuable than Docker's ambitious backup surface.
4. **Rosetta and platform controls in Advanced Run.** This is a small, honest port of an
   Apple-Silicon compatibility need, mapped to Apple's per-container model rather than
   Docker's global VM preference.
5. **Reduced unified logs workspace.** Build it only after Phase 4 streaming. It earns its
   cost when several containers or hosts interact, but subscriptions must be selected and
   bounded; “tail everything on every host” is not acceptable.

Then, if real usage warrants it, add **Duplicate…** as a lossy, inspect-derived run-sheet
prefill and image “used by” detail. Neither should precede the five above.

## Explicit non-goals

The shortest useful product boundary is:

- no Compose, Swarm, Kubernetes, stack model, YAML input, or homemade orchestrator;
- no transparent general exec in the Phase 2 remote grammar, no Docker Debug clone, and no
  writable file manager under the label of convenience;
- no shared-VM settings or Resource Saver imitation when the runtime is per-container VMs;
- no vulnerability database/scanner, extension marketplace, registry marketplace, AI
  assistant, cloud control plane, account system, or telemetry;
- no pause/resume/update buttons without corresponding runtime commands;
- no volume backup/clone scheduler until a physical-Mac prototype proves data and recovery
  semantics. “It can probably be scripted with Alpine” is not a product contract.

Building a Compose execution layer is specifically **not worth it**. It would dominate the
roadmap, duplicate mature tools, weaken the allowlisted remote boundary, and still inherit
the higher start and memory characteristics of one micro-VM per service. Flotilla's
host-aware run templates and explicit fan-out operations provide the fleet value without
pretending to be a declarative reconciler.

## Unverified items and how to settle them

1. **Volume clone/export/restore fidelity.** The command reference has no direct operation.
   On a physical macOS 26 host, prototype a helper-container copy and test ownership,
   permissions, xattrs, symlinks, sparse files, interruption, full destination, and a
   database under write load. Until restore is demonstrated, there is no backup feature.
2. **Per-volume byte size and attachment schema.** Capture real JSON fixtures from
   `container volume inspect`, `container inspect`, and `container system df` for used,
   unused, anonymous, and multiply referenced volumes. Ship only fields present in stable
   fixtures.
3. **Lossless duplication.** Compare inspect JSON with every supported `run` flag on a
   physical Mac, including secrets/env files, mounts, sockets, platform/Rosetta, DNS,
   capabilities, custom kernel/init, and stop signal. Expect a reduced prefill, not an
   inverse command.
4. **Service-log contract.** Confirm whether `container system logs` preserves parseable
   timestamps/severity/source and behaves consistently through service restart and remote
   execution. If not, present it as bounded raw text rather than structured records.
5. **Concurrent log-follow limits and ordering.** Measure process count, memory, cancellation,
   timestamp skew, and reconnect behaviour with several containers and several physical
   hosts before choosing the unified-log concurrency cap.
6. **Stopped-container file access.** Current documentation says `cp` requires a running
   container and `export` requires a stopped one. Verify there is no newer read-only mount
   or copy primitive before finalizing the Phase 4 browser limitations.
7. **Companion-study coverage.** Reconcile the candidate inventory and evidence with
   the CLI owner's `docker-desktop.md` and the core owner's `apple-container.md` when those files appear.
