# Flotilla wire protocol + data model spec

Design for `FlotillaCore/Wire.swift` (Phase 2) and the `Models`. Lets the laptop
implement without re-deriving the shape. Field names of the *container* models must
still be confirmed against real `--format json` output (`flotilla-probe`).

> **SETTLED BY Q1 — THIS IS NOT RAW COMMAND PASSTHROUGH.**
>
> The wire shape is the middle path: an argument array is passed through, but
> `args[0]` (and second-level command where applicable) must match the
> default-deny `Allowlist`, and every argument must satisfy that command's schema.
> The host validates again before spawning. Arbitrary command strings, unknown
> subcommands/flags, and a generic remote shell are forbidden. Frame length,
> argument size, concurrency, and deadlines are bounded at the transport/runtime
> layer. This decision is final; see `DECISIONS.md` Q1.

## Framing

Each message = `UInt32` big-endian byte length + a JSON-encoded `WireMessage`.
Optionally wrap as an `NWProtocolFramer`; manual length-prefix is fine to start.

The length prefix is not permission to allocate an arbitrary payload. Reject a
frame above the negotiated hard limit before allocating or decoding it. The
Phase 2 handshake also negotiates wire versions/capabilities; unknown message
types fail closed.

## Messages

```
WireRequest
  id: UUID                      // correlates response(s)
  kind: .command | .stream      // one-shot vs streaming (logs/stats)
  args: [String]                // allowlisted CLI args, e.g. ["ls","--all","--format","json"]

WireResponse
  id: UUID                      // matches request
  chunk: .stdout(String) | .stderr(String)   // streamed chunks
       | .done(exitCode: Int32)              // terminal
       | .error(String)                      // transport/auth/host error
```

- One-shot command: host runs the CLI, returns buffered stdout/stderr then `.done`.
- Stream (logs `-f`, `stats`): host emits `.stdout` chunks until the client cancels
  or the process exits, then `.done`.
- The client validates before sending. The host independently runs
  `Allowlist.validate`, applies `MountPolicy`, checks the request deadline and
  concurrency budget, and only then executes locally.
- Keep the protocol **narrow**: CLI semantics live in `ContainerCLI`, shared by
  both ends, while the wire and host runtime enforce the security envelope.
- The argument array is also the audit representation. Log metadata and outcome,
  but redact sensitive values and never treat it as a shell command string.

Phase 2 must reserve/design bidirectional and binary extensions before deployment:

- client → host `.stdin` and `.resize(rows:cols:)` frames for Phase 4 exec and
  password-stdin operations;
- an explicit cancellation frame;
- a binary frame type for future `cp`, `save`/`load`, and export transfers.

Those are protocol extensions, not permission to bypass the command allowlist.
Interactive exec remains a separate Phase 4 capability with fresh visible user
action and tighter lifetime/concurrency limits.

## Authorization

Before processing requests, the host verifies the peer certificate and separately
checks that its fingerprint is authorized (see
`networking-mtls-bonjour.md`). Certificate validity is not authorization.

Command authorization is mandatory, not a future option:

1. reject an unauthorized peer;
2. reject an oversized, expired, or over-budget request;
3. validate the subcommand and arguments with `Allowlist`;
4. apply `MountPolicy` to host paths;
5. spawn only the canonical validated argv, never a shell command.

Host mode also owns a persisted policy/settings store. Typed settings get/set
messages use the shared registry and do not become arbitrary file or preference
access. The run mode itself cannot be changed remotely.

## Data models

The container/image/stats/status models are **already implemented and tested**
against real `container` 1.0.0 output — see `reference/json-schemas.md` for the
captured schemas and `Sources/FlotillaCore/Models.swift` for the Swift. Key facts:
container name = `configuration.id`, image ref = `configuration.name`, state =
`status.state`, CPU is cumulative `cpuUsageUsec` (delta for %).

Flotilla-added (not from the CLI):

```
HostRef: id, displayName, endpoint, fingerprint, mode, online: Bool
```

Each decoded Container/Image is tagged with the `HostRef` it came from so the fleet
view knows which Mac it lives on. That association is Flotilla's, layered on top of
the CLI's JSON.

## Why constrained CLI args over the wire

Keeps the protocol tiny and resilient to `container` CLI additions — a new
**approved** subcommand needs an allowlist/schema update but no new RPC shape.
Typed convenience lives in `ContainerCLI`, which both `LocalHost` and
`RemoteHost` flow through identically. Default-deny validation preserves that
low marginal cost without turning the host into a remote shell.
