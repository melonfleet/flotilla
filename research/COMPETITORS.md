# Competitive landscape — published summary

The full analysis is **deliberately not in this repository**. It assessed around 25
third-party projects individually, named their authors, and recorded per-project verdicts on
signing, update mechanisms and maintenance status. Those findings were accurate when written
and were gathered to decide what Flotilla should build — but they were written in internal
voice, about people who read the same communities this project is launched into, and
publishing one project's private assessment of its neighbours is not something the neighbours
signed up for. It is kept out of tree.

What remains here are the market facts the rest of the repository actually cites, stated
without reference to who is doing well or badly. Where a competitor is named below it is for a
publicly documented feature, not a judgement.

## Scale

The niche is crowded, not narrow. There are **at least 25** GUIs targeting Apple's `container`,
of which roughly a dozen are actively maintained; GitHub's
[`apple-container` topic](https://github.com/topics/apple-container) alone returns
87 repositories. Two projects have passed 680 stars, and at least one Docker-first application
has shipped full `apple/container` support.

The category is young enough that names collide: at the time of the survey **two** distinct
products were called *Crane* and **two** were called *Container Desktop*. This is the evidence
behind the naming caution in `DECISIONS.md`.

## The twelve gaps, by how many products already ship them

Ranked by frequency across the verified set, which is the ordering `research/GAP-PLAN.md`
re-sequences:

| # | Capability | Products shipping it |
|---|---|---|
| 1 | Machine / VM management | ~13 |
| 2 | Docker Compose support | ~9 |
| 3 | Image building from a Dockerfile | ~8 |
| 4 | Notarised, signed, auto-updating distribution | ~7 |
| 5 | Registry authentication / private registry login | ~7 |
| 6 | Container filesystem browsing and file copy | ~5 |
| 7 | Multi-container / aggregated log viewing | ~4 |
| 8 | MCP server / AI-agent surface | 3 |
| 9 | Command palette / keyboard-first navigation | 3 |
| 10 | Docker Hub / registry search | 3 |
| 11 | Local AI model integration | 2 |
| 12 | Localisation | 2 |

**Machine management is table stakes**, not a nice-to-have: at least **13 of ~19** verified
products manage `container`'s persistent Linux VMs alongside containers, which is the single
most common capability Flotilla lacked when the survey was done. `research/MACHINES-SPEC.md`
is the response to that finding.

**Notarised, signed distribution is not universal** in this category — roughly 7 of the set.
That is context for `RELEASING.md` treating Developer ID signing and notarisation as a
requirement rather than a nicety, and for sequencing notarisation before any updater.

## The one gap nobody else has closed

**No Apple-`container`-first GUI offers remote or multi-host management at all.** Three tools
reach remote hosts, and all three do it over SSH; none uses a purpose-built transport with its
own authentication and authorisation model. This is the claim `DECISIONS.md` relies on when it
calls Flotilla's Phase 2 transport the thing nobody else has, and it is the reason the wire
design in `reference/wire-protocol.md` is treated as a security boundary rather than a
convenience.

## A pattern worth borrowing

Orchard ([andrew-waters/orchard](https://github.com/andrew-waters/orchard)) ships a host
dashboard alongside its container list. `Sources/Flotilla/DashboardView.swift` and
`research/MACHINES-SPEC.md` both follow that arrangement, and say so at the code.
