# Security review: machines and a general-purpose VM host

## Verdict

Neither proposal is ready to enter the Phase 2 wire boundary.

Proposal A is not nine ordinary additions to `Allowlist.commands`. It adds a control plane for the VM underneath every container on a host. Three commands — `machine delete`, `machine run`, and `machine set-default` — should never be callable over the wire. Remote `home-mount` should also be refused in both `ro` and `rw` forms. The remaining commands need a separately audited machine-admin capability, not merely `mutates: true` and the existing peer trust.

Proposal B is a new privileged, Darwin-only execution engine that consumes hostile media and can place hostile guests on the physical LAN. It must not be treated as a small extension of the container CLI integration. NAT-only virtualization may be compatible with the existing Developer ID, hardened-runtime, and notarization plan; bridged networking is release-blocked until Apple grants the restricted networking entitlement and a production-signed build passes the complete release gate.

This review does not soften the finding in [ALLOWLIST-AUDIT.md](ALLOWLIST-AUDIT.md): the existing table is not yet trustworthy as the complete Phase 2 boundary because 22 plugin-backed specs remain unverified. New machine grammar must wait behind that repair, not be used to make the unverified boundary larger.

## Security baseline used here

`Allowlist` currently has three important properties:

1. Grammar is default-deny, but grammar is not authorization.
2. Host paths in `run --volume` and both host-side `copy` endpoints are checked against a `MountPolicy` supplied by the filesystem-owning host. Remote callers cannot supply their own policy.
3. Arbitrary `container exec` is selected by `ExecPolicy.interactiveShell` only for the person driving their own local machine. The Phase 2 host posture remains `.processListOnly`.

Machine management has to preserve those properties while recognizing that a machine is a larger security domain than a container.

## Proposal A — `container machine`

### 1. Per-command remote blast radius

The captured 1.0.0 help proves the nine leaf names and describes the parent surface, but it does not contain leaf-level usage, flags, operand limits, output schemas, or error behavior. Therefore none of the nine has grammar suitable for an allowlist row yet.

| Subcommand | Phase | Risk if reached by a remote peer | Recommendation |
|---|---|---|---|
| `machine create` | Phase 1 safety; **higher Phase 2 concern** | Creates and boots persistent infrastructure. A peer can consume CPU, memory, disk, image-download bandwidth, VM slots, and boot concurrency. Crafted names/images/configuration may also reach new parsers. Repetition is a durable denial of service. | Do not expose until exact leaf help and accept/reject probes are captured. Then require a host-owned `machineAdmin` grant, hard per-peer and host-wide quotas, serialized creation, explicit resource ceilings, deadlines, disk-space reservation, and an audit record. No home mount at creation over the wire. |
| `machine delete` | Phase 1 destructive action; **critical Phase 2 concern** | Destroys the substrate and persistent state for every container in that machine. A force or mistaken-target variant could turn one authenticated request into host-wide data loss and prolonged outage. | **Never expose over the wire.** Keep local-only, require the exact machine identity rather than a default, show dependent containers and storage, require explicit destructive confirmation, and define backup/recovery behavior before UI exists. |
| `machine inspect` | Phase 1 privacy; Phase 2 disclosure | Can reveal machine configuration, resource sizing, network identity, disk locations, home-mount state, and implementation details useful for follow-on attacks. Raw output may grow new sensitive fields in later CLI releases. | Remote use may be acceptable only as a bounded typed projection with field allowlisting and redaction. Do not return raw or blindly decoded future fields. Capture and pin the JSON schema first. |
| `machine list` | Phase 1 privacy; Phase 2 disclosure | Lowest blast radius, but exposes names, status, default selection, capacity, and topology. It also supplies identifiers for destructive follow-on requests. Unbounded polling is a resource surface. | Candidate for Phase 2 only after leaf grammar/schema verification, response-size and rate limits, and field-level redaction. It does not imply permission to operate on every listed machine. |
| `machine logs` | Phase 1 privacy; **higher Phase 2 disclosure** | Boot/runtime logs can contain host paths, image locations, network configuration, command lines, failure payloads, and future secrets. Large or follow-style logs can exhaust memory, disk, or a wire connection. | Do not pass raw logs through the generic command path. Define a bounded typed request (`tail`, byte ceiling, time range), redact at the host, prohibit follow until streaming backpressure exists, and test malicious log content and truncation. |
| `machine run` | Phase 1 local power tool; **critical Phase 2 code execution** | Boots the VM if necessary and runs an arbitrary command or interactive shell inside the substrate that hosts all of its containers. Treat it as control of every workload and all data reachable from that VM, not as one container terminal. It also creates a bidirectional PTY/input/resize channel and an easy persistence and exfiltration path. | **Never expose over the wire.** Local-only, separately authorized, conspicuously audited, and unavailable to background/automation callers. Do not add a permissive machine-run grammar to the wire allowlist. |
| `machine set` | Phase 1 configuration safety; **critical Phase 2 authorization** | CPU/memory changes can starve the Mac or other machines; restart-required settings create outage. `home-mount` crosses the host filesystem boundary for the whole VM and therefore every workload in it. Unknown future keys could silently add privilege. | Model reviewed keys as typed operations; never accept generic `key=value`. Remotely permit only an explicit, versioned subset with host-owned ceilings and a stop/apply/restart transaction. Reject unknown keys. Refuse `home-mount` remotely in both modes. |
| `machine set-default` | Phase 1 global-state surprise; **high Phase 2 confused-deputy risk** | Changes the implicit target for later CLI calls by the app, the local user, or another peer. It can redirect otherwise valid operations to the wrong substrate, making audit records and authorization checks ambiguous. | **Never expose over the wire.** Phase 2 requests must name an explicit machine identity and the host must authorize that identity. A local UI may change the CLI default with confirmation, but Flotilla's wire behavior must not depend on mutable global default state. |
| `machine stop` | Phase 1 availability; **critical Phase 2 availability** | Stops every container on the target machine, including health/restart agents and unrelated workloads. It may interrupt writes and can strand the host service if Flotilla itself depends on that substrate. | Not a normal container mutation. If remote lifecycle administration is eventually required, gate it behind a distinct host-owned `machineAdmin` capability, exact machine identity, dependency preview, explicit confirmation, serialization, and an out-of-band recovery path. Never support `--all` remotely. |

Authentication is not sufficient authorization for any of these commands. Pairing a client proves identity; it does not make that client a substrate administrator.

### 2. `home-mount` versus `MountPolicy`

**Risk — Phase 1 and Phase 2, critical remotely.** `checkMountSpec` and `checkCopyEndpoint` make the host side of a filesystem crossing explicit and ask the host-owned `MountPolicy` whether that exact path is allowed. The default permits no host path. `home-mount` is more dangerous:

- it names an implicit, very broad path (`HOME`) rather than an auditable explicit source;
- it is VM-wide rather than scoped to one container invocation;
- `ro` still exposes SSH material, cloud credentials, browser/application data, source, documents, and other secrets to every sufficiently privileged guest workload;
- `rw` adds corruption, persistence, source-code modification, credential replacement, and host-user data destruction;
- changing it may survive restarts and silently affect workloads created later.

**Recommendation.** Remote callers get neither `home-mount=ro` nor `home-mount=rw`, regardless of `MountPolicy`. A permitted root such as `/Users/alice/project` must not be interpreted as permission to expose `/Users/alice` wholesale. If local product scope requires home mounting, use a separate `HomeMountPolicy` whose default is `.disabled`, whose local choices distinguish read-only from read-write, and whose caller provenance cannot be supplied over the wire. Require a specific local confirmation for `ro` and a stronger, repeated warning for `rw`. Prefer explicit narrow directory shares governed by `MountPolicy` over either home-wide mode.

This is stricter than bind mounts and `copy`, correctly so: those operations can identify and authorize a narrow path; `home-mount` cannot.

### 3. `machine run` versus `ExecPolicy.interactiveShell`

**Risk — Phase 1 local policy design; critical Phase 2 boundary.** The same `ExecPolicy.interactiveShell` must not authorize both operations. A container shell is scoped to one container's isolation boundary. A machine shell is beneath that boundary and must be assumed able to inspect or alter the runtime, all containers, machine storage, networking, and any shared host directory. Reusing one enum case would make “may open this container's Terminal tab” accidentally mean “may administer its host VM.” That is a classic confused capability.

**Recommendation.** Use a separate machine-access policy/capability, with machine shell disabled by default and a local-interactive-only state. Keep the existing `ExecPolicy` exactly container-scoped. The machine policy must be selected from trusted local caller context, never decoded from a wire request. Phase 2 should have no state that enables `machine run`; it is flatly absent from the wire protocol and allowlist. This also gives it a distinct audit category and prevents a future container-terminal preference from silently widening substrate access.

### 4. Commands flatly unavailable over the wire

The permanent deny list should be:

- **`machine delete`** — irreversible substrate and data destruction;
- **`machine run`** — arbitrary substrate command execution / shell access;
- **`machine set-default`** — mutable global routing state has no valid role in an explicit remote protocol.

In addition, **the `home-mount` key is permanently unavailable remotely**, even though safe typed subsets of `machine set` may eventually be allowed. `machine stop` is not on the permanent list only because deliberate remote host lifecycle administration is a plausible fleet requirement; it remains denied by default and requires a new substrate-admin authorization tier. If that tier is not built, `stop` remains unavailable too.

## Proposal B — general-purpose Virtualization.framework host

### 5. Entitlements and the release path

**Risk — Phase 1 if local VM hosting ships; release-blocking independently of Phase 2.** Virtualization.framework requires `com.apple.security.virtualization`. Apple documents adding it to the target and explicitly says the temporary App Sandbox key can be removed when it is otherwise unnecessary. That entitlement is therefore not inherently incompatible with the settled no-App-Sandbox position. Developer ID distribution still requires a valid Developer ID signature, hardened runtime, secure timestamp, notarization, and stapling; adding virtualization does not waive any of those gates. [Apple: adding the Virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project) [Apple: resolving notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)

Bridging is different. A `VZBridgedNetworkDeviceAttachment` requires `com.apple.vm.networking`, and Apple calls that entitlement restricted to developers of virtualization software and instructs developers to contact their Apple representative. It cannot be assumed available to this Developer ID team. [Apple: `com.apple.vm.networking`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking) [Apple: bridged attachment requirement](https://developer.apple.com/documentation/virtualization/vznetworkdeviceconfiguration/attachment)

**Recommendation.** Start NAT-only. Apple's NAT attachment does not require `com.apple.vm.networking`, which preserves the smaller entitlement inventory and avoids making an Apple-granted exception a launch dependency. [Apple: `VZNATNetworkDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment)

Do not claim bridged networking, sign a release with the entitlement, or schedule a release around it until all of the following are real rather than inferred:

1. Apple has granted the entitlement to the actual Team ID and bundle/helper identifiers used for distribution.
2. The exact archive, including every nested helper, is Developer ID signed with hardened runtime and the intended minimal entitlements.
3. `codesign` inspection shows no accidental debug or hardened-runtime exception entitlements.
4. Notarization succeeds, the ticket staples, Gatekeeper accepts it, and bridged networking works on a clean non-development Mac.
5. Sparkle validates and installs that same signed artifact without changing its designated requirement.

Failure anywhere is a release blocker under the installation/update decision summarized as item 13; it is not a documentation bug to fix after shipment.

### 6. Hostile media and bridged networking

#### Disk images and installer media

**Risk — Phase 1 attack surface; remotely supplied media would make it a critical Phase 2 concern.** Disk images, sparse-image metadata, partition tables, filesystems, kernels, boot loaders, and installer media are attacker-controlled structures consumed along a path involving Flotilla, Virtualization.framework, macOS, and the guest. A malformed or enormous image can target parser bugs, integer/offset errors, decompression or sparse-allocation bombs, disk exhaustion, device confusion, and VM escape vulnerabilities. Writable attachments also risk corrupting a source image or another VM using it.

**Recommendation.** Before shipment:

- accept only documented, necessary formats; Virtualization.framework's disk-image attachment currently documents RAW and ASIF, so do not add a broad image-conversion/parser stack without a separate review;
- never attach arbitrary host block devices, directories, sockets, or symlink-resolved targets; copy imports into an app-owned store using no-follow/open-file-descriptor handling and verify the opened object is the checked regular file;
- enforce physical and virtual size ceilings, free-space reservation, VM-count and device-count limits, timeouts, cancellation, and cleanup after failed imports;
- attach installer/reference media read-only and also open the underlying file read-only, matching Apple's stated best practice; use copy-on-write or a private per-VM disk for mutation; [Apple: read-only disk attachment](https://developer.apple.com/documentation/virtualization/vzdiskblockdevicestoragedeviceattachment/init%28filehandle%3Areadonly%3Asynchronizationmode%3A%29)
- prevent concurrent writers and cross-VM reuse of a writable disk; make deletion and snapshots transactional and recoverable;
- avoid parsing guest filesystems in Flotilla. If metadata extraction is required, put it in a minimal, sandboxed, disposable helper with no network, Keychain, home-directory, or fleet credentials;
- put the Virtualization.framework controller in a minimal separately testable process if a spike proves that process isolation and sandboxing work with the required entitlement. It must not be privileged and must not inherit unrelated Flotilla secrets;
- fuzz every parser Flotilla itself owns, maintain malicious/truncated corpus tests, and have a security-update policy tied to supported macOS releases;
- show provenance and hashes for downloaded media, but do not mistake a checksum for safety when user-supplied media is explicitly supported.

The safe claim is not “the guest contains hostile media.” The host still parses enough attacker-controlled structure to create and run the VM, so the design must minimize what the Flotilla process itself touches and assume framework or OS vulnerabilities remain possible.

#### Bridged networking

**Risk — Phase 1 LAN exposure; critical Phase 2 pivot.** A bridged guest shares the physical interface at a distinct network layer. It is a new LAN node, outside Flotilla's mTLS request boundary, able to expose guest services, scan peers, attack local devices, participate in broadcast protocols, and potentially spoof or disrupt local network traffic. A remote Flotilla peer that can create, boot, reconfigure, or bridge a guest gains a pivot onto the host's LAN even if every Flotilla wire request is authenticated. [Apple: bridged network interfaces](https://developer.apple.com/documentation/virtualization/vzbridgednetworkinterface)

**Recommendation.** Ship NAT as the only default. Bridging must remain unavailable over Phase 2 and to automation. If it is ever shipped locally, require all of the following: the entitlement/release proof above; an explicit per-VM local administrator choice; a clear LAN-exposure warning naming the physical interface; no remembered broad consent; an allowlist of eligible interfaces; guest firewall and service-hardening guidance; tests on hostile DHCP/DNS/IPv6 and network changes; and an incident-response switch that immediately disconnects the attachment. Enterprise deployment also needs network-owner approval and VLAN/isolation guidance. Do not describe bridging as merely another network dropdown.

### 7. The `FlotillaCore` seam

**Risk — Phase 1 architecture and Phase 2 verification.** Importing `Virtualization` into `FlotillaCore`, exposing `VZ*` objects in core protocols, or conditionally compiling core behavior on Darwin would break the Foundation-only property that lets VM agents and CI verify policy on Linux. It would also mix security-boundary logic with an entitled platform implementation that Linux tests cannot execute.

**Recommendation.** Nothing that requires Virtualization.framework belongs in `FlotillaCore`.

The seam should be:

- `FlotillaCore`: Foundation-only immutable request/configuration value types; resource-limit and path policy; state-transition rules; caller capability decisions; audit-event models; and a platform-neutral `VirtualMachineHost` protocol. Core types must use Flotilla-owned identifiers and enums, never `VZ*` types.
- a Darwin-only target such as `FlotillaVirtualization`: translation from validated core configuration to `VZVirtualMachineConfiguration`, framework validation, lifecycle callbacks, disk/file-descriptor handling, NAT/bridge attachment, and entitlement/runtime diagnostics.
- preferably a minimal Darwin helper executable behind a narrow IPC protocol: it owns the virtualization entitlement and media-facing framework calls, while the main app owns UI, peer identity, and authorization. The helper is not a root daemon and must not become a generic command or file service.
- Linux tests: fake the protocol adapter and exhaustively test configuration validation, quotas, authorization, state transitions, and wire decoding. Darwin integration and security tests separately prove the real adapter, signing, entitlements, media handling, and lifecycle behavior.

Phase 2 must authorize a typed VM operation before the Darwin adapter sees it. Raw framework configuration, paths, file descriptors, network-interface identifiers, or arbitrary key/value settings must never arrive directly from the wire.

## Do not ship until

1. **The existing allowlist audit is closed:** recapture all 22 plugin-backed leaf grammars plus `stats` and `system version`, confirm every proven defect is fixed with tests, and obtain a clean boundary review.
2. **Every proposed machine leaf is independently captured and probed:** usage, flags, aliases, repeatability, operands, value domains, output schema, exit behavior, and version drift are known. Parent help is not enough.
3. **Machine authorization exists as a separate host-owned tier:** pairing alone grants none of it; quotas, exact machine identity, confirmations, rate/concurrency limits, deadlines, and immutable audit events are enforced host-side.
4. **The permanent wire denials are tested:** `machine delete`, `machine run`, `machine set-default`, and every form of remote `home-mount` fail before process spawn. There is no client-supplied switch or policy that can enable them.
5. **Machine shell and container shell are separate capabilities:** `ExecPolicy.interactiveShell` cannot authorize substrate access, directly or through a shared preference.
6. **Destructive and availability workflows have recovery:** machine delete shows dependants and has a documented backup/recovery story; stop/set use a bounded stop/apply/restart transaction and cannot target all machines remotely.
7. **Hostile-media handling is isolated and bounded:** supported formats, no-follow regular-file opening, quotas, read-only reference media, single-writer rules, failure cleanup, fuzz/corpus tests, and a patch policy are implemented and reviewed.
8. **The VM implementation stays outside `FlotillaCore`:** Linux still builds and verifies all policy and wire types without importing or conditionally emulating Virtualization.framework.
9. **A NAT-only production archive passes the full release gate:** Developer ID, hardened runtime, least entitlements, notarization, stapling, Gatekeeper, clean-Mac execution, and Sparkle installation are proven on the exact distributed artifact.
10. **Bridging remains unshipped unless Apple and the release pipeline approve it:** the restricted `com.apple.vm.networking` entitlement is granted for the actual identifiers, the exact artifact passes the same release gate, and local-only LAN-risk controls and hostile-network tests are complete. Until then, bridged networking is not a feature.
