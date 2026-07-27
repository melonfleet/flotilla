# Flotilla research — preferences, settings & configuration

Scope: every user-facing preference the comparables expose (General, resources, file
sharing, network/proxy/DNS, updates, notifications, login item, theme, telemetry,
advanced) **plus** the data-layer view — where config is stored, in what format, with
what defaults, precedence, import/export and reset.

Read alongside `PLAN.md` (6 phases) and `DECISIONS.md` (settled choices). Nothing below
proposes anything already rejected there (no ssh, no gRPC, no k8s, no Containerization
framework linking, no Electron).

**One framing note that drives everything in §4:** Flotilla is the only product here
that has a **fleet**. Every comparable has exactly one settings scope ("this Mac").
Flotilla has three — *client app*, *this host*, *that remote host* — and none of the
comparables can be copied on that axis. That's the design problem this doc is really
about.

---

## 1. What the comparables do

### Docker Desktop (macOS) — the maximalist

The settings surface is 13 tabs. Worth walking in full because it's the superset
everyone else subsets.

**General**
- Start Docker Desktop when you sign in (default off) — login item.
- Open Docker Dashboard at startup (default off) — separate from the login item.
- Choose theme — Light / Dark / Use System (default: system).
- Configure shell completions (default off).
- Choose container terminal — integrated vs system terminal.
- Enable Docker terminal / Enable Docker Debug by default.
- Include VM in Time Machine backups (Mac-only, default off) — nice Mac-native touch.
- Use containerd for pulling and storing images (default on).
- Choose Virtual Machine Manager — Docker VMM vs Apple Virtualization framework
  (Mac/Apple Silicon only).
- Choose file sharing implementation — VirtioFS / gRPC FUSE / osxfs (default VirtioFS).
- Use Rosetta for x86/amd64 emulation (default off).
- Send usage statistics (default **on** — see anti-patterns).
- Show CLI hints (on), Enable Docker Scout image analysis (on), background SBOM
  indexing (off).
- **Automatically check configuration** (Mac-only, default on) — detects when
  something outside Docker Desktop has modified its symlinks/config, and offers to
  repair. This is the "user edited the file behind my back" problem, handled
  explicitly. Directly relevant to us.

**Resources → Advanced**
- CPU limit, Memory limit (default 50% of host RAM), Swap (default 1 GB), Disk usage
  limit, Disk image location (relocatable).
- **Resource Saver** — drops VM resource use during idle, auto-restarts on demand with
  a 3–10 s delay.

**Resources → File sharing**
- Virtual file shares — list of host dirs exposed to containers. Defaults: `/Users`,
  `/Volumes`, `/private`, `/tmp`, `/var/folders`.
- Synchronized file shares — the paid, faster bind-mount path (Pro/Team/Business).

**Resources → Proxies** — two independent proxy configs:
- *Docker Desktop proxy* (host-level traffic: login, pulls) and *Containers proxy*
  (traffic from inside containers). Each: System / No proxy / Manual (HTTP URL,
  HTTPS URL, bypass list). Basic auth creds cached in the OS credential store;
  Kerberos/NTLM is Business-only.

**Resources → Network**
- Docker subnet (default `192.168.65.0/24`), Use kernel networking for UDP (Mac),
  Enable host networking (Mac).

**Docker Engine** — a raw JSON editor over `$HOME/.docker/daemon.json`. The escape
hatch for anything not in the GUI.

**Builders** — inspect / select / create / remove / stop-start BuildKit builders.

**Kubernetes** — enable, provisioning method (kubeadm vs kind), show system
containers, reset cluster.

**Software updates**
- Automatically check for updates (on), Always download updates (off), Automatically
  update components without a full restart (on).

**Extensions** — enable extensions (off), allow only marketplace extensions, show
extension system containers.

**Notifications** — per-category toggles: task/process status, Docker
recommendations, announcements, surveys. Errors and release notifications are
**always on and not user-disableable**.

**Advanced (Mac only)** — the privileged bits:
- CLI tools install location: System (`/usr/local/bin`) vs User (`$HOME/.docker/bin`).
- Allow the default Docker socket (`/var/run/docker.sock`) — prompts for password.
- Allow privileged port mapping (ports 1–1024) — prompts for password.

**Beta features / AI / Docker Offload** — experimental opt-ins, cloud execution.

**Troubleshoot (not a settings tab, but the reset surface)**
- Reset to factory defaults (wipes containers, images, volumes, networks, build cache
  **and** settings), Uninstall, Gather diagnostics → produces a diagnostic ID.

**Data layer**
- User settings: `settings-store.json`. Path is inconsistently documented —
  `~/Library/Group Containers/group.com.docker/settings-store.json` and
  `~/Library/Application Support/Docker/settings-store.json` both appear in Docker's
  own docs *(verify on a real install)*. Contains **settings that don't appear in the
  GUI at all**, which is why support answers keep pointing at it.
- Admin/managed settings: `admin-settings.json`, structured as
  `"key": { "locked": true, "value": … }`. `locked: true` → immutable in GUI, CLI and
  config files; `locked: false` → acts as a suggested default the user may change.
  Placed via the installer's `--admin-settings` flag. Keys include `analyticsEnabled`,
  `disableUpdate`, `silentModulesUpdate`, `filesharingAllowedDirectories`, `proxy`,
  `containersProxy`, `extensionsEnabled`, `onlyMarketplaceExtensions`,
  `enhancedContainerIsolation`, `defaultNetworkingMode`, `blockDockerLoad`,
  `linuxVM.dockerDaemonOptions`, `kubernetes`.
- Precedence (Docker's stated order): user-specific cloud policy → org default policy
  → local `admin-settings.json` → macOS configuration profiles (proxy only) →
  user settings.
- Locked settings render **greyed out** with a "managed by your administrator" style
  affordance.
- Gated: Settings Management requires a **Docker Business subscription**.

### OrbStack — the minimalist native-Mac analogue (closest to Flotilla in spirit)

The whole settings surface is roughly **four panes and ~10 knobs**, and it is a
deliberate product statement.

**System**
- Use Rosetta to run Intel code (`rosetta`, default on).
- Memory limit (`memory_mib`) — a *ceiling*, not a reservation; memory is released
  dynamically when containers don't need it. Default cap ~8 GB.
- CPU limit (`cpu`) — a percentage, explicitly documented as "not a reservation".
- Hide OrbStack volume (`mount_hide_shared`) — hide the `~/OrbStack` mount from the
  Finder sidebar/Desktop. A pure Mac-native courtesy setting.

**Docker**
- IPv6 for containers (off by default "for compatibility").
- Engine config — JSON editor, same escape-hatch idea as Docker Desktop; also
  editable directly at `~/.orbstack/config/docker.json` (`orb restart docker` to
  apply).
- containerd image store (experimental).

**Network**
- Allow access to container domains & IPs (`network_bridge`) — reach containers by IP
  from the Mac with no port forwarding.
- Proxy (`network_proxy`) — defaults to the **system-wide** proxy; override only if
  you need to.

**Storage / Disk**
- Change disk location (Settings → Disk → Change Location).
- `orb delete docker` — drop Docker data only. `orb reset` — full factory reset.

**Advanced (CLI-only, no UI)**
- `ssh.expose_port` (default false), `docker.node_name` (default `orbstack`).
- Per-machine overrides: `orb config set machine.<name>.memory_mib 4096`,
  `machine.<name>.cpu`, `machine.<name>.disk_bytes`.

**Data layer**
- Config lives under `~/.orbstack/config/` (`docker.json`, `kubelet.conf`, …).
- **Every setting is settable from both the GUI and `orb config`** — this parity is
  stated as a design principle, and it's the single best idea in this whole survey.
- The docs page carries **no** section for updates, notifications, login item,
  telemetry, or theme — either handled silently or genuinely absent. Notable: the
  most-liked Mac container GUI ships fewer prefs than anyone, not more.

### Podman Desktop — the "settings as a typed registry" model

Preference panes: Resources (per-provider machine CPU/memory/disk), Proxy,
Registries, Extensions, Kubernetes, Docker compatibility, Appearance, CLI tools.

The interesting part is the **schema**. Every setting is a declared, typed,
defaulted, documented key — extensions contribute keys into the same namespace. All
of it lands in one file:
`~/.local/share/containers/podman-desktop/configuration/settings.json`.

Representative keys (verbatim, with defaults):

| Key | Type | Default | Note |
|---|---|---|---|
| `preferences.appearance` | string | `"system"` | system / dark / light |
| `preferences.login.start` | boolean | `true` | start on login |
| `preferences.login.minimize` | boolean | `false` | start minimized |
| `preferences.ExitOnClose` | boolean | platform | quit vs minimise to tray |
| `preferences.TrayIconColor` | string | `"default"` | **requires restart** |
| `preferences.update.reminder` | string | `"startup"` | `startup` or `never` |
| `preferences.zoomLevel` | number | `0` | −3…3 |
| `preferences.navigationBarWidth` | number | `160` | 48–240 px |
| `preferences.{extensionId}.engine.autostart` | boolean | `true` | per-provider autostart |
| `proxy.enabled` | number | `0` | 0=System, 1=Manual, 2=Disabled |
| `proxy.http` / `proxy.https` / `proxy.no` | string | `""` | |
| `registries.defaults` | array | `[]` | default registries + mirrors |
| `telemetry.enabled` | boolean | `true` | "send anonymous usage data to Red Hat" |
| `extensions.autoCheckUpdates` / `autoUpdate` | boolean | `true` | |
| `userConfirmation.bulk` | boolean | `true` | confirm bulk actions |
| `userConfirmation.fetchImageFiles` | boolean | `true` | |
| `tasks.toast` | boolean | `false` | task notifications |
| `window.restorePosition` | boolean | `true` | |
| `editor.integrated.fontSize` / `terminal.integrated.fontSize` | number | `10` | 6–100 |
| `terminal.integrated.lineHeight` | number | `1` | 1–4 |
| `kubernetes.Kubeconfig` | string | `~/.kube/config` | |

Also documented, in the same file and same doc page, an **"Internal settings"**
section — `window.bounds`, `statusBar.pinnedItems`, `navbar.disabledItems`,
`list.{listKind}` (per-list column preferences), `learningCenter.expanded`,
`welcome.version`, `telemetry.check`, `extensions.registryUrl`. UI state and user
preference share one store.

Deprecated keys are kept and marked in place (`preferences.navigationBarLayout` —
"Deprecated since 1.29"). Experimental settings are typed `object|null` and named
"EXPERIMENTAL: …" in the description.

Podman Desktop also documents **managed configuration** for enterprise deployment,
and explicitly notes proxying happens at three levels: OS, Podman engine
(`containers.conf`), and per-container env vars.

### Rancher Desktop — the best *precedence* model of the lot

Preference panes: Application (admin access, auto-start, background start, hide
notification icon, path management strategy, telemetry, updater, theme, debug),
Virtual Machine (CPU, memory, mount type, emulation/Rosetta, network), Container
Engine (dockerd/moby vs containerd; **Allowed Images** registry allowlist),
Kubernetes (enable/disable, version, port, Traefik, Flannel), WSL (Windows only).

**Data layer — the part worth copying:**
- Settings file: `~/Library/Application Support/rancher-desktop/settings.json`, with a
  top-level **`"version": 18`** integer used for schema migration.
- Structure is nested and typed: `application.{adminAccess,debug,extensions,
  pathManagementStrategy,telemetry,updater,autoStart,startInBackground,
  hideNotificationIcon,window,theme}`, `containerEngine.{name,allowedImages,
  mobyStorageDriver}`, `virtualMachine.{numberCPUs,memoryInGB,mount,…}`,
  `kubernetes.{…}`, `experimental.{…}`.
- **Deployment profiles**: two separate macOS plists —
  `io.rancherdesktop.profile.defaults` and `io.rancherdesktop.profile.locked`, in
  `/Library/Managed Preferences/` (admin, MDM-delivered), `/Library/Preferences/`
  (legacy) or `~/Library/Preferences/` (user). Admin profiles win over user profiles.
- **Precedence, in order:** admin profile defaults → user profile (only if no admin
  profile) → saved `settings.json` → command-line args → built-in defaults →
  **locked profile values override everything**.
- The *defaults* profile also serves as first-run seeding: "if all required settings
  are provided, then no first-run dialog will be shown."
- Profiles survive **factory reset and uninstall** — "Deployment profiles will not be
  modified or removed by Rancher Desktop."
- Locked settings render read-only in both GUI and CLI.
- CLI parity: `rdctl list-settings` (dump active config as JSON), `rdctl set --key=val`
  (chainable), `rdctl create-profile --from-settings` (**export current settings as a
  deployment profile** — plist for macOS, .reg for Windows), `rdctl factory-reset`.

### Colima / Lima — config-file-first, no GUI at all

- One YAML per profile: `~/.colima/<profile>/colima.yaml`. `colima template` prints
  the fully-commented template; `colima start --edit` opens it in `$EDITOR`.
- Keys and defaults (abridged): `cpu: 2`, `memory: 2` (GiB), `disk: 100` (GiB),
  `rootDisk: 20`, `arch: host`, `runtime: docker`, `vmType: qemu`, `cpuType: host`,
  `mountType: virtiofs|sshfs`, `mounts: []`, `mountInotify: false`,
  `network.address: false`, `network.mode: shared|bridged`, `network.interface: en0`,
  `network.dns: []`, `network.dnsHosts: {}`, `network.gatewayAddress: 192.168.5.2`,
  `sshConfig: true`, `sshPort: 0`, `forwardAgent: false`, `docker: {}` (raw
  daemon.json passthrough), `kubernetes.{enabled,version,k3sArgs,port}`,
  `autoActivate: true`, `binfmt: true`, `rosetta: false`,
  `nestedVirtualization: false`, `portForwarder: ssh`, `hostname`, `env: {}`,
  `provision: []` (system/user/after-boot/ready hook scripts).
- **Immutability is documented per key**: `arch`, `runtime`, `vmType`, `mountType`
  "cannot be changed after the VM is created"; `disk` "can only be increased".
- Flags override the file for that run; the file is the persistent truth. Profiles
  (`--profile`) give you N independent configs.

### Apple `container` — the thing we actually wrap (most important section)

This is the runtime's own config layer, and Flotilla's settings design has to sit on
top of it rather than duplicate it.

**Config file:** TOML, loaded at **service startup**, first-match-wins precedence:
1. `~/.config/container/config.toml` (user)
2. `<installRoot>/etc/container/config.toml` (shipped with the pkg)
3. hardcoded defaults for any absent key

**Full schema** (from `docs/container-system-config.md`):

```toml
[build]
rosetta  = true                     # Bool
cpus     = 2                        # Int
memory   = "2048mb"                 # MemorySize
image    = "ghcr.io/apple/container-builder-shim/builder:<tag>"

[container]
cpus     = 4                        # Int      ← default CPUs for new containers
memory   = "1g"                     # MemorySize ← default memory for new containers

[dns]
domain   = <unset>                  # String?

[kernel]
binaryPath = "opt/kata/share/kata-containers/vmlinux-…"
url        = "https://github.com/kata-containers/…"
digest     = "sha256:…"

[network]
subnet   = <unset>                  # CIDRv4?
subnetv6 = <unset>                  # CIDRv6?

[registry]
domain   = "docker.io"              # String

[vminit]
image    = "ghcr.io/apple/containerization/vminit:<tag>"

[plugin.<id>]                       # per-plugin namespace, plugin-defined schema
```

All top-level sections are optional; an omitted section falls back to defaults
wholesale. Source of truth is `Sources/ContainerPersistence/ContainerSystemConfig.swift`.

**Critical CLI facts for us:**
- `container system property list [--format json|toml]` prints the **merged effective
  config**. There is **no `property set`/`get`/`unset` subcommand** in the current
  command reference — writing config means *editing the TOML file by hand*.
  *(verify against the installed version at build time — this is a young CLI.)*
- Config is read **once at service start**, so `container system stop && start` is
  required for any change to take effect.
- `container system dns create|delete|list` is separate and **needs sudo** — it
  registers `*.domain` with the macOS resolver so the domain resolves from the host.
  Setting `[dns] domain` alone does nothing user-visible without it.
- Per-run resource overrides exist as flags: `container run -c/--cpus`,
  `-m/--memory`; `container build -c` (default 2), `-m` (default 2048MB).
- `container registry login/logout/list` owns registry credentials — Flotilla should
  drive that, not reimplement credential storage.

**What this means:** there is **no VM-sizing pane to build**. Apple `container` runs
one micro-VM per container with no shared host VM to size. The Docker/OrbStack/Colima
"Resources: CPU + memory + disk sliders" pane has *no analogue*. What exists instead
is (a) `[container] cpus/memory` = *defaults for new containers*, and (b) per-run
flags. That's a much smaller, much better settings surface — and it's a real
differentiator to present clearly rather than fake a resources slider.

### Fleet / menu-bar comparables (Tailscale, MDM admin consoles)

- **Tailscale for macOS** — the closest menu-bar-with-a-fleet analogue. Preferences
  are a short submenu off the menu-bar icon: Run unattended, Start on login, Use
  Tailscale DNS, Use Tailscale subnets, Run as exit node, Allow incoming connections.
  Everything else is server-side policy, not a local pref.
- **System policies**: Tailscale exposes per-*menu-item* MDM policies —
  `StartOnLoginMenuItem`, `RunExitNode`, `PreferencesMenu` — that **show or hide** UI
  affordances, not just lock values. That's a level beyond Docker/Rancher's
  grey-it-out: an admin can make a menu item disappear entirely.
- **Admin consoles (Jamf/Kandji)**: settings that apply to *many machines* are
  authored once as a profile and scoped to a smart group; per-device deviation is an
  exception, not the norm. The relevant lesson for Flotilla Phase 3: fleet settings
  want a *template + per-host override* shape, not 8 independent settings screens.

---

## 2. Patterns worth stealing

1. **GUI/CLI parity as a design rule (OrbStack).** "All settings can be changed from
   both the command line (`orb config`) and the app." Every setting is a key with a
   name; the GUI is one renderer of that key space. Why: it makes settings
   scriptable, diffable, supportable, and — crucially for us — it makes them
   *transmittable over the wire to a remote host* almost for free. If a setting is a
   named key with a typed value, `RemoteHost` can get/set it with two Wire messages.

2. **A typed, documented, defaulted settings registry (Podman Desktop).** One table:
   key, type, default, description, and the UI generated from it. Why: no drift
   between the pane and the store, defaults are declared once, and the doc page *is*
   the schema. In Swift this is a `SettingsKey<T>` value type + a static registry —
   cheap, and it makes the Jamf payload key list self-documenting.

3. **Rancher's defaults-vs-locked split, on two plists.** `…profile.defaults` seeds
   first run; `…profile.locked` overrides everything, permanently, and survives
   factory reset. Why it beats `jamf-config-profile.md`'s current "managed value wins"
   rule: the admin can *suggest* (mode=host as a starting point the user may change)
   or *enforce* (allowlist is not yours to edit) with the same mechanism. On macOS
   the "locked" half is nearly free — `/Library/Managed Preferences/<domain>.plist`
   already outranks the user domain in `UserDefaults.standard`.

4. **Export current settings as a deployment profile (`rdctl create-profile
   --from-settings`).** Configure one Mac by hand, export, deploy to the other seven.
   For an 8-node personal fleet this is *the* onboarding workflow, and it makes
   Phase 6 something you can test long before Jamf is involved.

5. **Locked settings visibly greyed out with an explicit "managed" label
   (Docker, Rancher).** Never a control that silently does nothing.

6. **Per-item MDM visibility policies (Tailscale).** Hide, not just disable.
   Worth a look for Phase 6 host-mode minis, where a whole client-mode UI is noise.

7. **`container system property list --format json` as a first-class fleet read.**
   No comparable does this because none has a fleet: showing the *merged effective
   config* of all 8 hosts side by side, with drift highlighted, is a feature Docker
   Desktop structurally cannot have. Registry domain, DNS domain, default
   cpus/memory, kernel digest — all four are things that silently differ across a
   hand-built fleet and cause "works on mini-3 only" bugs.

8. **The raw-config escape hatch (Docker Engine JSON editor, OrbStack engine config,
   `colima start --edit`).** Ship a real TOML editor for `~/.config/container/config.toml`
   with validation and a "restart service to apply" button, rather than trying to
   surface every key as a control. Covers everything Apple adds to the schema later
   without an app update.

9. **Docker's "Automatically check configuration" (Mac).** Detect that the file
   changed underneath you and offer to reconcile, instead of clobbering.

10. **Confirmation preferences as first-class settings (Podman's
    `userConfirmation.bulk`).** A fleet app that can `container delete -a` across 8
    hosts needs this *more* than a single-machine app does.

11. **Explicit, documented immutability and restart-required flags (Colima's "cannot
    be changed after creation", Podman's "requires restart").** Say it in the UI at
    the control, not in a doc.

12. **A schema `version` integer with migrations (Rancher's `"version": 18`).**
    Costs one field on day one; saves a corrupt-prefs bug report later.

13. **Sensible Mac-native small touches** — "Include VM in Time Machine backups",
    "Hide OrbStack volume from Finder". Cheap, and they read as *native* in a way that
    a settings slider never does.

---

## 3. Anti-patterns / things to avoid

1. **Settings sprawl.** Docker Desktop: 13 tabs, ~60 controls, including AI, Offload,
   Beta Features, Extensions and Docker Scout — most of which are product surface, not
   user need. OrbStack ships ~10 knobs and is the one people praise for being simple.
   For a personal 8-node hobby fleet, the OrbStack budget is the right one.

2. **Undocumented / GUI-invisible settings.** Docker's `settings-store.json` "contains
   all settings, including those that may not appear in the Docker Desktop GUI" — so
   support answers become "hand-edit this JSON". OrbStack's `ssh.expose_port` and
   `docker.node_name` are CLI-only with no UI. If a setting exists, it should be
   discoverable in the app.

3. **Destructive apply.** `rdctl set` "typically triggers a Kubernetes reset."
   Changing Docker's disk image location relocates the whole image store. Users learn
   to fear the settings screen. **Never let a Flotilla preference change stop or
   delete a running container without an explicit, specific confirmation.**

4. **Settings that silently don't apply.** Colima has a pile of keys that are inert
   after VM creation (`arch`, `vmType`, `runtime`, `mountType`; `disk` grows only).
   Apple `container` has our own version of this: config.toml is read **once at
   service start**, so an edited value does nothing until restart. If we surface those
   keys, we must surface the restart requirement at the control and offer the restart.

5. **Reset that conflates settings with data.** Docker's "Reset to factory defaults"
   destroys *all containers, images, volumes, networks and build cache* along with the
   preferences. `orb reset` likewise. Users reach for it wanting a clean *config* and
   lose their data. Split it: reset preferences ≠ delete data ≠ forget hosts.

6. **Telemetry on by default** (Docker `Send usage statistics` default on; Podman
   `telemetry.enabled` default `true`). For a personal, non-commercial app the correct
   amount of telemetry is **zero**, and saying so is a feature.

7. **Enterprise config gated behind a paid tier.** Docker's Settings Management needs a
   Business subscription. Nothing about writing a plist justifies a paywall; ours is
   free because it's just macOS.

8. **Internal UI state mixed into the user settings file.** Podman Desktop's
   `settings.json` holds `window.bounds`, `statusBar.pinnedItems`, `welcome.version`
   next to real preferences — so you can't hand someone your settings file, and
   "reset settings" and "reset window layout" are the same operation.

9. **Proxy configured at three disconnected levels** (Podman: OS / engine
   `containers.conf` / per-container env; Docker: separate host-proxy and
   containers-proxy panes). Users can't tell which one is in effect.

10. **Deprecated keys left live in the schema** (Podman's `navigationBarLayout`,
    "deprecated since 1.29"). Delete with a migration instead.

11. **Missing the boring settings.** OrbStack's docs have no update-channel,
    notification, login-item or telemetry settings at all. Simplicity is good;
    *unanswerable* ("does this launch at login? can I turn off that notification?") is
    not. The boring ones are exactly what a menu-bar app needs.

12. **A settings file the app rewrites wholesale**, clobbering hand edits. If we let
    users edit `config.toml` in the app, we must round-trip it, not regenerate it.

13. **Secrets in the settings file.** Registry credentials, certificate private keys
    and peer identities belong in the Keychain, never in a plist or an exported
    profile. This matters double for us: export/import of a host list must be
    explicitly incapable of carrying a private key.

---

## 4. → Proposed for Flotilla

### 4.0 Storage & precedence model (the data-layer decision) — **[core]**, Phase 1

**Preference domain:** `dev.melonfleet.Flotilla` *(matches the placeholder in
`reference/jamf-config-profile.md`; pick the final bundle ID before Phase 1 ships —
changing it later strands users' prefs.)*

Four stores, each with one job:

| Store | Holds | Why |
|---|---|---|
| `UserDefaults` (`~/Library/Preferences/dev.melonfleet.Flotilla.plist`) | scalar prefs: mode, port, theme, intervals, toggles | free MDM override path; `defaults read/write` works for support |
| **Keychain** | TLS identity (by label), peer fingerprint allowlist, any registry creds | already settled in `DECISIONS.md` / `PLAN.md`; keeps secrets out of exports |
| **SwiftData** | host inventory, per-host overrides, history/stats | already in the stack; hosts are records with relationships, not a plist blob |
| **Window/UI state** | sidebar width, selected tab, column layout | separate from preferences — so "reset settings" doesn't move your window (fixes anti-pattern #8) |

**Precedence (adopt Rancher's model, adapted):**

```
built-in defaults
  < managed "defaults" seed   (/Library/Managed Preferences, applied first-run only)
    < user setting            (UserDefaults / Settings UI)
      < per-host override     (host-scoped settings only; set on that host)
        < managed "locked"    (/Library/Managed Preferences — always wins)
```

On macOS the *locked* tier is nearly free: keys in
`/Library/Managed Preferences/dev.melonfleet.Flotilla.plist` already outrank the user
domain via `UserDefaults.standard`. The *defaults* tier needs an app-side convention —
a nested `defaultsSeed` dictionary copied into the user domain once on first run.
`UserDefaults.objectIsForced(forKey:)` tells the UI which controls to grey out.

> **Extends `reference/jamf-config-profile.md`.** That doc currently says "if a managed
> value is present it wins". Recommend upgrading to the two-tier defaults/locked split
> before Phase 2 writes the settings reader, because retrofitting precedence later
> means rewriting every settings accessor. No conflict with `DECISIONS.md`.

**Typed settings registry — [core], Phase 1.** One `SettingsKey<T>` type
(name, type, default, scope: `.app | .host | .perHost`, `requiresRestart: Bool`) and
a static registry. The Settings UI, the Wire get/set messages, the Jamf key list and
the export format all derive from it. This is the single highest-leverage decision in
this document: it's what makes remote settings and managed settings cost almost
nothing later.

**Schema `version` integer + migration path — [core], Phase 1.** Rancher's
`"version": 18`. One field, day one.

### 4.1 Phase 1 — local MVP settings

**General — [core]**
- Launch Flotilla at login (`SMAppService`, off by default).
- Show in menu bar / show in Dock / both (menu-bar apps need this; `MenuBarExtra`).
- Theme: System / Light / Dark, plus the watermelon accent from `design/branding.md`.
- Refresh interval for `container ls`/`stats` polling (default 5 s; "Off" allowed) —
  a menu-bar app that polls a CLI in a `Process` every second will show up in Activity
  Monitor and on battery. This is the one resource setting we genuinely need.
- Confirm before destructive actions: delete container / delete image / prune / any
  bulk action (default **on**, per Podman's `userConfirmation.bulk`).

**`container` CLI integration — [core]**
- Path to the `container` binary (default `/usr/local/bin/container`, with a "detect"
  button) — the preflight in `DECISIONS.md` needs somewhere to record what it found.
- Auto-start the `container` API service if it's not running (default: ask).
- Show the detected CLI version + "check for a newer `container` release" — feeds the
  guided-install flow already settled in `DECISIONS.md`.

**Defaults for new containers — [core]**
- Default CPUs and memory for `container run` (mirrors `[container] cpus/memory`;
  Flotilla applies them as `-c`/`-m` flags, or offers to write them to config.toml).
- Default registry (mirrors `[registry] domain`, default `docker.io`).
- Explicitly **[skip]** a Docker/OrbStack-style CPU/RAM/disk *resources slider pane*.
  There is no shared host VM to size — one micro-VM per container. Faking that pane
  would be inventing a control that does nothing.

**Notifications — [core]**
- Per-category toggles (container exited unexpectedly, image pull finished, build
  finished, host went offline). Default: errors + host-offline on, the rest off.
- Follow Docker's one good rule here: *don't* let users disable genuine error
  notifications — but unlike Docker, don't ship announcement/survey/recommendation
  categories at all, because we have nothing to announce.

**`config.toml` editor — [later]**, Phase 1 read-only → Phase 3 editable
- Phase 1: read-only view of `container system property list --format json`.
- Later: a validated TOML editor over `~/.config/container/config.toml` with
  round-tripping (not regeneration), an explicit "requires service restart" banner,
  and a restart button. This is the OrbStack/Docker engine-config escape hatch and it
  future-proofs us against Apple adding schema keys.

**Telemetry — [core] (as a stated non-feature)**
- No analytics, no crash upload, no phone-home. Put a line in the Settings UI saying
  so. Costs nothing, and it's the correct answer for a personal non-commercial app.
  *(Coordinate with the review's `deployment-ops.md` — if Sparkle's optional anonymous
  system-profile reporting is ever enabled, it must be opt-in and disclosed here.)*

**Reset — [core]**
- Three distinct, separately-confirmed actions, never merged (anti-pattern #5):
  *Reset preferences to defaults* · *Forget all hosts and trust* · *Reset window
  layout*. **Flotilla must never offer to delete container/image data as part of a
  settings reset** — that's the CLI's job and the user's decision.

### 4.2 Phase 2 — host mode / client mode over mTLS

- **Mode: Client / Host / Both** — [core]. Must be a `UserDefaults` key
  (`mode`) from day one so Phase 6 can force it; already specified in
  `jamf-config-profile.md`.
- **Host mode settings** — [core]: `listenPort`, advertise via Bonjour (on/off),
  Bonjour service name (default: the Mac's local hostname), require mTLS (locked on,
  shown but not editable), idle/allowlist behaviour.
- **Identity & trust** — [core]: Keychain label for the identity (default
  `Flotilla Identity`), generate/regenerate self-signed identity, show own SHA-256
  fingerprint (with copy button), `peerAllowlist` and `trustAnchorFingerprints`
  management UI. Fingerprints in the Keychain; **never** in an exportable plist.
- **Manual host entry** — [core], and it's mandatory per `DECISIONS.md`: hostname/IP +
  port, stored as records, editable.
- **Connection tuning** — [later]: connect timeout, retry/backoff, keepalive. Sensible
  defaults first; expose only if they turn out to matter.

### 4.3 Phase 3 — fleet view: the scoped-settings problem

This is where Flotilla stops having a comparable and has to make its own call.
Proposed model, in priority order:

- **Per-host settings, edited in the client, applied on the host** — [core].
  Two Wire messages, `getSettings` / `setSettings`, over the typed registry from §4.0.
  Falls straight out of the GUI/CLI-parity pattern (#1) if settings are named keys.
  *Extends `reference/wire-protocol.md` with two message types — worth flagging to
  whoever owns that doc.*
- **Per-host identity settings** — [core]: nickname, colour/tag, role, notes,
  "include in aggregate view", per-host poll interval (a mini on Wi-Fi shouldn't be
  polled like the local machine).
- **Fleet defaults + per-host override** — [core]. One template ("all hosts poll every
  10 s, all hosts default 2 CPUs") with explicit per-host deviations shown as
  overridden. This is the Jamf/Kandji admin-console shape (#7 in §1), and it's how
  8 machines stay manageable without 8 settings screens.
- **Config drift view** — [later], Phase 3. Merged
  `container system property list --format json` from every host in one table, with
  differing keys highlighted. Uniquely available to us; genuinely useful on a
  hand-built fleet; **read-only first** — writing config.toml remotely means editing
  a file and restarting a service on a machine you're not sitting at.
- **Import / export host list + settings** — [core], Phase 3. JSON export of the
  typed registry + host inventory (Rancher's `--from-settings`). Two hard rules:
  **never export private keys**, and export fingerprints as *fingerprints* so the
  importing machine still has to make its own trust decision.
- **Push settings to all hosts** — [later], Phase 3/6. Powerful and dangerous; needs
  a diff preview and per-host confirmation. Arguably better served by the Phase 6
  profile than by a button.

### 4.4 Phase 4 — streaming, exec, restart/health

- **Log viewer prefs** — [core]: default tail lines (`container logs -n`, default 200),
  wrap, timestamps, follow-on-open, buffer cap, monospace font size (Podman's
  `terminal.integrated.fontSize` is the precedent).
- **Stats/sparkline prefs** — [core]: sample interval, history window retained in
  SwiftData, and a retention/prune setting so history doesn't grow unbounded.
- **Exec/terminal prefs** — [later]: default shell (`/bin/sh`), default user, working
  dir, "open in Terminal.app instead" (Docker's *choose container terminal*).
- **Self-implemented restart/health policy** — [core] *for this phase*, and it is
  settings-heavy because `DECISIONS.md` commits us to implementing it ourselves:
  per-container restart policy (`no` / `on-failure` / `always`), max retries, backoff,
  health check command + interval + timeout + failure threshold. Stored per container
  in SwiftData (the CLI has nowhere to put them), scoped per host, and it wants a
  fleet-level default with per-container override.

### 4.5 Phase 5 — updates

- **Sparkle settings — [core]**: automatically check for updates (on), automatically
  download (off), check interval, update channel (stable / prerelease), "Check Now",
  current version + link to release notes. Docker's three-toggle set is the right
  granularity.
- Use Sparkle's own `UserDefaults` keys (`SUEnableAutomaticChecks`,
  `SUAutomaticallyUpdate`, `SUScheduledCheckInterval`, `SUFeedURL`) rather than
  wrapping them in custom keys — they then sit in our preference domain and become
  **lockable by the Phase 6 profile for free** (Docker's `disableUpdate` equivalent).
  *Coordinate with `reference/sparkle-updates.md` and the review's `deployment-ops.md`.*
- **[skip]** update settings for the `container` CLI itself beyond the version check
  from §4.1 — the pkg install is user-authorized per `DECISIONS.md`, and a silent
  runtime updater is out of scope.

### 4.6 Phase 6 — managed settings via Jamf

- **Two payload keys: `defaults` and `locked`** — [core], per §4.0. Extends
  `jamf-config-profile.md`.
- **Managed keys**: `mode`, `listenPort`, `bonjourEnabled`, `trustAnchorFingerprints`,
  `peerAllowlist`, `identityKeychainLabel`, `SUEnableAutomaticChecks` /
  `SUFeedURL` (so Jamf-managed minis don't self-update, per `PLAN.md` Phase 5), plus
  the fleet defaults from §4.3.
- **UI affordance for managed values** — [core]: greyed-out control + "Managed by your
  organization" footnote (Docker/Rancher both do this; it's the difference between a
  clear policy and a bug report).
- **Profiles survive reset/uninstall** — [core]: Flotilla's "reset preferences" must
  not attempt to clear the managed domain (it can't anyway, but the UI must say so).
- **Hide, not just disable, managed-away UI** — [later]. Tailscale's
  `PreferencesMenu` / `StartOnLoginMenuItem` pattern: on a mini pinned to host mode,
  hide the client UI entirely rather than showing a dead sidebar.
- **Export a profile from current settings** — [later], Phase 6 (or earlier —
  it's testable without Jamf): the `rdctl create-profile --from-settings` workflow,
  emitting a `.mobileconfig`/plist. Configure one mini by hand, deploy to seven.

### 4.7 Explicitly skipped

| Not doing | Why |
|---|---|
| CPU / RAM / disk resource sliders | No shared host VM to size — one micro-VM per container. The knobs are `[container] cpus/memory` defaults + per-run flags. |
| File-sharing / bind-mount configuration pane | Apple `container` has no VirtioFS-vs-gRPC-FUSE choice to make; mounts are per-run (`-v`/`--mount`). Belongs in the run dialog (the CLI owner's area), not in Settings. |
| Proxy configuration pane | The CLI inherits the system proxy; pulls go through it. Add only if it demonstrably breaks. Avoids anti-pattern #9 outright. |
| Kubernetes settings | Rejected in `DECISIONS.md`. |
| Extensions / plugin marketplace | Apple `container` has a `[plugin.<id>]` config namespace *(verify how it's used)*, but a plugin *store* is Docker-scale product surface for an 8-node hobby fleet. |
| Telemetry / analytics settings | Because there's no telemetry. |
| Licensing / activation settings | Personal, non-commercial. |
| Beta / experimental features tab | The whole app is pre-1.0; a beta tab inside a beta app is noise. |
| Shell-completion install, PATH management | The `container` pkg owns `/usr/local/bin`; we shouldn't fight it. |

---

## Open questions for the combined feature list

1. **Bundle ID / preference domain** — needs deciding before Phase 1 ships, since
   every managed key, Sparkle key and export format is namespaced by it.
2. **Does per-host settings sync belong in Wire (Phase 2) or the fleet layer
   (Phase 3)?** Cheapest if the two message types land with the rest of Wire in
   Phase 2, even if the UI arrives in Phase 3.
3. **Should Flotilla ever write `~/.config/container/config.toml`?** Reading it is
   unambiguously good. Writing it means owning a file another tool also owns, on a
   machine you may not be sitting at, with a service restart to apply. Recommendation:
   read in Phase 1, edit locally in Phase 3, edit remotely only if it proves necessary.
4. **`defaults` vs `locked` two-tier managed model** — confirm this before Phase 2
   writes the settings accessors (see §4.0); it's a cheap decision now and an
   expensive one later.
