# Flotilla research — features / runtime

Scope: the *functional* feature set — container lifecycle, images, volumes/mounts,
networking/ports, logs/exec/files/stats, search/filter, bulk actions, compose-like
handling, CLI↔GUI parity — plus what a **remote/fleet** view needs on top.

Comparables surveyed: **OrbStack** (closest native-Mac analogue), **Docker Desktop**
(the feature baseline everyone is measured against), **Podman Desktop**, **Rancher
Desktop**, **Portainer** (the only mainstream *multi-host* container GUI), and
**Apple's `container` CLI** itself (our actual runtime — it decides what is even
possible). Plus `tdeverx/contained-app`, the existing native GUI over the same CLI.

Everything below is filtered through one hard constraint: **Flotilla can only expose
what `container` can do.** Half of the Docker-Desktop feature list has no backing
command in `container` 1.1.0. That's the single most useful output of this research —
see §4's `[skip]` block.

---

## 1. What the comparables do

### Apple `container` CLI 1.1.0 (the runtime — what actually exists)

Sourced from `reference/container-cli.md` + `reference/json-schemas.md` (live capture
from 1.0.0) and the apple/container releases page (1.1.0 is latest as of this research;
1.0.0 froze the CLI/XPC surface, so 1.0.x/1.1.x are compatible — dates on the releases
page render oddly, *(verify)*).

**Lifecycle:** `run` (`-d -i -t --name -e -p -v --mount -c/--cpus -m/--memory
--network -k/--kernel --init --stop-signal`), `create`, `start` (`-a -i`), `stop`
(`-a --signal --time`), `kill` (`-a -s`), `delete|rm` (`-a -f`), `prune`, `exec`
(`-i -t -e -u -w -d`), `logs` (`-f -n --boot`), `cp` (both directions), `export`.
**Images:** `pull` (`--platform --arch --os --max-concurrent-downloads --progress`),
`push`, `build` (`-f -t --build-arg --target --no-cache --pull -o -c -m`, plus build
secrets since 0.11), `tag`, `save`/`load`, `delete`/`prune`, `inspect`.
**Registry:** `login --username --password-stdin --scheme`, `logout`, `list`.
**Network:** `create --internal --subnet --label --option`, `delete`, `list`,
`inspect`, `prune`. **Volume:** `create -s/--opt size=/--opt journal=/--label`,
`delete`, `list`, `inspect`, `prune`. **Builder:** `start|status|stop|delete`.
**System:** `start|stop|status|version|df|logs (-f --last)`, `dns create|delete|list`,
`kernel set`, `property list`. **Machine:** long-lived Linux environments (1.0.0).

Every read command takes `--format json`; `inspect` is already JSON. `container ls`
returns the *full* config + status object per container (published ports, mounts,
labels, networks, resources, init process, DNS, caps) — so a rich detail view needs
**no extra calls**.

What the CLI **does not** have, and therefore no GUI over it can have for free:
- **No `--restart` policy and no healthcheck.** (Already a settled Flotilla decision:
  self-implement.)
- **No event stream** (`docker events` has no analogue) → *everything is polling*.
- **No compose.** No `container compose`, no stack concept, no project grouping.
- **No `top`/process list**, no `pause`/`unpause`, no `rename`, no `update`
  (resources are fixed at create), no `diff`, no `commit`.
- **No filesystem-browse API** — only `exec` and `cp`.
- **No container-level `--label` filtering flags on `ls`** *(verify)*; filtering is the
  GUI's job over the decoded JSON.
- CPU in `stats` is **cumulative µs**, so there is no ready-made CPU % — you must
  sample twice and delta.
- The **API service must be running** (`container system status` → `"unregistered"`
  when down), and a fresh install needs `container system kernel set --recommended`
  before anything works.

### OrbStack (macOS-native Swift app; the closest analogue)

- **Positioning:** "near feature parity with Docker Desktop, but with a much simpler
  interface", explicitly a **native Swift app**. This is exactly Flotilla's brief.
- **v2.0 rebuilt the app as a "full-fledged container IDE"**: an integrated
  **terminal powered by Ghostty**, a **file manager for containers, volumes, images
  and machines**, a **fast log viewer with filtering**, and detail views showing
  container metadata + health status.
- **Log viewer** (since v0.16): search inside logs, and **tabs grouping a Compose
  project's containers** into one log stream.
- **Activity Monitor** (v1.11): CPU / memory / disk usage with customisable views;
  later releases added a **per-container monitoring tab** and **volume disk-usage
  calculation**.
- **Compose project groups in the container list** (v0.10) plus **multi-select batch
  operations** — the two features that make a 40-container list usable.
- **Container search** in the list (v0.9); **sorting** for images and volumes.
- **Native file access** (`~/OrbStack/docker/containers|images|volumes/<name>`,
  and `~/OrbStack/<name>` for Linux machines): browse *and edit* container/volume
  files in Finder, TextEdit, any macOS app. Images are read-only by design. There's
  a **folder button** on every container/image/volume that reveals it in Finder.
- **Automatic per-container domain names** (v0.17) — `foo.orb.local` instead of
  remembering published ports. A pure quality-of-life win that costs the user nothing.
- Registry credentials stored in the **macOS Keychain**; engine logs via `orb logs docker`.

### Docker Desktop (the feature baseline)

- **Containers view is the default**, listing containers **grouped by Compose
  project**, with **quick actions** (start / stop / pause / resume / delete) inline
  on each row.
- **Container detail is a tab bar**: **Logs**, **Inspect** (full config JSON: env
  vars, mounts, network, resource limits), **Bind mounts**, **Exec** (interactive
  shell session in the container), **Files** (visual filesystem browser),
  **Stats** (resource usage + performance graphs). This tab set is the de-facto
  industry standard — Podman Desktop and OrbStack both converged on roughly it.
- **Images view:** search / browse / pull / run / inspect, spanning both local images
  and Docker Hub.
- **Volumes view:** list volumes with the containers using them; export/import.
- **Builds view**, **Kubernetes view**, **Extensions marketplace**, **Dev
  Environments**, **Docker Scout** (vuln scanning), and **Gordon**, an embedded AI
  assistant.
- **Quick Search (⌘K-ish)** across containers, images, volumes, extensions *and
  docs*; an **integrated terminal** with copy/paste/search and session persistence;
  a customisable left-hand nav; a notifications centre; an in-app Learning Center.
- **Bulk Actions** on multi-selected containers — notably still shipping as *Early
  Access* in July 2026, i.e. even the market leader treated this as hard/late.
- **Resource Saver mode** — idles the VM when no containers run.
- **No multi-host story.** Remote hosts are a *CLI* feature (`docker context`, over
  SSH or TCP), and even there a context points at exactly **one** host; the
  multi-host-per-context request (docker/cli#3352) is unimplemented. The Desktop GUI
  does not aggregate hosts at all. **This is the gap Flotilla exists to fill.**

### Podman Desktop

- List / search / inspect / run / stop containers across **multiple container engines
  in one unified view** — the nearest thing to Flotilla's aggregation, but for
  *engines on one machine*, not machines.
- **Shell into a container**, view **logs**, basic controls, per-container detail.
- **Images:** build from Containerfile/Dockerfile, pull from remotes, push to
  **multiple registries with managed accounts**.
- **Pods:** select several containers to run as a pod, **unified logs for the pod**,
  inspect members. Also "play Kubernetes YAML locally without Kubernetes" and
  "generate Kubernetes YAML from pods".
- **Volumes** management; **Podman machine** create/manage; **allocated memory, CPU
  and storage** shown in the UI.
- **Tray icon** for status + starting/stopping the engine.
- **Extensions**, including importing Docker Desktop extensions via OCI images.

### Rancher Desktop

- Containers and Images tabs over containerd/moby; build, push, pull.
- **Port forwarding viewable and configurable from the GUI** (a first-class tab
  rather than a per-container detail field).
- **Image scanning with Trivy**, with vulnerabilities summarised by severity.
- Heavily **Kubernetes-first** (k3s bundled) — cluster/node/deployment views and
  resource stats. Most of its surface area is irrelevant to us (No-K8s is settled).
- Recent versions ship **snapshots** of the VM state *(verify — not confirmed in the
  sources I could reach)*.

### Portainer (the multi-host model — most relevant to Phase 3)

- **"Environments"** (renamed from "endpoints" in 2.10) are the unit of remoteness:
  Docker, Swarm, Kubernetes, ACI, Edge devices — all in one console.
- Environments are organised into **groups** and given **tags**; access policies can
  be applied to a group or to many environments at once.
- **Edge Agent** on each host **dials out** to the central Portainer and builds a
  reverse tunnel, so the fleet member doesn't need an inbound port or a public IP.
- **Edge Stacks**: define a Compose app once and **deploy it to many edge endpoints
  at once**, "without SSH-ing into each device".
- **Onboarding at scale**: generated provisioning scripts, plus an **Edge
  "waiting room"** where newly-appeared agents queue for an admin to approve them.
- **Async polling** mode for flaky/high-latency links, plus API-driven monitoring, so
  a fleet of thousands works from one instance.
- Weakness: it's a **web app with an agent per host**, not native; and it drills
  *into* one environment at a time rather than presenting a true cross-host container
  list.

### Fleet/menu-bar UX comparables (Tailscale)

- Tailscale's new macOS app (Tahoe 26+) is a **searchable list of devices with
  connection status** right in the menu; selecting one reveals detail + actions
  (ping, copy IP, send file).
- **Exit-node picker with latency indicators**, including one *recommended* node —
  i.e. the app does the ranking so the user doesn't compare numbers.
- Surfaces **ACL tags and device labels in the menu bar**, so an admin can sanity-check
  fleet state "without logging into the admin console for routine checks". That is
  precisely the value proposition of a menu-bar fleet view.
- Tailscale explicitly **outgrew the menu bar** and shipped a **windowed UI** in beta
  ("Escaping the notch") — the menu is for glance + quick action, the window for work.
  Flotilla's MenuBarExtra + NavigationSplitView split already matches this.

### `tdeverx/contained-app` (native GUI over the *same* CLI — read for ideas only, PolyForm NC)

- Containers, images, tags, image updates, archives, volumes, networks, registry
  credentials, **templates**, activity history, system resources.
- Run / edit / stop / **restart** / inspect / delete, with **app-managed health and
  restart behaviour** — confirming that self-implementing restart/health is the
  expected move for this CLI, not an exotic one.
- **Compose import → editable run forms** rather than launching opaque stacks. A
  genuinely smart answer to "container has no compose".
- **Reveals the exact `container` command before privileged run/edit operations.**
- Experiments/settings: command palette, Docker Hub search, image build workspace,
  keyboard shortcuts, Liquid Glass cards with per-container tint/icon/nickname.
- **Explicitly local-only — no remote hosts.** Also (from its README) no exec/terminal,
  no file browser, no bulk actions, no menu-bar extra *(verify — the README is the
  only source I read)*. So Flotilla's differentiators are: fleet, exec, files, bulk.

---

## 2. Patterns worth stealing

1. **The six-tab container detail: Logs / Inspect / Stats / Exec / Files / Mounts.**
   Docker Desktop, Podman Desktop and OrbStack independently converged on this. Users
   arriving from Docker will look for exactly these tabs. Every one is buildable on
   `container`: `logs`, `inspect` (already full JSON from `ls`), `stats`, `exec`,
   `exec`+`cp`, and `configuration.mounts`.

2. **Show the exact CLI command before running it** (contained-app). Perfect fit for
   Flotilla: the wire protocol *is* CLI args, so the command string is literally the
   payload. It doubles as the fleet audit log ("what did this app run on that Mac?")
   and makes the app teachable rather than opaque — this is a learning project.

3. **Bulk multi-select actions** (OrbStack v0.10; Docker only reached Early Access in
   2026). With 8 hosts × N containers, single-row actions do not scale. `container`
   even helps: `stop -a`, `kill -a`, `rm -a`, `image rm -a` exist natively.

4. **Grouping in the list, and log tabs per group** (OrbStack Compose groups). We have
   no Compose, but we have a **better grouping key: the host**. And the second-best:
   `configuration.labels`. Same UI, different pivot.

5. **Search-first navigation** (Docker's Quick Search; Tailscale's searchable device
   list; contained-app's command palette). ⌘K is already in the plan — make it search
   containers, images, *and hosts*, and make host-switching keyboard-only.

6. **A recommended choice, not just a table of numbers** (Tailscale's latency-ranked
   exit node). Flotilla equivalent: when you press "Run", *suggest the host* with the
   most free CPU/RAM instead of making the user read eight stat rows.

7. **Environments → groups → tags** (Portainer). Eight machines will want "studios" vs
   "minis", or "prod-ish" vs "scratch". Tags are cheap now and expensive to retrofit,
   and they map straight onto Jamf-delivered settings in Phase 6.

8. **Fan-out one action to many hosts** (Portainer Edge Stacks). For us the useful
   90% is much smaller than stack deployment: *pull this image on all hosts*,
   *stop everything on host X*, *upgrade the `container` CLI everywhere*.

9. **A "waiting room" for newly-discovered peers** (Portainer). Bonjour will surface
   unknown Macs; a pending-approval queue is a much better UX than a silent reject,
   and it's the natural home for fingerprint comparison.

10. **File browsing that lands in Finder** (OrbStack's folder button). We can't mount
    a container filesystem, but "**Reveal in Finder**" after a `container cp` to a
    temp dir gets 80% of the value for ~none of the effort.

11. **Compose import as a *form pre-fill*, not an execution engine** (contained-app).
    Users have `docker-compose.yml` files; translating one into a pre-filled run sheet
    is honest and cheap. Running an orchestrator is neither.

12. **Async/polling-tolerant design** (Portainer's async mode). Fleet members sleep,
    reboot, and drop off Wi-Fi. Cached last-known state **with an explicit staleness
    timestamp** beats an empty list or a spinner.

13. **Idle/resource-saver behaviour** (Docker Desktop Resource Saver). Our version:
    poll hard only when the window is frontmost; back off to ~30s when only the menu
    bar is visible; exponential backoff for offline hosts. With 8 hosts and *no event
    stream*, polling discipline is a real feature, not an optimisation.

---

## 3. Anti-patterns / things to avoid

- **Chasing Docker Desktop feature parity when the runtime doesn't have the features.**
  A Volumes tab that can't show what's *inside* a volume, a "pause" button that maps to
  no command, a Compose tab that only errors. Build the CLI's real surface, well.
- **Weight and background cost.** The universal Docker Desktop complaint is resource
  contention and slow startup (OrbStack's whole pitch is ~2s container start vs 30s+).
  A menu-bar app that polls eight Macs must not be the thing that heats the laptop.
- **In-app marketing surfaces.** Docker Desktop's notification centre, Learning Center,
  extensions marketplace, embedded AI assistant, sign-in prompts. Zero of this belongs
  in a personal tool; every one of them is a thing users complain about.
- **Hiding the CLI.** Users of `container` are CLI users. A GUI that makes the
  underlying command unknowable is untrustworthy and un-debuggable — and specifically
  bad when the *point* is understanding what ran on a remote Mac.
- **Opaque stacks** (contained-app's stated reason for import-not-run): a one-click
  action that starts seven containers you can't individually see or reason about.
- **Unbounded log views.** Naïvely `-f`-ing a chatty container into a SwiftUI `Text`
  will pin a core and blow memory. Cap the ring buffer, virtualise the list, and
  default to `logs -n 500` before offering follow.
- **Destructive actions without a preview.** `prune` across an eight-Mac fleet is a
  genuinely dangerous button. Always show *exactly what will be deleted, per host*,
  and never offer "prune all hosts" as a one-click.
- **Silent divergence between GUI and CLI state.** The user will also type `container`
  in Terminal. With no event stream, the GUI *will* go stale — so make refresh
  explicit, timestamped, and cheap (and refresh on window focus).
- **Per-container tunnels/streams at fleet scale.** Eight hosts × a live stats stream
  each × N containers is a self-inflicted DoS. One multiplexed connection per host,
  and only stream what's on screen.
- **Modal wizards for `run`.** The run flags are numerous (`-e -p -v --mount -c -m
  --network`); a five-step modal is worse than one scrollable sheet with sane defaults
  and the command preview updating live at the bottom.
- **Requiring a browser and a per-host agent** (Portainer). We already avoid this —
  one app, two modes, native. Don't drift toward a web view.
- **Overreaching on remote file paths** — see the traps in §4; a path picker that
  silently means "a path on a *different* Mac" is a data-loss bug waiting to happen.

---

## 4. → Proposed for Flotilla

Legend: **[core]** = v1, **[later]**, **[skip]**. Phase numbers refer to `PLAN.md`.

### Phase 1 — Local MVP

| Feature | Pri | Notes |
|---|---|---|
| Container list from `ls --all --format json`: name (`configuration.id`), image, state, uptime, CPU/mem, ports | **[core]** | The mockup grid. All fields are already in one call. |
| Lifecycle: start / stop / restart / kill / delete | **[core]** | `restart` = `stop` then `start` (no native restart cmd). Expose `--signal`/`--time` in an "advanced" disclosure. |
| Run sheet: image, name, `-d`, `-e`, `-p`, `-v`/`--mount`, `--cpus`, `--memory`, `--network`, `--init`, `--stop-signal` | **[core]** | One scrollable sheet, not a wizard. |
| **Live command preview** in the run sheet + a "copy command" button everywhere | **[core]** | Steal from contained-app. Trivial for us — args *are* the wire payload. |
| Logs viewer: `logs -n <N>`, follow toggle, in-view search/filter, copy, **`--boot` toggle** | **[core]** | `--boot` (micro-VM boot log) is unique to this runtime and is the first thing you need when a container won't start. Cap the buffer. |
| Inspect tab (pretty JSON + a friendly summary) | **[core]** | Free — `ls` already returns the whole object. |
| Stats: snapshot table + computed CPU % from Δ`cpuUsageUsec`, mem %, net/block IO | **[core]** | The delta maths is documented in `json-schemas.md`. Sparklines are Phase 4. |
| Search + filter (name, image, state, label) and sort | **[core]** | Client-side over decoded JSON; the CLI has no filter flags. |
| Multi-select **bulk actions** (stop/kill/delete/restart) | **[core]** | Prefer native `-a` where the selection *is* everything; per-id otherwise. |
| Images: list, pull (with progress), delete, prune, tag, inspect | **[core]** | Show arm64 variant size; hide `architecture: "unknown"` attestation variants. |
| Volumes: list, create, delete, inspect, prune | **[core]** | Cheap; `volume create` supports `-s`, `--opt journal=`, labels. |
| Networks: list, create, delete, inspect, prune | **[core]** | Read-only would be acceptable for v1, but create/delete is ~free. |
| Preflight: `system status`, `system version`, kernel-set + `system start` flow, guided `.pkg` install | **[core]** | Already a DECISION. Note the `kernel set --recommended` gotcha — a fresh Mac fails without it, and the prompt can't be answered in a non-TTY. |
| `system df` disk-usage panel | **[core]** | One call; directly answers "why is my disk full". |
| Menu-bar glance: running/total count, per-state dots, top offenders, quick stop | **[core]** | The reason the app exists. |
| ⌘K palette over containers + images (+ hosts from Phase 3) | **[core]** | Already in the tech stack. |
| Registry: `registry list`, login, logout | **[later]** | Local-only in Phase 1 is fine. Remote login needs stdin — see traps. |
| Image build UI (`build -f -t --build-arg --no-cache -o`) | **[later]** | Phase 4+. Build output is a long stream; do it after the streaming channel exists. |
| `image save`/`load`, `export` | **[later]** | Niche; useful for moving an image *between fleet Macs* without a registry — revisit in Phase 3. |
| Per-container nickname / tint / icon (contained-app) | **[later]** | Pure polish; branding already gives us pink/green. Local-only metadata in SwiftData. |
| Container templates / saved run configs | **[later]** | Phase 3+. Becomes much more valuable once "run this same thing on host N" exists. |

### Phase 2 — Host mode + client mode over mTLS

| Feature | Pri | Notes |
|---|---|---|
| **Full Phase-1 feature parity over the wire, with zero new feature code** | **[core]** | This is the acceptance criterion for Phase 2, and it falls out of the args-over-wire design in `wire-protocol.md`. Worth stating explicitly as a feature. |
| Per-host preflight surfaced remotely (`system status`/`version` of the peer) | **[core]** | First thing the client should ask a newly-connected host. |
| Pending-peer "waiting room" for Bonjour-discovered, un-allowlisted Macs | **[core]** | Portainer's pattern; far better than a silent TLS reject. Fingerprint shown for out-of-band comparison. |
| Per-peer subcommand restrictions (`args[0]` allowlist) | **[later]** | Already flagged as "future" in `wire-protocol.md`. A read-only peer role is the useful version. |

### Phase 3 — Fleet view

| Feature | Pri | Notes |
|---|---|---|
| **Aggregate container list with a Host column**, groupable by host | **[core]** | The thing no comparable does — Docker Desktop has no multi-host GUI at all, and Portainer drills into one environment at a time. |
| Per-host status: online/offline, running/total counts, CLI + apiserver version, `system df` | **[core]** | Matches the mockup's per-host dots + counts. |
| **Staleness indicator**: last-successful-poll timestamp per host; show cached data greyed rather than empty | **[core]** | Macs sleep. Portainer's async-polling lesson. |
| Adaptive polling: fast when frontmost, slow in menu-bar-only, exponential backoff when a host is down | **[core]** | There is **no event stream** in `container`, so polling policy is a first-class design concern, not a tweak. |
| Host groups / tags | **[core]** | Cheap now, expensive later; maps onto Phase 6 managed settings. |
| Host detail page (containers, images, volumes, networks, resources, versions) | **[core]** | Per-host *and* aggregate — users need both pivots. |
| Fan-out: pull an image to selected/all hosts | **[core]** | The highest-value fleet verb. Progress per host, partial-failure reporting. |
| **Version-skew warning** across the fleet (`container` CLI versions differ) | **[core]** | Classic fleet failure mode; one `system version` call per host already gives it. |
| Cross-host bulk actions (stop all on host X; delete by tag) | **[core]** | Always with an explicit per-host preview of what will be affected. |
| "Where should this run?" — rank hosts by free CPU/RAM in the run sheet | **[later]** | Tailscale's recommended-exit-node pattern. Needs host-level resource reporting first. |
| Fleet image inventory ("which hosts have `alpine:latest`?") | **[later]** | Aggregate `image list`, group by digest. Nice payoff for ~little work. |
| Aggregate fleet-wide stats dashboard / Swift Charts | **[later]** | Phase 4 once streaming lands; snapshot-only until then. |
| Image transfer host→host (`save`/`load` over the wire) | **[later]** | Avoids a registry on a LAN-only fleet. Needs binary framing — see traps. |

### Phase 4 — Live streaming + exec

| Feature | Pri | Notes |
|---|---|---|
| Live log streaming over the persistent connection (local + remote) | **[core]** | Already the phase's stated goal. |
| Live stats + sparklines (Swift Charts), per-container tab | **[core]** | OrbStack's Activity Monitor / per-container tab. Only stream what's visible. |
| **Interactive exec terminal** (`exec -i -t`) | **[core]** | The most-wanted tab in every comparable. **Extends the wire protocol** — see traps. |
| **Self-implemented restart policy + health checks** | **[core]** | Already a DECISION; contained-app does the same. Policy lives in the *host-mode* peer so it survives the client quitting — worth deciding explicitly. |
| File browser via `exec ls`/`stat` + `cp` for download/upload, with **Reveal in Finder** | **[core]** | Docker's Files tab and OrbStack's file manager, achievable without a file-provider extension. Read-only listing first; upload second. |
| Bind-mount / published-port editor on the run sheet with a **host-aware path picker** | **[core]** | See traps — paths and ports are the remote host's, not the client's. |
| Activity/history log of every command Flotilla ran, per host | **[later]** | contained-app has "activity history"; for a fleet it's genuinely useful forensics. SwiftData is already in the stack. |
| Per-container domain names (OrbStack's `*.orb.local`) | **[skip]** *(revisit)* | `container system dns create` exists, so a fleet-wide `*.flotilla.local` is *conceivable*, but DNS on 8 Macs is a project of its own. |

### Phase 5 — Auto-updates

| Feature | Pri | Notes |
|---|---|---|
| **Fleet-wide `container` CLI upgrade** (guided signed-`.pkg` install per host) | **[later]** | Natural companion to Sparkle self-update, and the fix for the version-skew warning. Must keep the "user authorization, never silent/privileged" rule from DECISIONS — which on a *remote* host means a local prompt on that Mac, not a click on the client. Flag this. |

### Phase 6 — Jamf / configuration profiles

| Feature | Pri | Notes |
|---|---|---|
| Managed host groups/tags + allowlist delivered by profile | **[core for that phase]** | Extends the Phase-3 tags feature; no new UI. |

### Explicit `[skip]` — and why

- **Kubernetes / any orchestrator view** — settled in DECISIONS; `container` is not a
  CRI runtime.
- **Compose as an execution engine (stacks, `up`/`down`, dependency ordering)** — the
  CLI has no compose and no dependency model; building one is a project, not a feature.
  **Do** ship compose-file *import into a pre-filled run sheet* (contained-app's
  approach) — `[later]`, Phase 3/4.
- **Image vulnerability scanning** (Rancher's Trivy, Docker Scout) — needs a bundled
  scanner + a vuln DB + updates. Enormous, and orthogonal to a fleet manager.
- **Extensions / plugin marketplace** (Docker, Podman) — personal project, no ecosystem.
- **Dev Environments, Learning Center, embedded AI assistant, notification centre**
  (Docker Desktop) — product-growth surfaces, not features.
- **Docker Hub browse/search inside the app** — `[later]` at best; a "pull by ref"
  field covers the real need, and Hub search is an unrelated web API.
- **Finder-mounted container/volume filesystems** (OrbStack's `~/OrbStack/...`) — that
  needs a FileProvider/FUSE-class extension, and it makes no sense for a *remote* Mac's
  containers. `cp` + Reveal in Finder is the 80% at 5% of the cost.
- **`container machine` management** — the plan already says mostly ignore; surfacing
  `machine list` read-only in host detail is the ceiling.
- **`pause`/`resume`, `rename`, live resource `update`, `top`, `commit`, `diff`** — no
  backing commands. Don't draw buttons for them.
- **USB passthrough / sound** (OrbStack v2.2) — irrelevant to headless fleet Macs.
- **Multi-host stack deployment** (Portainer Edge Stacks) — the fan-out primitives
  (pull image, run template on N hosts) give most of the value without an orchestrator,
  and Kubernetes-style scheduling is explicitly rejected.

### Conflicts with / extensions to DECISIONS.md and the reference docs

Five things in the list above cannot be built without amending a settled spec. Flagging
them now rather than discovering them mid-Phase-4:

1. **An interactive shell needs bidirectional streaming; the first protocol design is
   request/response only.** Carrying arguments once and streaming output back does not
   cover a live PTY, which needs input flowing the other way and a resize signal. This is
   an **extension**, not a contradiction — but it has to be designed before anything is
   deployed, or a later phase becomes a protocol break across a live fleet. Specifics are
   not published.
2. **`registry login --password-stdin` also needs client→host stdin**, and the
   credential lands in the *remote* Mac's keychain. Same frame type solves it; the
   trust/UX question ("this sends a registry password to that Mac") is worth an
   explicit confirmation dialog.
3. **`cp`, `save`/`load`, `export` move binary blobs.** The wire format is
   JSON-encoded messages — binary needs base64 (simple, ~33% overhead, fine for
   config files, bad for a 400 MB image tar) or a dedicated binary shape. Decide before
   promising fleet image transfer.
4. **Bind mounts, `-v` paths, and `--publish` ports are *host-relative*.** On a remote
   host, a file picker on the laptop selects a path that does not exist on the target
   Mac, and a published port is reachable at the *host's* address, not `localhost`.
   The run sheet must clearly bind "which Mac am I configuring", offer remote path
   completion (via `exec ls` on the host), and render port links as
   `http://<host>:<port>`. This is the single most likely source of user error in the
   whole app and has no equivalent in any local-only comparable.
5. **Restart/health policy ownership.** DECISIONS settles *that* we self-implement it;
   it doesn't settle *where the loop runs*. It should run in the **host-mode peer** —
   otherwise closing the laptop stops restarting containers on the minis. That makes
   host mode stateful (it needs a persisted policy store), which is a small but real
   expansion of "host mode just executes CLI args".

One non-conflict worth stating positively: because the wire protocol is **CLI args,
not typed RPCs**, every feature in the Phase-1 table is *automatically* a fleet feature
in Phase 2 at no marginal cost. That's an unusually strong property — Portainer needs a
purpose-built agent API per resource type to get the same result.

---

## Sources

- OrbStack: [Docker containers](https://docs.orbstack.dev/docker/), [Container, image, volume files](https://docs.orbstack.dev/features/native-files), [Release notes](https://docs.orbstack.dev/release-notes)
- Docker Desktop: [Use Docker Desktop](https://docs.docker.com/desktop/use-desktop/), [Dashboard walkthrough](https://oneuptime.com/blog/post/2026-02-08-how-to-use-docker-desktop-dashboard-effectively/view), [Resource Saver](https://dev.to/docker/what-is-resource-saver-mode-in-docker-desktop-and-what-problem-does-it-solve-gei), [multi-host contexts limitation (docker/cli#3352)](https://github.com/docker/cli/issues/3352)
- Podman Desktop: [Features](https://podman-desktop.io/features), [GitHub](https://github.com/podman-desktop/podman-desktop)
- Rancher Desktop: [Features](https://docs.rancherdesktop.io/1.6/getting-started/features/), [Containers UI](https://docs.rancherdesktop.io/ui/containers/)
- Portainer: [Environments](https://docs.portainer.io/admin/environments), [Edge Agent](https://docs.portainer.io/advanced/edge-agent), [Edge stacks to many environments](https://oneuptime.com/blog/post/2026-03-20-portainer-edge-stacks-multiple-environments/view), [Edge waiting room](https://oneuptime.com/blog/post/2026-03-20-edge-environment-waiting-room-portainer/view)
- Apple `container`: [Releases](https://github.com/apple/container/releases), [1.0.0](https://github.com/apple/container/releases/tag/1.0.0), plus repo-local `reference/container-cli.md` and `reference/json-schemas.md`
- Tailscale macOS: [Windowed macOS UI beta](https://tailscale.com/blog/windowed-macos-ui-beta), [Escaping the notch](https://tailscale.com/blog/macos-notch-escape), [Exit nodes](https://tailscale.com/docs/features/exit-nodes?tab=macos)
- [tdeverx/contained-app](https://github.com/tdeverx/contained-app) (PolyForm Noncommercial — read for ideas only)
