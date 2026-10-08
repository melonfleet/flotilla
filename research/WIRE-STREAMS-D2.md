# D2 — Bounded wire streams: sending images to hosts and following their logs

Design for PLAN.md Phase D, step D2 (7 October 2026). Written before the code so it can be reviewed
before it is built. Builds on the Phase B wire (Sources/FlotillaCore/Wire, Sources/FlotillaNet) —
read DECISIONS.md Q1, Q14, Q15, Q32, Q33 first.

## What it is for

1. **Sending an image from the admin Mac to a host** — the owner's decision (Phase B, 7 October):
   the admin Mac is the image source. Registry credentials never leave it; it pulls a private image
   with its own sign-in, then sends it: `container image save` on the admin → a bounded binary
   upload → `container image load` on the host. Hosts still pull public images themselves.
2. **Following a host's container logs live** — today `logs --follow` is `wireForbiddenFlags` and
   the Logs section can only fetch a host's logs. A follow is a long-lived child whose output
   streams back.

Both need data that does not fit the one-request-one-result shape: an upload of hundreds of
megabytes in the admin→host direction, and an open-ended stream in the host→admin direction.

## Captured facts (container 1.5.0, this Mac)

- `image save [--arch] [--os] [-o <path>] [--platform os/arch] <references>...` writes an OCI tar to
  `-o`, or to stdout without it. `alpine:3.22 --platform linux/arm64` → 4.1 MB, 0.09 s.
- `image load [-i <path>] [-f]` reads an OCI tar from `-i`, or from stdin without it. `-f` loads
  "even if the archive contains invalid files" — **never used**.
- Help captured in `reference/cli-help/container-image-{save,load}-1.5.0-help.txt`.

## Protocol version 2

`WireProtocol.supportedVersions` becomes `1...2`. Stream frames are valid only on a connection that
negotiated 2; on a version-1 connection they are `WireError.unexpected` as today, and the admin UI
says "update Flotilla on <host> to send images / follow logs". Nothing about version 1 changes.

New frame types (40–49 were reserved for exactly this):

| Type | Name | Direction | Header | Payload |
|-----:|------|-----------|--------|---------|
| 40 | `follow` | admin → host | `{id, arguments}` | — |
| 41 | `streamData` | both | `{id, seq, channel?}` | bytes, ≤ chunk limit |
| 42 | `streamEnd` | both | `{id, exitCode?, reason?, dropped?}` | — |
| 43 | `streamCredit` | both | `{id, bytes}` | — |
| 44 | `upload` | admin → host | `{id, purpose, bytes, sha256, label}` | — |

`id` shares the request id space (`WireClientSession.nextID`), so a stream and a request can never
collide, and `cancel` (11) stops either.

### Flow control: credit

A sender may only send `streamData` bytes it has been granted with `streamCredit`. Exceeding the
outstanding credit is a protocol violation and closes the connection. Credit is per stream.

- **Follow (host → admin).** The admin grants an initial window (1 MiB) and tops it up as the view
  consumes lines. With no credit the host keeps at most 256 KiB per stream; beyond that it **drops
  whole lines and counts them**, and `streamEnd.dropped` (and a periodic count in `streamData` on
  channel `notice`) tells the admin how many. A slow or stalled admin therefore costs the host a
  fixed amount of memory per stream, never more.
- **Upload (admin → host).** The host answers `upload` with an initial window (16 MiB) and grants
  more as it writes to disk. The admin never has more than the window in flight.

### Follow

1. Admin sends `follow {id, arguments}` — the full argv, e.g. `logs --follow -n 200 web`.
2. Host validates with the **same `Allowlist`** as a request, as a `.remotePeer`, plus one change:
   a spec may list flags as `wireStreamFlags` (only `logs`: `follow`). Those flags stay forbidden in
   a plain `request` and are **required** in a `follow`. Every other command is refused as a
   follow. `-n` stays required and capped (`.count`), so a follow cannot ask for unbounded backlog.
3. Host starts the child with `ContainerHost.stream` (as This Mac's live logs do), sends lines as
   `streamData` (channel `stdout`/`stderr`), batching on a short tick.
4. Ends with `streamEnd` when the child exits, on `cancel` (the host **terminates the child** —
   `CommandStream.cancel`, unlike a plain request which cannot be stopped mid-run, Q15), on
   connection close, or on a host-wide limit.

Limits: 8 follows per connection; 16 host-wide, counted separately from `maxRunningCommands` so a
row of live log views cannot starve real commands; a follow has no deadline but ends when the
connection does.

### Upload (image load)

1. Admin: `image save --platform linux/arm64 -o <file in the app's own temporary directory> <ref>`,
   run locally under a `MountPolicy.roots([that directory])` built for this one command — the same
   per-invocation, narrow-and-explicit pattern `buildImage` uses (CLAUDE.md "The file panel is the
   authorisation"). Then size and SHA-256 of the file.
2. Admin sends `upload {id, purpose: "image-load", bytes, sha256, label: <reference, for display>}`.
3. Host checks, before accepting a byte: `purpose` is known; `bytes` ≤ its upload ceiling (default
   8 GiB) **and** ≤ free space on the volume minus a reserve (2 GiB); at most 1 upload per connection
   and 2 host-wide. Then creates a private directory (0700) under its own temporary directory and an
   exclusive file in it (`O_CREAT|O_EXCL`, 0600, random name — no symlink can be pre-planted), and
   answers `streamCredit {id, 16 MiB}`. A refusal is a `failure` (13) with `refused`/`busy`.
4. Admin sends `streamData` chunks (≤ 1 MiB each, `seq` from 0, no gaps), never beyond credit. Host
   appends, hashes as it writes, tops up credit. More bytes than declared is a protocol violation.
   No chunk for 60 s aborts the upload.
5. Admin sends `streamEnd {id}`. Host checks byte count and SHA-256; on a match it runs
   `image load -i <that file>` — a command **the host builds itself**, never from the peer: the
   peer cannot name a path. It is validated by the `Allowlist` (`image load` is a new spec, exposure
   `.localOnly`, so a peer can never send it as a request) under a `MountPolicy.roots([that private
   directory])`, deadline 1800 s, and its output returns as an ordinary `result` (12) for `id`.
6. The file and directory are deleted on every path out — success, mismatch, cancel, timeout,
   connection close, app quit (and swept at start-up).

`image save` is also a new spec, `.localOnly`: only This Mac saves, for itself.

## Admin-side API

- `RemoteHost.stream(_:onLine:onEnd:) -> CommandStream` implemented through `follow`, so
  `ContainerCLI`'s existing live-log path works against a host unchanged; LogsView's Live and the
  container detail's Live then cover hosts that speak version 2.
- `AdminConnection.upload(file:, purpose:, label:, progress:) async throws -> CommandResult`.
- App: **Send to Hosts…** on This Mac's image rows, with the same host table as Push, per-host
  progress, and a note that a host pulls a public image faster itself.

## Questions for review

1. Is credit-based flow control as specified sufficient to bound memory on both sides, including a
   peer that never grants credit, grants absurd credit, or sends `streamCredit` for unknown ids?
2. Upload file handling: symlink/race attacks on the temp path, disk exhaustion (declared size vs
   actual, sparse files, many concurrent uploads), cleanup on every path, start-up sweep.
3. Is SHA-256 over the received bytes worth having under TLS 1.3 (integrity is already there)? It
   catches truncation and bugs; is there anything it should be bound to (the `upload` header)?
4. `image load` of an archive the admin chose: the admin is the host's owner (Q33). What should the
   host still refuse — `--force` is never passed; anything about archive size, layer count, or
   references that would overwrite an image the host owner pulled themselves?
5. Follow validation: can any argv other than `logs --follow …` be followed? Can `-n` be abused?
6. Version negotiation: any downgrade path given TLS is pinned both ways?
7. Resource exhaustion: many follows, slow readers, many tiny `streamData` frames, credit grants of
   1 byte, seq wrap-around.
8. Anything missing that a stream protocol over this transport usually needs.

## After review (Iris, 7 October — experiments/wire-streams-review-2026-10-07/iris-report.md)

No critical finding; five high and six medium. Every one is taken, as follows.

**High**

1. *Admin-side memory.* Credit returns as output is handed on, and every queue after that is
   bounded: the live-log `AsyncStream` and the viewer's inbox keep the newest lines and count what
   they drop. A host can then cost the admin a fixed amount however fast it writes.
2. *Frame amplification.* Empty `streamData` is a violation; every data frame is charged at least
   256 bytes of credit; a grant of 0 is a violation; arithmetic is checked; `seq` is `UInt64`; an
   upload piece must be at least 64 KiB unless it is the last; the host batches follow output on a
   100 ms tick rather than sending a frame per line.
3. *Disk.* One host-wide reservation ledger: an upload reserves twice its size (the archive plus
   the image store's copy) plus 2 GiB, against free space minus every other reservation, checked
   at admission and again before each credit grant, released only after the loader exits and the
   folder is gone. Twice is an estimate until measured on a large image; ENOSPC is reported plainly.
4. *Crafted archives.* A host refuses an upload unless its own `container` is at least **1.3.1** —
   the floor above both published advisories (path traversal ≤ 0.7.1, symlinked-blob read ≤ 1.3.0).
   The admin checks too, from the host's reported version, before saving anything.
5. *Lifecycle.* A cancel after the last byte does not claim to stop the loader (it cannot): the host
   lets it finish and the result arrives; the admin simply stops waiting. Stream ends carry a reason;
   the host's notices are marked as Flotilla's, not the container's.

**Medium**

6. *Files.* The root and each upload folder are created and opened without following links and
   checked to be directories owned by this user; the sweep removes only such folders.
7. *Chunk size* is the smaller of the stream limit and the negotiated frame limit less its header.
8. *Platform and identity.* The admin saves the `linux/arm64` variant when the image has one,
   otherwise `linux/amd64`, and refuses an image with neither. `label` is display only; the result
   shown is the references `image load` reports.
9. *Liveness.* An upload must keep moving: no piece for 60 s, or longer than 30 minutes plus a
   minute per 512 MiB, ends it.
10. *Scheduling.* Follows are capped at 8 host-wide (was 16), so commands keep their 8 and the host
    runs at most 16 children for admins.
11. *Recovery.* Not resumable in version 2, stated in the UI: a dropped transfer starts again.
12. *Version selection.* `welcome` echoes the host's range, and the admin checks the chosen version
    is the highest both speak (a host that sends no range — an older build — is taken at its word).
