# Upstream gaps — what `container` cannot do, and what Flotilla would add if it could

Things Flotilla deliberately does **not** offer because Apple's CLI has no way to express them.
Each entry says how it was established, and what we would build the day it changes. Re-check this
file whenever `container` is updated; every item has a one-line test.

**Pinned to:** `container CLI version 1.0.0 (build: release, commit: ee848e3)`
**Last checked:** 2026-09-11

---

## 1. A machine cannot join a network

`container machine create` has no networking option of any kind.

```sh
container machine create --help | grep -i network      # → no output
```

Compare `container run --network <network>`, which exists. So containers can be attached to a
network and machines cannot, and Flotilla's machine form correctly offers no control for it.

**If this lifts:** add a network picker to `MachineFormView`, mirroring the one now in
`RunSheetView` — the model (`model.networks`), the picker and the help text already exist and
would be copied almost verbatim.

## 2. A machine cannot mount a volume

The only mount option on a machine is `--home-mount ro|rw|none`, which controls whether the
user's home directory is mounted. There is no way to attach a named volume or an arbitrary host
path.

```sh
container machine create --help | grep -iE "volume|mount"   # → only --home-mount
```

**If this lifts:** add a volumes field to `MachineFormView` using the same `mountSpec` shape and
the same "use an existing volume" menu the run form now has.

## 3. Network and volumes are creation-time only

Neither the CLI nor Flotilla can attach a network or a volume to a container that **already
exists** — there is no `container network connect` equivalent, and `run` is the only command that
takes `--network` or `--volume`.

```sh
container network --help      # create, delete, inspect, list — no connect/disconnect
```

This is why the pickers live in the Run form and nowhere else, and why a container's detail
screen offers no way to change either.

**If this lifts:** a "Connect to network" action on the container row and detail screen, and the
same for volumes.

## 4. A machine is not where containers run

Not a gap so much as a correction, recorded here because it shaped items 1–3 and because the
wiki once said the opposite.

Measured on 2026-09-11: with **both machines stopped, including the one marked default**, a
container ran normally and neither machine started. The container took its own address on the
same bridge as the machines — `buildkit` on `192.168.64.6`, machines on `.7` and `.8`, the new
container on `.13`. Sequential neighbours on one network, not one thing nested in another.

```sh
container machine stop <each>
container run --rm docker.io/library/alpine:latest sh -c 'hostname -i'   # still works
container machine list                                                   # still stopped
```

Corroborating: `container run` has no flag for choosing a machine, and a container's own
`inspect` output never names one (see `Tests/FlotillaCoreTests/Fixtures/inspect-container.json`).

So each container gets its own VM, and a machine is a separate persistent VM you create and shell
into. **Machines are therefore not on your container networks either**, which is the real reason
item 1 bites: even if `--network` appeared on `machine create`, a machine joining a container
network would be a genuinely new capability rather than a missing flag.

## 5. What `set-default` affects is undocumented

```sh
container machine set-default --help
# OVERVIEW: Set the default container machine   — and nothing further
```

It certainly does **not** decide where containers run, because nothing does (item 4). Flotilla
exposes the action but does not claim a behaviour for it, and the wiki says so explicitly. If
Apple documents it, say what it does in `Machines.md` and in the row action's help text.

---

## How to re-check this file

After any `container` upgrade, run the greps above and update the pinned version. If an item has
lifted, the "if this lifts" note is the work; delete the entry once it is built.
