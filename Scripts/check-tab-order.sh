#!/usr/bin/env bash
#
# Every page's tabs are in one order (Kamal, 18 October): Overview · own views · Settings · Logs ·
# Inspect | Terminal · Files · Screen Sharing — `PageTabKind` in Sources/FlotillaCore/PageTabOrder.swift,
# where the reasoning is.
#
# `PageTabs` draws whatever it is given in that order, so the pill cannot be wrong. This holds the
# *sources* to it too, so a tab enum's `allCases`, a page's hand-written tab list and the pill never
# disagree — the container's remote tabs were once [.overview, .logs, .inspect, .processes], drawn
# one way and listed another. It fails when:
#
#   - a tab enum with `var kind: PageTabKind` declares its cases out of canonical order;
#   - an array literal of one tab enum's cases (`HostDetailTab.pages`, `tabs(for:)`) is out of order;
#   - a `PageTabs(items:` call gives its items no `kind:` (HostSettingsTab's sources excepted: a
#     pill inside a tab, choosing between two documents).
#
# It has a negative control: swap two cases in any of those enums and it fails.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 -I - <<'PY'
import pathlib, re, sys

core = pathlib.Path('Sources/FlotillaCore/PageTabOrder.swift').read_text()
body = core[core.index('enum PageTabKind'):]
body = body[:body.index('public enum Group')]
rank = {name: i for i, name in enumerate(re.findall(r'^\s*case\s+(\w+)\s*$', body, re.M))}
if len(rank) < 6:
    print(f"✗ check-tab-order read only {len(rank)} PageTabKind cases — the parse is broken"); sys.exit(1)

failures, enums_checked = [], 0
for path in sorted(pathlib.Path('Sources/Flotilla').glob('*.swift')):
    text = path.read_text()
    for m in re.finditer(r'\benum\s+(\w+)\s*:\s*String\s*,\s*CaseIterable[^{]*\{', text):
        name, start = m.group(1), m.end()
        depth, end = 1, start
        while depth and end < len(text):
            depth += {'{': 1, '}': -1}.get(text[end], 0); end += 1
        enum = text[start:end]
        if 'var kind: PageTabKind' not in enum:
            continue
        enums_checked += 1
        cases = re.findall(r'^\s*case\s+(\w+)\s*=', enum, re.M)
        kind_src = enum[enum.index('var kind: PageTabKind'):]
        mapping = {}
        ternary = re.match(r'var kind: PageTabKind\s*\{\s*self\s*==\s*\.(\w+)\s*\?\s*\.(\w+)\s*:\s*\.(\w+)', kind_src)
        if ternary:
            for c in cases:
                mapping[c] = ternary.group(2) if c == ternary.group(1) else ternary.group(3)
        else:
            switch = kind_src[:kind_src.index('\n    }')]
            for arm in re.finditer(r'case\s+([.\w,\s]+?):\s*\.(\w+)', switch):
                for c in re.findall(r'\.(\w+)', arm.group(1)):
                    mapping[c] = arm.group(2)
        missing = [c for c in cases if c not in mapping or mapping[c] not in rank]
        if missing:
            failures.append(f"{path}: {name} has no PageTabKind for {', '.join(missing)}"); continue

        def check(sequence, where):
            kinds = [rank[mapping[c]] for c in sequence]
            if kinds != sorted(kinds):
                failures.append(f"{where}: {name} order {' · '.join(sequence)} is not "
                                f"{' · '.join(sorted(sequence, key=lambda c: rank[mapping[c]]))}")
        check(cases, f"{path}")

        # Hand-written lists of this enum's cases, anywhere in the app.
        for other in pathlib.Path('Sources/Flotilla').glob('*.swift'):
            for lit in re.finditer(r'\[((?:\s*(?:' + name + r')?\.\w+\s*,)+\s*(?:' + name + r')?\.\w+\s*)\]', other.read_text()):
                items = re.findall(r'\.(\w+)', lit.group(1))
                if len(items) >= 2 and all(i in mapping for i in items) and (name in lit.group(1) or other == path):
                    line = other.read_text()[:lit.start()].count('\n') + 1
                    check(items, f"{other}:{line}")

    if path.name != 'HostSettingsTab.swift':
        for call in re.finditer(r'PageTabs\(items:', text):
            window = text[call.end():call.end() + 400]
            window = window[:window.find('selection:')] if 'selection:' in window else window
            # Discovery's resource-kind tabs have their own tested order (Q66), not detail-page order.
            discovery = path.name == 'SuggestionsView.swift' and 'SuggestionTab.allCases' in window
            if 'kind:' not in window and 'tabItems' not in window and not discovery:
                line = text[:call.start()].count('\n') + 1
                failures.append(f"{path}:{line}: PageTabs items carry no kind:, so the pill can't put them in order")

if enums_checked < 6:
    print(f"✗ check-tab-order found only {enums_checked} page tab enums — the parse is broken"); sys.exit(1)
if failures:
    print("✗ Page tabs out of the canonical order (PageTabKind):")
    for f in failures: print("  " + f)
    sys.exit(1)
print(f"✓ {enums_checked} page tab enums and their lists are in the canonical order")
PY
