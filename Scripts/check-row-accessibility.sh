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
#      on every row alike. Since 19 October the label is a required parameter of
#      `RowOverflowMenu`, so this holds the component to applying it, and holds every row to
#      using the component rather than a bare `Menu` around the glyph.
#
# And the `actions` slot itself must not be hidden from accessibility.
#
# **Since 17 October the actions are drawn on hover** (Kamal: "hover actions, like Mail"): on the
# row they show only while it is hovered or selected, over the trailing end of its text, at zero
# opacity otherwise. A control at zero opacity is not something to trust to VoiceOver, so the rule
# this holds now is stronger than "in the tree": **while VoiceOver is running, the actions are
# drawn**, inline after the text, on every row. Two more things therefore break it:
#
#   4. the actions slot being hidden from accessibility, or `.hidden()`, wherever it is drawn;
#   5. the VoiceOver branch going — `ResourceRow` no longer reading
#      `accessibilityVoiceOverEnabled`, or that branch no longer drawing the actions, or drawing
#      them through the hover's opacity.
#
# Negative controls — each proved to fail:
#   (1) change `.accessibilityElement(children: .contain)` in ResourceRow.swift to `.ignore`;
#   (2) add `.accessibilityActions { }` to the List row in RegistriesView.swift;
#   (3) delete `.accessibilityLabel(label)` from `RowOverflowMenu` in IconActionButton.swift, or
#       draw `RowOverflowGlyph()` in a bare `Menu` in a row section (19 October);
#   (4) add `.accessibilityHidden(true)` after `.allowsHitTesting(showsActions)` in ResourceRow.swift;
#   (5) delete `actionSlot` from the `if voiceOver {` branch in ResourceRow.swift (17 October).
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
# (4) The slot, its definition and every place it is drawn: no modifier that takes it out of the tree.
slot = re.search(r'private var actionSlot: some View \{(.*?)\n    \}', body, re.S)
if not slot:
    FAIL.append(f"{row}: no `actionSlot` — the one place the row's actions are drawn from")
else:
    uses = [body[m.start():m.start() + 300].split("\n\n")[0].split("}")[0]
            for m in re.finditer(r'\bactionSlot\b(?!: some View)', body)]
    for chunk in [slot.group(1)] + uses:
        if re.search(r'\.accessibility(Hidden|Element)\b|\.hidden\(\)', chunk):
            FAIL.append(f"{row}: the row's actions are hidden from accessibility where they are drawn")
            break

# (5) While VoiceOver runs, the actions are drawn — inline, and not through the hover's opacity.
if not re.search(r'@Environment\(\\\.accessibilityVoiceOverEnabled\)', body):
    FAIL.append(f"{row}: the row no longer reads accessibilityVoiceOverEnabled, so its hover-only "
                "actions are drawn at zero opacity for VoiceOver too")
else:
    branch = re.search(r'if voiceOver \{(.*?)\} else \{', body, re.S)
    if not branch or not re.search(r'^\s*actionSlot\s*$', branch.group(1), re.M):
        FAIL.append(f"{row}: the VoiceOver branch no longer draws the actions inline")

for path in sorted(pathlib.Path("Sources/Flotilla").glob("*.swift")):
    text = code(path.read_text())
    if "ResourceRow(" not in text:
        continue
    if re.search(r'\.accessibilityActions?\b', text):
        FAIL.append(f"{path}: a ResourceRow section supplies its own accessibility actions — "
                    "VoiceOver gets the ⋮ menu itself, not a second list that can drift from it")
    # Every `⋮` goes through `RowOverflowMenu`, whose label is required: the glyph alone is "⋮".
    for m in re.finditer(r'RowOverflowGlyph\(\)', text):
        line = text[:m.start()].count("\n") + 1
        FAIL.append(f"{path}: the ⋮ glyph near line {line} is drawn outside RowOverflowMenu, "
                    "which is what gives it a spoken label")

# (3) The component applies the label it requires.
menu = re.search(r'struct RowOverflowMenu<.*?\n\}\n', code(pathlib.Path(
    "Sources/Flotilla/IconActionButton.swift").read_text()), re.S)
if not menu or not re.search(r'\.accessibilityLabel\(label\)', menu.group(0)):
    FAIL.append("Sources/Flotilla/IconActionButton.swift: RowOverflowMenu no longer applies "
                ".accessibilityLabel(label), so every row's ⋮ is read as \"vertical ellipsis\"")

if FAIL:
    print("Row accessibility can drift from the row's menu:")
    for line in FAIL:
        print("  " + line)
    sys.exit(1)
print("✓ ResourceRow keeps its ⋮ menu in the accessibility tree, and no section replaces it")
PY
