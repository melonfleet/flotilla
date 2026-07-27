# Archive

Superseded material, kept deliberately for reference. **Nothing here is current** — do not
follow it, build from it, or treat it as a source of truth. It is retained because it
records how a decision was originally framed, which is often useful later even when the
answer has changed.

Current sources of truth: **`DECISIONS.md`** (settled decisions), **`PHASE1.md`** (build
contract), **`research/FEATURES.md`** (feature list), **`README.md`** / **`CLAUDE.md`**
(status and orientation).

> Convention: every melonfleet repo uses a top-level `archive/` with a README in this shape —
> each entry says what it was, when it was archived, why, and what replaced it. If a file
> could plausibly be mistaken for current guidance, it belongs here rather than deleted.

| File | Archived | What it was | Why archived → what replaced it |
|---|---|---|---|
| `dashboard-mockup.html` | 2026-07-27 | The owner's original dashboard concept — a card/tile grid of containers. | Kept **as a reference**, at the owner's request. Superseded twice: **Q2** in `DECISIONS.md` made a **table** the default view (cards stop scaling past ~20 rows, demoted to a toggle), and the full UI is now drawn in `research/review/mockups/`. Still worth reading for the original visual intent. |
| `PROMPTS.md` | 2026-07-27 | Paste-ready kickoff prompts, one per phase, for driving the build by hand in Claude Code. | The build is no longer driven by pasting prompts. Work is now specified in `PHASE1.md` and dispatched to the agent fleet via `.fleet/dispatch.sh`. |
| `AI-WORKFLOW.md` | 2026-07-27 | How **two** assistants (Claude Code + ChatGPT Codex) split the work on this repo. | Superseded by the five-agent fleet with mixed model tiers — see `FLEET.md` at the workspace root, and the ownership table in `PHASE1.md`. |
| `setup-mac.sh` | 2026-07-27 | One-shot local Mac setup: SSH alias, 1Password agent vault, commit signing. | Already run; the laptop is configured. `docs/LAPTOP-SETUP.md` remains the guide for bringing up a **new** Mac, and it covers the same ground in a form you can follow selectively. |

## Not archived here (deliberately)

- **`_inkwarden_legacy/`** at the workspace root — the pre-scrub FastAPI source InkWarden was
  re-platformed from. It stays **outside version control entirely** because it contains
  deployment specifics and other identifying detail. Reference it in place; never commit it.
- **`FLEET.md`** — current, and also intentionally uncommitted (personal accounts).
