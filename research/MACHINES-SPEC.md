# Machines section — spec

Scope: **`container machine` only** — the CLI's own persistent Linux micro-VMs. Not
general-purpose VM management (the core owner's question, separate doc). This is the #1 gap in
`research/COMPETITORS.md` (~13 of ~19 competitors ship it), and `DECISIONS.md`'s
2026-08-02 XPC-vs-CLI entry already settled *how* to build it: **shell out and decode,
same as everything else.** The CLI exposes the full surface — create, delete, inspect,
list, logs, run, set, set-default, stop — so the earlier XPC spike is withdrawn and there
is no second integration path to design here, only the usual one: `Allowlist` schema,
`ContainerCLI` methods, captured fixtures, UI.

**Everything in this document is UI/CLI/security design. No app code was written and no
git commands were run**, per the task brief.

---

## 1. CLI surface

### 1.1 What is actually verified

`reference/cli-help/container-1.0.0-help.txt` (the authority for the Allowlist, per
`CLAUDE.md`) captures only the **top-level** `container machine --help` — the subcommand
list and the four EXAMPLES lines. It does **not** contain per-subcommand help the way
`volume`/`network` do (those show "Plugin not found" placeholders per subcommand, which
still confirms the subcommand exists and takes no undocumented global flags; `machine`
has no such placeholders at all). There is also no `container` binary on this machine to
run `container help machine <sub>` live — confirmed by `which container` returning
nothing. **This is the gap to close before writing any `Allowlist` row**, not something
this document can paper over with a plausible guess.

What the capture *does* give us, verbatim from the EXAMPLES block
(`reference/cli-help/container-1.0.0-help.txt:937-952`):

```
container machine create alpine:3.22 --name my-machine
container machine run -n my-machine uname
container machine run -n my-machine -- cat /proc/cpuinfo
container machine set -n my-machine cpus=4 memory=8G home-mount=ro
container machine stop my-machine
container machine delete my-machine
```

Plus the subcommand list and one-line descriptions
(`reference/cli-help/container-1.0.0-help.txt:962-971`):

```
create        Create a new container machine and boot it
delete, rm    Delete a container machine
inspect       Display detailed information about a container machine
list, ls      List container machines
logs          Fetch container machine logs
run           Run a command or interactive shell in a container machine,
              booting the container machine if necessary
set           Set container machine configuration values
set-default   Set the default container machine
stop          Stop a running container machine
```

### 1.2 Table: verified vs. inferred vs. unknown

Precision matters more than prose here — this is the direct input to `Allowlist`
`CommandSpec` rows, and per `CLAUDE.md`'s standing lesson, **a too-loose shape is the
dangerous direction.** So this table marks confidence explicitly rather than presenting
one flat list.

| Subcommand | Operands (verified) | Flags (verified) | Inferred, NOT verified | Notes |
|---|---|---|---|---|
| `create` | 1 image reference (`alpine:3.22`) | `--name` (long form only seen; short spelling unverified) | `--cpus`/`-c`, `--memory`/`-m`, `--home-mount`, `--os`/`--arch` (task brief states `create` defaults to `--os linux`, so the flag exists in some form) | **Open question:** does `create` accept sizing/home-mount inline, or must every new machine follow up with `set` before first boot? Not shown in any example. Must capture live. |
| `run` | machine name (via `-n`, not positional) + a trailing command | `-n <name>` (short form only seen — unverified whether `--name` also works here) | whether `--` is required before the trailing command the way `container run`/`exec` sometimes need it — **the exact separator trap `CLAUDE.md` calls out by name**, and the two examples show *both* with and without `--` (`run -n my-machine uname` vs. `run -n my-machine -- cat /proc/cpuinfo`), which is itself a signal that the separator is contextual and must be tested adversarially before encoding a `TrailingPolicy` | Booting-if-necessary is documented behavior, not inferred — "booting the container machine if necessary" is in the CLI's own one-line description. |
| `set` | machine name (via `-n`) + one or more `key=value` tokens | `-n <name>` | Confirmed keys so far: `cpus`, `memory`, `home-mount` (values `4`, `8G`, `ro` respectively, from the one example). Whether other keys exist (`arch`?), whether `home-mount` accepts `rw`/`off`/unset, whether multiple `key=value` tokens in one invocation is the only supported form or single-key calls also work | This is the config-mutation command the stop-apply-restart trap (§4) hangs off. |
| `stop` | machine name, **positional**, no `-n` | none shown | `--all`, `--signal`, `--time` (container's own `stop` has all three; unverified whether machine `stop` mirrors it or is simpler, since a VM shutdown is a different operation from a container SIGTERM) | **Asymmetry to flag loudly:** `stop` takes the name as a bare operand while `run`/`set` take it via `-n`. This is exactly the kind of per-subcommand flag-spelling trap that bit `volume create`'s `-s`-only sizing flag — do not assume one calling convention across the whole `machine` family. |
| `delete`/`rm` | machine name, positional | none shown | `--force`/`-f`, `--all`/`-a` (container's `delete` has both) | Same asymmetry note as `stop`. |
| `list`/`ls` | none shown | none shown | `--format`, `--quiet`/`-q`, possibly `--all` (by analogy to `container list`) | **Nothing captured at all.** The JSON shape for a machine list entry is completely unknown — see §1.3. |
| `inspect` | none shown | none shown | one or more names, by analogy to `container inspect` | Same fixture problem as `list`. |
| `logs` | none shown | none shown | `-n <lines>`, `--follow`/`-f`, possibly `--boot` (a machine *is* the micro-VM `container logs --boot` already reads for a container — worth checking whether `machine logs` is that same boot log, or a distinct machine-daemon log, or both) | Unverified whether machine logs are bounded/paginated the same way. |
| `set-default` | machine name (positional, per sembsa's competitor description: "Container machines: create, set default, stop, delete") | none shown | whether it takes `-n` or a bare operand | No capture at all; inferred purely from a competitor's feature description, not from the CLI itself. |

### 1.3 The fixture problem, stated plainly

`CLAUDE.md`'s single sharpest lesson is: **"Fixtures must be captured, never written."**
`volumes.json` and `networks.json` were fabricated flat shapes that didn't match the real
nested `configuration`/`status` payload, and `ContainerVolume` *threw* on every real
volume as a result — tests stayed green throughout because nothing exercised the real
shape. There is **zero captured JSON for `machine list`, `machine inspect`, or `machine
logs`** anywhere in this repo. Do not write a `ContainerMachine` Codable model from a
guess at what fields it "should" have (name, cpus, memory, home-mount, state — the
obvious ones from the `set` example) and then hand-write a fixture to match it. That is
the exact failure mode the lesson exists to prevent. **The fixture must come from a live
`container machine create` + `machine list --format json` + `machine inspect` on real
hardware before `ContainerMachine` is coded**, the same discipline the CLI owner's Phase 1 volume
and network work eventually followed.

### 1.4 Security implication — this is not a UI-only feature

Two things elevate machine support above "one more resource tab":

1. **`home-mount` is a filesystem grant**, and unlike a container's `--volume`, it isn't
   an arbitrary host path — it's a fixed mapping (the user's home directory) with an
   access mode (`ro`, and presumably `rw`/off). That is actually a *narrower* grammar than
   `MountPolicy`'s general bind-mount case (`checkMountSpec` in `Allowlist.swift`, which
   validates arbitrary `source:/dest[:ro|rw]` specs against `MountPolicy.allowsHostPath`),
   but it is still exposing the home directory — SSH keys and all — to a VM, so it needs
   its own narrow `ValueShape` (e.g. `.homeMountMode`, accepting only the CLI's actual
   enumerated values) rather than being folded into the general `.mountSpec` shape. Do not
   reuse `.mountSpec` here; it would accept syntax `home-mount` never takes.
2. **A machine is where containers *run*.** Shell access to a machine (`machine run`
   without a trailing command, or with an interactive shell) is a strictly bigger grant
   than `container exec`'s interactive shell, because a compromised or careless caller
   with a machine shell can reach *every* container inside it, not just one. The existing
   `ExecPolicy` enum (`Allowlist.swift`) already encodes exactly this asymmetry for
   containers — `.processListOnly` default, `.interactiveShell` only for a `ContainerCLI`
   built for the machine's own owner. `machine run`'s interactive form needs the same
   treatment, gated the same way, and **must never be the default a remote Phase 2 peer
   receives.** `DECISIONS.md`'s own note on this document's source material says it
   outright: "machine creation with home mounts is a filesystem grant" and sequencing
   should follow security cost, not market-frequency ranking. the review's standing verdict
   (`research/ALLOWLIST-AUDIT.md`) that the `Allowlist` isn't yet the fully-audited Phase 2
   boundary applies with extra force to a brand new subcommand family.

---

## 2. What competitors converge on

Synthesized from `research/COMPETITORS.md` §"Gaps Flotilla should consider" #1 and the
five per-product write-ups named in the brief.

- **iContainer** — the best-documented machine UI in the survey: create / start-stop /
  edit (CPUs, memory, home mount) / delete, with **dedicated Info / Shell / Logs tabs per
  machine**. COMPETITORS.md calls this out explicitly as "directly analogous to Flotilla's
  per-container detail tabs — the most obvious shape for Flotilla to copy if machines get
  built." This is the shape this spec adopts in §3.3.
- **Orchard** — "a configuration editor with an explicit **stop-apply-restart
  workflow**, because machine config cannot be changed live." This is the single most
  important UX constraint in the whole feature and gets its own section (§4). Also: live
  resource-usage tracking and home-directory mapping.
- **ContainerManager** (Bart Reardon) — persistent Linux VMs with integrated terminal
  access, boot configuration controls (CPU/memory), and diagnostic logging for
  troubleshooting. Notably the closest in spirit and stack to Flotilla (SwiftUI, SwiftTerm,
  menu bar + window) — its "boot configuration controls" language is more evidence for the
  stop-apply-restart pattern.
- **Davit** — creation, boot/stop, CPU/memory sizing, and terminal access. Nothing beyond
  what iContainer and Orchard already establish.
- **Silcrate** — persistent Linux machines with home-directory mapping that **boot the
  image's own init system** — worth noting because it implies the machine's own boot
  behavior (not just create/stop) is something users care about seeing, which supports
  giving machines their own Logs tab rather than folding machine events into the
  container Logs tab.
- **Container Desktop (sembsa)** — the odd one out: "Container machines: create, **set
  default**, stop, delete" — no edit/inspect mentioned. `set-default` is otherwise absent
  from every other competitor's description, and is the reason the CLI table above
  includes it as its own row rather than assuming it's covered by `set`.
- **IcontainU** — presets for Alpine and Rocky UBI-init images at creation time. Not
  something to build now, but worth remembering as the "smart create" idea already applies
  to machines too, alongside containers.

**The converged shape, in one sentence:** create / list / per-machine Info+Shell+Logs
tabs / edit CPU+memory+home-mount through a stop-apply-restart workflow / delete. Nobody
in the survey does anything more exotic than that.

---

## 3. Flotilla's Machines section

### 3.1 Sidebar and window shell — reuse, minimal new code

- **`Sources/Flotilla/Navigation.swift`** — add a `.machines` case to the `Section` enum
  (`enum Section: String, CaseIterable, Identifiable, Hashable`, currently `dashboard,
  containers, images, volumes, networks, settings`). Give it a title ("Machines") and a
  `systemImage`. Suggest `"cpu"` — distinct from containers' `"shippingbox"` and reads as
  "compute", which is what a machine is. Placed after Networks, before Settings, matching
  where competitors group it (a peer of containers/images/volumes/networks, not a System
  item).
- **`Sources/Flotilla/MainWindowView.swift`** — three additions, each mechanical:
  1. A sidebar `row(.machines, count: …)` in the same `SwiftUI.Section` block as the other
     four resources (`MainWindowView.swift:36-42`), following the existing rule: `nil`
     until the tab has been visited once (machines load lazily, same as Images/Volumes/
     Networks — `model.state == .loaded ? … : nil`).
  2. A `case .machines: MachinesView(model: model, ui: machinesUI)` arm in the detail
     switch (`MainWindowView.swift:166-183`).
  3. A `@State private var machinesUI = MachinesUIState()` alongside the existing
     `containersUI` (`MainWindowView.swift:18`), for the identical reason documented
     there: state owned by the window root survives a trip to another section and back;
     state owned by the detail view does not.
- **`Sources/Flotilla/SectionToolbar.swift`** — reused **unmodified**. It's already the
  shared control band for every list screen; `MachinesView`'s toolbar is a
  `SectionToolbar(search:, searchPrompt: "Search machines…", updated:, leading: …,
  trailing: …)` call, exactly like Images/Volumes/Networks presumably already are.

### 3.2 The list screen — `MachinesView.swift` (new file, modeled on `ContainersView.swift`)

Not a byte-for-byte copy, but the same shape, because the owner explicitly wants "the same
menus, configurations and embedded windows the containers side uses":

- A `MachinesUIState` observable object (new, mirroring `ContainersUIState` — search text,
  sort order, column customization), owned by `MainWindowView` per §3.1.
- A table, running-first, columns drawn from what `list`/`inspect` actually returns once
  captured (§1.3) — at minimum Name, State, CPUs, Memory, Home mount, Created, Default
  (a checkmark/star for whichever machine `set-default` points at, since that's a
  concept no other resource in this app has).
- Per-row actions mirroring `ContainersView.rowActions`: Start(via `machine run` with no
  command, i.e. boot-only)/Stop swap, an overflow menu for Details…, and a destructive
  Delete — same `iconButton` pattern, same "always visible, never hover-revealed"
  accessibility rule.
- `detailScreen`/`detailHeader`/`stepper` — reuse the **pattern**, not the code (these are
  private methods on `ContainersView`, keyed to `Container`). `MachinesView` needs its own
  copies keyed to whatever the machine model turns out to be, with the same back button,
  same prev/next stepper "as currently shown" semantics, same non-wrapping ends. This is
  mechanical duplication of a pattern already proven correct, not a new design.
- **A bulk-action bar is probably not warranted at v1.** Every competitor's machine list is
  small (people run one to three machines, not twenty containers), so the 2+-selected
  threshold `ContainersView.bulkActionBar` uses may simply never fire. Ship the per-row
  actions; add bulk only if real usage shows multiple machines being managed at once.
- **Cards toggle:** skip it initially. `ContainersView.Presentation` (list/cards) exists
  because container counts scale past twenty; machines don't. A table-only view is honest
  about the difference in scale between the two resources and is less to build.

### 3.3 The detail screen — `MachineDetailView.swift` (new file) + `MachineDetailTab` (new enum)

This is where the "the owner wants Info/Shell/Logs" convergent shape (§2) lands, and it's
**not** a rename of `ContainerDetailView` — the tab set is genuinely different:

- **`MachineDetailTab`**, a sibling enum to `DetailTab` (`ContainerDetailView.swift:1293`),
  not an extension of it — `DetailTab` carries `.processes`/`.files`/`.inspect` cases that
  don't apply to a machine (there is no `ps` inside a VM the way there's a process list
  inside a container in this app's model, and there's no separate "Files" browsing
  concept specified for machines). Proposed cases: `.info`, `.shell`, `.logs`,
  `.configuration` — the exact four the iContainer writeup names ("Info / Shell / Logs")
  plus Configuration, because unlike a container's Configuration tab (read-only — Apple's
  `container` has no update command, per `ContainerDetailView.swift:1205-1213`), a
  machine's configuration is genuinely mutable via `machine set`. That distinction is the
  whole reason §4 exists.
- **The tab strip itself** (`ContainerDetailView.tabBar`, lines 73-105 — icon + label,
  underline for the selected tab, left-aligned, transcribed from the mockup's `.tabs`
  CSS) is currently a `private var` on `ContainerDetailView`, so it can't be imported by a
  new file as-is. Worth promoting to a small shared view — something like `DetailTabStrip<Tab:
  CaseIterable & Identifiable & RawRepresentable>` taking a binding and a `systemImage`
  closure — the moment a second detail screen needs it, which this is. That's a real,
  cheap extraction (one file, no behavior change) rather than a speculative one, since two
  call sites now exist. Same argument applies to the `card`/`detailRow`/`meter` building
  blocks at the bottom of `ContainerDetailView.swift` (lines 296-351) — they're private
  methods, and `MachineDetailView`'s Info tab wants the identical visual language (a grid
  of titled cards with label/value rows and a labelled bar meter for CPU/memory). Promote
  them to a small shared file (e.g. `DetailCards.swift`) rather than re-typing three
  near-identical private methods into the new file.
- **Info tab** — a grid of cards, same shape as `ContainerDetailView.overview`: a state
  card (running/stopped, started/created), a resource card (allocated CPUs/memory — no
  live sampling exists for machines any more than it does for containers beyond
  `StatsSampler`, so show allocation, not usage, unless `machine inspect` turns out to
  carry live figures), and a home-mount card (mode, and the path if `inspect` exposes one).
  Do **not** invent a network/ports card the way `ContainerDetailView.networkCard` has one
  — nothing in the CLI capture suggests a machine publishes ports the way a container
  does; leave it out until `inspect`'s real JSON says otherwise, per the "fabricated
  readouts" lesson two paragraphs above it in `ContainerDetailView.swift`.
- **Logs tab** — reuse the `LineListView`/`DisplayLine` machinery
  (`ContainerDetailView.swift:383-442`, already `private` but small enough to promote
  alongside the card helpers) with a new fetch call (`AppModel.fetchMachineLogs`, calling
  a new `ContainerCLI.machineLogs`). Same search/highlight/wrap/Copy/Save shape as
  `LogsTab`; skip the Boot Log toggle unless §1.2 confirms `machine logs` distinguishes
  boot vs. process output the way container logs does.
- **Shell tab** — see §3.4, it's the one with a real wrinkle.
- **Configuration tab** — genuinely new; see §4.

### 3.4 Terminal reuse — one real collision to fix first

`TerminalSessionStore` (`Sources/Flotilla/TerminalTab.swift:37-156`) is keyed by
`[String: [TerminalSession]]` where the `String` is a container ID. **Machine names and
container names are different namespaces in `container` itself but would collide in this
dictionary** — a container named `web` and a machine named `web` would share one entry,
so opening a shell in one could show up as, or clobber, the shell state of the other. The
type itself needs no changes (it's already generic over "a string key with sessions
under it"); the fix is **two separate store instances** — `AppModel.terminals` (existing,
containers) and a new `AppModel.machineTerminals`, both `TerminalSessionStore`, keyed by
machine name in the second case. Cheapest correct fix; do not namespace the keys inside
one store when a second instance is free.

The bigger design point: `TerminalTab.openShell()` builds its argv through
`Allowlist.validated(["exec", "-i", "-t", container.id, "--", shell], execPolicy:
model.cli.execPolicy)` (`TerminalTab.swift:354-357`). A `MachineShellTab` needs the exact
same shape of call, but against a new `CommandSpec` for `["machine", "run"]`, gated by
its own policy value — reusing `ExecPolicy` is the leaner move (a third case, e.g.
`.machineShell`, or reusing `.interactiveShell` if the two are judged equivalent risk) over
inventing a parallel enum, but that judgement call belongs to whoever does the security
review, not this spec.

**One behavioral difference from `TerminalTab` to design around explicitly:** container
`TerminalTab` refuses outright when the container isn't running ("Container is not
running… Start '<id>' to open a shell inside it" — `TerminalTab.swift:220-228`), because
`exec` requires an already-running container. `machine run` is documented to **boot the
machine if necessary**. So `MachineShellTab`'s empty/not-running state should not block —
it should say something like "Opening a shell will start this machine" and let the
button proceed, since refusing here would contradict the CLI's own stated behavior and
train users to manually start machines that the shell action would have started anyway.

### 3.5 Creating a machine — `ModalCard`, reusing the Run sheet pattern

Per `CLAUDE.md`: "a form is a question you answer and dismiss" — `ModalCard` (red ×, dim
behind) wraps Run, New Volume and New Network already. A "New Machine…" form belongs in
the same bucket, not embedded. Model it on `RunSheetView`'s validated live-command-preview
convention (referenced but not read in full here — same UI family as the Run sheet
`ContainersView` opens via `showingRun`/`runSheet`, `ContainersView.swift:83,143-147,535`):
image reference field, name field, and — pending the §1.2 open question about whether
`create` takes sizing/home-mount flags inline — either the same fields as `machine set`
or a note that they're configured in a follow-up step. **Do not guess this — it changes
whether "New Machine" is a one-step or two-step flow**, and building the wrong one means
redoing the form once the real flag set is captured.

---

## 4. The stop-apply-restart trap — designed, not just flagged

The CLI's own EXAMPLES block states the constraint outright: *"Change the container
machine configuration (takes effect after restart)"*, followed by `set` → `stop` → `run`
(which reboots it). `CLAUDE.md`'s own hard-won-lessons list has a directly-named version
of this exact failure mode: *"A setting that drives nothing is worse than a missing
one."* A Configuration tab that lets someone type `cpus=8` and shows no further feedback
is precisely that trap — the value is accepted, nothing observably changes, and the user
has no way to tell whether it worked, needs a restart, or silently failed.

Design, following Orchard's already-proven pattern from `research/COMPETITORS.md`:

1. **The Configuration tab is a real editable form** (CPU stepper/field, memory field,
   home-mount picker), unlike the container Configuration tab's read-only YAML rendering
   — the whole reason a container's tab is read-only ("Apple's `container` has no command
   that mutates an existing container… no `container update`") does not apply here, since
   `machine set` is exactly that mutating command for machines.
2. **Apply always calls `machine set` immediately** — there's no reason to defer the CLI
   call itself; `set` is documented to succeed and take effect at next boot regardless of
   current state.
3. **The UI's job is representing "applied but not yet running with this config."**
   Immediately after a successful `set`, show a persistent banner/badge on the
   Configuration tab (and arguably on the machine's row in the list, and the detail
   header) reading something like *"cpus=8, memory=8G pending — restart this machine to
   apply."* This state needs to be tracked client-side (comparing last-applied `set`
   values against what `inspect` currently reports as running, if `inspect` exposes a
   "reports vs. configured" distinction once captured — otherwise track it purely in
   `AppModel` as "we called set with these values and haven't seen a subsequent stop+start
   since").
4. **Offer the restart, don't just describe it.** A "Restart to Apply" button that runs
   `machine stop` then `machine run` (with no command, i.e. boot-only) back-to-back, with
   the same confirmation weight as any other action that interrupts running containers —
   because stopping the machine stops **every container running inside it**, which is a
   materially bigger blast radius than stopping one container. Word the confirmation
   accordingly ("Restarting this machine will also stop N container(s) running inside
   it"), not with the generic "This cannot be undone" copy the container delete
   confirmations use.
5. **If the machine is already stopped when Apply is pressed**, no restart affordance is
   needed — the new config takes effect on next `run` naturally. The pending banner should
   read differently in that case ("Applied — will take effect next start") rather than
   offering a restart button for a machine that isn't running to restart.

---

## 5. `FlotillaCore` additions (the CLI owner's side, by `PHASE1.md` ownership)

Named for completeness of the file-level ask; these are `FlotillaCore` and stay
Foundation-only per `PHASE1.md`:

- `ContainerMachine` model in `Models.swift` — **only after** a live fixture is captured
  (§1.3). Do not write this from inference.
- `Tests/FlotillaCoreTests/Fixtures/machines.json` (list) and `inspect-machine.json` —
  captured, not written, same as every other fixture in that directory.
- `ContainerCLI` methods: `listMachines`, `inspectMachine`, `createMachine`,
  `deleteMachine`, `stopMachine`, `setMachineDefault`, `setMachineConfig`, `machineLogs`,
  `runInMachine` — each routes through `Allowlist.validated` exactly like every existing
  mutation (`ContainerCLI.swift`'s `start`/`stop`/`remove`/etc. pattern, lines 170-207).
- `Allowlist.commands` rows for `["machine", "create"]`, `["machine", "delete"]`,
  `["machine", "inspect"]`, `["machine", "list"]`, `["machine", "logs"]`,
  `["machine", "run"]`, `["machine", "set"]`, `["machine", "set-default"]`,
  `["machine", "stop"]` — **held until §1.2's open questions are resolved by live
  capture.** Encoding a guessed shape now risks the exact "too-loose in the dangerous
  direction" mistake `--publish`'s bare-port bug and `start`'s 32-operand bug both were
  (`Allowlist.swift:381-382,863-869`).
- A new `ValueShape.homeMountMode` (or similarly named) rather than reusing
  `.mountSpec` — see §1.4.
- `AppModel` additions: `machines`, `machinesState` (same idle/loading/loaded/unavailable/
  failed shape as `state`/`imagesState`/etc.), `machineTerminals: TerminalSessionStore`
  (§3.4), `lastMachineDetailTab` (mirroring `lastDetailTab`).

---

## 6. Open questions to resolve before implementation, ranked

1. **Does `machine create` accept `--cpus`/`--memory`/`--home-mount` inline, or is a
   follow-up `set` mandatory before first boot?** Changes the New Machine form's shape.
2. **Does `machine run` require `--` before its trailing command in all cases, or only
   some?** Both forms appear in the CLI's own examples. This is the named separator trap
   from `CLAUDE.md` and needs adversarial live testing, not inference, before any
   `TrailingPolicy` is chosen.
3. **What does `machine inspect`/`machine list --format json` actually decode to?**
   Blocks the `ContainerMachine` model and every fixture. Highest-value single capture to
   do first, since it also answers most of §1.2's other unknowns (state field, exact
   home-mount enum values, whether ports/network info exists at all).
4. **Does `home-mount` support values beyond `ro`, and is there an "off"/unset state?**
   Needed for the config form's picker and for the `.homeMountMode` shape's exact
   whitelist.
5. **Is `machine logs` bounded/tailed the same way `container logs` is, and does it carry
   a boot-vs-process distinction?** Affects whether the Logs tab needs a toggle at all.
6. **What should `ExecPolicy` look like for `machine run`'s interactive form?** A security
   design question, not a UI one, but it blocks §3.4 — flagged for whoever owns that
   review (`research/ALLOWLIST-AUDIT.md`'s the review, per the standing verdict that the
   Allowlist isn't yet the complete Phase 2 boundary).

No design mockup exists for a Machines screen — unlike Containers, Main Window and
Settings, `research/review/mockups/` has nothing for machines. Everything in §3 is
derived from the existing container-detail and main-window mockups' *structure*
(sidebar, embedded detail, tab strip) plus the competitor survey's *content* (which
fields, which tabs), not from a Flotilla-specific visual design. Worth commissioning one
before the app owner builds this, the same way the container detail screen had one to transcribe
element-for-element rather than eyeball.
