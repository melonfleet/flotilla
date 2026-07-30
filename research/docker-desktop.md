# Docker Desktop — reference document for Flotilla

**Purpose:** this document exists so the owner can compare Flotilla's design against Docker
Desktop's actual, current behavior. It is **documentation-derived**. Nobody on this
project has hands-on access to Docker Desktop in this environment — there is no way to
launch it here, and no live install was used while writing this. Every claim below is
either:

- **documented** — sourced from `docs.docker.com`, Docker's own blog, or Docker release
  notes, with a link; or
- **reported** — sourced from a GitHub issue, forum thread, or community post describing
  observed behavior, with a link; or
- **unverified** — explicitly flagged as such in the final section, with a note on what
  would settle it.

Nothing here is first-hand observation. Where two sources disagreed (e.g. the Resource
Saver icon changing over time), both are cited and the discrepancy is called out rather
than silently resolved.

---

## 1. The complete UI

Docker Desktop's dashboard is organized as a left-hand navigation with the following
top-level sections, per the docs' own overview page and supporting pages:

- **Containers** — list of running/stopped containers, container detail view. See §2–3.
- **Images** — browse/manage local images and images available via Docker Hub search.
- **Volumes** — manage named volumes; inspect data.
- **Builds** — build history, BuildKit build details, in-progress/completed builds; this
  is where the multi-select "delete" UI bug below was reported.
- **Models** — Docker Model Runner UI for pulling/running local AI models (part of
  Docker's 2025 AI push).
- **MCP Toolkit** — discovers, configures, and organizes Model Context Protocol (MCP)
  servers into "Profiles"; has its own **Catalog**, **Clients**, and **OAuth** sub-tabs.
  A "Secret Engine" stores PATs/OAuth tokens and injects them into MCP containers at
  runtime. [Docker MCP Toolkit docs](https://docs.docker.com/ai/mcp-catalog-and-toolkit/toolkit/)
- **Docker Hub** — search, browse, pull, run, or view details of images without leaving
  the app. [Explore Docker Desktop](https://docs.docker.com/desktop/use-desktop/)
- **Logs** — a unified, cross-container/cross-source log view, distinct from the
  per-container Logs tab (§3). Announced in beta in Docker Desktop 4.65.0
  (2026-03-16: "Added a new **Logs** view where you can explore logs from all sources in
  one unified view. (Beta)") and reached general availability in 4.72.0 (2026-05-06:
  "The **Logs** view is now generally available."). [Release notes](https://docs.docker.com/desktop/release-notes/)
- **Kubernetes** — standalone single- or multi-node cluster, see §4.
- **Extensions** — third-party tool marketplace embedded in the dashboard, see §6/§7.
- **Gordon** — Docker's AI agent, see below.
- **Settings** — gear icon in the header; see §4.
- **Troubleshoot** — separate menu for restart/reset/diagnostics, reached from the tray
  icon or a bug icon in the header.
- **Notifications Center** — bell icon; release announcements, install progress, etc.
- **Quick Search** — header-level search across containers, images, volumes,
  extensions, and docs.
- **Docker menu / tray icon** — the persistent background presence: dashboard toggle,
  settings, updates, quit.

**Gordon** (AI assistant): built into Docker Desktop, the `docker ai` CLI, and
docs.docker.com; free with any Docker account. Has shell access, filesystem operations,
full Docker CLI access, a Docker-docs knowledgebase via RAG, and web access. A
specialized sub-agent handles Dockerfile → Docker Hardened Image (DHI) migration.
Accessed via Docker Desktop 4.74+, "Gordon" tab, after login.
[Gordon docs](https://docs.docker.com/ai/gordon/), [capabilities](https://docs.docker.com/ai/gordon/concepts/capabilities/)

**Status bar**: shows engine status and, when idle, a Resource Saver indicator (§5).

---

## 2. The containers list, in detail

This is the view most directly comparable to Flotilla's table.

### Columns

Docker's own docs page on the Containers view does **not** enumerate the column set or
defaults in prose — WebFetch of `docs.docker.com/desktop/use-desktop/container/`
returned only that the view "lists all running and stopped containers and applications,"
with a Search field and per-row lifecycle actions. **The exact default column set could
not be confirmed from primary docs** (see §9).

What is documented, from release notes recovered via search (exact release/version not
pinned down — see §9):

> "Columns can be resized, hidden and reordered. Columns sort order and hidden state is
> persisted, even after Docker Desktop restarts." Row selection is also persisted across
> tab switches and restarts.

This "columns" feature has had real bugs: [docker/for-mac#6391](https://github.com/docker/for-mac/issues/6391)
reported that hidden columns in the Containers tab **re-enabled themselves** a few
seconds after being hidden, on Docker Desktop 4.10.0/4.10.1 (macOS). The issue is
tagged `status/3-fixed` in GitHub but the fetched thread contains no maintainer
explanation of the root cause.

### Filtering, search, running-only

- A **Search** field locates a container by name. [Containers view docs](https://docs.docker.com/desktop/use-desktop/container/)
- A **Compose filter** lets you show only containers belonging to one Compose project —
  reported via search results, not confirmed against primary docs text directly (treat
  as reported, not documented verbatim).
- An "only show running containers" style toggle is referenced by third-party tools
  (e.g. Podman Desktop copying the idea, [podman-desktop/podman-desktop#707](https://github.com/podman-desktop/podman-desktop/issues/707))
  as something Docker Desktop already has; the exact wording/location in current Docker
  Desktop UI is **unverified** — see §9.

### Inline charts

- A **"Show charts"** control appears directly above the containers list and renders a
  CPU/memory usage graph. Per a Docker community forum thread, one user found the
  control "present on some installations but absent on others" with identical settings,
  and speculated it might be gated by Docker Hub sign-in status — this is anecdotal, not
  documented behavior, and should be read as a **reported inconsistency**, not a
  confirmed feature flag. [Forum thread](https://forums.docker.com/t/enable-container-cpu-and-memory-usage-charts-in-docker-desktop-for-mac/136593)
- Clicking into a container's own stats shows "a dashboard of the current stats updated
  every few seconds" (same thread).

### Per-row and bulk actions

- Per-row lifecycle actions: start, stop, pause, resume, restart, delete. [Containers view docs](https://docs.docker.com/desktop/use-desktop/container/)
- Container **rename** is documented as CLI-only (`docker container rename`); community
  discussion (Laracasts, Docker forums) reports **no GUI affordance** to rename a
  container from the dashboard — reported, not exhaustively confirmed against every
  current version.
- Multi-select / bulk actions exist but have a documented UI bug: on the **Builds** tab
  (not Containers specifically), selecting multiple items hides the delete button until
  the window is resized — [docker/desktop-feedback#330](https://github.com/docker/desktop-feedback/issues/330),
  reported against Docker Desktop 29.4.1 on Windows, open/unfixed at time of writing.
  Whether the identical bug affects the Containers tab's own multi-select is
  **unverified**.

---

## 3. Container detail view

Per `docs.docker.com/desktop/use-desktop/container/`, selecting a container opens a
detail pane with these tabs (confirmed present in current docs; exact left-to-right
ordering in the live UI is not something the fetched text guarantees, so treat ordering
as approximate):

- **Logs** — real-time container stdout/stderr, with `Cmd+F`/`Ctrl+F` in-view search,
  matches highlighted, timestamps.
- **Inspect** — low-level container metadata: local path, image version, SHA-256,
  port mappings, and other `docker inspect`-equivalent data.
- **Bind mounts** — mount configuration details (page confirms the tab exists; detailed
  contents beyond "mount configuration" were not returned by the fetch — treat depth as
  **unverified**).
- **Exec** (or **Debug**, when enabled) — run commands inside the container; Debug mode
  offers "a customizable toolbox" with pre-installed tools (vim, nano, htop, curl) for
  containers that lack a shell.
- **Files** — browse the filesystem of running *or stopped* containers; view, edit,
  copy, delete files; see which files were recently added/modified/deleted; right-click
  → "Save as…" to download a file or folder. [Collabnix walkthrough](https://collabnix.com/say-goodbye-to-complex-commands-manage-container-files-with-ease-in-docker-desktop/)
- **Stats** — CPU, memory, network, and disk usage over time for that container.

Quick action buttons (pause/resume/start/stop) are also available directly from this
detail panel, not just the list row.

---

## 4. Settings, exhaustively

From `docs.docker.com/desktop/settings-and-maintenance/settings/`:

**General**
- Start Docker Desktop at sign-in (default: disabled)
- Open Dashboard on start (default: disabled)
- Theme (default: follow system)
- Shell completions (default: disabled)
- Container terminal / Docker terminal / Debug features (default: disabled)
- VM Time Machine backup exclusion on Mac (default: disabled)
- containerd image store (default: enabled)
- WSL 2 engine on Windows (default: disabled — i.e. Hyper-V backend is the base default
  on Windows, WSL2 is opt-in per this doc summary; treat as reported, worth
  double-checking against current Windows-specific docs since this has shifted across
  versions)
- File sharing implementation on Mac: VirtioFS (default)
- Rosetta emulation on Apple Silicon (default: disabled)
- Usage statistics (default: enabled)
- Enhanced Container Isolation (default: disabled)
- CLI hints (default: enabled)
- Docker Scout analysis (default: enabled)
- Background SBOM indexing (default: disabled)
- Mac configuration auto-check (default: enabled)

**Resources**
- CPU/memory limits (host-percentage sliders)
- Swap (default: 1 GB)
- Disk usage limit, image storage location
- **Resource Saver mode** toggle (see §5)
- File sharing: synchronized file shares (paid tiers), virtual file shares
- Proxies: system/manual/none, container-specific proxy for image pulls, Basic/Kerberos/NTLM auth
- Network: custom Docker subnet (default `192.168.65.0/24`), kernel networking for UDP
  on Mac, host networking on Mac
- WSL integration (Windows): per-distro toggle

**Docker Engine** — raw JSON edit of the daemon config (`$HOME/.docker/daemon.json`),
editable via the Dashboard's text editor or externally.

**Builders** — inspect active BuildKit builders (version, status, capabilities, disk
usage), switch builders, create new ones via CLI, remove non-selected builders,
start/stop `docker-container` driver builders.

**AI** — configuration for Gordon and Docker Model Runner.

**Kubernetes** — per `docs.docker.com/desktop/features/kubernetes/`:
> "Choose your cluster type: **Kubeadm** creates a single-node cluster and the version
> is set by Docker Desktop. **kind** creates a multi-node cluster and you can set the
> version and number of nodes."

Additional options: "Show system containers (advanced)" toggle, "Edit cluster" (switch
provisioner or node count), stop/reset cluster, and a `KubernetesImagesRepository`
setting to source control-plane images from a registry other than Docker Hub. kind
provisions faster (~30s vs ~1min for kubeadm) and works with Enhanced Container
Isolation. [Kubernetes docs](https://docs.docker.com/desktop/features/kubernetes/)

**Software Updates**
- Automatically check for updates (default: enabled)
- Always download updates (default: disabled)
- Automatically update components (default: enabled)

**Extensions**
- Enable Docker Extensions (default: disabled, per the summarized source — worth
  re-checking, since Extensions being off-by-default is a meaningful product signal if
  true and should not be taken on faith; flagged in §9)
- Restrict to marketplace-only extensions
- System container visibility toggle

**Beta / "Features in development"** — opt into experimental features and the Developer
Preview program.

**Notifications** — toggle status updates, recommendations, announcements, surveys;
errors and release notifications are always on.

**Advanced (Mac only)** — CLI tool install path (system vs user), default socket
permission, privileged port mapping permission (ports 1–1024).

**Docker Offload** — cloud-based execution: enable (subscription-gated), idle timeout,
GPU support toggle.

---

## 5. Behavioral details

### Resource Saver mode

Introduced in **Docker Desktop 4.22**, released **2023-08-09**
([Docker blog](https://www.docker.com/blog/docker-desktop-4-22/)). At launch, Docker's
own announcement stated:

> Resource Saver "automatically activates after 30 seconds of inactivity (no running
> containers)" and displays "a leaf icon ... over the whale icon in the Docker Desktop
> menu and dashboard" — already saving "up to 38,500 CPU hours daily across all Docker
> Desktop users" at announcement time.

Current docs (`docs.docker.com/desktop/use-desktop/resource-saver/`) describe the same
feature but with **different specifics**, which is worth flagging as a genuine
discrepancy rather than an error on one side — the feature has evidently changed since
2023:

- Default idle timeout is now **5 minutes**, not 30 seconds, before the Linux VM is
  stopped (host-side CPU/memory drops "by 2GB or more").
- The current docs describe the indicator as a **moon icon** ("A moon icon displays on
  the Docker Desktop status bar as well as on the Docker icon in the system tray"), not
  the leaf icon from the 2023 announcement. This could reflect a UI refresh; it was not
  possible to pin down exactly which release changed the icon — flagged in §9.
- Non-container commands (e.g. listing images/volumes) generally do **not** wake the VM;
  container-touching commands do, taking roughly 3–10 seconds to restart the VM (faster
  on Mac/Linux, slower on Windows with Hyper-V).
- Configurable via Settings → Resources, or directly via `autoPauseTimeoutSeconds` in
  the settings-store JSON (minimum 30 seconds, no restart required). File locations
  differ by OS (`~/Library/Group Containers/group.com.docker/settings-store.json` on
  Mac).

[Resource Saver docs](https://docs.docker.com/desktop/use-desktop/resource-saver/),
[4.22 announcement](https://www.docker.com/blog/docker-desktop-4-22/)

### The ⌘Q / quit ambiguity

This is a long-standing, well-documented source of user confusion, and predates
Resource Saver.

- [docker/for-mac#6167](https://github.com/docker/for-mac/issues/6167) (filed
  2022-02-11, against Docker Desktop 4.5.0 on macOS 12.2/Apple Silicon): earlier Docker
  Desktop versions could be "backgrounded" via ⌘Q — the GUI window closed but the
  daemon/menu-bar presence stayed alive. As of 4.5.0, ⌘Q instead **fully quits** the
  application; there is no longer a way to dismiss just the window while keeping Docker
  running. The reporter's framing: "Previous versions of Docker Desktop were intended to
  be left running 'backgrounded' by launching the app without the GUI frontend
  presentation."
- On Linux, the ambiguity cuts the other way: [docker/desktop-linux#109](https://github.com/docker/desktop-linux/issues/109)
  and [docker/desktop-linux#184](https://github.com/docker/desktop-linux/issues/184)
  report that quitting the Docker Desktop **UI** also kills any open terminal windows
  attached to it — an unexpected side effect of what looked like a GUI-only action.
- A community-documented workaround for Mac users who want containers stopped cleanly
  before quitting: run `docker ps -q | xargs -r -L1 docker stop` and then
  `osascript -e 'quit app "Docker"'`, because quitting the app does not reliably stop
  containers gracefully on its own.

Net: whether ⌘Q "quits the app," "stops containers," or "leaves the VM running" has
genuinely changed across versions and platforms, and is exactly the kind of ambiguity
users still hit — it is not resolved by one canonical current answer, per the sources
above.

### Engine stopped/crashed handling

Reported (community sources, not a single canonical doc page): Docker Desktop can get
stuck showing "Docker Desktop is starting…" indefinitely; causes range from low disk
space to WSL2 kernel issues (Windows) to Virtualization.framework problems (Mac). The
CLI offers `docker desktop restart` for a scripted restart. Persistent failures often
require unregistering WSL2 distros (Windows) or a full reinstall. This whole area is
**reported troubleshooting folklore**, not a documented state-machine — Flotilla
shouldn't assume Docker Desktop has a clean, documented crash-recovery contract; the
evidence suggests it doesn't always work well. [Troubleshooting roundup](https://oneuptime.com/blog/post/2026-02-08-how-to-troubleshoot-docker-desktop-not-starting/view)

### Flicker-avoidance / polling vs streaming

**Unverified.** No primary-source documentation was found describing Docker Desktop's
specific mechanism for avoiding UI flicker on live-updating views (containers list,
Stats tab, Logs view), nor precise polling intervals vs. streaming. The Logs view GA
note (4.72.0) and various Gordon UI bugfixes in recent release notes (e.g. 4.82.0 fixing
a blank chat area, 4.78.0 fixing a React warning on first keystroke) show Docker
actively fixes UI-state bugs in these panes, which indicates the live views are
React-based and stateful, but this is inference, not a documented flicker-avoidance
strategy. Would need Docker's own engineering blog (if one exists on this topic) or
inspection of the shipped Electron/React bundle to confirm.

---

## 6. Compose integration

**Context for why this section exists:** Apple's `container` CLI has no Compose concept
at all — no multi-container project file, no `up`/`down` for a project, no dependency
graph. This section is included so Flotilla's team understands what Docker Desktop does
here **in order to know what cannot be directly ported**, not as a spec for a Flotilla
Compose feature.

- Docker Desktop's Dashboard groups containers into a collapsible entry per Compose
  project, keyed off the project name (from the top-level `name:` field in
  `compose.yaml`, or the directory name by default). This grouping is a **Docker
  Desktop UI construct** — it is not visible via `docker ps`, only in the Dashboard.
- Compose 4.22 (2023-08-09) added the `include:` top-level key, letting large Compose
  projects be split into subprojects/building blocks that load as self-contained units —
  relevant context for how "a project" is defined in the UI, since `include` composes
  multiple files into one logical group. [4.22 blog](https://www.docker.com/blog/docker-desktop-4-22/)
- A grouped Compose project can reportedly be started/stopped as a unit from the
  Containers view, and a Compose-project filter can narrow the containers list to one
  project — this was recovered from secondary sources (blog/tutorial content), not
  quoted verbatim from `docs.docker.com`, so treat the exact UI affordance (a filter
  chip vs. a dropdown vs. something else) as **reported, not confirmed**.

Bottom line for Flotilla: Docker Desktop's Compose grouping is a client-side UI
convenience layered on data Compose itself already produces (project labels on
containers). Since `container` has no equivalent labeling concept, Flotilla cannot copy
this pattern without inventing its own project/grouping metadata — which is out of scope
unless a future decision explicitly adds one.

---

## 7. What's genuinely good (per docs and community sentiment)

- **Resource Saver mode** is a well-regarded, low-friction idle-cost reduction — stopping
  the whole Linux VM rather than just pausing containers, with a fast (3–10s) resume.
  [Docs](https://docs.docker.com/desktop/use-desktop/resource-saver/)
- **Onboarding speed**: reviewers note new developers can "pull images and be up and
  running within minutes instead of spending half a day" on environment setup — a
  consistently cited strength across review aggregators (G2/TrustRadius/Capterra
  summaries).
- **In-container Files tab**: browsing, editing, and downloading files from a running or
  stopped container without a shell is a genuinely useful GUI-only capability with no
  CLI equivalent as convenient. [Collabnix](https://collabnix.com/say-goodbye-to-complex-commands-manage-container-files-with-ease-in-docker-desktop/)
- **Columns persistence** (resize/hide/reorder retained across restarts) once it worked
  reliably is a small but real quality-of-life feature directly relevant to Flotilla's
  own Columns picker (implemented recently per the repo's git log:
  "a Columns button beside the view switcher").
- **Gordon** as an embedded, container-aware AI agent with shell + CLI + docs RAG access
  is a differentiated feature with no direct Flotilla analog, and not something Flotilla
  needs to chase, but worth naming as a genuine capability gap between the two tools.

---

## 8. What users complain about

- **CPU/memory overhead at idle and under load.** Multiple GitHub issues describe
  high `vmmem`/`dockerd` CPU usage even with no containers running
  ([docker/for-win#8742](https://github.com/docker/for-win/issues/8742),
  [docker/for-mac#5413](https://github.com/docker/for-mac/issues/5413),
  [docker/for-mac#1131](https://github.com/docker/for-mac/issues/1131)); one report
  cites 2GB+ RAM held by `vmmem` after reboot with nothing running, ballooning further
  once a dev container starts. Enabling Kubernetes was specifically called out as making
  idle CPU usage much worse (30–60% vs 7% with Kubernetes off, one user's report).
- **VM overhead vs. native tools generally.** The Linux VM model itself (whether via
  HyperKit historically, Apple's Virtualization.framework now, or the newer opt-in
  Docker VMM backend introduced in 4.35) is a recurring complaint vector, since it's
  structurally heavier than a lighter native container runtime. Docker's own newer VMM
  backend claims to close some of this gap (e.g. `git status` on bind-mounted native ARM
  workloads), but doesn't support Rosetta-emulated Intel images, so it's not a strict
  replacement. [VMM docs](https://docs.docker.com/desktop/features/vmm/)
- **Slow/unpredictable startup and shutdown.** Windows reports of 140–180 second
  graceful shutdown/startup cycles, or Docker stuck "starting" for hours
  ([docker/for-win#15015](https://github.com/docker/for-win/issues/15015)); Mac reports
  of up to 80 seconds for all containers to come up on Apple Silicon after Desktop
  itself launches.
- **The ⌘Q / quit ambiguity** — covered in depth in §5. Users don't have a stable mental
  model of whether quitting stops containers, tears down the VM, or does something
  version-dependent; on Linux, quitting the UI has even closed unrelated terminal
  sessions. This is arguably the single most relevant complaint for Flotilla to actively
  avoid, since Flotilla is also a menu-bar-adjacent app making the same category of
  decision.
- **Licensing change (August 2021).** Docker Desktop stopped being free for
  organizations with 250+ employees or $10M+ revenue, requiring a paid Business
  subscription; this was widely discussed on Hacker News
  ([HN thread](https://news.ycombinator.com/item?id=28369570)) and in trade press
  ([InfoWorld](https://www.infoworld.com/article/2268969/docker-desktop-is-no-longer-free-for-enterprise-users.html)).
  Not directly relevant to Flotilla's technical design, but relevant as a trust/goodwill
  data point in "what not to repeat," and moot anyway since Flotilla is explicitly
  non-commercial per `CLAUDE.md`.
- **UI bugs in exactly the areas Flotilla is building.** The hidden-columns bug
  ([docker/for-mac#6391](https://github.com/docker/for-mac/issues/6391)) and the
  multi-select delete-button-hidden bug
  ([docker/desktop-feedback#330](https://github.com/docker/desktop-feedback/issues/330))
  both land squarely on table/column/bulk-selection UI — the same surface Flotilla just
  built (per the repo's recent commits on Columns and checkboxes). Worth treating as a
  concrete regression-test reminder: resize/hide-column persistence and multi-select
  action visibility are both places Docker Desktop has visibly shipped bugs before.
- **General "gets slow suddenly sometimes" sentiment** on lower-spec machines, per review
  aggregator summaries (G2/TrustRadius/Capterra) — vaguer than the GitHub issues above,
  but a consistent secondary theme.

---

## 9. Unverified / needs confirmation

- **Exact default column set for the Containers list** (e.g. Name, Image, Status, Port,
  CPU, Memory, Created, Last started — some of these were named in a search-engine
  auto-summary, not confirmed against fetched primary-doc text). Would need a direct,
  full-text capture of `docs.docker.com/desktop/use-desktop/container/` (the fetch tool
  used here returned a lossy summary, not raw markdown) or a screenshot from someone
  running Docker Desktop.
- **Which specific release introduced the resizable/hideable/persisted Columns
  feature**, and which release fixed the re-enabling bug in
  [docker/for-mac#6391](https://github.com/docker/for-mac/issues/6391). Only the buggy
  version (4.10.0/4.10.1) is confirmed; the fix version is not.
- **Exact wording and placement of the "only show running containers" toggle** in
  current Docker Desktop. Confirmed only that similar tools (Podman Desktop) reference
  it as an existing Docker Desktop capability; not confirmed against Docker's own docs
  text.
- **Whether "Show charts" is a stable, always-on control or something gated/flaky**, per
  one forum poster's unconfirmed theory about Docker Hub sign-in gating it. Needs either
  an official changelog entry or a second independent report.
- **Resource Saver icon: leaf (2023 announcement) vs. moon (current docs).** Both are
  sourced, but the specific release that changed it was not found. Would need to
  cross-reference dated release notes for an icon-change entry, or a set of dated
  screenshots.
- **Whether "Enable Docker Extensions" defaults to off** in current Docker Desktop, as
  one settings-summary claimed — this is a meaningful claim (Extensions being opt-in)
  that deserves a direct doc quote rather than a paraphrase.
- **Windows WSL2-vs-Hyper-V default backend** — the General-settings summary above
  states WSL2 is default-disabled, but this has reportedly changed across Docker Desktop
  versions and Windows versions; would need a version-pinned doc quote.
- **UI flicker-avoidance mechanism and polling/streaming cadence** for live views —
  no primary source found at all; flagged as fully unverified in §5.
- **Engine crash/recovery as a documented state machine** — what was found is
  troubleshooting folklore (forums, blogs), not an authoritative Docker doc describing
  guaranteed crash-recovery behavior. Treat the entire §5 "Engine stopped/crashed
  handling" subsection as community-sourced, not documentation-sourced.
- **Compose-project filter UI affordance** (§6) — recovered from tutorial/blog content,
  not a verbatim doc quote; the precise interaction (filter chip, dropdown, grouped
  section header) is not confirmed.
- Everything in this document is, by construction, secondhand — no claim here should be
  treated as equivalent to a screenshot or a live install. Where this document says
  "documented," that means "found in Docker's own docs," not "confirmed by running the
  app."
