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
| `PROMPTS.md` | 2026-07-27 | Paste-ready kickoff prompts, one per phase, for driving the build by hand in Claude Code. | The build is no longer driven by pasting prompts. Work is specified in `PHASE1.md` and dispatched from there. |
| `AI-WORKFLOW.md` | 2026-07-27 | How two assistants split the work on this repo — one able to build and run on the Mac, one restricted to a Linux sandbox. | Superseded by a larger set of assistants with mixed model tiers. The durable part of it is the rule that survived: anything that must build, run the real `container` CLI, or touch signing happens on the Mac, and a sandbox that cannot do those may not be trusted to verify them. |
| `setup-mac.sh` | 2026-07-27 | One-shot local workstation setup: SSH alias, credential-manager agent, commit signing. | Already run, and **removed from the repository on 2026-09-05** rather than archived: it configured one maintainer's workstation identity and is of no use to a reader of this project. Bringing up a new machine is covered by the credential manager's own documentation. |

## Not archived here (deliberately)

Some material in the surrounding workspace is **kept out of version control entirely**, not
archived, because it contains deployment specifics, account details, or other identifying
information. It is referenced in place and never committed. If you are looking for a file this
repository mentions but does not contain, that is why.
