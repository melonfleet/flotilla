# Upstream gaps — what `container` cannot do, and what Flotilla would add if it could

Things Flotilla deliberately does **not** offer because Apple's CLI has no way to express them.
Each entry says how it was established, and what we would build the day it changes. Re-check this
file whenever `container` is updated; every item has a one-line test.

**Pinned to:** `container CLI version 1.4.1 (build: release, commit: 9a8917c)`
**Last checked:** 2026-09-12 on 1.4.1 — **all six still hold**, re-run against the live CLI, not
the docs. Two results changed wording rather than substance and are noted under their items:
machines now take an address on the *container* subnet (item 4), and `set-default`'s leaf help
still says nothing about what it affects even though the tagged reference does (item 6).

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

**Re-measured on 1.4.1, 2026-09-12.** Still true, and the evidence is now stronger rather than
weaker: five containers ran for the whole upgrade with **both machines stopped**. What did change
is addressing — under 1.0.0 machines sat on `192.168.64.x` while containers were on `.67`; on
1.4.1 a booted machine took `192.168.67.3`, on the same subnet as the containers. Sharing a
subnet is not hosting: `run` still has no machine selector and a container still never names one.
It does mean the old "sequential neighbours on one bridge" observation is now literally true of
one bridge.

So each container gets its own VM, and a machine is a separate persistent VM you create and shell
into. **Machines are therefore not on your container networks either**, which is the real reason
item 1 bites: even if `--network` appeared on `machine create`, a machine joining a container
network would be a genuinely new capability rather than a missing flag.

## 5. A machine's filesystem cannot be copied to or from

Containers have a Files tab: it lists with `container exec <id> -- ls -la -- <path>` and moves
files with `container copy`. A machine can do the first and not the second.

```sh
container copy --help          # "between a container and the local filesystem"; endpoints are
                               # container:path — no machine form, and there is no `machine cp`
container machine run --help   # takes <executable> and <arguments>, so `ls -la` works
```

So a Files tab for machines would browse and never transfer — a tab that looks exactly like the
container one and silently does half of it. That is why there isn't one, rather than an oversight.

**If this lifts:** `FilesTab` needs making source-agnostic first (it is written against container
plumbing throughout), then a `listMachineDirectory` on `ContainerCLI` using `machine run`, and the
Files tab joins the machine detail after the divider beside Settings.

## 6. What `set-default` affects is undocumented

```sh
container machine set-default --help
# OVERVIEW: Set the default container machine   — and nothing further
```

**Re-checked on 1.4.1:** the leaf help is unchanged — still that one line. Apple's *tagged
reference* does explain it ("Commands that take an optional container machine ID use the default
when you don't provide one"), and that sentence is in the 1.0.0 reference too, so the
documentation always had what the help still withholds. Flotilla can therefore state the
behaviour and cite the reference; it should not claim the CLI explains itself, because it does
not.

It certainly does **not** decide where containers run, because nothing does (item 4). Flotilla
exposes the action but does not claim a behaviour for it, and the wiki says so explicitly. If
Apple documents it, say what it does in `Machines.md` and in the row action's help text.

---

## How to re-check this file

After any `container` upgrade, run the greps above and update the pinned version. If an item has
lifted, the "if this lifts" note is the work; delete the entry once it is built.

Run them against the **installed binary**, not the tagged documentation. The 1.4.1 pass found the
two disagreeing: the reference documents `--scheme auto` as present and the 1.3.0 release notes
say it was removed, and only the live help settles which is true. `Scripts/capture-cli-help.sh`
writes the whole leaf surface to a file named for the version it captured, which is the evidence
a later reader needs.
