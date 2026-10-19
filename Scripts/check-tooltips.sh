#!/usr/bin/env bash
#
# Every icon-only control says what it does on hover, and nothing takes that away.
#
# ## Why this exists
#
# The 19 October tooltip audit read all of `Sources/Flotilla` and found about 213 icon-only
# controls, of which four had no tooltip: two row `⋮` menus, the Tasks drawer's caret and the
# menu-bar item. Nearly everything else was covered because it went through `IconActionButton`,
# whose `help:` is required — the misses were all hand-rolled `Button`s and `Menu`s. It also found
# about fifteen `.help(cond ? text : "")` and `.help(text ?? "")`, which explain a control only
# while it *cannot* be used, and one trap that silently deletes tooltips:
#
#   a `.help` on a segmented `Picker`, or on any view around one, sets every segment's own tooltip
#   to nil — measured with `NSSegmentedControl.toolTip(forSegment:)` on macOS 26.
#
# So this fails on three things:
#
#   1. a `Button` or `Menu` whose label is only a picture — `Image(…)`, `ToolbarMenuGlyph(…)`, a
#      `Label` drawn `.iconOnly` — with no `.help(` in its own modifier chain;
#   2. a `.help(` whose argument contains an empty string literal outside an interpolation —
#      `cond ? text : ""`, `text ?? ""`. Use `.help(ifAny:)` for text that is truly optional, and
#      give a usable control a real tooltip;
#   3. a `.help(` in the modifier chain of a segmented picker — after `.pickerStyle(.segmented)`
#      or after an `IconSegmentedPicker(…)` — or within six lines below it at the indentation the
#      picker starts at or shallower, which is where an enclosing view's `.help` lands. Per-segment
#      `.help` sits on each segment's content, deeper and before the style, and is not matched.
#      Even `.help("")` on an ancestor does it (measured), so rule 2 matters here too.
#
# ## What grep cannot see — read before trusting a green run
#
#   * Rule 1 only knows `Button` and `Menu` literals. A control built some other way (`Toggle` with
#     `.button` style, `onTapGesture` on an image, a `MenuBarExtra` label) is invisible to it, and
#     so is a helper like `FilesTab.tool(_:_:)` *at its call sites* — the helper's own `Button` is
#     checked, so the guarantee holds only if the helper passes its text to `.help`.
#   * A label is "icon-only" by its source: a label that is a custom view (`GretaAvatarView`,
#     `TagDot`) is not recognised, and a `Label` without `.iconOnly` is assumed to draw its words,
#     which is right in a segmented picker and a form but not in a toolbar.
#   * Rule 2 sees literals only. `.help(someString)` where `someString` is `""` at run time passes.
#   * Rule 3 is lexical distance, not the view tree. An ancestor's `.help` more than six lines
#     below the picker, a `.help` on a view several levels up, or `.pickerStyle(.segmented)`
#     applied to a whole container of pickers are all missed.
#   * Strings are blanked by a small scanner, not a Swift parser. Raw strings with `#` delimiters
#     and odd nesting may confuse it; if it ever reports nonsense, that is the first suspect.
#
# A control that genuinely needs no tooltip can say why on the line above it:
#   // check-tooltips: no help — <reason>
#
# Negative controls — each proved to fail (19 October), then restored and passing again:
#   (1) delete `.help(row.isExpanded ? …)` from the caret in TaskDrawer.swift — a missing help;
#   (2) make the Processes Reload in ContainerDetailView.swift `.help(container.isRunning ? "" : …)`
#       — an empty-string help;
#   (3) add `.help("View")` after the `IconSegmentedPicker(…)` in InspectPane.swift, and after
#       `.fixedSize()` inside IconSegmentedPicker.swift itself — a help on a segmented picker.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, pathlib

def mask(text):
    """Comments → spaces; string contents (interpolations included) → spaces, quotes kept.

    A non-empty literal becomes `"   "` and an empty one stays `""`, so rule 2 can tell them apart
    and an empty literal inside `\\( … )` is blanked with the string around it. Newlines are kept so
    line numbers survive."""
    out = []
    i, n = 0, len(text)
    def blank(s):
        return "".join("\n" if c == "\n" else " " for c in s)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(blank(text[i:j])); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(blank(text[i:j])); i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(blank(text[i:j])); i = j
        elif text.startswith('#"', i):
            j = text.find('"#', i + 2)
            j = n if j < 0 else j + 2
            out.append('"' + blank(text[i + 1:j - 1]) + '"'); i = j
        elif c == '"':
            # A single-line literal, skipping escapes and nested interpolations.
            j, depth = i + 1, 0
            while j < n:
                if depth == 0 and text[j] == "\\" and j + 1 < n and text[j + 1] == "(":
                    depth = 1; j += 2; continue
                if depth > 0:
                    if text[j] == '"':      # a literal inside the interpolation
                        k = j + 1
                        while k < n and text[k] != '"' and text[k] != "\n":
                            k += 2 if text[k] == "\\" else 1
                        j = k + 1; continue
                    if text[j] == "(": depth += 1
                    elif text[j] == ")": depth -= 1
                    j += 1; continue
                if text[j] == "\\": j += 2; continue
                if text[j] == '"' or text[j] == "\n": break
                j += 1
            out.append('"' + blank(text[i + 1:j]) + '"'); i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)

def close(m, i, open_, shut):
    """Index just past the bracket matching the one at `i`."""
    depth = 0
    for j in range(i, len(m)):
        if m[j] == open_: depth += 1
        elif m[j] == shut:
            depth -= 1
            if depth == 0: return j + 1
    return len(m)

def chain(m, i):
    """Names of the modifiers applied from index `i`: `.a(…) .b { … }`, across lines."""
    names = []
    while True:
        k = re.match(r'\s*\.(\w+)', m[i:])
        if not k: return names
        names.append(k.group(1)); i += k.end()
        while True:
            s = re.match(r'[ \t]*([({])', m[i:])
            if not s: break
            start = i + s.start(1)
            i = close(m, start, s.group(1), ")" if s.group(1) == "(" else "}")

PICTURE = re.compile(r'\b(Image|ToolbarMenuGlyph|RowOverflowGlyph)\(|\.labelStyle\(\.iconOnly\)')
WORDS = re.compile(r'\bText\(|\bLabel\(')

FAIL = []
for path in sorted(pathlib.Path("Sources/Flotilla").glob("*.swift")):
    text = path.read_text()
    m = mask(text)
    lines = text.split("\n")
    line_of = lambda i: m.count("\n", 0, i) + 1
    def exempt(i):
        ln = line_of(i)
        return ln >= 2 and "check-tooltips: no help" in lines[ln - 2]

    # Rule 1: `Button { … } label: { … }`, `Button(…) { … }`, `Menu { … } label: { … }`.
    for k in re.finditer(r'\b(Button|Menu)\b', m):
        i = k.end()
        a = re.match(r'\s*\(', m[i:])
        if a:
            i = close(m, i + a.end() - 1, "(", ")")
        b = re.match(r'\s*\{', m[i:])
        if not b:
            continue                         # `Button("Title") …`: it draws its words
        first_end = close(m, i + b.end() - 1, "{", "}")
        lbl = re.match(r'\s*label:\s*\{', m[first_end:])
        if lbl:
            body_start = first_end + lbl.end() - 1
            end = close(m, body_start, "{", "}")
            body = m[body_start:end]
        elif k.group(1) == "Button" and a:
            body, end = m[i + b.end() - 1:first_end], first_end   # `Button(action:) { label }`
        else:
            continue
        if not PICTURE.search(body) or (WORDS.search(body) and ".iconOnly" not in body):
            continue
        if "help" in chain(m, end) or exempt(k.start()):
            continue
        FAIL.append(f"{path}:{line_of(k.start())}: an icon-only {k.group(1)} with no .help")

    # Rule 2: an empty literal in a `.help(` argument, outside any interpolation.
    for k in re.finditer(r'\.help\(', m):
        start = k.end() - 1
        arg = m[start:close(m, start, "(", ")")]
        if '""' in arg and not exempt(k.start()):
            FAIL.append(f"{path}:{line_of(k.start())}: .help can be \"\" — "
                        "use .help(ifAny:) or give both states a tooltip")

    # Rule 3: a `.help` on a segmented picker or just around it. The anchor is the line that ends
    # the picker — its `.pickerStyle(.segmented)`, or the closing `)` of an `IconSegmentedPicker(…)`,
    # which spells the style inside itself — and the indentation is where the picker starts.
    masked = m.split("\n")
    anchors = []
    for k in re.finditer(r'\.pickerStyle\(\s*(\.segmented|SegmentedPickerStyle\(\))\s*\)', m):
        ln = line_of(k.start())
        anchors.append((ln, len(lines[ln - 1]) - len(lines[ln - 1].lstrip()), k.end()))
    for k in re.finditer(r'\bIconSegmentedPicker\(', m):
        ln = line_of(k.start())
        end = close(m, k.end() - 1, "(", ")")
        anchors.append((line_of(end), len(lines[ln - 1]) - len(lines[ln - 1].lstrip()), end))
    for ln, indent, end in anchors:
        hit = "help" in chain(m, end)
        for j in range(ln, min(ln + 6, len(lines))):
            row = masked[j]
            if ".help(" in row and len(row) - len(row.lstrip()) <= indent:
                hit = True
        if hit:
            FAIL.append(f"{path}:{ln}: .help on or around a segmented picker "
                        "— it removes every segment's own tooltip")

if FAIL:
    print("Tooltips missing, empty, or taken away:")
    for line in FAIL:
        print("  " + line)
    sys.exit(1)
print("✓ every icon-only Button and Menu has a tooltip; none is \"\"; no segmented picker loses its segments'")
PY
