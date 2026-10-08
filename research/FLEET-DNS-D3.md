# D3 — Fleet DNS: domains on hosts, per-host zones, names across Macs

Design for PLAN.md Phase D, step D3 (7 October 2026). Builds on DECISIONS Q27 (the DNS section),
Q32 (the DNS helper) and Q33 (the admin owns its hosts). Written before the code so the owner can
settle its open questions.

## Measured facts (container 1.5.0, this Mac)

- `container system dns create <domain>` writes `/etc/resolver/containerization.<domain>`:
  `domain <d>`, `search <d>`, `nameserver 127.0.0.1`, `port 2053`. It needs root.
- The runtime's DNS server listens on **127.0.0.1:2053 only** (UDP, `lsof`). No other Mac can ask
  it anything.
- It answers `<container>.<domain>` with the container's own address on this Mac's virtual network
  (192.168.64.0/24 or a custom network). **Those addresses are not reachable from another Mac.**
- Inside a container, `/etc/resolv.conf` names the network gateway (`192.168.65.1`) and the domain;
  it resolves other containers by name and forwards outside names. Not yet measured: whether it
  follows macOS's per-domain resolver files (`/etc/resolver/*`) for a domain it does not own.
- `--localhost <ip>` (help: "Set the ip address to be redirected to localhost") is for containers
  reaching the Mac. It is not a general address record.

So a name for a container on **another** Mac can only lead to that Mac's own address, and only to a
port the container publishes there.

## Part A — DNS on every Mac (management)

The DNS section becomes fleet-wide like every other section: each Mac's domains in one table with a
Host column, and Create / Delete / Use for Containers on a chosen Mac.

- A host runs its own `FlotillaDNSHelper`, approved once by its owner in Login Items (or
  pre-approved by a managed Login Items profile on a Jamf-managed mini). Without it, a host's DNS
  rows are read-only and say why.
- `system dns list` becomes readable by a paired admin (`.remotePeer`). `create`/`delete` stay
  local-only as argv: the admin sends a **typed** request (create a domain / delete domains) on the
  wire, the host re-validates it exactly as its helper does, and hands it to its own helper. The
  peer never sends an argv that runs as root.
- "Use for Containers" on a host edits that host's `config.toml` and restarts its runtime, after the
  same warning as on This Mac (every container there stops).

## Part B — Per-host zones

Each Mac's runtime names its containers in its own zone, `<host>.<fleet domain>` — `web.mini.fleet.internal`
— so two Macs' `web` never share a name. The fleet domain is chosen once on the admin Mac; a host's
label is its zone name (made DNS-safe). Setting it up on a host is Part A's create plus Use for
Containers.

## Part C — Names that resolve on every Mac

`web.mini.fleet.internal` should resolve on the admin Mac and on other hosts too, to the mini's LAN
address, **only while `web` publishes a port there**; otherwise Flotilla reports the missing
mapping rather than return an address that leads nowhere.

Nothing on a Mac can answer that today. The design: **Flotilla answers it itself** — a small DNS
responder inside Flotilla, on loopback only, answering `*.<other host>.<fleet domain>` from what
Flotilla knows about the fleet. Each Mac gets a resolver file for every *other* host's zone pointing
at it, written by the helper. Because hosts only talk to the admin, the admin sends each host the
fleet's name table; a host keeps the last one it was sent.

This widens decision 19 a second time: the helper would also write and remove resolver files that
point at Flotilla's own responder, typed and validated like the rest. It also adds a network
listener to Flotilla (loopback only). Both are the owner's call.

## Open questions for the owner

1. Build order: Parts A and B now, Part C after? Or all three?
2. Part C's mechanism: Flotilla's loopback responder plus helper-written resolver files, or leave
   cross-Mac names out?
3. Confirming a DNS change on a host: on the admin Mac only (the admin owns its hosts, Q33), or also
   on the host?
4. The fleet domain's default: `fleet.internal` (`.internal` is reserved for private use), or the
   owner's choice?

## Part C in detail (8 October, before building)

**The responder.** Flotilla answers DNS itself, on **127.0.0.1 only** (UDP and TCP, port 7869 —
next to the wire's 7868, unused by anything measured). It answers `A` for `<container>.<zone>` where
`<zone>` is **another** Mac's zone, with that Mac's address, only while `<container>` publishes a
port there; `AAAA` gets an empty answer so lookups do not stall; everything else is refused. TTL 30
seconds. A Mac's own zone is never Flotilla's: the runtime answers it, as today.

**The name table.** The admin Mac builds it from what it already polls: each host's zone, the
address the admin reaches it at, and its containers' published ports. Hosts do not know each other,
so the admin sends each host the table with a new host call, `.setFleetNames(table)` (wire version
5); a host keeps the last one it was sent. A container with no published port is in the table
marked unreachable, so Flotilla can say why it has no name rather than return an address that leads
nowhere.

**The two new helper operations — the whole of the widening.**

1. `syncFleetResolvers(fleetDomain, zones)` — makes `/etc/resolver/flotilla.<zone>` exist for
   exactly these zones and no others. Each file is always the same four lines:
   `domain <zone>` / `search <zone>` / `nameserver 127.0.0.1` / `port 7869`. The helper checks, as
   root: every zone is the DNS grammar, not `.local`, and a subdomain of `fleetDomain`; `fleetDomain`
   ends in a suffix reserved for private use; at most 256 zones; no zone has a runtime
   (`containerization.<zone>`) file here. It writes each file atomically, 0644, root-owned, and never
   reads, writes or removes any file whose name does not start `flotilla.`.
2. `removeFleetResolvers()` — removes every `/etc/resolver/flotilla.*` file, and nothing else.

Neither takes a nameserver or a port: they are fixed, so the helper can only ever send a private
fleet zone to Flotilla on this Mac — never a real domain, never to another server.
