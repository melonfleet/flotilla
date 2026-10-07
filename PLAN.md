# Flotilla — native macOS fleet manager for Apple `container`

## Context

Apple's `container` is an open-source Swift CLI that runs Linux containers as one
micro-VM each on Apple Silicon. Flotilla is a personal, non-commercial native app
for managing containers on the local Mac and across a small fleet of remote Macs.
Each remote Mac runs the same app in host mode.

Flotilla communicates Swift-to-Swift over Network.framework with mTLS. Bonjour
handles discovery on a flat LAN; manual hostname/IP and port entry is mandatory
for routed or segmented networks. It does not use the macOS `ssh` binary, expose
a generic remote shell, or attempt to be Kubernetes.

**Status (2026-10-06):** the Phase 1 local app is essentially complete and has
been brought up to Apple `container` 1.5.0. The Foundation-only core, local
execution boundary, settings, diagnostics, navigation and local management
surfaces are built. Phase B networking is not: there is still no `Wire`,
`RemoteHost`, Network.framework transport, mTLS listener, Bonjour advertisement
or persisted host policy store.

The roadmap has been re-phased around the work agreed on 6 October. Phases A and
E can progress alongside the host and fleet work.

## Branding and appearance

The approved visual language is the watermelon identity. Melon colours belong
on the chrome, backgrounds, charts, status and wordmark. Controls follow macOS:
the system accent supplies buttons, selection and focus, and the system link
colour supplies links. A separate semantic error colour remains required.

Light and dark are both first-class. `Auto` is preselected during first run and
follows the system. A theme changes the window bar and content background only;
tables remain opaque, and glass is reserved for chrome and control clusters.

Phase A changed the window-bar lockup to **melonfleet** in bold, with the
watermelon o, a thin divider, and **flotilla** in lower-case light weight — in
white, straight on the bar, with a faint shadow (the owner tried a light-glass
capsule and preferred white). White alone measures 1.6:1 on the Canary bar; the
shadow keeps it legible, and Canary is its weakest theme. The links, dark-mode
and settings buttons share one translucent light-glass capsule with soft ink,
the same on every theme. See DECISIONS Q31.

The menu-bar symbol remains a monochrome template image.

## Architecture

```text
Flotilla.app  (one app, client/host/both modes)
├── FlotillaCore  (Foundation-only shared spine)
│   ├── Models
│   ├── ContainerCLI
│   ├── ContainerHost
│   │   ├── LocalHost   → Process
│   │   └── RemoteHost  → Phase B mTLS connection
│   ├── Allowlist       → permitted subcommands and argument schemas
│   ├── MountPolicy     → allowed host bind-mount roots
│   ├── WirePolicy      → commands a remote peer may reach
│   ├── Settings        → typed registry and managed precedence
│   ├── Diagnostics
│   ├── Wire            → Phase B framing and messages
│   └── Transport       → Phase B Network.framework and mTLS
├── Client UI
│   ├── MenuBarExtra and main window
│   ├── local and remote hosts through ContainerHost
│   └── fleet-wide resource tables
├── Stateful host runtime
│   ├── mTLS listener and Bonjour advertisement
│   ├── peer and certificate authorisation
│   ├── persisted policy and per-host settings store
│   └── validated local CLI execution
└── Privileged DNS helper  (Phase D)
    ├── SMAppService daemon approved once, on hosts and the admin Mac
    ├── DNS create/delete only
    └── accepts only the Developer ID-signed Flotilla app
```

Host mode is deliberately **stateful**. Its persisted policy store is required
for per-host settings and, later, restart and health loops that continue when the
admin Mac disconnects.

Every execution path uses the same boundary:

1. `ContainerCLI` creates an argument array.
2. `Allowlist` validates the subcommand and argument schema. `MountPolicy`,
   `ExecPolicy` and `WirePolicy` apply their separate restrictions.
3. `LocalHost` executes locally, or `RemoteHost` sends the validated shape over
   the wire.
4. The host validates again before spawning `container`.

The settled wire shape is CLI argument passthrough constrained by a default-deny
subcommand allowlist. The protocol also bounds frame length, concurrency and
deadlines. It never accepts an arbitrary command string and does not require a
new typed RPC for every CLI operation.

A host peer must construct its `ContainerCLI` with `.remotePeer`. Before Phase B
ships, every command receives an owner review of its
`CommandSpec.exposure`; valid syntax alone does not make a command safe for a
remote administrator.

## Tech stack

- Swift 6.2+ and SwiftUI on macOS 26, Apple Silicon only.
- Foundation-only `FlotillaCore`, also buildable and testable with Swift 6.1 on
  Linux.
- Network.framework for mTLS transport and Bonjour.
- SwiftData for local history. The host policy store is required, but its storage
  implementation is not settled here.
- SwiftTerm for the local PTY terminal; it remains the only third-party
  dependency and is attached to the macOS app only.
- Swift Charts when fleet streaming supplies real continuous data.
- Sparkle for unmanaged updates; Jamf for managed minis.
- Keychain for identities, trust material and saved group secrets.
- No App Sandbox for v1. Use hardened runtime, Developer ID, notarisation and
  minimal entitlements.

## Build phases

### Phase 1 — Local app and shared foundation

Phase 1 is essentially complete. The app now covers the local `container` 1.5.0
surface through the common validation boundary.

Core and local resource management include:

- Captured JSON models for containers, images, stats, system status, versions,
  volumes and networks.
- Container lifecycle, bounded and live logs, inspect, processes, terminal
  execution and file browsing, download and upload.
- Images with pull, progress, tag, delete, prune, inspect and build.
- Volumes and networks with list, create, delete, inspect, detail and prune.
- Machines and the provisional local-only Kubernetes cluster family.
- Snapshot stats, `system df`, preflight, missing-kernel remediation and runtime
  fault reporting.
- Tags, Activity, the global Logs surface and sortable table/card resource
  views.
- The default-deny `Allowlist`, injectable `MountPolicy`, local-only
  `ExecPolicy`, `WirePolicy`, command deadlines and bounded process output.

Work completed since the 31 July plan includes:

- A previewable, redacted support bundle with a user-chosen destination and no
  upload.
- Launch at login through `SMAppService`.
- Separate preference and window-layout resets. Host/trust reset remains
  disabled until host identity exists.
- An About and Privacy view listing every network destination.
- Clickable published ports and volume and network detail screens.
- Progress surfaces for long operations and previews for destructive prune
  operations.
- Working per-category notifications.
- Groups as saved run configurations, shown as expandable rows in Containers.
  A user-started group may wait up to two minutes for a member's configured
  ready port before starting the next member.
- A real local terminal, live logs and the Files tab.
- Image build and registry catalogue, sign-in and sign-out flows.
- Suggestions for groups, volumes, networks, machines, clusters and DNS.
- The DNS section: local domains, container-domain configuration and the
  narrowly authorised administrator flow for DNS creation and deletion.
- Versioned `.flotilla` configuration export and reviewed import for groups or a
  whole Mac. It exports definitions, not volume data, image layers or running
  state.
- Detection of the `container` network-bridge fault from
  apple/container#2051, with warnings on affected container and network
  surfaces.
- The 1.5.0 Kubernetes changes, missing-kernel check and HTTP-registry
  restrictions.

Phase 1 leftovers are assigned to Phase E:

- A ⌘K command palette.
- `is:` and `image:` search grammar.
- Passes for Reduce Motion, Reduce Transparency and Increase Contrast.
- A guided Apple `.pkg` installation flow. Today Flotilla links to Apple's
  releases page and leaves installation to the user.
- A general `config.toml` view. DNS already edits only `[dns] domain`, preserving
  every other byte.
- `--rosetta` and `--arch` in Run.

Three boundaries are deliberate:

- Compose is not going to happen. Apple has no Compose object, and implementing
  one would make Flotilla an orchestrator.
- Groups are not an orchestrator beyond Q21's user-initiated, start-time ready
  wait. There is no `depends_on`, ongoing health watch or group restart policy.
- General interactive `exec` over the wire is not going to happen. The local
  terminal is authorised for this Mac's owner; forwarding the same grammar to a
  remote host would be general remote code execution.

### Phase A — Look and navigation

Rebuild the window shell before fleet data makes the existing hierarchy harder
to change.

**Built 6 October (DECISIONS Q31).**

- Use the white `melonfleet | flotilla` lockup described above.
- Put links, dark-mode and settings into one translucent light-glass capsule on
  the right, with soft ink on every theme.
- Replace grouped sidebar cards with a flat list and thin dividers between these
  blocks:

  ```text
  Overview
  ─────────────────
  Containers
  Images
  Registries
  Volumes
  Networks
  DNS
  Machines
  Clusters
  ─────────────────
  Hosts
  ─────────────────
  Activity
  Logs
  ```

- Start with the sidebar collapsed to icons.
- Move its collapse control out of the window bar and onto the middle of the
  sidebar edge.
- Replace Dashboard with Overview. Overview shows fleet numbers only: connected
  hosts and their states, resource totals and things needing attention.
- Add Hosts immediately, initially containing only **This Mac**. It has the same
  setup as every other section (the owner, 6 October): table and cards, search,
  filter, hideable sortable columns, select-all, row menus, tags, Add and
  Refresh, and the activity band. Add and Remove are present but disabled, with
  the reason, until Phase B.
- Make the This Mac landing page the current per-Mac dashboard. Its CPU, memory,
  disk, runtime and local resource information does not belong on fleet
  Overview.
- Keep settings behind the window-bar control rather than adding it to the
  sidebar.

### Phase B — Host mode over mTLS

Build the stateful host runtime and its remote client path.

**B1 built 7 October** (`Sources/FlotillaCore/Wire/`, `WireTests`): frames are
`[UInt32 length][UInt8 type][UInt32 header length][JSON header][raw payload]`,
with command output as raw bytes so escaping cannot inflate it, and a declared
length over the limit refused before it is buffered. Messages: hello, welcome,
reject, request, cancel, result, failure, ping, pong, close; types 40–49 reserved
for bounded streams. `WireHostSession` and `WireClientSession` are transport-free
state machines: version negotiation, limits intersected to the stricter side,
per-connection concurrency, deadlines a caller may shorten but never lengthen,
and every request re-validated on the host by the `Allowlist` as a
`.remotePeer` under the host's own `MountPolicy`. The client bounds what it
accepts too. `create` became exposed per the owner's review.

**B2a built 7 October** (`Sources/FlotillaCore/Trust/`, `TrustTests`): the
enrolment key (`FLT1-` + 60 Crockford base32 characters: version, the admin
fingerprint's first 128 bits, a 128-bit secret, CRC-32 for typos); the
eight-character pairing code (ten minutes, five tries); the 256-word list for
the four fingerprint words; `PeerBook` (pending → approved / rejected,
approved → revoked, rejected stays blocked, seven-day expiry, plist-native);
and both pairing handshakes as state machines over five new frame types
(4–8), with HMAC transcripts binding both TLS fingerprints and both nonces so
a machine in the middle breaks the proofs. Cryptography is injected
(`PairingCrypto`); B2b supplies CryptoKit, the Keychain identity, the stored
book and the approval screens. B3 needs a certificate for each Mac's key;
`swift-certificates` (Apple) is the chosen dependency — the owner, 7 October.

**B2b built 7 October** (`Sources/FlotillaTrust/`, `FlotillaTrustTests`, macOS
only): each Mac's P-256 key in the login Keychain and a self-signed P-256/SHA-256
certificate for it (subject "Flotilla", no person or computer named, twenty
years — trust is the pinned fingerprint, not the dates); the fingerprint is
SHA-256 of the SubjectPublicKeyInfo, computable from any certificate a peer
presents; `PairingCrypto.system` (CryptoKit HMAC-SHA256 and SHA-256, system
random) checked against RFC 4231 and the SHA-256 standard vector; `PeerBookStore`
(plist under `peerBook`) and `EnrolmentKeyStore` (admin key in the Keychain,
rotatable; host key from the profile's managed `enrolmentKey`, or pasted and
validated). Two Keychain facts measured on the way: the login Keychain ignores
the label given when a certificate is added (it is set afterwards), and it fails
key creation when two keys are made at once in one process (now serialised).
The approval screens arrive with B3, when a request can actually come in.

**B3a built 7 October** (`Sources/FlotillaNet/`, `FlotillaNetTests`): Network.framework
TLS 1.3 with each Mac's identity, the host requiring the caller's certificate.
TLS accepts any certificate and proves key possession; trust is the fingerprint,
checked in one place above TLS — a known, approved key gets a trusted
`WireHostSession`, any other key can only pair (the welcome says which).
`HostServer` listens (optional Bonjour `_flotilla._tcp`), runs a trusted admin's
commands off the connection queue through `ContainerHost`, routes a stranger's
pairing to `PairingHostSession`, and closes a revoked key's live connections.
`AdminConnection` connects, runs numbered requests with deadlines and keepalive
pings, and pairs by code or enrolment key. Six loopback tests with two real
Keychain identities over real TLS cover a stranger refused, code pairing then a
command, a wrong code counted, the host owner saying the words do not match,
enrolment into the approval list, and revocation. They found a race: the admin
declared pairing done before the host had saved the trust, so a quick
reconnect could be refused; the admin now finishes on the host's
acknowledgement.

**B3b built 7 October** (app): Settings ▸ Host Mode (the owner's choice) — how
this Mac is used (Admin / Host / Admin and host, the existing `mode` key, now
live), its identity, the listener's status, port and Bonjour, the pairing code
with its countdown, the enrolment key from a profile or pasted, the admin Macs
it trusts, and on an admin the fleet enrolment key (create, reveal, copy,
replace). First run now asks how the Mac will be used beside appearance, unless a
profile sets it. Hosts lists every Mac in the `PeerBook` with its state, a
banner and filter for Macs waiting for approval, Approve / Turn Away / Remove
Access / Remove, and a page for each host; Add Host pairs a found or typed Mac by
code or enrolment key, and both Macs show the four words. An admin with a key
asks each newly found host once to enrol. `enrolmentKey` joined the managed
settings. No `.mobileconfig` export (the owner: not now). Live on this Mac: the
listener on 7868, the code, and Add Host reaching its own listener over TLS and
refusing to pair with itself.

**Two Macs, 7 October** (this laptop and a macOS 27.0.1 VM in UTM, shared
network): Bonjour found the VM; pairing by code showed the same four words on
both, the owner confirmed both, and each side recorded the other; the VM removed
the laptop and the laptop removed the VM; with the fleet key pasted on the VM,
Add Host with no code enrolled it, it waited in Hosts with its serial number, and
approval made it Paired. One gap found and fixed: automatic enrolment asked only
when a Mac was first seen, so a host given its key later never appeared; it now
also asks when a key is created and every two minutes for found Macs it does not
know.

**Remote commands built 7 October** (`RemoteHost`): a paired host is a
`ContainerHost`, so every `ContainerCLI` call works against it unchanged with
`wirePolicy: .remotePeer`. It pins the approved fingerprint on every connection —
a different key at the same address gets nothing — and requires the host still
to trust this Mac. Calls beyond the agreed concurrency queue instead of failing,
and the blocking form waits on the connection's own queue, never Swift's
cooperative pool (tested with forty simultaneous calls). Hosts now asks each
paired host for its version, containers and machines. Against the VM the round
trip is complete: the host validated `system version` as a remote peer and
answered that the `container` CLI is not installed. Next: the M1 mini on
macOS 26 (the owner is setting it up), for real containers.

- Define bounded protocol framing, version and capability negotiation, explicit
  request lifecycle and failure semantics.
- Carry only validated CLI argument arrays. Validate on both sides and enforce
  frame, argument, concurrency and deadline limits before spawning.
- Reserve compatible framing for later bounded streams and binary operations
  without exposing a generic shell.
- Review every `CommandSpec.exposure` with the owner. A syntactically valid
  command is not remotely available until that review admits it through
  `WirePolicy`.
- Build mutual TLS with a unique per-device identity, explicit two-sided pairing,
  peer allowlists, immediate revocation and closed live sessions after
  revocation.
- Keep discovery separate from identity. Support Bonjour and mandatory manual
  hostname/IP and port entry through the same trust flow.
- Add `RemoteHost` while preserving the same `ContainerCLI` semantics used by
  `LocalHost`.
- Add the persisted host policy and settings store, with typed per-host
  get/set messages. Mode itself is never remotely switchable.
- Provide a minimal host-mode UI: listener state, address, identity and
  fingerprint, peers, recent commands and a control to stop accepting
  connections.
- Distinguish connecting, unreachable, untrusted and version-mismatched hosts in
  the UI.
- Preserve immediate local control and a manual re-pair recovery path.

Decided with the owner (7 October):

- **Exposure:** a paired admin Mac starts with reads and lifecycle — lists,
  inspect, logs, and run/create/start/stop/delete for containers, images,
  volumes and networks. Terminal, runtime start/stop and machines are reviewed
  one by one later. Two others are not withheld so much as replaced (the owner,
  7 October):
  - **Registries — the admin Mac is the image source.** Registry sign-in never
    goes to a host, because a credential must not leave the admin Mac. Instead
    the admin pulls a private image with its own sign-in, then sends it to the
    host with `container image save` → the bounded binary stream → `image load`
    on the host. Hosts still pull public images directly, which spares the
    laptop's bandwidth. The admin's image store acts as the fleet's cache.
  - **DNS — per-host zones.** `container` names containers under one domain per
    Mac (`config.toml`), so different hosts can already sit in different zones
    — storefront hosts in one, back-end hosts in another. The DNS section gains
    the Host column and Host picker every section gets in Phase C. It waits for
    Phase D only because creating a domain on a host needs root there, which is
    the helper's job.
- **Enrolment, two ways to the same result** (the owner, 7 October). Both end
  with each side pinning the other's key in its peer list, revocable at once.
  - **Fleet enrolment key**, modelled on CrowdStrike's CID, for managed
    deployment. The admin Mac generates a key that carries its own public-key
    fingerprint and a random 256-bit secret, with a checksum so a mistyped key
    is caught. The key reaches hosts in a configuration profile (managed
    preference in `dev.melonfleet.Flotilla`, alongside host mode on and the
    port, locked) or is pasted by hand. A host holding it trusts only the admin
    whose key it names; the admin accepts a host only once it proves it holds
    the secret, so a spoofed Bonjour advert cannot join. New hosts appear in
    Hosts and in Activity as **Waiting for approval**, and none is trusted until
    the owner approves it on the admin Mac (the owner, 7 October): approval
    shows the computer name, model, serial number, macOS version, address and
    fingerprint words, so it can be checked against the inventory. Reject
    blocks that identity; an unanswered request expires after seven days. The
    admin can rotate the key, which stops new enrolments without touching
    hosts already enrolled.
  - **One-time code** for a single unmanaged Mac: the host shows a short code,
    the owner types it on the admin Mac, and both show the same fingerprint
    words to confirm.
  - The key is a bearer secret for asking to enrol only: anyone with the
    profile can ask, and only the owner's approval admits a Mac, and managed preferences are readable by local users on that
    Mac (as a CrowdStrike CID is). It never grants a host anything over the
    admin, and the admin's per-host identities, not the key, carry trust after
    enrolment.
- **Port:** 7868 by default, changeable in Settings.
- **Where host mode runs — headless Macs.** `container` today runs only inside
  a logged-in user's GUI session: `system start` installs its API server as a
  per-user LaunchAgent in `gui/<uid>`, and with nobody logged in it fails with
  an XPC error (apple/container#2008, open, with a draft fix in #2045; #1514
  asks for LaunchDaemon support). So host mode is a login item (SMAppService
  agent) in that user's session, and a headless Mac mini cluster runs a
  dedicated service account with automatic login — the usual Mac CI-farm
  setup. Automatic login needs FileVault off on that Mac, which the setup guide
  must say plainly. Move to a LaunchDaemon only once upstream supports a
  non-GUI domain; measure it on the M1 mini, logged out, before relying on it.

Testing proceeds in two steps:

1. macOS VMs exercise pairing, mTLS, framing, UI, rejection, revocation and
   version paths without launching containers.
2. The physical M1 Mac mini exercises real remote list, create, lifecycle, logs
   and other approved commands.

The acceptance criterion is safe local-feature parity through a remote host for
every command approved by the exposure review.

### Phase C — Fleet-wide tables

Turn the local resource surfaces into fleet surfaces.

- Every resource section lists items from all connected hosts.
- Every table gains a Host column and host filter.
- Every create form gains a Host picker.
- Overview shows real connected-host states, resource totals and attention
  counts.
- Hosts provides per-host status, identity, versions, settings, trust,
  last-seen time, disk use and resource counts, as columns in the same table.
  Add Host (the pairing flow) and Remove become live here.
- Activity records actions performed from this admin Mac, including host
  addition and removal, deployments and cross-host operations.
- Logs is global, with a Host column. It fetches bounded tails when viewed rather
  than maintaining an unbounded central log store.
- Hosts and their containers keep producing their own logs while disconnected.
  Reconnection fetches only the requested bounded tail.
- Cache the last successful result and show its age when a host is stale or
  offline rather than replacing it with an empty table.
- Use adaptive polling and back off unreachable hosts.
- Show app, wire and `container` version skew before an incompatible action is
  attempted.
- Add fan-out image pulls to selected or all hosts.
- Report per-host progress and partial failures for every fan-out operation.
- Keep trust state distinct from connection state.
- Support safe host and settings export without private keys. Imported
  fingerprints remain claims to verify, not automatic trust.
- Keep cross-host actions explicit about the hosts and objects affected.

Progress (7 October):

- **Containers — built.** Fleet-wide rows, Host column and filter, remote lifecycle, detail,
  Logs tab, bulk actions, Run with a Host picker. Live-tested on the M1 mini.
- **Images — built.** One row per image per Mac (`HostedImage`), Host column (hidden by default,
  as in Containers) and filter, stale marker; Run opens on the image's Mac with that Mac's images
  as suggestions; Tag, Delete, bulk delete, detail and Inspect run on the image's Mac. Prune stays
  This Mac's. Live-tested on the mini: list across three hosts, Inspect, tag, delete.
- **Volumes and Networks — built.** Same shape (`HostedVolume`, `HostedNetwork`): rows from every
  Mac, Host column and filter, stale marker, tags keyed per host; New Volume and New Network gain
  a "Create on" picker; delete, bulk delete, detail and Inspect act on the row's Mac. Every Mac's
  built-in `default` network is listed and cannot be deleted. A host's creates and deletes are
  recorded in the activity feed as "name on host", and every detail screen's Recent events now
  reads that key — a host's `web` no longer shows This Mac's `web` history. Live-tested on the
  mini: create, inspect and delete a volume; create and delete a network.
- **Fan-out pulls — built.** New Image ▸ Pull has a "Pull to" checklist; every chosen Mac pulls
  from the registry itself, all at once, one line per Mac in the progress panel, and a partial
  pull is reported as a failure naming what did succeed. Over HTTP only This Mac pulls (the wire
  refuses `--scheme`). Live-tested: `hello-world` to all four Macs, then a bulk delete across
  them. Bulk-delete dialogs in every fleet section now name the Macs they touch.
- **Logs — built.** A paired host's running containers are log sources (fetched over the wire),
  each line carries its Mac in a Host column, sources read "web on mini", search matches host
  names, CSV gains a Host column. Live streaming stays This Mac's until the wire has streams
  (Phase D), and the Live button says so.
- **Overview — built.** Every Mac's connection state, "N of M connected", fleet totals for
  containers, images, volumes and networks, and attention items for a host that is not answering
  or waiting for approval. Groups, DNS, machines and clusters are labelled This Mac's.
- **Launch-time connection race — fixed.** Measured: in the first moment after launch macOS can
  refuse Flotilla's local-network lookups while it applies the Local Network permission, and the
  connection sat in `preparing` until the 20-second deadline, then a 60-second backoff. An attempt
  now gets 6 seconds to reach the host and is made again, up to three times; a connection that
  never came up closes at once instead of waiting out the graceful-close backstop.
- **Version skew — built.** `VersionSkew` (FlotillaCore, tested on Linux) compares This Mac's
  `container` and Flotilla with each host's; Flotilla now reports its build number (`0.0.0 (308)`).
  Hosts has a Flotilla column and marks a differing version; Overview lists a host whose
  `container` differs by a minor release or more, or whose Flotilla build differs; Run, Pull,
  New Volume and New Network say so before acting on such a host, because the Allowlist is
  audited against This Mac's `container` and options change at minor releases. A wire-protocol
  mismatch was already refused at the handshake.
- **Host and settings export — built (DECISIONS Q34).** Hosts are a checkbox in the `.flotilla`
  export, written as name, where and expected fingerprint — never keys or trust; on import each
  becomes an unpaired row whose pairing is refused if a different key answers. Flotilla's settings
  export and import from Settings ▸ Advanced as their own file. Live-tested against a spoofed host.
- **Phase C is complete.** Known gaps carried forward: remote Live log streaming and image
  transfer need wire streams (Phase D); per-host subnets and pushed definitions are Phase D.

### Phase D — Pushed infrastructure

Build pushed infrastructure in three layers. Each layer must be useful without
assuming the next one exists.

#### Layer 1 — Shared definitions

- Define network, volume and domain definitions once on the admin Mac.
- Preview changes before pushing the same definitions to selected hosts.
- Report drift, per-host results and partial failures.
- Treat volumes as empty definitions. This does not move volume data.
- Treat identically named networks as separate private networks on each Mac.
- Give every host its own address block and every network an explicit subnet
  from it — for example one `/20` per host from an inventoried `10.240.0.0/12`,
  checked against LAN, VPN and Kubernetes ranges first (Iris, 6 October). This
  replaces the interim pick from `192.168.100.0/24` upward that gateway-wired
  Suggestions use today, and keeps a future routed overlay possible.

Order (7 October): **D1** layer 1 below; **D2** bounded wire streams, then images sent from the
admin Mac (save → stream → load) and live logs from hosts; **D3** layer 2 — the DNS helper on
hosts, per-host DNS zones, fleet names; **D4** layer 3's research reviewed with the owner.

**D1 — built (DECISIONS Q35).** Push to Hosts… on This Mac's networks and volumes, with a per-host
preview and results and an On hosts column that marks drift; a /20 per Mac from 10.240.0.0/12,
shown on each host's page; pushed networks and gateway-wired Suggestions take /24s from it.
Live-tested across all three hosts. Not built: editing a Mac's block by hand. Choosing hosts is a
table built for a fleet of dozens (the owner, 7 October): search by name, tag or state, a Show
filter (all, can be chosen, selected), Select All Shown and a count, ten rows high and scrolling —
`HostChecklist`, shared by Push to Hosts and New Image ▸ Pull to.

#### Layer 2 — Fleet DNS

- Give fleet resources names that resolve on every enrolled host.
- Resolve a local container to its local address.
- Resolve a container on another host through that host's published ports,
  tracked by Flotilla.
- Detect missing or stale published-port mappings and report them rather than
  returning a misleading address.
- Install a privileged host helper as an `SMAppService` daemon.
- Ask the host owner to approve it once during enrolment.
- Limit it to DNS create and delete operations.
- Accept requests only from Flotilla's Developer ID-signed app.
- Do not turn it into a general privileged command runner.

The same helper installs on the admin Mac too (the owner, 7 October): approved
once in System Settings ▸ Login Items, after which creating or deleting a DNS
domain asks for an in-app confirmation instead of the administrator password.
Only `system dns create|delete` need root; the runtime restart that follows a
container-domain change never did, so it already needs no password. Without
the helper (unsigned builds, or the owner declines it) the password prompt
remains the fallback.

This narrowly amends decision 19: root still runs one thing, never silently,
but the approval moves from a password per change to a one-time install
approval plus a visible confirmation per change. The helper accepts XPC only
from Flotilla's Developer ID-signed app, re-applies `AdminExecutable` and the
`Allowlist`, and is never a general privileged runner. Developer ID signing is
therefore a dependency.

#### Layer 3 — Cross-host network, if feasible

Research a true cross-host overlay in
`experiments/cross-host-network-2026-10-06`.

Do not promise or ship an overlay unless the experiment establishes a secure,
supportable design. In `container` 1.5, container networks are private to each
Mac. Without Layer 3, all cross-host container traffic uses host-published ports,
including traffic reached through fleet DNS.

### Phase E — Release preparation

Phase E can run alongside Phases B–D, although the Phase D helper depends on its
signing work.

- Check signing on the M3 development Mac. One `check-signing` step requires the
  owner's Apple credentials.
- Move the app to an Xcode project.
- Configure the hardened runtime, minimal entitlements, Developer ID signing,
  notarisation and stapling.
- Sign and verify every nested executable and dependency.
- Package a beta only after clean-install and upgrade checks pass.
  `v1.5.0.0-beta.2` was the planned tag; reconsider the label before creating
  it.
- Rewrite the test plan around the new phases, physical-host boundary,
  privileged helper and release gates.
- Add wiki links to form rails only for the release candidate. They are
  deliberately held until then so unfinished documentation does not become UI.
- Capture current demo screenshots after the Phase A shell is settled.
- Complete the Phase 1 leftovers: ⌘K, `is:`/`image:` search, the accessibility
  passes, guided `.pkg` installation, a general `config.toml` view and
  `--rosetta`/`--arch` in Run.

The package installer must remain visible and user-authorised. Flotilla must
never silently install or upgrade Apple's privileged package.

## Later

### Under consideration — modern integrations (the owner, 6 October)

Not decided. Iris's research (`experiments/modern-features-2026-10-06/iris-report.md`)
recommends, in order: a read-only `flotilla` CLI companion; App Intents for
Shortcuts and Spotlight; Quick Look for `.flotilla` files; a read-only `stdio`
MCP server, then MCP-prepared actions the app shows and the user approves; then
widgets. Defer webhooks and a local REST API; do not build an extension
marketplace or a cloud assistant. For the assistant: start with Apple's
on-device Foundation Models plus retrieval over our own docs and captured
`--help`, with citations; offer a downloadable 3–4B model only if evaluation
shows the system model falls short. Her 15 open questions are the owner's.

- **MCP and other current integrations.** An optional Model Context Protocol
  server so AI assistants can read fleet state and, only with the user's
  approval, act through Flotilla — every call crossing the same `Allowlist`,
  `MountPolicy` and `WirePolicy` as the UI, local-only by default, with nothing
  privileged and nothing silent. Survey what comparable tools now ship before
  choosing.
- **An optional Flotilla assistant (Experimental section).** A small model,
  downloaded on request and never bundled, that knows `container` and Flotilla
  and answers "how do I build X" with the correct commands or Flotilla steps.
  It runs on the Mac, so no prompt leaves it — the no-phone-home promise
  applies. Open questions: model size and licence, fine-tuning versus retrieval
  over our own docs and captured `--help`, how answers are checked against the
  `Allowlist` before they are shown, and whether it may pre-fill a form (never
  run anything itself).

### Registry browser (the owner, 7 October)

Agreed for after Phase C; not started. Docker Desktop lists and searches Docker Hub from inside
the app. Flotilla gains the same: a Browse button in Images that opens the **default registry**
(`defaultRegistryDomain`, set from the Registries table — Docker Hub or GitHub's, whichever it is
at the time), lists its images, searches them, and offers Pull (to This Mac or, with Phase C's
fan-out, to chosen hosts) from a result.

To settle before building:

- `container` has no search command, so this talks to the registry's own HTTP API. Docker Hub
  has a public search endpoint; GitHub Container Registry has no public catalogue search, so
  browsing it likely means the GitHub Packages API, which needs a signed-in account — say so in
  the UI rather than show an empty list.
- It is a network request Flotilla makes itself, so the no-phone-home promise applies: only when
  the user opens the browser or types a search, never in the background, and nothing about the
  Mac sent with it.
- Credentials stay where Q20 put them: `container registry login` and the Keychain. If an API
  needs a token, decide where it lives before anything is written.
- Results are untrusted text from the internet: shown, never executed, and a reference only ever
  reaches `image pull` through the `Allowlist` like a typed one.

### Host-run policies and streaming

- Add live log and stats streams over persistent connections.
- Bound every stream, stop or pause work that is not visible, and prevent a
  fleet-sized set of per-container streams from becoming self-inflicted load.
- Add real sparklines and a Stats view only when the displayed data comes from
  those streams.
- Implement restart policy and health checks on the host peer, backed by its
  persisted policy store, so they continue when the admin Mac disconnects.
- Include retries, backoff, timeouts, thresholds and a history that explains why
  the host acted.
- Extend file, bind-mount and port workflows to remote hosts through explicit,
  bounded operations with host-aware paths. Do not reuse a generic remote
  terminal to obtain that access.

### Sparkle auto-updates

- Integrate Sparkle 2 for unmanaged Macs with an HTTPS appcast, Ed25519 artefact
  signatures, Developer ID and notarisation.
- Separate check, download and install controls and obtain first-run consent for
  update checks.
- Add a host-safe interruption point: stop accepting new mutations, finish
  bounded work, persist consistent state, relaunch and rerun preflight.
- Verify archive, signatures, notarisation, stapling, clean installation,
  previous-version upgrade, appcast version monotonicity and fallback.
- Use named-host canaries and an explicit reinstall rollback runbook.
- Keep the previous notarised artefact available. Sparkle has no downgrade
  mechanism.
- Jamf, not Sparkle, remains the update authority on managed minis.

### Jamf and configuration profiles

- Deliver a unique per-device identity and managed settings without changing the
  transport.
- Use two managed tiers: `defaults` seeds editable values and `locked` overrides
  and disables editing.
- Manage mode, listener and Bonjour settings, trust anchors, peer allowlists,
  identity label, update policy, diagnostics policy, minimum client version and
  fleet defaults.
- Show the effective value, source, validation errors and lock state in
  diagnostics.
- Never let a reset alter the managed domain.
- Use a unique per-device identity rather than one shared certificate.
- Test app-before-profile, profile-before-app, renewal overlap, removal,
  revocation, restart, locked-screen, logout and segmented-network behaviour on
  staged managed hardware.
- Treat loss of a managed identity as an error, not permission to generate an
  unmanaged replacement.

## Critical environment constraint — nested virtualisation

The development Mac is an M3 Max. Nested virtualisation is supported there for
Linux guests only. A macOS VM in UTM still cannot run the Linux micro-VMs used by
Apple `container`.

- Local development and real local containers run natively on the M3 Max.
- macOS VMs test mTLS, pairing, wire framing, UI, rejection, revocation and
  version-skew paths.
- Real remote lifecycle tests use the physical M1 Mac mini as the host peer.
- Manual host entry remains mandatory because mDNS does not cross routed
  networks, VLANs or subnets.

## Verification

- On macOS: run `swift build` and `swift test`, build the app bundle, then launch
  and exercise it with a clean GUI-style `PATH`.
- On Linux with Swift 6.1: run `swift build` and `swift test`; SwiftPM selects the
  portable manifest and excludes the SwiftUI app.
- Phase 1: verify local list, create, lifecycle, terminal, files, logs, build,
  registry, DNS, export/import and system features against `container` 1.5.0.
- Phase A: inspect every light and dark theme at supported window sizes. Measure
  the white lockup and the button capsule on Canary and verify the collapsed sidebar, edge toggle,
  Overview and This Mac navigation.
- Phase B: verify discovery, manual entry, bilateral pairing, validation,
  exposure rejection, limits, revocation, persistence and version negotiation
  in macOS VMs, then approved remote operations on the M1 mini.
- Phase C: verify host columns and filters, create-host selection, stale cached
  data, reconnect tails, version skew, fan-out progress and partial failures
  across virtual and physical peers.
- Phase D: verify identical definitions, drift and failure reporting; DNS
  resolution for local and remote containers; helper signature checks and
  operation limits; and published-port behaviour without an overlay.
- Phase E: verify `codesign`, hardened-runtime entitlements, `spctl`,
  notarisation, stapling, clean installation, upgrade and beta artefact
  contents.
- Later: verify host policies survive admin disconnection and restart, streams
  stay bounded, Sparkle uses named canaries, and both managed-settings tiers and
  identity lifecycles work on a staged Jamf-managed mini.
