# Iris report: migration, HA and self-healing for Flotilla

*Iris, 2026-10-12, for the 1.5 manual migration and the 2.0 high-availability idea (TODO items 7 and "2.0 idea"). Research, not a decision.*

## Summary

Apple `container` 1.5 has no checkpoint, restore, process-state transfer, or live migration. Flotilla can therefore offer only a **cold reconstruction**: pre-stage the image, stop the workload, copy named-volume contents, recreate it from saved configuration, start it on the destination, verify health, and retain the stopped source for rollback.

That is realistic for 1.5. Automatic failover in 2.0 is realistic first for **stateless, explicitly opted-in services**. Safe stateful HA is not realistic until Flotilla has quorum, reliable fencing, pre-replicated data, and a stable service address. Without fencing, an isolated source may still be running; without prior replication, a failed Mac’s volume data cannot be recovered.

## 1. What Apple `container` 1.5 permits

The exhaustive captured 1.5 help lists `copy`, `export`, image `save/load`, and volume create/list/inspect/delete—but no checkpoint, restore, pause, migration, or volume export/import command. The same is true of Apple’s [1.5.0 command reference](https://github.com/apple/container/blob/1.5.0/docs/command-reference.md). Apple Containerization runs each container in its own lightweight VM, but exposes no VM-state migration API in this release ([Containerization design](https://github.com/apple/Containerization#design)).

Therefore, **“cold migration only” is correct, with one qualification:** `container` has no first-class cold-migration operation either. Flotilla would stop and *reconstruct* the workload elsewhere; it cannot resume CPU, memory, open sockets, or TCP sessions.

Available data paths:

- `container image save --platform … --output …` creates an OCI archive, and `image load --input …` loads it ([captured save help](reference/cli-help/container-image-save-1.5.0-help.txt:1), [load help](reference/cli-help/container-image-load-1.5.0-help.txt:1)). This transfers the image, not the container’s writable layer or volumes.
- `container copy`/`cp` copies files or folders between the local filesystem and a **running** container. Thus an application container—or preferably a purpose-built helper—can expose a mounted named volume and copy data out or back in ([Apple command reference](https://github.com/apple/container/blob/1.5.0/docs/command-reference.md#container-copy-cp)).
- `container export` writes a container filesystem tar. Apple documents only the container filesystem; it takes no volume name and 1.5 has no matching `import`. It is useful for inspection or emergency extraction, but is not an evidenced volume-migration primitive.
- The robust workaround is a temporary helper container mounting `volume:/data` plus a private Flotilla staging directory, running a **fixed** tar command. Apple’s own volume documentation confirms named volumes are local ext4 filesystem images mounted into containers ([volume documentation](https://github.com/apple/container/blob/1.5.0/docs/volumes.md)); Apple’s still-open request for `container volume cp` explicitly describes the helper-container approach as the current workaround ([apple/container#895](https://github.com/apple/container/issues/895)).

Limits are material: stop every writer for application consistency; `cp` gives no documented preservation guarantees for ownership, ACLs or extended attributes; tar implementation and metadata must be tested; sparse volume capacity is not used-byte count; anonymous volumes must first be identified; and writable-rootfs changes are not preserved by image save. Host-folder mounts, custom local kernels, sockets and other host-local resources are not portable.

## 2. What established systems transfer to Flotilla

| System | What it really does | Lesson for 2–10 Macs |
|---|---|---|
| vSphere/vCenter | Cold relocation moves a powered-off VM. vMotion copies live memory/device state; Storage vMotion moves live disks. HA **restarts** VMs after failure; DRS scores placement and drives vMotion from demand, capacity and migration cost ([HA/DRS](https://www.vmware.com/docs/ha-and-drs-in-vmware-cloud-on-aws), [vMotion/Storage vMotion](https://www.vmware.com/docs/vmw-svmotion-sql-performance-white-paper)). | Keep planned migration, HA restart, placement and storage mobility as separate concepts. Flotilla has only the cold-restart analogue. |
| Kubernetes | Controllers create replacement Pods; they do not move a running process. PDBs rate-limit voluntary eviction such as drain, but cannot prevent involuntary node failure. Replicas and accessible persistent storage provide availability ([Disruptions/PDBs](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/), [node pressure](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)). | Desired configuration plus health and replacement is transferable; a PDB-like “minimum available” matters only once Flotilla supports replicas. |
| Nomad | Restarts locally, then reschedules/replaces allocations; planned drain has bounded parallelism and health gates. Placement filters hard constraints then scores feasible nodes ([rescheduling](https://developer.hashicorp.com/nomad/docs/job-specification/reschedule), [scheduling](https://developer.hashicorp.com/nomad/docs/concepts/scheduling/how-scheduling-works)). | This is the closest conceptual model. Local host volumes remain node-bound unless external storage is available. |
| Docker Swarm | A manager reconciles replicated-service desired state, recreating failed tasks. Its routing mesh/load balancer makes published services reachable on every node; bind/local volumes remain problematic ([services](https://docs.docker.com/engine/swarm/services/), [routing mesh](https://docs.docker.com/engine/swarm/ingress/)). | Recreate replicas and give them a stable service identity; do not mistake local data for portable data. |
| Proxmox HA | Quorum, cluster locks and watchdog fencing ensure only one owner before restarting a guest. Shared storage or ZFS snapshot replication supplies data; interval replication can lose changes since the last sync ([administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf), [QDevice guidance](https://pve.proxmox.com/wiki/Migrate_to_Proxmox_VE#Cluster)). | Fencing and storage are prerequisites, not later polish. A two-node cluster needs an independent voter. |
| Podman/CRIU | Checkpoints Linux process state, transfers it and restores it, including optional volume/rootfs data and TCP handling. Current Podman checkpointing is root-only and depends on compatible CRIU/runtime/kernel environments ([Podman checkpointing](https://podman.io/docs/checkpoint), [restore security and limits](https://docs.podman.io/en/latest/markdown/podman-container-restore.1.html)). | Demonstrates what genuine live migration requires—and what Apple `container` 1.5 does not expose. |

## 3. Recommended 1.5 manual migration

1. **Create an immutable migration plan.** Record a migration ID, source, destination, container/group membership, start order, image digests, configuration, named volumes, Q53 policies and expected address changes. Reuse `Flotillafile`/`ConfigurationFile` validation and `GroupMember` conversion, but do not claim complete fidelity: the current file format omits writable-rootfs state, host folders, secret values and Q53 policy. Arbitrary CLI-created containers with unsupported run options should be refused or show explicit omissions.

2. **Pre-flight before stopping anything.** Require both hosts connected and trusted; compatible Flotilla wire and `container` versions; runnable image architecture; healthy runtime; sufficient destination CPU, memory and disk plus staging space; no destination container, network or volume name collision; all volumes accounted for and used only by the selected workload; no host bind mounts or anonymous/unportable resources; required Keychain secrets readable; and a rollback-capable source. Use host metrics and `system df`, groups, `StackPlanner.Taken`, the Allowlist and `MountPolicy`.

3. **Resolve published ports.** Compare every host IP/port/protocol against target containers and claimed group ports. Refuse clashes by default. A user-approved remap must also update dependent configuration and the migration preview—never silently choose another port.

4. **Pre-stage images while the source still runs.** Skip an image already present with the same platform digest. Otherwise reuse Flotilla’s existing `image save` → SHA-256 → bounded, credit-controlled wire upload → host-owned `image load` path. Never use `image load --force`. Registry credentials stay on the admin Mac, as already decided for Send to Hosts.

5. **Enter the downtime window.** Mark the Q53 stop as deliberate and suspend automatic health remediation for this migration. Stop group members in reverse start order and wait until all consumers of each shared volume are stopped.

6. **Move each named volume once.** A new typed host operation—not remote shell—creates a fixed helper, mounts the source volume read-only and tars it into Flotilla’s private transfer directory. A new bounded **download** stream sends it to the admin; the existing upload machinery sends it to the target. Verify SHA-256 at every hop. Create the target volume with the recorded size/options, extract via another fixed helper, then verify a sorted manifest of file hashes, sizes, types and symlink targets. Preserve numeric ownership, modes and hard links; explicitly document or reject unsupported ACL/xattr/special-file cases.

7. **Recreate, then restore policy.** Reuse validated Flotillafile/group run options to create target containers and reapply each Q53 restart/health policy through the typed `.setPolicy` call. Secrets remain references in the group and values in the admin Mac’s Keychain; resolve them only into the validated `run` request, never an archive, temporary file, Flotillafile or Activity entry.

8. **Re-wire and start.** Moving a whole group preserves member names and same-network bare-name wiring. Start in group order, using existing ready ports and Q53 health checks. A partial cross-host move is harder: Apple networks do not span Macs, so dependencies require published ports and target host-qualified Fleet DNS names. `StackPlanner` can recompute known template tokens, but arbitrary environment strings cannot safely be inferred; require explicit review or refuse partial migration. Refresh Fleet DNS after the target becomes healthy.

9. **Commit or roll back.** Do not delete source containers or volumes automatically. Before target start, any interruption may remove migration-tagged target resources, re-enable source policy and restart the source. Once the target has accepted traffic, automatic rollback is unsafe because it may discard new writes: stop the target first and require confirmation before restarting the old copy. Delete the source only after explicit commit.

With images pre-staged, downtime is approximately:

`source stop + volume tar + source→admin transfer + admin→target transfer + extract/verify + ordered start/health`.

Large volumes therefore mean minutes or tens of minutes, not vMotion-like seconds.

Activity should show one parent migration plus every phase: actor, migration ID, source/target, stop reason, image and volume byte counts/digests, creations, policy transfer, readiness/health, DNS refresh, commit or rollback, elapsed downtime and failures. Never log secret values or sensitive staging paths.

## 4. Realistic 2.0 building blocks

**Detection.** Combine host mTLS heartbeats from more than one observer, runtime status, host CPU/memory/disk pressure, container state and Q53 probes. A lost admin-to-host path alone must not declare the host dead.

**Quorum and fencing.** Two voters require both votes and tolerate no failure. Two workload Macs plus an independent, always-on witness can form 2-of-3; a sleeping admin laptop is a poor witness. Three host voters tolerate one failure and are the sensible baseline, matching Raft practice ([Nomad quorum table](https://developer.hashicorp.com/nomad/docs/architecture/cluster/consensus)).

Quorum chooses an owner, but fencing prevents the old owner from continuing. A lease enforced only by Flotilla.app is insufficient because Apple containers can outlive the app. Safe stateful failover requires either a runtime-level lease/stop mechanism, external power/MDM fencing, or positive confirmation that the source stopped. If an unreachable Mac cannot be fenced, Flotilla must not automatically start a second stateful singleton.

**Placement.** Filter by architecture/version, policy, image, ports, network capability, volume availability and minimum CPU/memory/disk. Then score remaining headroom, failure-domain spread, image locality and migration cost, with an N+1 reserve. Use hysteresis rather than chasing instantaneous load.

**Data.** Periodic file-level rsync/tar replication is possible through helpers, but copying a live database is only crash-consistent at best. Quiesced/application-native backups or database replication are preferable. Apple 1.5 exposes no named-volume snapshot API; copying its private `volume.img` would couple Flotilla to runtime internals. Every replicated-volume policy must state its RPO—“last successful sync at…”—and explicitly accept that interval’s possible data loss.

**Addressing.** Existing Fleet DNS names encode location (`container.host.fleet.internal`); migration changes the name, and DNS does not preserve live connections. Add a stable service alias such as `web.services.fleet.internal`, quorum-controlled and mapped to the healthy owner. Multiple records can later support replicas, but DNS alone is coarse load balancing; a true proxy/tunnel belongs after Q47’s fleet ledger and host-to-host mTLS.

**Anti-flapping.** Require consecutive failures and a hold-down period; one active recovery per workload; one evacuation at a time per host; exponential retry; fleet-wide move budgets; a 10–30 minute cooldown; and no automatic failback. Q53’s existing restart backoff and five-in-ten-minutes give-up rule is the precedent ([Q53](DECISIONS.md:2260)).

A safe staged path is:

1. Manual cold migration and planned drain.
2. Automatic **planned evacuation** from a reachable source, with confirmed stop and health-gated cutover.
3. Quorum-backed auto-recreation only for explicitly stateless/replicated services.
4. Stateful failover only after fencing and supported replication exist.

The first automatic version should not move single-copy volumes after an unreachable-host failure, run in a two-node no-witness fleet, preserve sessions, infer arbitrary dependency addresses, auto-failback, or promise transparent load balancing.

## 5. Decision and security risks

- HA makes Flotilla an orchestrator, conflicting with Q21’s “group is a saved form submission, not an orchestrator.” Treat it as a new 2.0 service/workload abstraction and settle that explicitly.
- A migration stop must suppress Q53 restart on the source before acting, then transfer policy ownership; otherwise both Macs may restart the same workload.
- Q38/Q39 remain intact: app updates do not touch running containers, and runtime upgrades occur automatically only when none run. Using migration to drain for an update would require a new owner decision ([Q38/Q39](DECISIONS.md:1871)).
- Q33 permits the admin broad control of its own hosts, but does not authorize a generic remote shell or silent new privileged work ([Q33](DECISIONS.md:1762)). Volume helpers and fencing must be narrow typed operations, owner/profile-controlled.
- Every plan, helper invocation and host-to-host forwarding hop must independently cross the Allowlist, `MountPolicy` and `WirePolicy`; transfer sizes, concurrency, paths, archive members and deadlines must be bounded. The 2.0 trust path should follow Q47: signed fleet ledger, then ledger-checked host-to-host mTLS—not an ad hoc migration channel.
