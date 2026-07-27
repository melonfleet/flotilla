# Flotilla — proposal review: decisions

_2026-07-27 14:14 · **9 of 9** decided._

### Q1 — Wire shape: CLI-args passthrough, or typed bounded operations?
**Decision:** Middle path: args + subcommand allowlist

### Q2 — Table or the card grid as the default view?
**Decision:** Table default with a card toggle

### Q3 — Does host mode become stateful?
**Decision:** Yes — host mode gets a persisted policy store

### Q4 — Confirm the two-tier defaults/locked managed model now?
**Decision:** Confirm two-tier now (defaults + locked)

### Q5 — Is §3's Phase 1 the Phase 1 you want?
**Decision:** Approve §3 as-is

### Q6 — Notifications in Phase 1 or Phase 3?
**Decision:** Phase 1 — full per-category toggles (SET)

### Q7 — Should Flotilla ever write config.toml?
**Decision:** SET's ladder: read P1, edit locally P3, remote only if needed

### Q8 — Bundle ID / preference domain
**Decision:** dev.melonfleet.Flotilla (decided 2026-07-27) _(locked)_

### Q9 — Record "no App Sandbox for v1" as a decision?
**Decision:** Yes — record 'no App Sandbox for v1' in DECISIONS.md
