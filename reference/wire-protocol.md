# Flotilla wire protocol + data model spec

Design for `FlotillaCore/Wire.swift` (Phase 2) and the `Models`. Lets the laptop
implement without re-deriving the shape. Field names of the *container* models must
still be confirmed against real `--format json` output (`flotilla-probe`).

## Framing

Each message = `UInt32` big-endian byte length + a JSON-encoded `WireMessage`.
Optionally wrap as an `NWProtocolFramer`; manual length-prefix is fine to start.

## Messages

```
WireRequest
  id: UUID                      // correlates response(s)
  kind: .command | .stream      // one-shot vs streaming (logs/stats)
  args: [String]                // raw container CLI args, e.g. ["ls","--all","--format","json"]

WireResponse
  id: UUID                      // matches request
  chunk: .stdout(String) | .stderr(String)   // streamed chunks
       | .done(exitCode: Int32)              // terminal
       | .error(String)                      // transport/auth/host error
```

- One-shot command: host runs the CLI, returns buffered stdout/stderr then `.done`.
- Stream (logs `-f`, `stats`): host emits `.stdout` chunks until the client cancels
  or the process exits, then `.done`.
- Keep the protocol **dumb**: the client sends CLI args, the host executes them
  locally. All semantics live in `ContainerCLI`, shared by both ends.

## Authorization

Before processing requests the host verifies the peer cert fingerprint is on its
allowlist (handled at the TLS layer, see `networking-mtls-bonjour.md`). Optionally
restrict which `args[0]` subcommands a peer may run (future).

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

## Why CLI-args-over-the-wire (not a typed RPC per command)

Keeps the protocol tiny and resilient to `container` CLI additions — a new
subcommand needs no protocol change. Typed convenience lives in `ContainerCLI`,
which both `LocalHost` and `RemoteHost` flow through identically.
