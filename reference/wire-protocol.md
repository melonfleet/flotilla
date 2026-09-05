# Wire protocol — not published

The design for Flotilla's remote transport is **deliberately not in this repository**.

Multi-host management is planned for a later release. The framing, message types, authorisation
model and data flow are worked out, and they are kept private for now — a small project's
design work is one of the few advantages it has, and publishing an implementable spec before
the implementation exists gives it away for nothing.

Other documents in this repository refer to this file. Those references are about how the
boundary constrains Phase 1 decisions — why `WirePolicy` and `CommandSpec.exposure` exist in the
core today, why the allowlist has to be at least as strict as the CLI, and why an interactive
shell grammar is a scoped capability rather than a default. That reasoning stands on its own and
is in `DECISIONS.md` and the [Security model](https://github.com/melonfleet/flotilla/wiki/Security-Model)
wiki page.

What is true of the shipping app, and is what actually matters to anyone using it: **nothing
listens.** No port is opened, no connection is accepted, and the related settings are visibly
disabled with the reason stated.
