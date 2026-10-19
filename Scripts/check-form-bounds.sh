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
# so starting a second pull meant minimising the drawer to find Pull. The commit is now a
# `FormPrimaryButton` and the Cancel a `FormCancelButton`, both in the `FormHeader`'s trailing slot —
# so a screen with a FormHeader declares no default or cancel shortcut of its own (those come only
# from the two components) and no footer to put one in. A confirmation dialog's `role: .cancel`
# carries no shortcut and is not matched.
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
    echo "  Put Cancel (FormCancelButton) and the commit (FormPrimaryButton) in the FormHeader's"
    echo "  trailing slot, and drop the bottom row — it is under the Tasks drawer (Q64)."
    exit 1
fi

echo "  form bounds OK"
echo "  form actions in the header OK"
