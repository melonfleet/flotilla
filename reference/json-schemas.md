# Real `container` 1.0.0 JSON schemas

Captured live from `container` 1.0.0 (commit ee848e3) on macOS 26, arm64. These are
the **authoritative** shapes the models in `Sources/FlotillaCore/Models.swift` decode,
and they're pinned by the fixtures in `Tests/FlotillaCoreTests/Fixtures/`. Re-run
`swift run flotilla-probe` after a CLI upgrade to check for drift.

## `container ls --all --format json` → array of Container

Top level: `id`, `configuration`, `status`. The container **name is `configuration.id`**
(there's no separate name field). State is `status.state`.

```jsonc
{
  "id": "flotilla-probe-test",
  "configuration": {
    "id": "flotilla-probe-test",
    "creationDate": "2026-06-30T09:05:20Z",
    "image": {
      "reference": "docker.io/library/alpine:latest",
      "descriptor": { "digest": "sha256:…", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 9218 }
    },
    "platform": { "architecture": "arm64", "os": "linux" },
    "resources": { "cpus": 4, "memoryInBytes": 1073741824, "cpuOverhead": 1 },
    "networks": [ { "network": "default", "options": { "hostname": "…", "mtu": 1280 } } ],
    "initProcess": { "executable": "sleep", "arguments": ["300"], "environment": ["PATH=…"],
                     "workingDirectory": "/", "terminal": false, "user": { "id": { "uid": 0, "gid": 0 } } },
    "labels": {}, "mounts": [], "publishedPorts": [], "publishedSockets": [],
    "dns": { "nameservers": [], "options": [], "searchDomains": [] },
    "capAdd": [], "capDrop": [], "readOnly": false, "rosetta": false, "ssh": false,
    "useInit": false, "virtualization": false, "runtimeHandler": "container-runtime-linux", "sysctls": {}
  },
  "status": {
    "state": "running",
    "startedDate": "2026-06-30T09:05:25Z",
    "networks": [ { "network": "default", "hostname": "…", "ipv4Address": "192.168.64.2/24",
                    "ipv4Gateway": "192.168.64.1", "ipv6Address": "fd15:…/64", "macAddress": "fe:dd:…", "mtu": 1280 } ]
  }
}
```

`container inspect <id>` returns the same object (pretty-printed).

## `container image list --format json` → array of Image

Reference is `configuration.name`. Per-arch detail (incl. size) is in `variants[]`.

```jsonc
{
  "id": "28bd5fe8…",
  "configuration": {
    "name": "docker.io/library/alpine:latest",
    "creationDate": "2026-06-16T00:00:15Z",
    "descriptor": { "digest": "sha256:28bd…", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 9218 }
  },
  "variants": [
    { "digest": "sha256:e7a1…", "size": 4184689, "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" },
      "config": { "architecture": "arm64", "os": "linux", "config": { "Cmd": ["/bin/sh"], "Env": ["PATH=…"], "WorkingDir": "/" },
                  "rootfs": { "type": "layers", "diff_ids": ["sha256:…"] }, "history": [ … ] } }
    // …one variant per platform (amd64, arm/v6, arm/v7, 386, ppc64le, riscv64, s390x, plus "unknown" attestation entries)
  ]
}
```

Note: a multi-arch image has many `variants`, including `architecture: "unknown"`
attestation manifests. Filter to real platforms; pick `arm64` for host-relevant size.

## `container stats --no-stream --format json` → array

```jsonc
{ "id": "flotilla-probe-test", "numProcesses": 1,
  "cpuUsageUsec": 3697,                    // CUMULATIVE — % needs delta over time
  "memoryUsageBytes": 2002944, "memoryLimitBytes": 1073741824,
  "networkRxBytes": 24628, "networkTxBytes": 602,
  "blockReadBytes": 1744896, "blockWriteBytes": 0 }
```

There is no ready-made CPU %. Sample twice and compute
`Δ cpuUsageUsec / Δ wall-clock-usec * 100`. Memory % = usage/limit.

## `container system status --format json` → object

```jsonc
{ "status": "running",                     // or "unregistered" when service is down
  "apiServerAppName": "container-apiserver", "apiServerVersion": "container-apiserver version 1.0.0 …",
  "apiServerBuild": "release", "apiServerCommit": "ee848e3…",
  "appRoot": "/Users/<user>/Library/Application Support/com.apple.container/", "installRoot": "/usr/local/" }
```

When the service isn't started, `status` is `"unregistered"` and the apiServer* fields
are empty strings.

## `container system version --format json` → array

```jsonc
[ { "appName": "container", "version": "1.0.0", "buildType": "release", "commit": "ee848e3…" },
  { "appName": "container-apiserver", "version": "container-apiserver version 1.0.0 …", "buildType": "release", "commit": "ee848e3…" } ]
```

## Service bootstrap gotchas (learned during capture)

- A fresh install needs a Linux kernel before the service runs: `container system
  kernel set --recommended` (downloads the kata-containers static kernel), then
  `container system start`. The interactive prompt can't be answered in a non-TTY —
  the preflight flow should install the kernel explicitly.
- `container system start` is required before any container/image command works.
