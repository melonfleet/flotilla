**Iris: fresh-volume ownership on Apple `container`, and the fix for Flotilla**

Research date: **18 October 2026**. Scope: Apple `container` **1.5.0** source and documentation, its pinned `containerization` dependency, and the current Flotilla checkout. No containers were started during this research; proposed commands and fixes still require live validation.

**Recommendation**

Add a **typed, per-volume initialization policy to recipes**. Before starting a service, Flotilla should explicitly create its named volumes and initialize ownership using a fixed, digest-pinned helper container running as root.

For a genuinely fresh volume, **change ownership of the mount root only**. Recursive `chown` is unnecessary when there is no application data and would also change ext4’s recovery directory. Preserve the service image’s normal user.

Use **tested numeric UID:GID metadata in the recipe** initially. Inspect the selected image’s `User` field as a consistency check, but do not automatically treat it as the required owner of every volume: entrypoints can change identity, groups differ from UIDs, and directories can intentionally have different owners.

Automatically initialize **only volumes whose creation Flotilla can prove it performed for this operation**. Existing, imported, restored, or user-selected volumes need a separate repair workflow.

Apple’s inspected 1.5.0 implementation creates an empty ext4 filesystem and attaches it without Docker-style image-directory population. No native named-volume ownership option was found. The evidence and limitations follow below.

**Open questions for Kamal**

1. Can the first release require an explicit UID, GID, and initialization policy for each affected recipe volume, with unresolved recipes remaining unavailable?
2. Should automatic initialization be limited to newly created Suggestions volumes, leaving existing-volume repair as a separate feature? **Recommended: yes.**
3. Can we ship a small Flotilla-owned helper with a fixed executable and digest, or must we use an upstream BusyBox/Alpine image?
4. Where should the host persist initialization records, including recovery after an app crash or remote disconnection?
5. Do any affected recipes require files copied from the image, particular directory modes, or multiple owners? Ownership changes alone cannot supply these.
6. Which exact image tags, platform manifests, and GIDs were used in the Mac Studio tests? The reported UIDs are useful leads, but incomplete initialization specifications.
7. Should an upstream request cover both ownership-at-creation and Docker-compatible population? I could not verify a directly matching open issue or PR.

**What Apple actually creates**

The 1.5.0 `volume create` command accepts a name, labels, driver options, and `-s` for size. It calls `ClientVolume.create` with the fixed driver `"local"`; it has no image argument or owner argument. Its help describes `--opt` as “Set driver specific options.” [Apple’s `VolumeCreate.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Volume/VolumeCreate.swift)

The server creates a volume directory and a backing file named `volume.img`. It formats that file with the Swift `EXT4.Formatter`, using a 4096-byte block size, the requested capacity, and an optional journal configuration. It then stores the volume configuration. This path neither reads an image directory nor sets an application owner. Duplicate names produce a `volumeAlreadyExists` error. [Apple’s `VolumesService.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift)

This is **not a subprocess invocation of Linux `mkfs.ext4`**. Consequently, familiar `mke2fs` options cannot simply be supplied through `--opt`.

Apple’s package pins `containerization` to **0.47.0**. That formatter creates a sparse file, initializes the filesystem root with `Inode.Root()`, and creates `/lost+found` with mode `0700`. [Apple’s package dependency](https://raw.githubusercontent.com/apple/container/1.5.0/Package.swift), [the pinned ext4 formatter](https://raw.githubusercontent.com/apple/containerization/0.47.0/Sources/ContainerizationEXT4/EXT4%2BFormatter.swift)

The root initializer inspected on `containerization/main` contains:

```swift
inode.mode = Self.Mode(.S_IFDIR, 0o755)
inode.uid = 0
inode.gid = 0
```

That means a root-owned directory writable only by its owner. **Qualification:** the corresponding types file at tag 0.47.0 could not be retrieved; these initializer values were verified on `main`, while the call to that initializer was verified at 0.47.0. Confirm the resulting numeric ownership and mode on the installed build. [Apple’s root-inode implementation](https://github.com/apple/containerization/blob/main/Sources/ContainerizationEXT4/EXT4%2BTypes.swift)

There is also a documentation/source discrepancy concerning journaling. The volume documentation says:

> “By default, a volume uses a journaled `ext4` filesystem.”

However, the inspected creation path passes `nil` when no `journal` option is supplied, and the formatter initializes a journal conditionally. **The actual no-option journaling behavior needs runtime verification.** This discrepancy does not affect the ownership diagnosis. [Apple’s volume documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/volumes.md), [formatter journal initialization](https://raw.githubusercontent.com/apple/containerization/0.47.0/Sources/ContainerizationEXT4/EXT4%2BFormatter.swift)

**There is no Docker-style population in the inspected mount path**

During `run`/`create`, Apple resolves each named volume by creating or inspecting it, then constructs a filesystem mount from its backing image and requested destination. The service image is used separately for the container root filesystem. The volume-resolution code does not copy the image’s destination directory into the volume. [Apple’s `Utility.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Utility.swift)

The runtime subsequently appends those mounts to the container configuration; no population or ownership-adjustment step appears there either. **Conclusion from the inspected source paths:** mounting the fresh volume hides the image directory, including its useful ownership, permissions, and any initial contents. [Apple’s `RuntimeService.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/RuntimeLinux/Server/RuntimeService.swift)

That explains the direct permission failures: an image may contain a directory prepared for UID 472, but mounting a fresh root-owned filesystem over it replaces the visible directory metadata.

**Available flags and their limits**

| Interface | Verified behavior in the inspected 1.5.0 sources/docs |
|---|---|
| `volume create --opt …` | Implemented creation settings are `size` and `journal`. No UID, GID, or root-mode setting was found. |
| `volume create -o …` | The command declares `--opt`; it does not declare Docker’s `-o` alias. |
| `--mount type=volume,…` | No ownership directive. Unknown keys are rejected. `mode` and `size` are restricted to tmpfs. |
| `--volume name:/path:…` | Documents `ro`; the parser forwards suffix options but implements no `:U` ownership operation. |
| `--user`, `--uid`, `--gid` | Configure process identity; they do not initialize volume ownership. |
| `--init` | Runs an init process for signal forwarding and process reaping; it is not a volume initializer. |

Sources: [command reference](https://raw.githubusercontent.com/apple/container/1.5.0/docs/command-reference.md), [mount parser](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Parser.swift), [process and management flags](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Flags.swift).

An arbitrary option surviving parsing is not evidence of support. In particular, neither `--opt uid=1000` nor a `uid=` mount option is a verified way to change ext4 inode ownership. Do not add such options to recipes.

**Upstream issues and PRs**

Two related ownership reports were verified:

- **[#333](https://github.com/apple/container/issues/333): closed, labeled `wontfix`.** PostgreSQL fails because `chmod` and `chown` are denied on a **host bind mount**. This is a different storage path from a fresh named ext4 volume.
- **[#1830](https://github.com/apple/container/issues/1830): open in the retrieved page.** Concerns external APFS directory sharing and VM bootstrap failures. The reporter describes a native block-volume workaround, but explicitly says the original bind-mount failure remains unresolved.

These reports establish related bind-mount limitations, not an upstream fix for this named-volume problem.

**Unverified:** a directly matching issue or PR for fresh named-volume ownership or missing image-directory population. Searches did not establish one, and GitHub’s filtered issue/PR pages were not reliably retrievable. Do not describe this as a known open issue with an invented issue number.

**How other systems handle it**

| System | Mechanism | Relevance to Apple `container` |
|---|---|---|
| Docker | Populates an empty volume from the image destination, preserving directory/file metadata. | Not implemented in the inspected Apple path; reproducible with additional initialization machinery. |
| Podman `:U` | Recursively changes source ownership using the container’s identity and user-namespace mapping. | No equivalent Apple option found; a helper can reproduce the ownership change. |
| Podman `--userns=keep-id` | Maps the invoking Linux user into the container namespace. | No equivalent Apple flag found. Setting `--user` is not equivalent. |
| Kubernetes `fsGroup` | Establishes group access on supported volumes through kubelet or the storage driver. | No direct equivalent for ordinary Apple `container run`. |
| Kubernetes init container | Completes preparation before the application starts. | Reproducible as a sequential helper run orchestrated by Flotilla. |
| OrbStack | Includes a Docker engine and Linux-side named volumes. | Docker semantics apply through its Docker backend; this is not an Apple volume option. |
| Colima, Docker runtime | Runs Docker as its default runtime. | Likewise provides Docker’s behavior through that backend. |

Docker documents:

> “these files or directories are propagated (copied) into the volume by default.”

The condition is an **empty destination volume**, not merely a recently created name. `volume-nocopy` disables population. Moby’s implementation skips a nonempty destination and copies metadata along with contents; it does not choose ownership by looking at the service’s `USER`. [Docker volume documentation](https://docs.docker.com/engine/storage/volumes/), [Moby population code](https://raw.githubusercontent.com/moby/moby/v28.5.1/daemon/create_unix.go), [Moby content-copy implementation](https://raw.githubusercontent.com/moby/moby/v28.5.1/container/container_unix.go)

Podman’s documentation says `:U` recursively changes ownership and warns that walking thousands of inodes delays startup. `keep-id` instead establishes identity mappings and can override the image’s default process user. Neither mechanism guarantees that an arbitrary existing directory becomes writable without suitable ownership or permissions. [Podman run documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html)

Kubernetes’ `fsGroup` is principally a **group-access mechanism**, not a request to make every file owned by the application UID. Supported volumes may receive group and permission changes. `fsGroupChangePolicy: OnRootMismatch` can avoid repeated traversal, and capable CSI drivers can perform the operation themselves. [Kubernetes security contexts](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)

A root init container can also prepare the mounted directory. Kubernetes requires it to finish successfully before proceeding, but init containers can be retried or re-executed; they are not inherently once-per-volume operations. Flotilla needs its own persistence policy. [Kubernetes init containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)

OrbStack explicitly includes a Docker engine and stores named-volume data on the Linux side. Colima explicitly identifies Docker as its default runtime; its other runtime choices should not be assumed to have identical semantics. The conclusion that their Docker backends inherit Docker population behavior is an **inference from those documented architectures**, not a benchmark performed here. [OrbStack Docker](https://docs.orbstack.dev/docker/), [OrbStack volumes](https://docs.orbstack.dev/docker/file-sharing), [Colima runtimes](https://colima.run/docs/runtimes/)

**Candidate fixes, ranked**

| Rank | Fix | Safety and reliability |
|---|---|---|
| **1** | Initialize fresh volumes with a fixed root helper, using tested per-volume metadata. | Preserves the service identity and confines changes to newly provisioned storage. Recommended general solution. |
| **2** | Use a documented image-specific initialization mechanism that drops privileges afterward. | Good where tested; less uniform and potentially repeated on every start. |
| **3** | Implement image-directory population for recipes that need it. | More complete Docker compatibility, but copying mixed ownership, links, modes, and initial files substantially expands scope. |
| **4** | Run the long-lived service with `--user 0`. | Broad privilege increase; may fail image assumptions and leave root-owned application data. Avoid as the default repair. |

A future native Apple ownership option could simplify rank 1, but **none was verified in 1.5.0**.

Running a service as root inside its VM does not make it macOS host root. Nevertheless, it increases authority over the service’s accessible files and resources, and changes the image’s intended security posture. Some applications reject root; others create data that later prevents a return to their normal user.

Distinguish permanent root execution from an image’s supported **root bootstrap followed by privilege dropping**.

For example, Jupyter Docker Stacks documents `CHOWN_HOME` and `CHOWN_EXTRA`, with optional recursive behavior. Its user-changing startup features require root and subsequently launch the command as the notebook user. This is a plausible recipe-specific alternative, subject to testing the exact image. A `umask` setting alone cannot grant access to an already unwritable directory. [Jupyter Docker Stacks configuration](https://jupyter-docker-stacks.readthedocs.io/en/latest/using/common.html)

Do not assume `PUID`, `PGID`, or similarly named variables work across unrelated image families. Changing a data-directory argument also only helps if the replacement is writable **and remains persistent**.

**Where the UID and GID should come from**

The recipe should describe the **required owner of each persistent path**, including any deliberate difference from the image’s initial process identity.

A proposed schema could contain:

```json
{
  "suffix": "data",
  "path": "/var/lib/example",
  "initialization": {
    "kind": "ownership",
    "uid": 1000,
    "gid": 100,
    "scope": "root",
    "version": 1
  }
}
```

This is a proposal, not an existing Flotilla schema or a verified identity for any listed recipe.

Associate that specification with the tested image reference, resolved manifest digest, platform, and any environment settings that affect identity. A tag change or user override should trigger revalidation, **not automatic rechowning of existing data**.

Apple’s `image inspect` emits an array of image resources containing per-platform variants and their OCI configs. Select the variant that will actually run, then read its nested OCI `config.User`. Do not use Docker’s `.Config.User` JSON path unchanged or select the first variant arbitrarily. [Apple’s inspect command](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Image/ImageInspect.swift), [image-resource structure](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerResource/Image/ImageResource.swift)

Flotilla already decodes the nested variants, but its current `RunConfig` retains only `Env`, `Entrypoint`, and `Cmd`. It would need to retain `User` too. [Flotilla’s current image model](Sources/FlotillaCore/Models.swift:168)

Interpret image users carefully:

| Image `User` value | What is required |
|---|---|
| `1000:100` | Numeric pair is explicit. |
| `1000` | UID is explicit; determine the applicable primary group. Do not assume GID 1000. |
| `jovyan` | Resolve the name using the image’s `/etc/passwd`; obtain its primary GID. |
| `app:storage` | Resolve the user and group using the image’s account files. |
| Missing or empty | Default initial identity is generally root; an entrypoint may still drop to another user. |

OCI permits numeric and named combinations and specifies account-file lookup when a group is omitted. Apple’s parser takes the image user as its default unless process flags override it. **The exact Apple guest-side fallback for every numeric-only edge case was not verified here.** [OCI image configuration](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md), [Apple process parser](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Parser.swift)

Names must be resolved against the **service image**, never the Mac’s accounts or the helper image’s accounts.

A generic resolver could inspect the final merged image filesystem, accounting for layers and whiteouts, without executing the image. Alternatively, a bounded `id` probe can work for known images with a verified executable, overriding their entrypoint and mounting no application data. Neither approach is currently established as a complete Flotilla implementation.

Do not automatically run arbitrary images as root to discover their users. Distroless images may lack `id` or a shell, and inspecting the initial identity still cannot discover every privilege change an entrypoint performs. Explicit recipe metadata avoids making that resolver a prerequisite.

**How the helper should run**

For an already-proven fresh volume, the essential operation is:

```text
chown -h NUMERIC_UID:NUMERIC_GID /flotilla-volume
```

The destination should always be the same helper-controlled mount point. It need not match the service’s destination.

An illustrative Apple CLI invocation is:

```sh
container run --rm \
  --user 0:0 \
  --network none \
  --no-dns \
  --read-only \
  --mount type=volume,source=NEW_VOLUME,target=/flotilla-volume \
  --entrypoint /bin/chown \
  HELPER_IMAGE_AT_APPROVED_DIGEST \
  -h NUMERIC_UID:NUMERIC_GID /flotilla-volume
```

**Unverified command example:** placeholders require substitution, the selected helper’s executable must be checked, and the complete invocation needs testing on the supported runtime. The CLI declares these flags; its configuration code handles the no-network case. Flotilla’s current allowlist does not admit this invocation. [Apple flags](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Flags.swift), [network configuration](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Utility.swift)

A plain `chown` example omits important production checks. Prefer a small fixed helper that:

- Verifies the destination is the expected mounted filesystem.
- Rejects unexpected contents before changing ownership.
- Preserves a genuine, empty ext4 `/lost+found`.
- Changes only the mount root and explicitly declared fresh subdirectories.
- Verifies the resulting numeric owner and required mode.
- Returns a bounded, structured result.

Pin the helper by digest, provide the required architecture, and pull it before allocating application resources. A tiny helper still incurs VM startup and teardown.

Run it attached and wait for success. Apple’s foreground `run` propagates the process exit status. Ensure the helper VM releases the filesystem before starting the service; process completion alone should not be assumed to prove teardown has finished. [Apple’s `ContainerRun.swift`](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Container/ContainerRun.swift)

**First creation, existing data, and recording completion**

“First creation” must mean **successful creation by this provisioning transaction**, not “the name was absent in the last UI refresh.”

A safe sequence is:

1. Resolve the service image and initialization specification.
2. Allocate a unique volume name and operation UUID; persist the provisioning intent.
3. Explicitly create the volume with Flotilla management and operation labels.
4. Require successful creation. If the name already exists, stop automatic initialization.
5. Inspect the volume and bind its returned metadata to the operation.
6. Ensure no other container references it; acquire Flotilla’s per-volume provisioning lock.
7. Persist that initialization is being attempted.
8. Run the fixed helper and verify its result.
9. Wait for helper teardown, then durably record completion.
10. Permit service creation/start only after all required volumes are ready.

A useful record includes:

| Field | Purpose |
|---|---|
| Host/runtime identity | Prevents confusing identically named volumes on different Macs. |
| Volume name, creation date, operation label | Distinguishes the provisioned instance from ordinary name reuse. |
| Recipe ID and initialization version | Identifies the applied policy. |
| Service manifest digest and platform | Records the tested image variant. |
| UID, GID, scope, optional mode | Records exactly what was requested. |
| Helper digest and operation UUID | Identifies the initializer. |
| State, timestamps, verified result | Supports recovery and auditing. |

Apple’s volume JSON exposes a name-based ID and creation metadata; it should not be treated as an immutable generation identifier. Flotilla’s captured 1.5.0 fixture confirms that shape. [Captured volume inspection](Tests/FlotillaCoreTests/Fixtures/container-1.5.0/inspect-volume.json:1)

An optional helper receipt inside the volume can support recovery, but it should not be the sole authority: application users can potentially alter it, and some applications require clean directory contents. Creation labels should carry provenance; use Flotilla’s host-side store for mutable completion state.

There is an unavoidable crash window between changing filesystem metadata and recording success elsewhere. **A Boolean cannot guarantee literal exactly-once execution across crashes.** To satisfy “never runs twice,” persist the attempted state before launch and do not automatically replay an ambiguous attempt. Reconcile through read-only inspection; unresolved cases require explicit recovery.

If controlled retries are later allowed, the helper must recognize a matching completed operation and return without repeating changes.

Never initialize automatically merely because:

- A volume is empty or currently unused.
- Its root is owned by UID 0.
- Its name starts with `flotilla`.
- The completion record is missing.
- A container failed with `Permission denied`.

Those conditions do not establish ownership of the data. Losing Flotilla’s records must not turn existing volumes into fresh ones.

**Cost and recursive initialization**

Changing the root directory’s owner is approximately constant work regardless of the volume’s advertised capacity. Apple’s images are sparse, so capacity is not the same as allocated data. [Apple’s volume documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/volumes.md)

Recursive ownership changes scale with **inode count and metadata I/O**. A directory containing millions of small files can be expensive even when its byte size is modest. Podman explicitly documents this startup cost. No Mac Studio timing was measured here. [Podman’s ownership warning](https://docs.podman.io/en/latest/markdown/podman-run.1.html)

Use recursion only for an explicitly defined tree that Flotilla itself has just populated and whose contents require one owner. Preserve mixed ownership when copying image contents. Existing-volume repair should show scope, require an explicit action, and recommend a backup.

Do not run a second helper while an earlier attempt might still be active. Cancellation must include teardown or reconciliation of the named helper container.

**Security requirements**

The initializer must never become a general root command facility.

For symlinks, `-h`, `-R`, and traversal policy solve different problems:

- `-h` changes the symlink itself rather than its target.
- `-R` requests recursion.
- `-P` prevents traversal through symlinked directories.
- `-H` and `-L` permit forms of symlink traversal and are inappropriate here.

BusyBox documents these distinctions. If recursion is ever needed, a candidate is `chown -h -R -P …`, but its behavior must be tested in the **pinned helper build**. [BusyBox `chown` documentation](https://busybox.net/downloads/BusyBox.html)

The implementation must also:

- Reject a symlink in the target path itself; use a fixed mount point without a trailing slash.
- Never follow links outside the mounted filesystem.
- Never recursively operate on a host bind mount.
- Never mount the service’s other volumes, host folders, runtime sockets, or SSH agent into the helper.
- Never execute scripts or binaries found on the data volume.
- Never use `chmod -R 777` as a substitute for ownership.
- Never change ownership while another container can modify the tree.

For a custom helper, descriptor-based operations such as opening the mount root without following symlinks and calling `fchown` reduce path races. Recursive implementations need additional filesystem-boundary and race protections; `-P` alone is not a complete security boundary.

Use the smallest tested capability set. Root-only ownership initialization may need only `CHOWN`; mode changes, receipts, and traversal can require additional permissions. **The minimum complete capability profile remains unverified.** Do not grant `ALL`.

**Fit with Flotilla’s Allowlist and MountPolicy**

The current `run` rule permits a selected set of flags and trailing container command tokens. It does **not** permit `--user`, `--entrypoint`, `--mount`, `--read-only`, or capability controls. Its existing `.command` trailing policy does not express the helper restriction. [Current run rule](Sources/FlotillaCore/Allowlist.swift:819)

Add a typed operation such as:

```text
initializeFreshRecipeVolume(operationID)
```

The host should resolve that operation to its locally recorded volume and initialization specification, then construct and validate the CLI argv itself.

The helper command profile should require:

- One exact approved image digest and executable.
- One named-volume mount at one fixed destination.
- Root as the fixed helper identity.
- Fixed networking and isolation flags.
- Bounded numeric UID/GID values.
- No arbitrary command, environment, path, extra mount, or entrypoint.
- Provenance tying the volume to the pending provisioning operation.

Validation must occur before execution and must not fall back to the general `run` rule when a helper-profile check fails. Keep the existing `ContainerCLI` validation, timeout, error, and audit path. [Validated execution boundary](Sources/FlotillaCore/ContainerCLI.swift:332)

`MountPolicy` currently permits named volumes and controls access to host paths. That is appropriate but insufficient for ownership initialization: a syntactically valid named volume can still contain valuable existing data. Add the provenance restriction above, and force the initializer to reject host paths even for a local caller using an otherwise unrestricted mount policy. [Current MountPolicy](Sources/FlotillaCore/MountPolicy.swift:1)

The Suggestions library is already treated as untrusted input. Extend it with a bounded initialization enum and numeric fields, not free-form scripts, helper images, or arbitrary argv. Apply the same checks to imported recipes and updates. [Suggestions validation model](Sources/FlotillaCore/SuggestionLibrary.swift:1)

The integration must cover both paths:

- Standalone Suggestions currently prefill the editable Run form; carry the initialization specification through that flow and revalidate after edits. Its unique-name selection is helpful but cannot replace creation-time checks. [Standalone Suggestions flow](Sources/Flotilla/SuggestionsView.swift:204)
- Stack creation already has an explicit volume-creation phase. Initialize each affected volume there, before services can start. For remote hosts, provenance and completion state belong on the host performing the operation. [Stack volume creation](Sources/Flotilla/AppModelSuggestions.swift:164)

**What remains to establish for the failing recipes**

The Mac Studio results and the following UID candidates come from the supplied test report; they were not independently reproduced here.

| Recipe | Reported path / identity | Remaining verification |
|---|---|---|
| Grafana | `/var/lib/grafana`, UID 472 | Exact GID and any required initial content. |
| Prometheus | `/prometheus`, UID 65534 | GID and actual image user representation. |
| Loki | `/loki`, UID 10001 | GID and required rules/data directory layout. |
| Filebrowser | `/database` | Effective UID:GID, parent ownership, database initialization. |
| pgAdmin4 | `/var/lib/pgadmin`, UID 5050 | GID and startup behavior. |
| Jupyter | `/home/jovyan/work`, UID 1000 | GID and identity-changing environment settings. |
| code-server | `/home/coder/project`, UID 1000 | Exact image family, GID, and workspace behavior. |
| Vault | `/vault/file` | Effective writer identity and entrypoint privilege handling. |
| Invoice Ninja | `/var/www/app/storage` | Writer identity, directory contents, and possibly multiple owners. |
| Ghost | `no such table` | Database path, migrations, backend configuration, and earlier errors. |

The direct permission errors strongly fit the fresh-volume mechanism. **Ghost remains a hypothesis:** a missing table is not evidence of an ownership failure by itself. Ownership initialization also cannot restore image files hidden by a mount.

**Validation required before shipping**

Test the pinned helper and each repaired recipe on the supported macOS/runtime combinations:

1. Demonstrate fresh-volume numeric ownership and the original non-root write failure.
2. Initialize ownership, then start the unmodified service and verify persistence after recreation.
3. Confirm ordinary restarts and app relaunches perform no initialization.
4. Confirm existing, imported, populated, and same-name replacement volumes are never automatically changed.
5. Interrupt provisioning before launch, during execution, and after success but before completion recording; verify safe recovery.
6. Reject bind mounts, alternate helper digests, extra argv, symlink targets, unexpected contents, and unauthorized remote requests.
7. Verify helper failure blocks service startup and teardown completes before volume reuse.

Record the runtime versions, image manifests, UID:GID values, helper digest, and observed results with each recipe’s test evidence. **No helper invocation, recipe repair, or performance claim in this document should be marked live-tested until those checks pass.**
**Iris: fresh-volume ownership on Apple `container`, and the fix for Flotilla**

Research date: **18 October 2026**. Scope: Apple `container` **1.5.0** source and documentation, its pinned `containerization` dependency, and the current Flotilla checkout. No containers were started during this research; proposed commands and fixes still require live validation.

**Recommendation**

Add a **typed, per-volume initialization policy to recipes**. Before starting a service, Flotilla should explicitly create its named volumes and initialize ownership using a fixed, digest-pinned helper container running as root.

For a genuinely fresh volume, **change ownership of the mount root only**. Recursive `chown` is unnecessary when there is no application data and would also change ext4’s recovery directory. Preserve the service image’s normal user.

Use **tested numeric UID:GID metadata in the recipe** initially. Inspect the selected image’s `User` field as a consistency check, but do not automatically treat it as the required owner of every volume: entrypoints can change identity, groups differ from UIDs, and directories can intentionally have different owners.

Automatically initialize **only volumes whose creation Flotilla can prove it performed for this operation**. Existing, imported, restored, or user-selected volumes need a separate repair workflow.

Apple’s inspected 1.5.0 implementation creates an empty ext4 filesystem and attaches it without Docker-style image-directory population. No native named-volume ownership option was found. The evidence and limitations follow below.

**Open questions for Kamal**

1. Can the first release require an explicit UID, GID, and initialization policy for each affected recipe volume, with unresolved recipes remaining unavailable?
2. Should automatic initialization be limited to newly created Suggestions volumes, leaving existing-volume repair as a separate feature? **Recommended: yes.**
3. Can we ship a small Flotilla-owned helper with a fixed executable and digest, or must we use an upstream BusyBox/Alpine image?
4. Where should the host persist initialization records, including recovery after an app crash or remote disconnection?
5. Do any affected recipes require files copied from the image, particular directory modes, or multiple owners? Ownership changes alone cannot supply these.
6. Which exact image tags, platform manifests, and GIDs were used in the Mac Studio tests? The reported UIDs are useful leads, but incomplete initialization specifications.
7. Should an upstream request cover both ownership-at-creation and Docker-compatible population? I could not verify a directly matching open issue or PR.

**What Apple actually creates**

The 1.5.0 `volume create` command accepts a name, labels, driver options, and `-s` for size. It calls `ClientVolume.create` with the fixed driver `"local"`; it has no image argument or owner argument. Its help describes `--opt` as “Set driver specific options.” [Apple’s `VolumeCreate.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Volume/VolumeCreate.swift)

The server creates a volume directory and a backing file named `volume.img`. It formats that file with the Swift `EXT4.Formatter`, using a 4096-byte block size, the requested capacity, and an optional journal configuration. It then stores the volume configuration. This path neither reads an image directory nor sets an application owner. Duplicate names produce a `volumeAlreadyExists` error. [Apple’s `VolumesService.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift)

This is **not a subprocess invocation of Linux `mkfs.ext4`**. Consequently, familiar `mke2fs` options cannot simply be supplied through `--opt`.

Apple’s package pins `containerization` to **0.47.0**. That formatter creates a sparse file, initializes the filesystem root with `Inode.Root()`, and creates `/lost+found` with mode `0700`. [Apple’s package dependency](https://raw.githubusercontent.com/apple/container/1.5.0/Package.swift), [the pinned ext4 formatter](https://raw.githubusercontent.com/apple/containerization/0.47.0/Sources/ContainerizationEXT4/EXT4%2BFormatter.swift)

The root initializer inspected on `containerization/main` contains:

```swift
inode.mode = Self.Mode(.S_IFDIR, 0o755)
inode.uid = 0
inode.gid = 0
```

That means a root-owned directory writable only by its owner. **Qualification:** the corresponding types file at tag 0.47.0 could not be retrieved; these initializer values were verified on `main`, while the call to that initializer was verified at 0.47.0. Confirm the resulting numeric ownership and mode on the installed build. [Apple’s root-inode implementation](https://github.com/apple/containerization/blob/main/Sources/ContainerizationEXT4/EXT4%2BTypes.swift)

There is also a documentation/source discrepancy concerning journaling. The volume documentation says:

> “By default, a volume uses a journaled `ext4` filesystem.”

However, the inspected creation path passes `nil` when no `journal` option is supplied, and the formatter initializes a journal conditionally. **The actual no-option journaling behavior needs runtime verification.** This discrepancy does not affect the ownership diagnosis. [Apple’s volume documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/volumes.md), [formatter journal initialization](https://raw.githubusercontent.com/apple/containerization/0.47.0/Sources/ContainerizationEXT4/EXT4%2BFormatter.swift)

**There is no Docker-style population in the inspected mount path**

During `run`/`create`, Apple resolves each named volume by creating or inspecting it, then constructs a filesystem mount from its backing image and requested destination. The service image is used separately for the container root filesystem. The volume-resolution code does not copy the image’s destination directory into the volume. [Apple’s `Utility.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Utility.swift)

The runtime subsequently appends those mounts to the container configuration; no population or ownership-adjustment step appears there either. **Conclusion from the inspected source paths:** mounting the fresh volume hides the image directory, including its useful ownership, permissions, and any initial contents. [Apple’s `RuntimeService.swift`, 1.5.0](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/RuntimeLinux/Server/RuntimeService.swift)

That explains the direct permission failures: an image may contain a directory prepared for UID 472, but mounting a fresh root-owned filesystem over it replaces the visible directory metadata.

**Available flags and their limits**

| Interface | Verified behavior in the inspected 1.5.0 sources/docs |
|---|---|
| `volume create --opt …` | Implemented creation settings are `size` and `journal`. No UID, GID, or root-mode setting was found. |
| `volume create -o …` | The command declares `--opt`; it does not declare Docker’s `-o` alias. |
| `--mount type=volume,…` | No ownership directive. Unknown keys are rejected. `mode` and `size` are restricted to tmpfs. |
| `--volume name:/path:…` | Documents `ro`; the parser forwards suffix options but implements no `:U` ownership operation. |
| `--user`, `--uid`, `--gid` | Configure process identity; they do not initialize volume ownership. |
| `--init` | Runs an init process for signal forwarding and process reaping; it is not a volume initializer. |

Sources: [command reference](https://raw.githubusercontent.com/apple/container/1.5.0/docs/command-reference.md), [mount parser](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Parser.swift), [process and management flags](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Flags.swift).

An arbitrary option surviving parsing is not evidence of support. In particular, neither `--opt uid=1000` nor a `uid=` mount option is a verified way to change ext4 inode ownership. Do not add such options to recipes.

**Upstream issues and PRs**

Two related ownership reports were verified:

- **[#333](https://github.com/apple/container/issues/333): closed, labeled `wontfix`.** PostgreSQL fails because `chmod` and `chown` are denied on a **host bind mount**. This is a different storage path from a fresh named ext4 volume.
- **[#1830](https://github.com/apple/container/issues/1830): open in the retrieved page.** Concerns external APFS directory sharing and VM bootstrap failures. The reporter describes a native block-volume workaround, but explicitly says the original bind-mount failure remains unresolved.

These reports establish related bind-mount limitations, not an upstream fix for this named-volume problem.

**Unverified:** a directly matching issue or PR for fresh named-volume ownership or missing image-directory population. Searches did not establish one, and GitHub’s filtered issue/PR pages were not reliably retrievable. Do not describe this as a known open issue with an invented issue number.

**How other systems handle it**

| System | Mechanism | Relevance to Apple `container` |
|---|---|---|
| Docker | Populates an empty volume from the image destination, preserving directory/file metadata. | Not implemented in the inspected Apple path; reproducible with additional initialization machinery. |
| Podman `:U` | Recursively changes source ownership using the container’s identity and user-namespace mapping. | No equivalent Apple option found; a helper can reproduce the ownership change. |
| Podman `--userns=keep-id` | Maps the invoking Linux user into the container namespace. | No equivalent Apple flag found. Setting `--user` is not equivalent. |
| Kubernetes `fsGroup` | Establishes group access on supported volumes through kubelet or the storage driver. | No direct equivalent for ordinary Apple `container run`. |
| Kubernetes init container | Completes preparation before the application starts. | Reproducible as a sequential helper run orchestrated by Flotilla. |
| OrbStack | Includes a Docker engine and Linux-side named volumes. | Docker semantics apply through its Docker backend; this is not an Apple volume option. |
| Colima, Docker runtime | Runs Docker as its default runtime. | Likewise provides Docker’s behavior through that backend. |

Docker documents:

> “these files or directories are propagated (copied) into the volume by default.”

The condition is an **empty destination volume**, not merely a recently created name. `volume-nocopy` disables population. Moby’s implementation skips a nonempty destination and copies metadata along with contents; it does not choose ownership by looking at the service’s `USER`. [Docker volume documentation](https://docs.docker.com/engine/storage/volumes/), [Moby population code](https://raw.githubusercontent.com/moby/moby/v28.5.1/daemon/create_unix.go), [Moby content-copy implementation](https://raw.githubusercontent.com/moby/moby/v28.5.1/container/container_unix.go)

Podman’s documentation says `:U` recursively changes ownership and warns that walking thousands of inodes delays startup. `keep-id` instead establishes identity mappings and can override the image’s default process user. Neither mechanism guarantees that an arbitrary existing directory becomes writable without suitable ownership or permissions. [Podman run documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html)

Kubernetes’ `fsGroup` is principally a **group-access mechanism**, not a request to make every file owned by the application UID. Supported volumes may receive group and permission changes. `fsGroupChangePolicy: OnRootMismatch` can avoid repeated traversal, and capable CSI drivers can perform the operation themselves. [Kubernetes security contexts](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)

A root init container can also prepare the mounted directory. Kubernetes requires it to finish successfully before proceeding, but init containers can be retried or re-executed; they are not inherently once-per-volume operations. Flotilla needs its own persistence policy. [Kubernetes init containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)

OrbStack explicitly includes a Docker engine and stores named-volume data on the Linux side. Colima explicitly identifies Docker as its default runtime; its other runtime choices should not be assumed to have identical semantics. The conclusion that their Docker backends inherit Docker population behavior is an **inference from those documented architectures**, not a benchmark performed here. [OrbStack Docker](https://docs.orbstack.dev/docker/), [OrbStack volumes](https://docs.orbstack.dev/docker/file-sharing), [Colima runtimes](https://colima.run/docs/runtimes/)

**Candidate fixes, ranked**

| Rank | Fix | Safety and reliability |
|---|---|---|
| **1** | Initialize fresh volumes with a fixed root helper, using tested per-volume metadata. | Preserves the service identity and confines changes to newly provisioned storage. Recommended general solution. |
| **2** | Use a documented image-specific initialization mechanism that drops privileges afterward. | Good where tested; less uniform and potentially repeated on every start. |
| **3** | Implement image-directory population for recipes that need it. | More complete Docker compatibility, but copying mixed ownership, links, modes, and initial files substantially expands scope. |
| **4** | Run the long-lived service with `--user 0`. | Broad privilege increase; may fail image assumptions and leave root-owned application data. Avoid as the default repair. |

A future native Apple ownership option could simplify rank 1, but **none was verified in 1.5.0**.

Running a service as root inside its VM does not make it macOS host root. Nevertheless, it increases authority over the service’s accessible files and resources, and changes the image’s intended security posture. Some applications reject root; others create data that later prevents a return to their normal user.

Distinguish permanent root execution from an image’s supported **root bootstrap followed by privilege dropping**.

For example, Jupyter Docker Stacks documents `CHOWN_HOME` and `CHOWN_EXTRA`, with optional recursive behavior. Its user-changing startup features require root and subsequently launch the command as the notebook user. This is a plausible recipe-specific alternative, subject to testing the exact image. A `umask` setting alone cannot grant access to an already unwritable directory. [Jupyter Docker Stacks configuration](https://jupyter-docker-stacks.readthedocs.io/en/latest/using/common.html)

Do not assume `PUID`, `PGID`, or similarly named variables work across unrelated image families. Changing a data-directory argument also only helps if the replacement is writable **and remains persistent**.

**Where the UID and GID should come from**

The recipe should describe the **required owner of each persistent path**, including any deliberate difference from the image’s initial process identity.

A proposed schema could contain:

```json
{
  "suffix": "data",
  "path": "/var/lib/example",
  "initialization": {
    "kind": "ownership",
    "uid": 1000,
    "gid": 100,
    "scope": "root",
    "version": 1
  }
}
```

This is a proposal, not an existing Flotilla schema or a verified identity for any listed recipe.

Associate that specification with the tested image reference, resolved manifest digest, platform, and any environment settings that affect identity. A tag change or user override should trigger revalidation, **not automatic rechowning of existing data**.

Apple’s `image inspect` emits an array of image resources containing per-platform variants and their OCI configs. Select the variant that will actually run, then read its nested OCI `config.User`. Do not use Docker’s `.Config.User` JSON path unchanged or select the first variant arbitrarily. [Apple’s inspect command](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Image/ImageInspect.swift), [image-resource structure](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerResource/Image/ImageResource.swift)

Flotilla already decodes the nested variants, but its current `RunConfig` retains only `Env`, `Entrypoint`, and `Cmd`. It would need to retain `User` too. [Flotilla’s current image model](Sources/FlotillaCore/Models.swift:168)

Interpret image users carefully:

| Image `User` value | What is required |
|---|---|
| `1000:100` | Numeric pair is explicit. |
| `1000` | UID is explicit; determine the applicable primary group. Do not assume GID 1000. |
| `jovyan` | Resolve the name using the image’s `/etc/passwd`; obtain its primary GID. |
| `app:storage` | Resolve the user and group using the image’s account files. |
| Missing or empty | Default initial identity is generally root; an entrypoint may still drop to another user. |

OCI permits numeric and named combinations and specifies account-file lookup when a group is omitted. Apple’s parser takes the image user as its default unless process flags override it. **The exact Apple guest-side fallback for every numeric-only edge case was not verified here.** [OCI image configuration](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md), [Apple process parser](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Parser.swift)

Names must be resolved against the **service image**, never the Mac’s accounts or the helper image’s accounts.

A generic resolver could inspect the final merged image filesystem, accounting for layers and whiteouts, without executing the image. Alternatively, a bounded `id` probe can work for known images with a verified executable, overriding their entrypoint and mounting no application data. Neither approach is currently established as a complete Flotilla implementation.

Do not automatically run arbitrary images as root to discover their users. Distroless images may lack `id` or a shell, and inspecting the initial identity still cannot discover every privilege change an entrypoint performs. Explicit recipe metadata avoids making that resolver a prerequisite.

**How the helper should run**

For an already-proven fresh volume, the essential operation is:

```text
chown -h NUMERIC_UID:NUMERIC_GID /flotilla-volume
```

The destination should always be the same helper-controlled mount point. It need not match the service’s destination.

An illustrative Apple CLI invocation is:

```sh
container run --rm \
  --user 0:0 \
  --network none \
  --no-dns \
  --read-only \
  --mount type=volume,source=NEW_VOLUME,target=/flotilla-volume \
  --entrypoint /bin/chown \
  HELPER_IMAGE_AT_APPROVED_DIGEST \
  -h NUMERIC_UID:NUMERIC_GID /flotilla-volume
```

**Unverified command example:** placeholders require substitution, the selected helper’s executable must be checked, and the complete invocation needs testing on the supported runtime. The CLI declares these flags; its configuration code handles the no-network case. Flotilla’s current allowlist does not admit this invocation. [Apple flags](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Flags.swift), [network configuration](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/Services/ContainerAPIService/Client/Utility.swift)

A plain `chown` example omits important production checks. Prefer a small fixed helper that:

- Verifies the destination is the expected mounted filesystem.
- Rejects unexpected contents before changing ownership.
- Preserves a genuine, empty ext4 `/lost+found`.
- Changes only the mount root and explicitly declared fresh subdirectories.
- Verifies the resulting numeric owner and required mode.
- Returns a bounded, structured result.

Pin the helper by digest, provide the required architecture, and pull it before allocating application resources. A tiny helper still incurs VM startup and teardown.

Run it attached and wait for success. Apple’s foreground `run` propagates the process exit status. Ensure the helper VM releases the filesystem before starting the service; process completion alone should not be assumed to prove teardown has finished. [Apple’s `ContainerRun.swift`](https://raw.githubusercontent.com/apple/container/1.5.0/Sources/ContainerCommands/Container/ContainerRun.swift)

**First creation, existing data, and recording completion**

“First creation” must mean **successful creation by this provisioning transaction**, not “the name was absent in the last UI refresh.”

A safe sequence is:

1. Resolve the service image and initialization specification.
2. Allocate a unique volume name and operation UUID; persist the provisioning intent.
3. Explicitly create the volume with Flotilla management and operation labels.
4. Require successful creation. If the name already exists, stop automatic initialization.
5. Inspect the volume and bind its returned metadata to the operation.
6. Ensure no other container references it; acquire Flotilla’s per-volume provisioning lock.
7. Persist that initialization is being attempted.
8. Run the fixed helper and verify its result.
9. Wait for helper teardown, then durably record completion.
10. Permit service creation/start only after all required volumes are ready.

A useful record includes:

| Field | Purpose |
|---|---|
| Host/runtime identity | Prevents confusing identically named volumes on different Macs. |
| Volume name, creation date, operation label | Distinguishes the provisioned instance from ordinary name reuse. |
| Recipe ID and initialization version | Identifies the applied policy. |
| Service manifest digest and platform | Records the tested image variant. |
| UID, GID, scope, optional mode | Records exactly what was requested. |
| Helper digest and operation UUID | Identifies the initializer. |
| State, timestamps, verified result | Supports recovery and auditing. |

Apple’s volume JSON exposes a name-based ID and creation metadata; it should not be treated as an immutable generation identifier. Flotilla’s captured 1.5.0 fixture confirms that shape. [Captured volume inspection](Tests/FlotillaCoreTests/Fixtures/container-1.5.0/inspect-volume.json:1)

An optional helper receipt inside the volume can support recovery, but it should not be the sole authority: application users can potentially alter it, and some applications require clean directory contents. Creation labels should carry provenance; use Flotilla’s host-side store for mutable completion state.

There is an unavoidable crash window between changing filesystem metadata and recording success elsewhere. **A Boolean cannot guarantee literal exactly-once execution across crashes.** To satisfy “never runs twice,” persist the attempted state before launch and do not automatically replay an ambiguous attempt. Reconcile through read-only inspection; unresolved cases require explicit recovery.

If controlled retries are later allowed, the helper must recognize a matching completed operation and return without repeating changes.

Never initialize automatically merely because:

- A volume is empty or currently unused.
- Its root is owned by UID 0.
- Its name starts with `flotilla`.
- The completion record is missing.
- A container failed with `Permission denied`.

Those conditions do not establish ownership of the data. Losing Flotilla’s records must not turn existing volumes into fresh ones.

**Cost and recursive initialization**

Changing the root directory’s owner is approximately constant work regardless of the volume’s advertised capacity. Apple’s images are sparse, so capacity is not the same as allocated data. [Apple’s volume documentation](https://raw.githubusercontent.com/apple/container/1.5.0/docs/volumes.md)

Recursive ownership changes scale with **inode count and metadata I/O**. A directory containing millions of small files can be expensive even when its byte size is modest. Podman explicitly documents this startup cost. No Mac Studio timing was measured here. [Podman’s ownership warning](https://docs.podman.io/en/latest/markdown/podman-run.1.html)

Use recursion only for an explicitly defined tree that Flotilla itself has just populated and whose contents require one owner. Preserve mixed ownership when copying image contents. Existing-volume repair should show scope, require an explicit action, and recommend a backup.

Do not run a second helper while an earlier attempt might still be active. Cancellation must include teardown or reconciliation of the named helper container.

**Security requirements**

The initializer must never become a general root command facility.

For symlinks, `-h`, `-R`, and traversal policy solve different problems:

- `-h` changes the symlink itself rather than its target.
- `-R` requests recursion.
- `-P` prevents traversal through symlinked directories.
- `-H` and `-L` permit forms of symlink traversal and are inappropriate here.

BusyBox documents these distinctions. If recursion is ever needed, a candidate is `chown -h -R -P …`, but its behavior must be tested in the **pinned helper build**. [BusyBox `chown` documentation](https://busybox.net/downloads/BusyBox.html)

The implementation must also:

- Reject a symlink in the target path itself; use a fixed mount point without a trailing slash.
- Never follow links outside the mounted filesystem.
- Never recursively operate on a host bind mount.
- Never mount the service’s other volumes, host folders, runtime sockets, or SSH agent into the helper.
- Never execute scripts or binaries found on the data volume.
- Never use `chmod -R 777` as a substitute for ownership.
- Never change ownership while another container can modify the tree.

For a custom helper, descriptor-based operations such as opening the mount root without following symlinks and calling `fchown` reduce path races. Recursive implementations need additional filesystem-boundary and race protections; `-P` alone is not a complete security boundary.

Use the smallest tested capability set. Root-only ownership initialization may need only `CHOWN`; mode changes, receipts, and traversal can require additional permissions. **The minimum complete capability profile remains unverified.** Do not grant `ALL`.

**Fit with Flotilla’s Allowlist and MountPolicy**

The current `run` rule permits a selected set of flags and trailing container command tokens. It does **not** permit `--user`, `--entrypoint`, `--mount`, `--read-only`, or capability controls. Its existing `.command` trailing policy does not express the helper restriction. [Current run rule](Sources/FlotillaCore/Allowlist.swift:819)

Add a typed operation such as:

```text
initializeFreshRecipeVolume(operationID)
```

The host should resolve that operation to its locally recorded volume and initialization specification, then construct and validate the CLI argv itself.

The helper command profile should require:

- One exact approved image digest and executable.
- One named-volume mount at one fixed destination.
- Root as the fixed helper identity.
- Fixed networking and isolation flags.
- Bounded numeric UID/GID values.
- No arbitrary command, environment, path, extra mount, or entrypoint.
- Provenance tying the volume to the pending provisioning operation.

Validation must occur before execution and must not fall back to the general `run` rule when a helper-profile check fails. Keep the existing `ContainerCLI` validation, timeout, error, and audit path. [Validated execution boundary](Sources/FlotillaCore/ContainerCLI.swift:332)

`MountPolicy` currently permits named volumes and controls access to host paths. That is appropriate but insufficient for ownership initialization: a syntactically valid named volume can still contain valuable existing data. Add the provenance restriction above, and force the initializer to reject host paths even for a local caller using an otherwise unrestricted mount policy. [Current MountPolicy](Sources/FlotillaCore/MountPolicy.swift:1)

The Suggestions library is already treated as untrusted input. Extend it with a bounded initialization enum and numeric fields, not free-form scripts, helper images, or arbitrary argv. Apply the same checks to imported recipes and updates. [Suggestions validation model](Sources/FlotillaCore/SuggestionLibrary.swift:1)

The integration must cover both paths:

- Standalone Suggestions currently prefill the editable Run form; carry the initialization specification through that flow and revalidate after edits. Its unique-name selection is helpful but cannot replace creation-time checks. [Standalone Suggestions flow](Sources/Flotilla/SuggestionsView.swift:204)
- Stack creation already has an explicit volume-creation phase. Initialize each affected volume there, before services can start. For remote hosts, provenance and completion state belong on the host performing the operation. [Stack volume creation](Sources/Flotilla/AppModelSuggestions.swift:164)

**What remains to establish for the failing recipes**

The Mac Studio results and the following UID candidates come from the supplied test report; they were not independently reproduced here.

| Recipe | Reported path / identity | Remaining verification |
|---|---|---|
| Grafana | `/var/lib/grafana`, UID 472 | Exact GID and any required initial content. |
| Prometheus | `/prometheus`, UID 65534 | GID and actual image user representation. |
| Loki | `/loki`, UID 10001 | GID and required rules/data directory layout. |
| Filebrowser | `/database` | Effective UID:GID, parent ownership, database initialization. |
| pgAdmin4 | `/var/lib/pgadmin`, UID 5050 | GID and startup behavior. |
| Jupyter | `/home/jovyan/work`, UID 1000 | GID and identity-changing environment settings. |
| code-server | `/home/coder/project`, UID 1000 | Exact image family, GID, and workspace behavior. |
| Vault | `/vault/file` | Effective writer identity and entrypoint privilege handling. |
| Invoice Ninja | `/var/www/app/storage` | Writer identity, directory contents, and possibly multiple owners. |
| Ghost | `no such table` | Database path, migrations, backend configuration, and earlier errors. |

The direct permission errors strongly fit the fresh-volume mechanism. **Ghost remains a hypothesis:** a missing table is not evidence of an ownership failure by itself. Ownership initialization also cannot restore image files hidden by a mount.

**Validation required before shipping**

Test the pinned helper and each repaired recipe on the supported macOS/runtime combinations:

1. Demonstrate fresh-volume numeric ownership and the original non-root write failure.
2. Initialize ownership, then start the unmodified service and verify persistence after recreation.
3. Confirm ordinary restarts and app relaunches perform no initialization.
4. Confirm existing, imported, populated, and same-name replacement volumes are never automatically changed.
5. Interrupt provisioning before launch, during execution, and after success but before completion recording; verify safe recovery.
6. Reject bind mounts, alternate helper digests, extra argv, symlink targets, unexpected contents, and unauthorized remote requests.
7. Verify helper failure blocks service startup and teardown completes before volume reuse.

Record the runtime versions, image manifests, UID:GID values, helper digest, and observed results with each recipe’s test evidence. **No helper invocation, recipe repair, or performance claim in this document should be marked live-tested until those checks pass.**
