# Apple `container` 1.4.1 → 1.5.0

**Research date:** 2026-10-05  
**Flotilla baseline:** `container CLI version 1.4.1 (build: release, commit: 9a8917c)`  
**Upgraded to:** `container CLI version 1.5.0 (build: release, commit: d265d66)`, released 2026-09-29  
**Distance:** one minor release  
**Flotilla version this makes:** `1.5.0.0` — `<container version>.<Flotilla revision>`
(DECISIONS.md, 2026-09-12). The next beta is tagged **`v1.5.0.0-beta.2`** when it is packaged,
not before.

The format follows [CONTAINER-UPGRADE.md](CONTAINER-UPGRADE.md), the 1.0.0 → 1.4.1 report, so the
two can be read side by side.

## Evidence and limits

Two independent passes, one from the source and one from the binary:

- **Upstream.** Iris (the fleet's ChatGPT reviewer) read the 1.5.0 release notes, every linked PR,
  the security advisory, and the docs at tag `1.5.0` on GitHub, and wrote the impact table below.
  Each row carries the link it rests on. Iris worked read-only and changed nothing.
- **Local.** Claude ran the installed 1.5.0 on the M3 Max under macOS 27.0.1: help recaptured for
  every command, fixtures recaptured, a field-by-field shape diff against the 1.4.1 set, and a live
  pass over Flotilla's screens with real containers, a volume, a network, a machine and a
  Kubernetes cluster.

Where the two agree, the finding is stated plainly. Nothing here relies on a release note alone.

## Versions

| Version | Release date | Tag commit | Position |
|---|---:|---|---|
| [1.5.0](https://github.com/apple/container/releases/tag/1.5.0) | 2026-09-29 | `d265d66` | latest |
| [1.4.1](https://github.com/apple/container/releases/tag/1.4.1) | 2026-09-09 | `9a8917c` | previous baseline |

## What changed, and what it touches in Flotilla

Iris's table, checked against the binary. The **Local** column is what the installed CLI showed.

| Change | Evidence | Flotilla area | Local |
|---|---|---|---|
| **Breaking: `k8s start` is gone.** Restarts were unreliable, especially after the node got a new IP. The only supported recovery is `k8s delete` then `k8s create` with the same name, which destroys the cluster's data. `container start <node>` is not a substitute: it skips the Kubernetes repair, readiness and kubeconfig steps. | [PR #2290](https://github.com/apple/container/pull/2290), [#2156](https://github.com/apple/container/issues/2156), [recovery docs](https://github.com/apple/container/blob/1.5.0/docs/kubernetes.md#recovering-a-stopped-cluster) | `AppModelClusters.swift`, `ContainerCLI.swift`, the cluster row, the allowlist | Confirmed: `container k8s start --help` fails. **Done**, `e2dcebe`: Start is now a destructive Recreate (DECISIONS Q22 amended). |
| **Needs change: `--node-image` must name a tag.** The tag now sets the Kubernetes version `kubeadm` uses. Untagged and digest-only references fail with `invalidArgument` before anything is provisioned. | [PR #2271](https://github.com/apple/container/pull/2271) | New Cluster's node-image field, the allowlist | **Done**, `e2dcebe`: a new `ValueShape.taggedImageReference`; the form explains a missing tag. |
| **Security fix: kubeconfig sanitising.** Before 1.5.0, guest-controlled `exec`, `auth-provider`, `proxy-url` and similar entries could be copied into a host kubeconfig, which is host code execution. 1.5.0 rebuilds each entry from an allowlist and refuses unsafe ones. Severity **High**, no CVE. It is the only security fix in 1.5.0. | [GHSA-44v5-vx46-ghv6](https://github.com/apple/container/security/advisories/GHSA-44v5-vx46-ghv6), [PR #2310](https://github.com/apple/container/pull/2310) | `writeKubeconfig` (Clusters ▸ Write kubeconfig) | No syntax change. A refused config exits non-zero, and `withProgress` already reports that in the panel. Apple's audit command was run against `~/.kube/config` on this Mac: clean. |
| **Fixed: cluster create follows the node image's iptables backend.** It was hard-coded to `iptables-nft`. On an older kernel without nftables, `k8s create` used to fail with misleading output. | [PR #2145](https://github.com/apple/container/pull/2145) | Cluster-create progress and errors | Not reproducible here (current kernel). Nothing to change. |
| **Fixed: localhost DNS changes no longer cut container egress.** Only Container's own PF anchor is reloaded now. | [PR #2256](https://github.com/apple/container/pull/2256) | DNS domains, running containers | No new output or exit code. Nothing to change. |
| **Fixed: port-forward releases the backend on disconnect.** | [PR #2260](https://github.com/apple/container/pull/2260) | Published ports | No new output or exit code. Nothing to change. |
| **Fixed: `Entrypoint: [""]` images run, and builds under a symlinked path copy everything.** | [PR #2296](https://github.com/apple/container/pull/2296), [PR #2252](https://github.com/apple/container/pull/2252) | Run and Build results | Failures Flotilla used to report faithfully now don't happen. Nothing to change. |
| **New: `k8s create --cni <path>`** selects a plain Kubernetes YAML manifest instead of the bundled kindnet. Helm charts must be rendered first. `NONE` is not an option. | [PR #2254](https://github.com/apple/container/pull/2254), [CNI docs](https://github.com/apple/container/blob/1.5.0/docs/kubernetes.md#custom-cni) | `NewClusterView.swift`, the allowlist | Confirmed in `k8s create --help`. **Not exposed**: default-deny until someone wants it (DECISIONS Q22 amended). |
| **No change: none of the six `UPSTREAM-GAPS.md` gaps closed.** Still no machine network or volume attachment, no connect after creation, no machine-aware `copy`. | [command reference](https://github.com/apple/container/blob/1.5.0/docs/command-reference.md) | [UPSTREAM-GAPS.md](UPSTREAM-GAPS.md) | All six one-line tests re-run against the binary: all hold. For item 4, the only machine was stopped and a container still ran. |
| **No change: macOS 26 on Apple silicon is still the minimum.** | [README](https://github.com/apple/container/blob/1.5.0/README.md#requirements) | `Package.swift` | Flotilla already targets macOS 26.0. |

## What the binary showed that the notes do not

**The core CLI's help is byte-for-byte identical to 1.4.1.** Every command Flotilla allowlists
outside `k8s` has the same flags, operands and defaults. The whole capture is
`reference/cli-help/container-1.5.0-help.txt` (`f3c595f`). The allowlist needed no change outside
`k8s`.

**No payload changed shape.** All fourteen machine-capturable JSON payloads were recaptured with
`Scripts/capture-fixtures.sh --out Tests/FlotillaCoreTests/Fixtures/container-1.5.0` and compared to
the 1.4.1 set by key path and value type. Every difference is a different subject, not a different
schema: the 1.5.0 containers have a volume mount and no `--cap-add`, and the images carry no
`Entrypoint` or labels. Nothing was added or renamed on a subject both sets share.

**A fresh install has no kernel, and nothing says so until you run something.** On a Mac that
never had `container`, 1.5.0 installs and `system status` reports `running`, but every container
and machine fails to start until `container system kernel set --recommended` downloads one (about
20 s). The 1.4.1 upgrade had a similar trap (a resident old daemon, now detected as version skew).
This one isn't an upgrade problem, so an upgrade wouldn't hit it. A new user would hit it on day one.

`system property list` can't detect it: it prints the kernel configuration whether or not the
kernel exists. The file can be checked, though. `system status` gives `paths.appRoot`, and the
installed kernel is `<appRoot>/kernels/default.kernel-<arch>`. That's a startup check Flotilla
could make without running anything. It's logged as its own to-do because it's a feature, not part
of the bump.

**Built the same day** (DECISIONS Q25): `PreflightResult.needsKernel`, a Download Kernel
button, and an allowlist row for `system kernel set --recommended` only. Building it found a
CLI bug: `kernel set` fails if `<appRoot>/kernels` is missing ("The file “vmlinux-…” doesn't
exist", about the temp file). Flotilla creates the empty folder first.

**Signing in to an HTTP registry no longer works at all.** Found testing the Registries section
against a throwaway `registry:2` on `localhost:5001` with htpasswd auth. With a correct password,
`container registry login --scheme http` fails with "refusing insecure credential exchange:
registry localhost issued an authentication challenge over an insecure connection". The check is
in `apple/containerization` (`RegistryClient.swift`): any non-HTTPS base that answers with an
authentication challenge is refused, with no exemption for `localhost`. The same sign-in worked on
1.4.1, which is how `Fixtures/registries.json` was captured on 13 September. It applies to pulls as
well, so an HTTP registry is only usable anonymously. Flotilla now offers no Sign In for an HTTP
registry and will not add a required one over HTTP (DECISIONS Q26).

**Networks can lose their bridge — apple/container#2051, still present in 1.5.0 (observed and
reduced 6 October).** Each network's kernel bridge (`bridge100`, `bridge101`, …) is created when
the network's first container starts and destroyed when its last one stops. A network is given its
bridge *number* at its first start, and if network B first starts while network A's bridge is down,
**both are given the same number**. When both have containers they share one bridge carrying only
one of their gateway addresses; when either's last container stops, the bridge is destroyed under
the other. The surviving network then has no gateway on the Mac at all — its containers still reach
each other, but cannot reach the gateway or the internet, the Mac cannot route to them, and their
**published ports do not answer although the port-forwarder is listening**. Only restarting the
runtime recovers it.

- **What this Mac showed** before any experiment: no host address for the `default` network's
  `192.168.64.0/24` and no route to it; the default network's containers were members of
  `bridge100`, which carried `shop-net`'s `192.168.70.1`. That is the morning's "default network
  broke", and the earlier "custom networks stopped carrying traffic" is the same bug the other way
  round.
- **Reproduced on 1.5.0** with the issue's own steps (throwaway `fx-ra`/`fx-rb`): with containers on
  both, one bridge, carrying B's address; kill B's container and the bridge is gone, and A's
  container's connection to `1.1.1.1:443` times out.
- **A restart repaired it** here, as the issue says; four further attempts at ordinary use (restart;
  restart and recreate a network; containers started in sequence and all at once) all stayed
  healthy — it needs the specific first-start ordering.
- **A second finding, not in the issue: network subnets can move across a restart.** `default` and a
  custom network created without `--subnet` swapped `192.168.64.0/24` and `192.168.65.0/24`
  (networks with containers that had run, like `shop-net`, kept theirs). Restarted containers take
  addresses in the new subnet, so anything that wrote a **gateway address** down — Suggestions'
  gateway wiring (Q28) — would point at the wrong network afterwards. Related, open:
  apple/container#1836 (container IPs change on restart), #1740 (sticky IPs).

Nothing to file: #2051 is open with a deterministic reproduction. A comment confirming 1.5.0 is
worth adding — with the owner's OK. What Flotilla should do is in TODO.md.

**Container DNS names work, once the domain is configured** (also 6 October; DECISIONS, groups
section). Containers created *before* `[dns] domain` was set did not get names; recreated ones did.

## Fixtures

**The value-pinned set stays on 1.4.1.** The `SmokeTests` assertions (six containers, a
4,122,138-byte image) describe the resources that existed when the set was captured. Overwriting
it with 1.5.0 failed them for that reason alone. The upgrade needs to prove decoding, not that one
Mac's state matches another's.

**The 1.5.0 set is decode-only and lives beside it**, in `Fixtures/container-1.5.0/`, pinned by
`Container150DecodeTests`. A later bump adds a folder. It has fourteen files, not nineteen. The
other five each need a state made specially, and were captured by hand once against 1.4.1:

- a version skew;
- an empty Mac;
- an administrator's DNS domain;
- a registry login;
- three purpose-made port containers.

The first draft of this set copied those five in from 1.4.1, which labelled 1.4.1 output as
1.5.0's. A byte comparison caught it, and the set was recaptured clean. `capture-fixtures.sh` now
takes `--out`, and its `CAPTURED.md` lists anything it skipped.

## Recommendation

**Adopt 1.5.0. It's done: Flotilla is `1.5.0.0`.** The security fix alone would justify it. The
cost was one breaking change in an experimental family, now handled, plus one tightened flag.

Still open, none of them blocking:

- the kernel startup check above;
- `--cni` behind a file picker, if anyone asks;
- tagging `v1.5.0.0-beta.2` at packaging.

## Source links

- [Release 1.5.0](https://github.com/apple/container/releases/tag/1.5.0)
- [Security advisory GHSA-44v5-vx46-ghv6](https://github.com/apple/container/security/advisories/GHSA-44v5-vx46-ghv6)
- PRs: [#2290](https://github.com/apple/container/pull/2290) (k8s start removed) ·
  [#2271](https://github.com/apple/container/pull/2271) (tagged node image) ·
  [#2310](https://github.com/apple/container/pull/2310) (kubeconfig sanitising) ·
  [#2254](https://github.com/apple/container/pull/2254) (`--cni`) ·
  [#2145](https://github.com/apple/container/pull/2145) (iptables backend) ·
  [#2256](https://github.com/apple/container/pull/2256) (DNS egress) ·
  [#2260](https://github.com/apple/container/pull/2260) (port-forward) ·
  [#2296](https://github.com/apple/container/pull/2296) (empty entrypoint) ·
  [#2252](https://github.com/apple/container/pull/2252) (symlinked build context)
- Docs at the tag: [kubernetes.md](https://github.com/apple/container/blob/1.5.0/docs/kubernetes.md) ·
  [command-reference.md](https://github.com/apple/container/blob/1.5.0/docs/command-reference.md)
