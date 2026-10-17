# Host identity, check-in, and inventory for Flotilla

_Research current to 17 October 2026. Historical implementation sources are identified where used._

## Executive recommendation

Flotilla should adopt a staged version of option **(c): address history plus an optional host-initiated check-in**.

1. Ship address history and Bonjour discovery first. Persist addresses learned from authenticated sessions, try those addresses in a bounded order, and accept a connection only after it proves the host’s pinned public-key fingerprint.
2. Add a lightweight host check-in approximately every 15 minutes, using a stable per-host phase so the fleet does not synchronize. Keep full inventory on a separate daily schedule.
3. Allow callbacks only over trusted LAN interfaces or an overlay such as Tailscale by default. A callback cannot reliably reach a roaming administrator behind NAT unless Flotilla also has an overlay, public rendezvous service, or relay.
4. Continue treating the host key fingerprint as the authoritative identity. Hardware UUID and serial number should help recognize a wiped and re-enrolled Mac, but must not silently authorize its new key.
5. Store a daily capacity record and refresh live capacity immediately before presenting or executing a migration.

The major architectural decision is not polling interval. It is whether Flotilla may depend on Tailscale or operate a small rendezvous/relay service. Without one of those, reliable discovery is impossible when both Macs roam behind unrelated NATs.

## Decisions needed from the owner

- May Flotilla recommend or integrate with Tailscale, or must it work without third-party networking?
- If not Tailscale, is a minimal Flotilla rendezvous/relay service acceptable, or must remote reconnection remain manual?
- Should the administrator listener be restricted to LAN and overlay interfaces, as recommended, or exposed to public interfaces?
- Must every post-wipe key change require administrator confirmation, or may a recovery secret or physical one-time code authorize it?
- Is a persistent background helper or LaunchDaemon in scope? Host callbacks and discovery cannot operate while their responsible process is stopped.
- Is retaining the current inventory plus 30 daily historical samples sufficient, and should exported diagnostics redact hardware identifiers by default?

## Principles

Flotilla should keep three concepts separate:

- **Trust:** Is this the same cryptographic peer that was authorized previously?
- **Recognition:** Does an unfamiliar key probably belong to previously known hardware?
- **Discovery:** At what address can that peer be reached now?

A hostname, IP address, serial number, hardware UUID, and MAC address can assist recognition or discovery. None is a substitute for cryptographic trust.

Likewise, check-in and inventory are different operations:

- A **check-in** is a small liveness and locator update.
- **Inventory** is a larger, slower snapshot used for management and planning.
- **Live telemetry** is fetched immediately when making a time-sensitive placement or migration decision.

That separation is common across established management products and is important for both scale and correctness.

## Jamf Pro

### Which identifiers Jamf uses

Jamf exposes several identifiers because they serve different layers of the system:

| Identifier | Meaning | Expected durability |
|---|---|---|
| Jamf Computer ID | Database identifier for the inventory record | Stable while that record exists |
| Jamf Management ID | Server-assigned GUID associated with the managed record | Stable while the same record is retained; not hardware proof |
| UDID | Mac hardware UUID, conventionally derived from `IOPlatformUUID` | Normally survives an OS erase; can change after logic-board replacement and can collide in poorly cloned VMs |
| Serial number | Apple hardware/asset identifier | Normally survives an erase; repair and manufacturing exceptions exist |
| Primary/secondary MAC | Network-interface inventory | Changes with adapters and can be private or rotating |
| Computer name | Mutable inventory attribute | Changes freely |
| Last reported IP addresses | Mutable reachability and inventory attributes | Change whenever the network changes |

Jamf’s general inventory exposes Computer ID, Management ID, name, last check-in, last inventory update, last contact, IP addresses, and enrollment time. Its hardware inventory exposes UDID, serial number, primary and secondary MAC addresses, model, processor, and memory. Jamf also makes Management ID, UDID, serial, MAC, and Jamf ID available as payload variables.

Jamf does not publicly document a complete server-side precedence algorithm for reconciling all these values during every enrollment path. It is therefore safer to describe the behavior in layers:

- Computer ID and Management ID identify the **Jamf record**, not immutable physical hardware.
- The UDID/`IOPlatformUUID` and serial number are the strongest documented hardware-correlating fields.
- MAC addresses, IP addresses, and computer names are inventory attributes, not record identity.
- A Mac can be renamed or moved to another network without becoming another managed computer.
- Re-enrollment means an existing inventory record is enrolled again; Jamf provides settings controlling which history and inventory fields are cleared in that process.
- A remote wipe removes the MDM profile and Jamf management framework but does not itself delete or rewrite the Jamf inventory record.
- If that record has been deleted, or the hardware identifiers no longer reconcile because of repair or cloning, a later enrollment may produce a new Jamf record and new server identifiers.

Jamf’s Mac UDID has historically been associated with `IOPlatformUUID`, including operational workflows that query Jamf by the value read from I/O Registry. This is useful evidence, but the exact internal reconciliation order should not be treated as a public contract.

### Rename, IP change, and post-wipe re-enrollment

Rename and network changes update attributes on the existing record. Jamf even supports policy triggers based on network-state changes, which reinforces that a changed name or IP is an event affecting a managed record rather than a new identity.

After an erase:

1. The previous inventory record still exists unless an administrator or retention process removes it.
2. Its old MDM enrollment and management framework no longer control the erased Mac.
3. Automated Device Enrollment or another enrollment flow installs new management credentials.
4. Jamf can treat this as re-enrollment of the existing record when it recognizes it.
5. Server-side record identifiers remain useful only if the same record was retained; they are not independent proof that the freshly enrolled key belongs to the old physical device.

This supports Flotilla’s proposed distinction: hardware identifiers may recognize a reinstalled machine, but a new cryptographic key still requires an authorized transition.

### Recurring check-in

Jamf’s default recurring check-in frequency is **15 minutes**. Current API documentation allows 5, 15, 30, or 60 minutes, with 5 and 60 as the documented minimum and maximum.

A recurring Jamf check-in is principally a policy request:

1. The Jamf binary contacts Jamf Pro.
2. Jamf determines which policies scoped to that computer have the recurring check-in trigger.
3. Eligible policies run according to their execution-frequency rules.
4. Results and logs are reported, and Jamf updates check-in/contact state.

It is not the same as `jamf recon` and does not normally send a full inventory snapshot on every 15-minute heartbeat. Policies can install packages, run scripts, restart systems, or perform other management actions, so operators must also avoid placing expensive “ongoing” work on every recurring check-in.

Jamf’s public documentation describes the semantics but does not publish a stable wire-level field schema for the check-in request. Flotilla should copy the architectural separation, not a private protocol.

### Frequency, launchd, and jitter

Current Jamf support documentation says a computer may be prompted up to five minutes before or after the configured frequency because of a randomizing factor intended to reduce server strain.

An older but concrete installed configuration shows how Jamf implemented that behavior:

```text
launchd StartInterval: 1800
command: jamf policy -randomDelaySeconds 300
```

This means launchd starts the job at its recurring interval and the Jamf process adds a random delay of up to 300 seconds. If each run chooses a different delay, the interval between actual contacts can appear as the nominal interval plus or minus five minutes: one run may wait nearly five minutes and the next almost none, or vice versa. It does not mean launchd predicts the future and starts a particular run before its scheduled launch.

That exact plist evidence is historical and should not be assumed to be a permanent current file layout. The current supported behavioral statement is the documented randomized window. Jamf also notes that each Mac starts its recurring interval when the setting reaches that Mac, naturally distributing devices enrolled or configured at different times.

### Inventory and `recon`

Jamf’s preconfigured Update Inventory policy runs weekly by default, although administrators can change or remove it. The `jamf recon` command performs an inventory update.

Inventory may include:

- Hardware, OS, processor, memory, storage, and network details
- Security settings such as FileVault and firewall state
- Users and location metadata
- Installed applications, services, printers, local accounts, receipts, and updates
- Extension attributes and other administrator-selected information

Current Jamf also obtains inventory through MDM commands and declarative status reports. Declarative status can report some values when they change rather than waiting for a complete periodic recon.

The important scaling lesson is that a small 15-minute policy check should not imply a 15-minute full inventory scan.

### Scale and APNs

Jamf combines several mechanisms:

- Recurring Jamf-binary check-ins for policy evaluation
- Periodic inventory updates
- Apple Push Notification service notifications for immediate MDM work
- Declarative status reporting for supported change-driven state

APNs does not carry the confidential management command or response. It wakes or notifies the Apple device, which then contacts its MDM service over its own authenticated connection. This reduces the need for rapid MDM polling but does not replace Jamf’s recurring policy channel or inventory collection.

At larger scale:

- Per-device start times and randomized delays spread recurring policy requests.
- Expensive inventory runs occur less often.
- Immediate MDM operations use APNs rather than waiting for the next poll.
- Mass enrollment, simultaneous policy changes, or a forced fleet-wide `recon` can still create a thundering herd.
- “Ongoing” policies placed on every recurring check-in can burden both clients and the Jamf server.

Flotilla should adopt the same separation and explicitly control fleet-wide phasing.

## Other management systems

### Comparative summary

| System | Durable identity model | Contact model | Inventory cadence and spreading | Post-wipe behavior |
|---|---|---|---|---|
| Kandji, now Iru | Tenant device record plus UUID and serial reconciliation | Agent every 15 minutes; daily agent and MDM checks; APNs for immediate MDM commands | Daily computer/app inventory; no public jitter algorithm found | Documentation says matching UUID and serial links an erased/re-enrolled Mac instead of duplicating it |
| Munki | Manifest selection, usually explicit `ClientIdentifier`, hostname, or serial | Client pull through launchd | Current Munki 7 job uses `StartInterval 3600`; no built-in jitter in that plist | No canonical UEM enrollment record; behavior depends on manifest naming and any reporting add-on |
| Fleet/osquery | Hardware UUID by default, or per-install instance identity; random node keys authenticate enrollment | Outbound TLS polling; common defaults around 10 seconds for configuration/distributed-query channels | Host details default hourly; scheduled reports support a stable ±10% splay | UUID can reconnect an installation to hardware identity; instance mode intentionally creates a new identity after reinstall |
| Microsoft Intune | Enrollment/service device record, Intune Device ID, Entra Device ID, serial and hardware metadata | Initial 15-minute refreshes, then approximately every 8 hours; APNs/change-driven pushes | Hardware/software inventory generally every seven days; no public macOS jitter algorithm found | New enrollment credentials and service records can produce a new device record; stale duplicates are possible |

### Kandji / Iru

The current Kandji support site states that Kandji is transitioning to Iru and directs customers to migrate by 1 December 2026. The documented macOS behavior remains a useful comparison:

- The agent checks in every 15 minutes to execute assigned Blueprint and Library Item work.
- A daily agent check collects computer information and application inventory.
- A separate daily MDM check requests device, security, application, profile, certificate, and available-update information.
- Immediate MDM commands use APNs.
- If an erased Mac returns with matching UUID and serial number, the service links it to the previous device record instead of creating a duplicate.

This is close to the structure Flotilla needs: a frequent small control contact, a slower inventory cycle, and explicit hardware-assisted re-enrollment recognition. The public documentation does not describe a check-in jitter algorithm.

### Munki

Munki is a client-pull software distribution system rather than a complete UEM identity service.

If `ClientIdentifier` is not configured, Munki tries identifiers such as the fully qualified hostname, short hostname, serial number, and `site_default` when selecting a manifest. An explicit stable `ClientIdentifier`, preferably independent of the mutable computer name, is therefore important.

Current Munki 7 source defines a launchd job with:

```text
StartInterval = 3600
managedsoftwareupdate --auto --quiet
```

No random delay appears in that current plist. Older Munki versions used a calendar trigger around a fixed minute and a supervisor process that randomized execution over a wider window; that historical implementation should not be attributed to current Munki 7.

Munki does not by itself define a canonical enrollment identity or a full central hardware-inventory database. Deployments commonly add MunkiReport or another reporting service. A rename can change manifest selection when the deployment relies on hostname rather than an explicit identifier.

The relevant lessons are:

- Client pull can work with a static repository.
- Mutable names make poor identity.
- An hourly launchd interval without fleet phasing may synchronize after common installation or boot events.
- Reporting and control-plane identity need separate design.

### Fleet and osquery

Fleet separates device uniqueness from authentication:

- The default and recommended uniqueness source is hardware UUID.
- Alternatives include hostname and `instance`.
- `instance` represents a particular installation and is preferable for cloned VMs or dual-boot cases where hardware UUID is not unique enough.
- Enrollment exchanges an enrollment secret for random node keys used in subsequent authenticated communication.
- Fleet’s Orbit component also relates its agent identity to hardware UUID.

Typical agent channels are outbound polls. Fleet configuration examples use short intervals such as ten seconds for configuration or distributed-query work. Host-detail collection defaults to approximately one hour. Scheduled query reports have configurable intervals and a stable splay of approximately ±10%, locked per host, to distribute load.

This provides two useful patterns for Flotilla:

1. Keep an installation or enrollment identity distinct from hardware recognition.
2. Derive a stable per-host schedule offset instead of choosing fleet-wide wall-clock boundaries.

### Microsoft Intune for macOS

Intune’s standard macOS policy refresh behavior is initially frequent and then relatively slow:

- A newly enrolled Mac checks approximately every 15 minutes during its first hour.
- Normal maintenance sync is approximately every eight hours.
- Change-driven policy can be pushed through Apple’s notification path.
- User or administrator actions can request an immediate sync.
- The separate Intune management agent used for scripts and some apps also typically checks about every eight hours; an administrative MDM Sync does not necessarily force that independent agent channel.

Intune exposes an Intune Device ID, Entra Device ID, serial number, and other hardware information. Hardware and software inventory generally refreshes every seven days, as does macOS discovered-app inventory.

Intune does not document those service GUIDs as immutable physical identity across erase and enrollment. A wiped Mac receives a new MDM profile and enrollment credentials, and stale or duplicate device records can occur. Serial and model information assist Automated Device Enrollment and troubleshooting, but Flotilla should not copy an assumption that a cloud record ID proves continuity after a wipe.

## Discovery and roaming systems

### Tailscale

Tailscale gives each registered node a stable virtual address, normally in its `100.x` address space, that remains the same as the device changes physical networks. MagicDNS maps device names to those virtual addresses.

There are several identities involved:

- The **machine key** identifies the device to Tailscale’s coordination system.
- A **node key** authenticates and authorizes the node on the tailnet and participates in encrypted peer networking. Node keys can expire or rotate.
- The stable virtual IP belongs to the registered Tailscale node.
- The MagicDNS name is a convenient locator and may change when a machine is renamed or naming conflicts are resolved.

Removing the node, resetting state, losing the relevant key material, or reinstalling/wiping it can create a new Tailscale registration and address. The address is stable across ordinary roaming, not eternally bound to physical hardware.

For Flotilla, Tailscale is attractive because it solves four difficult problems without making Flotilla operate a public service:

- Stable addressing
- NAT traversal
- Peer authentication and encryption
- Relay fallback when a direct path cannot be established

Flotilla must still verify its own pinned host key. A Tailscale identity should provide reachability and an additional security boundary, not replace application-level authorization.

### Syncthing

Syncthing demonstrates a clean separation between identity and location.

A Syncthing Device ID is derived from the hash of the device’s TLS certificate/public key. It is stable cryptographic identity, not a hostname or IP address. Peers can resolve that ID through:

- Explicit static addresses
- Local discovery broadcasts
- Global discovery
- Relays when direct connectivity fails

Direct encrypted connections are preferred. Discovery provides candidate addresses, while TLS proves the Device ID. Relays carry end-to-end encrypted traffic but can observe metadata such as source addresses, Device IDs, and traffic volume. Device IDs are identifiers rather than secrets, and global discovery creates its own privacy considerations.

Flotilla should copy this pattern: find candidate endpoints through several untrusted mechanisms, then prove identity cryptographically at the connection.

### Bonjour and Sleep Proxy

Bonjour provides zero-configuration discovery on a local link. It is excellent for finding a Flotilla host after its DHCP address or local hostname changes while the administrator is on the same LAN.

It is not a general roaming solution:

- Multicast DNS normally stays on the local link.
- Apple warns that Bonjour’s security model assumes a cooperative local network.
- Wide-area Bonjour or hybrid proxying requires additional DNS or gateway infrastructure.
- Bonjour advertisements reveal that a service exists and can expose metadata to other local users.

Apple’s historical Bonjour Sleep Proxy allowed another LAN device to advertise a sleeping Mac’s Bonjour services and wake it when accessed. Apple Remote Desktop still notes that waking a Mac on another subnet requires a sleep proxy. This solves local sleep/wake reachability; it does not give a roaming Mac a persistent public locator. Apple’s AirPort hardware, once a common provider of this feature, has been discontinued.

Flotilla should use Bonjour as a local discovery enhancement only.

### Back to My Mac and present-day replacements

Back to My Mac previously combined iCloud-mediated discovery with remote screen and file access. Apple discontinued it in 2019.

Apple’s suggested replacements—iCloud Drive, built-in Screen Sharing, and Apple Remote Desktop—cover file access or interactive control but do not provide a general-purpose rendezvous layer for an arbitrary Flotilla service. Screen Sharing still requires network reachability, a suitable network path, or a separate overlay/VPN arrangement.

Modern Apple MDM avoids this problem by requiring a management service at a stable, reachable FQDN and using APNs to prompt devices to call it.

### Peer-to-peer management patterns

Practical “peer-to-peer” products usually retain a stable coordination component:

- Tailscale coordinates identity and path discovery, then establishes direct encrypted peer connections where possible.
- Syncthing uses local/global discovery and relays around its direct encrypted sessions.
- MeshCentral can rendezvous browser and agent connections through its server and use direct WebRTC traffic where available, with server relay fallback.
- Apple content caching allows peer caches to exchange software content, but the management/control plane remains separate.

A durable coordinator is useful for authorization, revocation, audit, asynchronous message delivery, and NAT traversal. Fully serverless management is practical only when peers are already mutually reachable, such as on one LAN.

### When neither side has a stable address

If both the administrator and host roam behind unrelated NATs, Flotilla has these options:

| Approach | Works across roaming NAT? | Trade-off |
|---|---:|---|
| Shared overlay such as Tailscale | Yes | Third-party dependency, but no Flotilla cloud service |
| Flotilla rendezvous/mailbox with optional relay | Yes | Flotilla operates Internet infrastructure and handles metadata |
| Public endpoint plus dynamic DNS and port forwarding | Sometimes | Poor fit for mobile devices, carrier NAT, captive networks, and consumer routers |
| Bonjour | No, unless co-located | Simple and effective on one LAN |
| Manual re-pairing or QR/code exchange | Only with user coordination | Acceptable fallback, not autonomous management |
| Direct callbacks with no coordinator | No reliable guarantee | Both sides may be unreachable, asleep, or behind symmetric NAT |

There is no protocol trick that lets two simultaneously unreachable peers discover each other asynchronously without some shared reachable system, previously established overlay, or manual coordination.

## Proposed Flotilla design

### Option comparison

| Option | Benefits | Limitations and risks |
|---|---|---|
| **(a) Administrator stores address history, tries alternatives, uses Bonjour, and verifies fingerprint** | Smallest change; no new administrator listener; handles rename, DHCP changes, multiple interfaces, and return to a known network | Cannot recover when every stored locator is stale and Bonjour is unavailable; probing stale addresses has privacy and SSRF-like risks |
| **(b) Host checks in to the administrator every ~15 minutes with jitter** | Administrator learns changes promptly; supports lightweight status/config delivery | Administrator needs a reachable listener; direct Internet callbacks fail behind NAT or while asleep; expands attack surface |
| **(c) Both** | Best local and roaming recovery; callback updates locators while administrator remains authoritative | Most implementation and security complexity; still needs an overlay or rendezvous service for arbitrary roaming |

Option **(c)** is recommended, delivered in stages. Option (a) should remain useful even after check-in exists because callbacks can fail and an administrator may need to reconnect using its own observations.

### Address history and connection strategy

For each host, persist endpoint observations with:

- Address or DNS name
- Port
- Address family
- Interface and scope, when known
- Source: authenticated host report, observed peer address, Tailscale, manually entered value, DNS, or Bonjour
- First seen, last seen, last success, last failure
- Recent round-trip time
- Whether the endpoint has ever proved the expected fingerprint

Candidate order should adapt to the administrator’s present network. A reasonable baseline is:

1. Last successful reachable endpoint
2. Tailscale address or MagicDNS name
3. Same-subnet/private addresses appropriate to the current interface
4. Other authenticated address history
5. User-entered DNS names
6. Bonjour results

Use bounded parallel connection attempts similar to Happy Eyeballs rather than blocking on a long sequential list. Apply per-host and global limits.

Every candidate must complete the authenticated handshake and prove the pinned public-key fingerprint before Flotilla accepts any application data. A stale address may now belong to someone else.

Do not allow a host report to turn the administrator into a general-purpose network scanner:

- Accept candidates only from authenticated sessions or explicit user input.
- Reject unspecified, multicast, and loopback targets unless a narrowly defined local use requires them.
- Treat link-local addresses as interface-scoped.
- Avoid VM bridges and unrelated interfaces unless the user enabled them.
- Restrict candidate ports to the enrolled Flotilla service port.
- Cap the number and lifetime of stored endpoints.
- Use short timeouts and connection-rate limits.
- Never follow a key mismatch automatically.

### Check-in schedule

Use a lightweight check-in every 15 minutes, but do not schedule every host at `:00`, `:15`, `:30`, and `:45`.

A suitable stable phase is:

```text
phase = HMAC(enrollment_secret, "flotilla-checkin-phase") mod 900
```

Each host then checks once in every 900-second window at its assigned phase. This produces an even fleet distribution without schedule drift. A small additional per-run dither, such as 0–60 seconds, can prevent repeated collisions caused by timer rounding, but the stable phase should do most of the spreading.

Also check in after:

- Wake from sleep
- A material network-path change
- Enrollment or key rotation
- A Flotilla agent upgrade

Coalesce those triggers and rate-limit them. When the administrator is unavailable, apply exponential backoff with randomization, reset it after a meaningful network-path change, and retain only the latest state rather than queuing thousands of stale heartbeats.

The administrator should be able to return signed configuration, including the requested inventory interval. The host retains the last valid configuration while disconnected.

### Minimal check-in content

A check-in should contain only what is needed for liveness, discovery, and configuration:

- Protocol and agent versions
- Enrollment identifier and current host-key fingerprint
- Current hostnames
- Candidate addresses with interface and scope information
- Tailscale address/name when intentionally enabled and detected
- Current time and boot/session identifier
- Last inventory generation and timestamp
- Small runtime-health summary
- Nonce or sequence number for replay protection

It should not send full process lists, installed applications, detailed container metadata, or daily capacity history.

### Listener scope

A host-initiated check-in requires an administrator-side listener. Default behavior should be:

- Bind only to explicitly selected LAN and Tailscale interfaces.
- Do not expose a raw public Internet listener automatically.
- Require mutual authentication or an equivalent pinned-key handshake immediately.
- Reveal as little as possible before authentication.
- Rate-limit connection attempts and payload sizes.
- Make the listener’s firewall and background-operation consequences clear in the UI.
- Allow the user to disable callbacks while retaining administrator-initiated discovery.

If Bonjour advertises the listener, use a generic or opaque instance name and minimal TXT data. Do not publish serial numbers, UUIDs, user names, host fingerprints, or fleet membership.

### Security and privacy by option

Option (a) has no new listening service, but it can still leak information through probes. A malicious enrolled host could also inject internal addresses to induce administrator-side connections. Candidate validation, strict ports, bounded probing, and fingerprint verification are therefore required.

Option (b) adds:

- Listener discovery and fingerprinting
- Denial-of-service risk
- Replay attempts
- Malicious payload handling
- LAN disclosure that the administrator runs Flotilla
- Possible public exposure from permissive interface binding

Use TLS or an equivalent cryptographic session, mutual proof of enrollment, freshness nonces, small fixed schemas, strict parsing, connection limits, and no meaningful pre-authentication response.

Option (c) combines the risks but gives the best recovery. The callback should update discovery state; it should not grant the host authority over the administrator or bypass the normal pinned-key trust decision.

## Host identity for Flotilla

### Recommended record

Store these fields separately:

| Field | Purpose | Trust status |
|---|---|---|
| Host public-key fingerprint | Authoritative peer identity | Trusted after explicit enrollment |
| Locally generated enrollment ID | Names an enrollment epoch independent of mutable network properties | Trusted inside the authenticated record |
| Key history and revocation state | Supports authorized rotation and prevents old-key reuse | Trusted |
| `IOPlatformUUID` | Strong recognition signal across an ordinary OS erase | Not authentication; repair and cloning caveats |
| Serial number | Strong secondary recognition and asset signal | Not authentication; service/replacement caveats |
| Observed MAC addresses by interface | Diagnostics and weak recognition only | Never primary identity |
| Hostname history | User-facing recognition and discovery | Mutable |
| Endpoint history | Reachability | Untrusted until the expected key is proved |

Normalize UUID and serial formatting before comparison. Keep original display forms only if useful for diagnostics.

### Why MAC address is unsuitable

A MAC address belongs to an interface, not the whole computer. Interfaces can be added, removed, replaced, or disabled. Apple platforms also support private Wi-Fi addresses, including fixed-per-network and rotating behavior. A Mac’s Wi-Fi address is therefore not a durable global identity.

Store MAC addresses, if at all, as time-bounded observations with interface and source metadata. Do not use them to authorize re-enrollment.

### Key rotation

If the old private key is still available, it should sign a key-transition statement containing:

- Old and new public keys
- Enrollment ID
- Monotonic sequence or transition timestamp
- Relevant protocol version
- A context string specific to Flotilla key rotation

After validation, the administrator can retain the host record, mark the old key superseded, and trust the new key without manual re-enrollment.

### Wipe and new-key recognition

An erased host will normally lose its Flotilla private key and local enrollment ID. On its next enrollment:

1. Create a new pending cryptographic identity.
2. Compare normalized `IOPlatformUUID`, serial number, model, and optionally other non-secret signals with prior records.
3. If UUID and serial both match exactly, present a clear “possible re-enrollment of this host” workflow.
4. Show old and new fingerprints, last-seen time, matching hardware fields, and the consequences of accepting the change.
5. Require administrator confirmation, an existing recovery secret, or a physical one-time code.
6. Preserve the previous enrollment epoch and revoked key history.
7. If identifiers conflict, collide, or only weak evidence matches, create a separate host record.

Never silently trust a new key solely because it supplied a readable UUID or serial number. Those fields can be spoofed by software, copied in virtual machines, or altered during hardware repair.

### Privacy treatment

UUID, serial number, address history, and fleet-presence history can track a device across networks and OS reinstalls.

Flotilla should:

- Encrypt sensitive local records and store application secrets in Keychain.
- Avoid placing UUIDs, serials, or fingerprints in Bonjour.
- Redact or hash them in exported diagnostics unless the user opts in.
- Avoid unrelated installed-application, user, SSID, or geolocation inventory by default.
- Provide an explicit forget/revoke operation.
- Bound endpoint and historical-capacity retention.
- Document whether any rendezvous service can observe peer identifiers, addresses, and timing metadata.

## Capacity inventory

### Cadence

Use three levels:

1. **Lightweight check-in:** every 15 minutes with stable per-host phasing.
2. **Full capacity inventory:** every 24 hours by default.
3. **Live refresh:** on demand and immediately before migration planning or execution.

Offer an inventory interval range of:

- 1 hour
- 6 hours
- 12 hours
- 24 hours — default
- 3 days
- 7 days
- Manual/off

Warn that shorter intervals increase disk, process, container-runtime, network, and battery work. Apply a stable per-host phase or approximately 10% deterministic splay to inventory schedules as well.

Force or request a fresh inventory after enrollment, agent upgrade, major OS/runtime change, and material container-state change when practical. The administrator’s configured interval should reach the host through the lightweight check-in channel.

Keep the current record and approximately 30 daily historical samples by default. Detailed per-container time series should not grow without bounds.

### Inventory record

Each record should include an envelope:

- Schema version
- Sampling timestamp and duration
- Flotilla and host-agent version
- Data-source versions
- Boot identifier and uptime
- Completeness, per-section errors, and staleness
- Inventory generation number

#### Identity and capability

- Host-key fingerprint and enrollment epoch
- `IOPlatformUUID` and serial number
- Model identifier
- Apple silicon chip/architecture
- Performance and efficiency core counts where available
- Total physical memory
- macOS version and build
- Flotilla protocol version
- Apple container CLI and API-service versions
- Installed container kernel/default image digest when applicable
- Runtime availability and running state

#### Reachability

- Current names
- Interface names, address families, prefixes, and scopes
- Tailscale address/name when enabled
- Last successful endpoint and observed round-trip time
- Power source and battery state
- Time zone
- Last check-in, successful session, and network change

Avoid treating a daily endpoint snapshot as more authoritative than a newly authenticated check-in.

#### Host capacity

- Total and available storage
- Memory total, used, available, pressure, and swap where obtainable
- CPU utilization and load
- Thermal-pressure state where available
- Uptime and recent reboot
- Relevant link type and speed when it materially affects migration

Free disk and current CPU/memory load can change rapidly. Daily values are useful for trend and screening, but must be refreshed before choosing a destination.

#### Container capacity and use

Apple’s current container CLI supports inspection of running containers and resource statistics. Record:

- Running, stopped, and total container counts
- Per-container configured CPU and memory limits
- Current CPU percentage, memory use, network I/O, block I/O, and process count where supported
- Images, containers, and volumes from `container system df`, including total, active, bytes, and reclaimable space
- Image digests, platforms, and local presence
- Volume and mount types, including local bind-path dependencies
- Published ports and relevant network constraints
- Runtime configuration that affects destination compatibility

The full inventory should avoid continuous high-frequency stats collection. Sample current usage during inventory, and obtain a fresh sample for migration decisions.

#### Migration-specific facts

For each workload, derive or record:

- Estimated required RAM, disk, and CPU
- Architecture and runtime compatibility
- Required image platform and whether the target already has the image
- Persistent volumes and bind mounts requiring transfer
- Published-port conflicts
- External network dependencies
- Estimated transfer size
- Source-to-target connectivity and recent latency
- Whether secrets or local-only files require special handling

#### Reliability and freshness

- Last successful check-in and inventory
- Sampling failures
- Runtime failures
- Recent reboots
- Capacity-data age
- Confidence or completeness status

### Migration ranking

Apply hard filters before calculating a score:

1. Host is reachable and authenticated.
2. Architecture, OS, runtime, and container-kernel requirements are compatible.
3. Enough disk and memory remain after safety margins.
4. Required ports, mounts, volumes, and external dependencies can be satisfied.
5. Inventory is sufficiently fresh, or a live refresh succeeds.

Then rank viable targets using:

- Memory and disk headroom
- Current CPU/memory pressure
- Image locality and expected transfer volume
- Network latency and reliability
- Power stability
- Historical runtime reliability
- Inventory freshness

Show the user why each target was accepted, rejected, or ranked. The first implementation should recommend a destination but keep migration approval manual.

## Proposed implementation sequence

### Phase 1: durable identity and administrator-led discovery

- Add normalized `IOPlatformUUID`.
- Persist hostname and authenticated endpoint history.
- Track endpoint source, scope, success, failure, and recency.
- Add bounded parallel retry and Bonjour discovery.
- Require the existing pinned fingerprint on every candidate connection.
- Add pending re-enrollment UX for UUID-and-serial matches.

### Phase 2: daily capacity records

- Add the inventory envelope and host-capacity snapshot.
- Incorporate current `HostFacts`.
- Collect Apple container list, inspect, stats, and `system df` data.
- Add freshness indicators and on-demand refresh.
- Use hard compatibility filters and explainable target ranking.

### Phase 3: optional check-in

- Add a stable per-host 15-minute phase.
- Send only liveness, locator, inventory-generation, and runtime summary data.
- Bind the administrator listener to selected LAN/Tailscale interfaces.
- Add mutual authentication, replay protection, rate limiting, and background-helper behavior.
- Retain address-history discovery as fallback.

### Phase 4: remote rendezvous, only if required

Choose one:

- Document Tailscale as the supported roaming transport.
- Integrate another user-managed overlay.
- Operate a minimal Flotilla rendezvous/mailbox with optional encrypted relay.
- Keep remote reconnection manual.

This decision should precede any attempt to make direct Internet callbacks appear reliable.

## Sources

### Jamf Pro

- [Jamf Pro — Recurring Check-in Frequency](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Recurring_Check-in_Frequency)
- [Jamf Pro API — Update computer check-in settings](https://developer.jamf.com/jamf-pro/reference/put_v3-check-in)
- [Jamf Support — Setting recurring check-in for computers in Jamf Pro](https://support.jamf.com/en/articles/11037893-setting-recurring-check-in-for-computers-in-jamf-pro)
- [Jamf Pro — Configuring the Recurring Check-in Frequency](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.23.0/Configuring_the_Recurring_Check-in_Frequency)
- [Jamf community — Example Jamf launchd `StartInterval` and `randomDelaySeconds`](https://community.jamf.com/general-discussions-2/mac-will-not-check-in-automatically-13617)
- [Jamf 100 Course — Policies and recurring check-in](https://learn.jamf.com/r/en-US/jamf-100-course-current/Lesson_21)
- [Jamf Pro — Execution Frequency for Policies](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Execution_Frequency_for_Policies)
- [Jamf Pro — Computer Inventory Information](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Computer_Inventory_Information)
- [Jamf Pro Security Overview — Data Collection](https://learn.jamf.com/r/en-US/jamf-pro-security-overview/Data_Collection)
- [Jamf Pro — Hardware Category for macOS](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Hardware_Category_macOS)
- [Jamf Pro — Computers General Category](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Computers_General_Category)
- [Jamf Pro — Payload Variables for macOS Configuration Profiles](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Payload_Variables_for_macOS_Configuration_Profiles)
- [Jamf Pro Developer — Computer inventory endpoint field mapping](https://developer.jamf.com/jamf-pro/docs/deprecation-of-classic-api-computer-inventory-endpoints)
- [Jamf Pro — Re-enrollment Settings](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Re-enrollment_Settings)
- [Jamf Pro — Remote Commands for Computers](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Remote_Commands_for_Computers)
- [Jamf community — Querying a computer by `IOPlatformUUID`](https://community.jamf.com/t5/jamf-pro/computer-naming-script-to-pull-information-from-jss/m-p/145717)
- [Jamf Pro — Triggers for Policies](https://learn.jamf.com/r/en-US/jamf-pro-documentation-11.15.0/Triggers_for_Policies)
- [Apple Platform Deployment — Use Apple products on enterprise networks](https://support.apple.com/en-gb/guide/deployment/dep2de55389a/1)

### Kandji / Iru, Munki, Fleet, and Intune

- [Kandji Support — Product transition notice](https://support.kandji.io/)
- [Kandji — macOS check-in](https://www.support.kandji.io/kb/macos-check-in)
- [Kandji — Understanding when devices go offline](https://www.support.kandji.io/kb/understanding-when-devices-go-offline)
- [Kandji — Global variables](https://www.support.kandji.io/kb/global-variables)
- [Munki — Current managed software update launchd job](https://github.com/munki/munki/blob/main/launchd/LaunchDaemons/com.googlecode.munki.managedsoftwareupdate-check.plist)
- [Munki Wiki mirror — Historical launchd jobs and randomization](https://github-wiki-see.page/m/lesula/munki/wiki/Launchd-Jobs-and-Changing-When-Munki-Runs)
- [Munki Wiki mirror — Preferences and `ClientIdentifier`](https://github-wiki-see.page/m/munki/munki/wiki/Preferences)
- [Fleet — fleetd authentication](https://fleetdm.com/guides/fleetd-authentication)
- [Fleet — Server configuration and host uniqueness](https://fleetdm.com/docs/configuration/fleet-server-configuration)
- [Fleet — Enroll hosts](https://fleetdm.com/guides/enroll-hosts)
- [Fleet — Agent configuration](https://fleetdm.com/docs/configuration/agent-configuration)
- [Fleet — Reports, intervals, and splay](https://fleetdm.com/guides/reports)
- [Fleet — `system_info` table](https://fleetdm.com/tables/system_info)
- [Microsoft — Troubleshoot device profiles in Intune](https://learn.microsoft.com/en-us/mem/intune/configuration/device-profile-troubleshoot)
- [Microsoft — Intune management agent for macOS](https://learn.microsoft.com/en-us/intune/app-management/deployment/management-agent-macos)
- [Microsoft — View device details in Intune](https://learn.microsoft.com/en-us/intune/device-management/inventory-and-status/device-details)
- [Microsoft — Discovered apps in Intune](https://learn.microsoft.com/en-gb/intune/app-management/discovered-apps)
- [Microsoft — Troubleshoot macOS virtual-machine enrollment](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/device-enrollment/troubleshoot-macos-vm-enrollment)

### Discovery, roaming, and privacy

- [Tailscale — IP and DNS addresses](https://tailscale.com/kb/1033/ip-and-dns-addresses/)
- [Tailscale — MagicDNS](https://tailscale.com/docs/features/magicdns)
- [Tailscale — Node keys](https://tailscale.com/docs/concepts/node-keys)
- [Tailscale — Tailscale identity](https://tailscale.com/docs/concepts/tailscale-identity)
- [Syncthing — Device IDs](https://docs.syncthing.net/dev/device-ids.html)
- [Syncthing — Relaying](https://docs.syncthing.net/v1.26.0/users/relaying.html)
- [Syncthing — Security and discovery FAQ](https://docs.syncthing.net/users/faq)
- [Apple — Bonjour security](https://support.apple.com/en-lamr/101889)
- [Apple Developer — Bonjour](https://developer.apple.com/bonjour/)
- [Apple — OS X Mountain Lion Core Technologies Overview, including Sleep Proxy](https://www.apple.com/media/us/osx/2012/docs/OSX_MountainLion_Core_Technologies_Overview.pdf)
- [Apple Remote Desktop — Wake computers](https://support.apple.com/en-gb/guide/remote-desktop/apd5535ee19/mac)
- [Apple — AirPort service information](https://support.apple.com/en-us/124173)
- [Macworld — Back to My Mac discontinuation and replacements](https://www.macworld.com/article/231779/apple-will-drop-back-to-my-mac-in-macos-mojave-here-are-some-workarounds-if-you-rely-on-it.html)
- [Apple — Share another Mac’s screen](https://support.apple.com/en-euro/guide/mac-help/mh11848/27/mac/27)
- [Apple Platform Deployment — Choose an MDM solution](https://support.apple.com/guide/deployment-education/choose-a-mobile-device-management-solution-edu1c1be3511/1/web/1)
- [MeshCentral — Design and direct WebRTC connections](https://docs.meshcentral.com/design/)
- [Apple Platform Deployment — Introduction to content caching](https://support.apple.com/guide/deployment/intro-to-content-caching-depde72e125f/web)
- [Apple — Private Wi-Fi addresses](https://support.apple.com/en-us/102509)

### Apple container

- [Apple container — Project and current requirements](https://github.com/apple/container)
- [Apple container — Command reference](https://github.com/apple/container/blob/main/docs/command-reference.md)
- [Apple container — Resource usage and statistics](https://github.com/apple/container/blob/main/docs/resource-usage.md)
