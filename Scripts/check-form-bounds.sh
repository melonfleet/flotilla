#!/usr/bin/env bash
#
# Every screen with a `FormHeader` must bound its own height.
#
# ## Why this exists
#
# `New Volume` and `New Network` blanked the entire window. Neither wrapped its fields in a
# `Form` or a `ScrollView`, and both applied `.frame(maxHeight: .infinity)` — which inside a
# parent that is itself unbounded does not mean "fill the window", it means "as tall as you
# like". Measured on a 720pt window, the enclosing `NavigationSplitView` grew to **2020pt** and
# dragged the sidebar, the toolbar and the form itself off the top of the window at y=-90.
#
# The result is not a cosmetic fault. The Back button goes off-screen with everything else, so
# there is no way out of the screen and the only recovery is quitting the app. A tester lost
# three test phases to it before reporting it.
#
# The three create screens that never showed this — MachineFormView, RunSheetView,
# BuildImageView — all wrap their fields in a `Form`. Volumes and Networks were the only two
# with neither container, and were the only two that broke. That is the whole rule.
#
# This is a *shape* check, not a layout test: the app target has no test target, so an invariant
# the compiler cannot see gets enforced here or not at all.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
offenders=()

for file in $(git ls-files 'Sources/Flotilla/*.swift'); do
    [ -f "$file" ] || continue          # tracked but deleted in the working tree
    grep -q "FormHeader(" "$file" || continue
    # FormHeader.swift itself defines the component; it is not a screen.
    case "$file" in */FormHeader.swift) continue ;; esac
    # `ScrollView {` and not bare `ScrollView`: RunSheetView carries a *horizontal* one for its
    # image suggestion chips, and that satisfied the old pattern while bounding no height at all —
    # so this check was passing that file for a reason unrelated to the thing it tests.
    # `FormScaffold` bounds height the same way, and additionally owns the explainer rail.
    # A `List` scrolls and keeps its own height too — the Docker Hub browser's two panes are
    # Lists (10 October), and was flagged though it has never grown the window.
    if grep -qE '^\s*(Form \{|ScrollView \{|FormScaffold \{|List(\(| \{))' "$file"; then continue; fi
    offenders+=("$file")
    fail=1
done

if [ "$fail" -ne 0 ]; then
    echo "✗ a screen with a FormHeader does not bound its own height:"
    for f in "${offenders[@]}"; do echo "    $f"; done
    echo "  Wrap the fields in a FormScaffold (as MachineFormView and RunSheetView do), a Form,"
    echo "  or a vertical ScrollView. Without one, .frame(maxHeight: .infinity) grows the window's"
    echo "  split view past its own bounds and pushes every control — Back included — off-screen."
    exit 1
fi

# ## Every form commits from its header (Q64, Kamal, 19 October)
#
# Forms used to commit from a bottom-right row. The Tasks drawer rises over the bottom of the page,
# so starting a second pull meant minimising the drawer to find Pull. The actions are in the
# `FormHeader` now, drawn by it from a `FormActions` value (Q65) — so a screen with a FormHeader
# declares no default or cancel shortcut of its own (those come only from the cluster, in
# FormHeader.swift) and no footer to put one in. A confirmation dialog's `role: .cancel` carries no
# shortcut and is not matched.
placement=()
for file in $(git ls-files 'Sources/Flotilla/*.swift'); do
    [ -f "$file" ] || continue
    grep -q "FormHeader(" "$file" || continue
    case "$file" in */FormHeader.swift) continue ;; esac
    hits=$(grep -nE 'keyboardShortcut\(\.(defaultAction|cancelAction)\)|var [A-Za-z]*[Ff]ooter\b' "$file")
    [ -n "$hits" ] || continue
    while IFS= read -r line; do placement+=("$file:$line"); done <<< "$hits"
done

if [ "${#placement[@]}" -ne 0 ]; then
    echo "✗ a form's actions are not in its header:"
    for p in "${placement[@]}"; do echo "    $p"; done
    echo "  Give the FormHeader a FormActions (⋯, ✕ and the commit) and drop the bottom row —"
    echo "  it is under the Tasks drawer (Q64, Q65)."
    exit 1
fi

# ## A form header holds one cluster, and only that (Q65, Kamal, 19 October)
#
# Every form's header ended in words that changed from form to form — Cancel, Done, Skip, Save,
# Pull, Push to 3 Hosts, Select All. Now it is ⋯, ✕ and ▶ or ✓, always in that order, drawn by
# `FormHeader` from a `FormActions` value. The compiler already refuses a view in that slot (it is
# not a view builder); this holds the line in three more places the compiler cannot see:
#
#   1. the retired components, `FormPrimaryButton` and `FormCancelButton`, are not used anywhere —
#      not even redefined somewhere else to be put back;
#   2. inside a `FormHeader(…)` call, from its opening line until its brackets close, there is no
#      control of a form's own: no `Button`, `Menu`, `Toggle`, `IconActionButton`,
#      `ToolbarIconButton` or `ActionCluster`. A trailing closure written there with a button in it
#      fails here as well as in the compiler;
#   3. `FormHeader` itself takes no view-builder slot, and `PageHeader` — the same layout with a
#      free right-hand side — is used only by a host's page, which is not a form.
header=()
for file in $(git ls-files 'Sources/Flotilla/*.swift'); do
    [ -f "$file" ] || continue
    # 1. The retired components, outside comments.
    hits=$(grep -nE 'Form(Primary|Cancel)Button\b' "$file" | grep -vE '^[0-9]+:\s*//')
    if [ -n "$hits" ]; then
        while IFS= read -r line; do header+=("$file:$line  (retired component)"); done <<< "$hits"
    fi
    case "$file" in */FormHeader.swift) continue ;; esac
    # 2. Each FormHeader( call, to where its brackets balance at the end of a line.
    if grep -q "FormHeader(" "$file"; then
        hits=$(awk '
            /^[[:space:]]*\/\// { if (!inside) next }
            !inside && /FormHeader\(/ { inside = 1; depth = 0 }
            inside {
                line = $0
                sub(/\/\/.*$/, "", line)
                if (line ~ /(^|[^A-Za-z])(Button|Menu|Toggle|IconActionButton|ToolbarIconButton|ActionCluster|FormPrimaryButton|FormCancelButton)[[:space:]]*[({]/)
                    print FNR ":" $0
                opens = gsub(/[({]/, "&", line); closes = gsub(/[)}]/, "&", line)
                depth += opens - closes
                if (depth <= 0) inside = 0
            }' "$file")
        if [ -n "$hits" ]; then
            while IFS= read -r line; do header+=("$file:$line  (inside a FormHeader)"); done <<< "$hits"
        fi
    fi
    # 3. PageHeader is for a host's page only.
    case "$file" in */HostsView.swift) ;; *)
        hits=$(grep -nE 'PageHeader\(' "$file" | grep -vE '^[0-9]+:\s*//')
        if [ -n "$hits" ]; then
            while IFS= read -r line; do header+=("$file:$line  (PageHeader outside a host's page)"); done <<< "$hits"
        fi ;;
    esac
done
# 3. FormHeader's own declaration, to its first closing brace at column 4 + 1: no slot for views.
slot=$(awk '/^struct FormHeader[: ]/ { inside = 1 } inside && /@ViewBuilder|<Trailing/ { print FNR ":" $0 } inside && /^}/ { inside = 0 }' \
    Sources/Flotilla/FormHeader.swift)
if [ -n "$slot" ]; then
    while IFS= read -r line; do header+=("Sources/Flotilla/FormHeader.swift:$line  (a view slot on FormHeader)"); done <<< "$slot"
fi

if [ "${#header[@]}" -ne 0 ]; then
    echo "✗ a form header holds something other than its FormActions cluster:"
    for h in "${header[@]}"; do echo "    $h"; done
    echo "  A form's actions are a FormActions value — ⋯ extras, ✕, and the commit as .startsJob (▶)"
    echo "  or .keepsChanges (✓) with today's words as its label — passed as FormHeader(actions:)."
    echo "  No button of a form's own goes in its header (Q65)."
    exit 1
fi

echo "  form bounds OK"
echo "  form actions in the header OK"
echo "  form header holds only its cluster OK"
