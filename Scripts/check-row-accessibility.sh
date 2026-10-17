#!/usr/bin/env bash
#
# VoiceOver must be offered whatever a row's `⋮` / right-click menu offers.
#
# `ResourceRow` used to be one flattened accessibility element (`children: .ignore`) and each
# section handed it a hand-written `.accessibilityActions` list to replace the controls it had
# hidden. Five lists, five drifts: Hosts lost This Mac's runtime controls, Rename, Connect and
# Remove Access; Registries lost Browse, Create a Token, Copy and Tags; Clusters lost Load Image's
# disabled rule. Nothing compared them with the menus, which is this script's job now.
#
# The structural answer is that the row stays a labelled *container* and its `⋮` `Menu` — the same
# builder as the right-click menu, which `check-menu-parity.sh` holds — stays in the accessibility
# tree. So VoiceOver is given the menu itself, with its items in order, its disabled items, its
# submenus and its confirmations, and there is no second list to forget. Three things break that:
#
#   1. `ResourceRow` flattening its children again;
#   2. a section re-adding a replacement action list beside a `ResourceRow`;
#   3. a row's `⋮` menu with no accessibility label — it would be read as "vertical ellipsis",
#      on every row alike.
#
# And the `actions` slot itself must not be hidden from accessibility.
#
# Negative controls — each proved to fail:
#   (1) change `.accessibilityElement(children: .contain)` in ResourceRow.swift to `.ignore`;
#   (2) add `.accessibilityActions { }` to the List row in RegistriesView.swift;
#   (3) delete the `.accessibilityLabel("More actions for …")` under a row's overflow Menu;
#   (4) add `.accessibilityHidden(true)` after `.layoutPriority(3)` on `actions` in ResourceRow.swift.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, pathlib

FAIL = []

def code(text):
    """Source with // comments blanked, so prose that names a modifier is not mistaken for one."""
    return re.sub(r'//[^\n]*', '', text)

row = pathlib.Path("Sources/Flotilla/ResourceRow.swift")
body = code(row.read_text())
if re.search(r'accessibilityElement\(\s*children:\s*\.(ignore|combine)\s*\)', body.split("struct ResourceChip")[0]):
    FAIL.append(f"{row}: the row flattens its children (.ignore/.combine), which hides its ⋮ menu and buttons from VoiceOver")
if not re.search(r'accessibilityElement\(\s*children:\s*\.contain\s*\)', body):
    FAIL.append(f"{row}: the row is no longer declared `.accessibilityElement(children: .contain)`")
if re.search(r'\bactions\s*\.fixedSize\(\)(\s*\.\w+\([^()]*\))*?\s*\.accessibility(Hidden|Element)', body):
    FAIL.append(f"{row}: the `actions` slot is hidden from accessibility")

for path in sorted(pathlib.Path("Sources/Flotilla").glob("*.swift")):
    text = code(path.read_text())
    if "ResourceRow(" not in text:
        continue
    if re.search(r'\.accessibilityActions?\b', text):
        FAIL.append(f"{path}: a ResourceRow section supplies its own accessibility actions — "
                    "VoiceOver gets the ⋮ menu itself, not a second list that can drift from it")
    # Every overflow Menu is labelled before the next declaration: the glyph alone is "⋮".
    for m in re.finditer(r'Menu\s*\{[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*label:\s*\{\s*RowOverflowLabel\(\)\s*\}', text):
        tail = text[m.end():m.end() + 400]
        tail = tail.split("\n\n")[0]
        if '.accessibilityLabel(' not in tail:
            line = text[:m.start()].count("\n") + 1
            FAIL.append(f"{path}: the ⋮ menu near line {line} has no .accessibilityLabel")

if FAIL:
    print("Row accessibility can drift from the row's menu:")
    for line in FAIL:
        print("  " + line)
    sys.exit(1)
print("✓ ResourceRow keeps its ⋮ menu in the accessibility tree, and no section replaces it")
PY
