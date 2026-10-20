# Job 5: Lifecycle tests of Iris's cluster and machine suggestions

Run on the mini on 20 October 2026. Source: `research/SUGGESTIONS-EXPANSION-IRIS.md` (the **Machines** and **Clusters** sections) in a fresh clone of `melonfleet/flotilla`.

| | |
|---|---|
| `container --version` | `container CLI version 1.5.0 (build: release, commit: d265d66)` |
| `sw_vers` | macOS 26.6.2 (25G83) |
| Host | `hw.memsize` 8589934592 (8 GiB), `hw.ncpu` 8. Half of memory is **4G**, so any profile asking for more than 4G was skipped. |
| `kubectl` | **Not installed on the mini.** Node and pod checks used the `kubectl` built into the kind node image, through `container exec <cluster> kubectl --kubeconfig /etc/kubernetes/admin.conf …`. `container k8s list` was used as the CLI's own view. |
| Raw logs | `out/work/` holds create logs, per-machine transcripts, live help captures and before/after state. Home paths, user names and the host name have been replaced with placeholders. |

## Summary

| Candidate | Values | Create | Result | Verdict |
|---|---|---|---|---|
| **k8s-starter** | 2 CPU, 2G, K135 | 34 s | Create, kubeconfig, Ready and workload pass. **Restart fails** and the cluster cannot recover. | **fix** |
| **k8s-compact** | 2 CPU, 4G, K135 | 34 s | Same as starter: **restart fails** (cause found, see below). | **fix** |
| **k8s-test** (`--rm`) | 2 CPU, 2G, K135, `--rm` | 33 s | Create, Ready and workload pass, and stopping removes it. **The kubeconfig entry and `current-context` are left behind**, and `k8s delete` can't remove them. | **fix** |
| k8s-dev | 4 CPU, 8G, K135 | — | Skipped: 8G is more than half of the mini's memory. | untested |
| k8s-build | 6 CPU, 12G, K135 | — | Skipped: 12G is more than the mini's memory. | untested |
| k8s-metrics | 6 CPU, 16G, K135 | — | Skipped: 16G is more than the mini's memory. | untested |
| k8s-compat-134 | 4 CPU, 8G, **K134** | — | Skipped: 8G. **The K134 image was never run.** | untested |
| k8s-eval-136 | 4 CPU, 8G, **K136** | — | Skipped: 8G. **The K136 image was never run.** | untested |
| alma9-build | A9, 6 CPU, 8G, none | — | Skipped: 8G. | untested |
| alma10-services | A10, 8 CPU, 8G, none | — | Skipped: 8G. | untested |
| alpine-box | A, 2 CPU, 2G, rw | 4 s (9 s on first pull) | All steps pass.¹ | **ship** |
| alpine-isolated | A, 2 CPU, 1G, none | 4 s | All steps pass.¹ | **ship** |
| alpine-review | A, 2 CPU, 2G, ro | 3 s | All steps pass.¹ | **ship** |
| alpine-build | A, 4 CPU, 4G, rw | 4 s | All steps pass, including a user-installed toolchain.¹ | **ship** |
| alma9-dev | A9, 4 CPU, 4G, rw | 15 s | All steps pass, including systemd.¹ | **ship** |
| alma10-dev | A10, 4 CPU, 4G, rw | 14 s | All steps pass, including systemd.¹ | **ship** |

¹ Every machine hit the same runtime quirk: **the first `machine run` right after `create` fails** (see F3). It is not tied to any profile, so it doesn't change the per-row verdicts, but Flotilla has to handle it.

Image digests resolved on the mini (`container image inspect`; this is the index digest):

| Alias | Reference | Digest |
|---|---|---|
| K135 | `docker.io/kindest/node:v1.35.5` | `sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95` (matches Iris's pin) |
| K134 | `docker.io/kindest/node:v1.34.8@sha256:02722c2d…3256` | not pulled (no candidate fit the host) |
| K136 | `docker.io/kindest/node:v1.36.1@sha256:3489c767…ebd5` | not pulled (no candidate fit the host) |
| A | `alpine:3.22` → `docker.io/library/alpine:3.22` (resolved to 3.22.6) | `sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8` |
| A9 | `almalinux/9-init:9.8-20261002` | `sha256:85b089b501411649d76607b81c55fb18044493d0fed589f53bb2fad3e7307bb2` |
| A10 | `almalinux/10-init:10.2-20261002` | `sha256:c8a5eee8dbb215f6cb9103bc8686ab02f7eb5f495d32333220147b2a899d28e1` |

Note: `alpine:3.22` is a moving tag. Today it resolves to 3.22.6. Flotilla's "tie evidence to the resolved digest" rule should record the digest above, not just the tag.

---

## Failures first

### F1. Clusters do not survive stop and start (k8s-starter, k8s-compact): fix

Container 1.5.0 has **no `container k8s start` or `stop`.** The captured 1.4.1 help lists `start`, but 1.5.0 has dropped it. The only way to stop and start a cluster is with `container stop` / `container start` on the cluster's container, which shares the cluster's name.

What happened, the same way on both clusters:

```
$ container stop flt-test-k8s-starter            # rc=0, 5 s; k8s list shows "stopped"
$ container start flt-test-k8s-starter           # rc=0, but the container exits after about 3 s
INFO: detected IPv4 address: 192.168.64.16
INFO: detected old IPv4 address: 192.168.64.15
INFO: clearing and regenerating the certificate for serving the Kubernetes API
error: unable to read config from "/kind/kubeadm.conf" : open /kind/kubeadm.conf: no such file or directory
```

A second `container start` keeps the container running, but the API server crash-loops for good:

```
kube-apiserver   Exited   attempt 6
E… run.go:72] "command failed" err="open /etc/kubernetes/pki/apiserver.crt: no such file or directory"
kubelet: dial tcp 192.168.64.20:6443: connect: connection refused
```

**Cause:** on restart the node VM gets a new IP from the default network. kind's entrypoint sees the change, **deletes** the API server's serving certificate, and tries to regenerate it from `/kind/kubeadm.conf`. Apple's wrapper never writes that file. The certificate is now gone, so the cluster can't be recovered. The workload state after restart was therefore "unreachable": the pods' containers show `Exited` in `crictl`, and no API answers. On compact I tried 3 start attempts with 2 minutes each, and none became Ready.

Before the stop, both clusters were healthy:

```
NAME                   STATUS   ROLES           AGE   VERSION
flt-test-k8s-starter   Ready    control-plane   29s   v1.35.5
flt-test-sleep                  1/1     Running   0          15s     # busybox:1.37 sleep 3600
flt-test-web-79f6cb7566-6w287   1/1     Running   0          15s     # nginx:1.29-alpine deployment
```

**Fix for Flotilla:** don't offer Start/Stop for clusters on 1.5.0. Treat "stop" as "delete" and say so, or hide it. This applies to every non-disposable row, including the 5 I couldn't run, because the cause is in the runtime and not in the sizing. Worth raising upstream (Kamal): the wrapper either needs to pin the node IP or provide `/kind/kubeadm.conf`. This probably explains why `k8s start` was removed. The mini's own stopped `dev-mini` cluster will very likely fail the same way on its next start. I did not touch it.

Headroom (starter, 2G): after the system pods and the 2 test pods were up, the node had `available 1526 MB` free, and requests were `cpu 950m (31%)`, `memory 290Mi (14%)`. So 2G is usable for learning manifests.

### F2. Disposable cluster leaves a stale kubeconfig (k8s-test, `--rm`): fix

```
$ container stop flt-test-k8s-test        # rc=0
$ container list --all | grep flt-test-k8s-test        # (nothing): removed ✔
$ container k8s list | grep flt-test-k8s-test          # (nothing): removed ✔
$ grep -c flt-test-k8s-test ~/.kube/config             # 7: cluster, context and user still there ✘
current-context: flt-test-k8s-test                     # points at a cluster that no longer exists ✘
$ container k8s delete --name flt-test-k8s-test
Error: failed to delete container (cause: "notFound: "container with ID flt-test-k8s-test not found"")
```

The VM and container really are removed when it stops. But nothing in `container k8s` can then remove the kubeconfig entry, and `kubectl` isn't on the mini. **Fix for Flotilla:** when a `--rm` cluster stops, remove its cluster/context/user from the kubeconfig itself and restore the previous `current-context`, or tell the user to run `kubectl config delete-context …`. I cleaned up by restoring the backup (see the end of this report).

### F3. First `machine run` after `create` always fails (all machines): fix in Flotilla, not per row

`machine create` already boots the machine (`list` shows `running` with an IP). The first `machine run` straight after that fails and leaves the machine **stopped**:

```
flt-test-alpine-box  …  192.168.64.29  2  2G  1.1G  running  *
$ container machine run --name flt-test-alpine-box -- /bin/true
Error: The operation couldn’t be completed. Operation not supported on socket   (rc=1)
$ container machine run --name flt-test-alpine-box -- /bin/true                 (rc=0, 1 s)
```

This happened in 8 of 8 attempts (6 candidates and 2 probe machines), for Alpine and AlmaLinux alike. The error says "…on socket" or "…by device". Waiting 15 s after create did not help. Every later `run`, from either stopped or running, worked. **Fix for Flotilla:** after Create, don't call `machine run` straight away. If the first boot or run fails with this error, retry once. Or treat the machine as booted after `create` and run nothing until the user asks.

### F4. `machine run` re-parses its arguments in the guest shell: Flotilla note

`machine run -- sh -c 'grep MemTotal /proc/meminfo'` printed BusyBox's `grep` usage text, and `machine run -- echo '$HOME' "x  y"` printed `/home/<user> x y`. The arguments are joined with spaces and run again by the login shell, so quoting is lost and `$VARS` expand **in the guest**. Pass the whole command as one string: `machine run --name X -- 'grep MemTotal /proc/meminfo'` works. This answers the open `--` / `TrailingPolicy` question in MACHINES-SPEC. It matters for any command Flotilla builds. A string from a library or the user is shell-evaluated inside the machine.

---

## Passes in detail

### Clusters: the steps that passed (starter, compact, test)

| Step | starter | compact | test (`--rm`) |
|---|---|---|---|
| Create (`container k8s create --name flt-test-… --cpus N --memory M --node-image K135 [--rm]`) | pass, 34 s | pass, 34 s | pass, 33 s |
| `container k8s list` | `running 2 2048 MB` | `running` | `running` |
| `write-config --kubeconfig <file>` | pass (rc 0) | pass | pass |
| Node `Ready` | `Ready control-plane v1.35.5`, Debian 13 node, containerd 2.3.1 | `Ready … 23s v1.35.5` | `Ready … 23s v1.35.5` |
| Workload Running | nginx deployment + busybox pod: `1/1 Running` | same | busybox pod: `1/1 Running` |
| Stop | pass (rc 0, 5 s) | pass | pass, and **removed** ✔ |
| Start again | **fail** (F1) | **fail** (F1) | n/a (removed) |
| Delete (`k8s delete --name`) | pass. Container gone, kubeconfig entries gone (`grep -c` = 0) | pass, same | **kubeconfig left** (F2) |

Other cluster notes:
- `k8s create` writes `~/.kube/config` **and switches `current-context`** to the new cluster.
- `k8s delete` removes the cluster's entries but leaves **no `current-context` line at all**. It does not restore the previous one (`dev-mini`). Flotilla should save and restore it.
- `write-config --kubeconfig <new file>` writes the cluster, context and user but **no `current-context`**. A user needs `--context` or `kubectl config use-context` to use that file.
- The API server URL in the kubeconfig is `https://<cluster>.<host>.fleet.internal:6443`, the fleet DNS name, not an IP.
- The CLI's default cluster name is `k8s-dev`, which is the same as Iris's "Standard development" name. Flotilla must always pass `--name`, so that a typo or a missing field never lands on someone's real cluster.

### Machines: all 6 tested profiles

Booted the way Flotilla does it: `container machine run --name X -- /bin/true`, because there is no `machine start` and the no-command form needs a PTY (MACHINES-SPEC §2). Every row followed create → boot (#1 fails per F3, #2 passes) → checks → `machine stop` → boot again → `machine delete`.

| Step | alpine-box (rw) | alpine-isolated (none) | alpine-review (ro) | alpine-build (rw) | alma9-dev (rw) | alma10-dev (rw) |
|---|---|---|---|---|---|---|
| Create | pass, 4 s | pass, 4 s | pass, 3 s | pass, 4 s | pass, 15 s | pass, 14 s |
| Boot via `run /bin/true` | #1 fail (F3), #2 pass 1 s | same | same | same | same | same |
| `/etc/os-release` | `alpine 3.22.6` | `alpine 3.22.6` | `alpine 3.22.6` | `alpine 3.22.6` | `almalinux 9.8 (Olive Jaguar)` | `almalinux 10.2 (Lavender Lion)` |
| CPUs / memory seen | 2 / 2153056 kB | 2 / 1128060 kB | 2 / 2153056 kB | 4 / 4144800 kB | 4 / 4144800 kB | 4 / 4144800 kB |
| Runs as host user | uid matches host | same | same | same | same | same |
| Home mount | `virtiofs rw`. Read ok, write ok, host sees the file | home path absent: `can't create …: nonexistent directory` | `virtiofs ro`. Read ok, write fails: `Read-only file system` | `virtiofs rw`, read and write ok | `virtiofs rw`, read and write ok | `virtiofs rw`, read and write ok |
| PID 1 | `init` (BusyBox) | `init` | `init` | `init` | `systemd` | `systemd` |
| systemd service | n/a | n/a | n/a | n/a | `is-system-running` = `running`. Test unit `started=active`, then `after_stop=inactive` | same |
| Extra | — | — | — | `apk add make gcc musl-dev` as root, then a Makefile prints `built_ok`, `gcc (Alpine 14.2.0)` | — | — |
| Stop | pass (`stopped`) | pass | pass | pass | pass | pass |
| Boot again | pass, 1 s, uptime 0.41 s (fresh boot) | pass | pass | pass | pass, `state_after_reboot=running` | pass, `state_after_reboot=running` |
| Delete | pass, nothing left | pass | pass | pass | pass | pass |

Other machine notes:
- The host home is mounted at **its macOS path** (`/Users/<user>`) in the guest. The guest's `$HOME` is `/home/<user>` in every mode. Flotilla's copy should say "your Mac home appears at its usual path", not "as your home directory".
- With no other machine present, each new machine **became the default automatically** (`*` in `machine list`), even without `--set-default`. Iris's rule "do not add `--set-default`" holds, but users should know about this side effect. Deleting it prints `Deleted default container '…'. Set a new default with …`.
- The tool-install test used `--root` (`machine run --root`), since the default user can't `apk add`.

---

## CLI help: the clone's captures compared with the live 1.5.0 help

The clone has no 1.5.0 captures for `k8s` (latest is 1.4.1) or `machine` (only 1.0.0). Live output is saved in `out/work/k8s*.txt` and `out/work/machine*.txt`.

| Command | Difference |
|---|---|
| `container k8s` | 1.4.1 listed `start` (Start a stopped Kubernetes cluster). **1.5.0 has no `start`**, and neither version has `stop`. 1.5.0's subcommands are `create, delete|rm, list|ls, load-image, write-config`. `k8s start --help` now just prints the parent help. |
| `k8s create` | 1.5.0 adds `--cni <path>`. Everything else matches Iris's shape `--name --cpus --memory --node-image [--rm]`. The default `--node-image` is exactly K135. Default `--name` is `k8s-dev`. |
| `k8s delete`, `list`, `load-image`, `write-config` | No change. |
| `container machine` (top level) | The 1.0.0 "machine" capture is really a concatenation of every subcommand's help, not the top-level page. Live top-level shows examples plus `create, delete|rm, inspect, list|ls, logs, run, set, set-default, stop`. There is **no `start`**, as MACHINES-SPEC says. |
| `machine create` | `--scheme` is now `(http, https)` with default `https`; it was `auto`. New flags `--virtualization` (nested virtualisation, M3+) and `--kernel <path>`. `--cpus`, `--memory`, `--home-mount ro|rw|none` and `--name` are unchanged, so Iris's shape is valid. |
| `machine set` | New keys `virtualization=<bool>` and `kernel=<path>`. |
| `machine run`, `stop`, `delete`, `inspect`, `list`, `logs`, `set-default` | No change. |

Suggested follow-up (not done, since nothing is pushed): add `container-k8s-*-1.5.0-help.txt` and `container-machine-*-1.5.0-help.txt` to `reference/cli-help/` from `out/work/`.

## Needs Kamal

1. **Untested rows:** 7 rows (k8s-dev, k8s-build, k8s-metrics, k8s-compat-134, k8s-eval-136, alma9-build, alma10-services) need more than 4G and must be run on a bigger host. The **K134 and K136 node images have never been booted anywhere.** The F1 restart failure will apply to the 5 clusters whatever host they run on.
2. **Upstream:** the cluster restart failure (F1), the stale kubeconfig after `--rm` (F2) and the first-run-after-create error (F3) look like `container` 1.5.0 bugs worth filing.
3. **Mini's own `dev-mini` cluster** is stopped, and F1 suggests it will not come back on `container start`. Left untouched.

## `~/.kube/config`

- Backed up first to `out/kubeconfig.before`.
- During the run: each `k8s create` added a cluster/context/user named `flt-test-…` and set `current-context` to it. `k8s delete` removed the entries for starter and compact, but left no `current-context`. The `--rm` cluster's entries and `current-context: flt-test-k8s-test` were left behind (F2).
- The final diff against the backup was only those `flt-test-k8s-test` entries and the `current-context` line. **I restored the backup.** `~/.kube/config` is now byte-identical to how it started (`cmp` clean, `current-context: dev-mini`).
- The per-cluster kubeconfig files I wrote with `write-config` (they held the test clusters' client keys) were deleted from `out/work/`.

## Final `flt-test-` leftovers

```
container k8s list        | grep flt-test   → (none)
container machine list    | grep flt-test   → (none)
container list --all      | grep flt-test   → (none)
container volume list     | grep flt-test   → (none)
container network list    | grep flt-test   → (none)
probe files in out/work                     → (none)
```

`out/work/state-before.txt` and `state-after.txt` are identical, so the mini's own containers, volumes, networks and the `dev-mini` cluster are as they were. No `sudo`, DNS, Helper, system settings or `container system stop/start` were used. Nothing was pushed or signed, and no repository files were changed, so there are no patches.
