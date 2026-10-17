#!/usr/bin/env bash
#
# Every row's `⋯` button must offer exactly what a right-click on that row offers.
#
# This is rule 1 in `ContextMenus.swift` — "never a capability you can *only* reach by
# right-clicking" — and it had already been broken twice by the time this check was written.
# The containers row overflow held Details and Copy while a right-click on the same row offered
# ten items, so Logs, Terminal, Inspect, Run Again, Force Kill and Delete were right-click-only;
# and `ContainerCard`'s own `⋯` was a third list again, under a comment claiming it was "the same
# overflow menu as the table row, from the same definition".
#
# The rule the check enforces is structural, not textual: the body of the `Menu` labelled
# `RowOverflowLabel()` must be the *same call* as the body of a `.contextMenu` in the same file.
# Sharing one builder is the only way the two stay in step; comparing two hand-written lists
# would just be a second place to forget.
#
# A component that takes its menu from its owner (`ContainerCard`) passes the check with a bare
# `menuContent()`, and the owner is then held to passing the same builder it right-clicks with.
#
# Negative controls — the failures this was proved against:
#   replace `actions(for: container)` in ContainersView's overflow Menu with
#   `Button("Details…") { openDetail(container.id) }` and this script must fail;
#   and (17 October) replace `menu(for: row)` in VolumesView's `rowContextMenu` with any other
#   builder, and it must fail too — the list's right-click is followed into its delegate.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, pathlib

FAIL = []
CALL = re.compile(r'^[A-Za-z_]\w*\([^()]*\)$')

# Surfaces that borrow the `⋯` glyph for a menu with no row to right-click. One entry, and it
# is named rather than matched by a rule so a new one has to be argued for rather than inherited.
NOT_A_ROW = {"RuntimeStatusBand.swift"}

for path in sorted(pathlib.Path("Sources/Flotilla").glob("*.swift")):
    text = path.read_text()
    if "RowOverflowLabel()" not in text:
        continue
    # Bodies of `.contextMenu { <single expression> }`, in any of its spellings.
    ctx = set(re.findall(r'\.contextMenu\s*\{\s*([^\n{}]+?)\s*\}', text))
    # And the list's own right-click, `.contextMenu(forSelectionType:) { ids in <call> }`, which is
    # how every row section is right-clicked since the two-line rows (Q56). It hands a *selection*
    # to a function that picks the single-row menu for one id; every builder that function calls
    # counts as right-clickable. Until Cards was scrapped this check passed on the cards'
    # `.contextMenu { … }` alone and never looked at the list's.
    for delegate in re.findall(
            r'\.contextMenu\(forSelectionType:[^)]*\)\s*\{\s*\w+\s+in\s*(\w+)\(', text):
        m = re.search(r'func ' + delegate + r'\(.*?\n    \}\n', text, re.S)
        if m:
            ctx |= {c + "(" for c in re.findall(r'\b([A-Za-z_]\w*)\(for:', m.group(0))}
    # Bodies of `Menu { <single expression> } label: { RowOverflowLabel() }`.
    overflow = re.findall(
        r'Menu\s*\{\s*([^\n{}]+?)\s*\}\s*label:\s*\{\s*(?://[^\n]*\n\s*)*RowOverflowLabel\(\)',
        text)
    # And the builder an owner hands to a card that takes one.
    passed = set(re.findall(r'menuContent:\s*\{\s*([^\n{}]+?)\s*\}', text))

    if not ctx and not passed and path.name in NOT_A_ROW:
        continue

    if not overflow:
        FAIL.append(f"{path}: has RowOverflowLabel() but no single-call Menu body to check")
        continue

    # Every `⋯` must be a single shared call. A hand-written body is not extracted above, so a
    # file with one good `⋯` and one hand-written one used to pass on the good one — which is how
    # the Containers negative control below had quietly stopped failing.
    labels = len(re.findall(r'label:\s*\{\s*(?://[^\n]*\n\s*)*RowOverflowLabel\(\)', text))
    if labels > len(overflow) and path.name not in NOT_A_ROW:
        FAIL.append(f"{path}: {labels - len(overflow)} `⋯` menu(s) with a hand-written body — "
                    "share the builder the right-click uses")

    # Delegated: the view takes its menu from whoever places it, and the owner is held to
    # passing the same builder it right-clicks with (the `passed` loop, below, in that file).
    delegated = [b for b in overflow if CALL.match(b) and b.endswith("()")]
    own = [b for b in overflow if b not in delegated]

    if not own:
        continue

    # A file with its own row menu and no context menu anywhere offers that menu one way only,
    # which is the very thing this check exists to stop. One surface is legitimately exempt: the
    # sidebar's runtime band borrows the glyph for a menu that has no row to right-click. Named
    # rather than skipped by rule, so a new one has to be looked at rather than inherited.
    if not ctx:
        if path.name not in NOT_A_ROW:
            FAIL.append(f"{path}: row menu `{own[0]}` with no context menu anywhere — "
                        "a menu reachable only from the `⋯` button")
        continue

    for body in own:
        name = body.split("(")[0]
        if not any(c.split("(")[0] == name for c in ctx):
            FAIL.append(f"{path}: overflow menu is `{body}` but no .contextMenu uses `{name}`")

    for body in passed:
        name = body.split("(")[0]
        if not any(c.split("(")[0] == name for c in ctx):
            FAIL.append(f"{path}: passes `{body}` as a card menu but right-clicks a different builder")

if FAIL:
    print("Row `⋯` menu and right-click menu disagree:")
    for line in FAIL:
        print("  " + line)
    sys.exit(1)
print("✓ every row overflow menu shares its builder with a context menu")
PY
