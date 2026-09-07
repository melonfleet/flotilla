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
    grep -q "FormHeader(" "$file" || continue
    # FormHeader.swift itself defines the component; it is not a screen.
    case "$file" in */FormHeader.swift) continue ;; esac
    if grep -qE '^\s*(Form \{|ScrollView)' "$file"; then continue; fi
    offenders+=("$file")
    fail=1
done

if [ "$fail" -ne 0 ]; then
    echo "✗ a screen with a FormHeader does not bound its own height:"
    for f in "${offenders[@]}"; do echo "    $f"; done
    echo "  Wrap the fields in a Form (as MachineFormView, RunSheetView and BuildImageView do)"
    echo "  or a ScrollView. Without one, .frame(maxHeight: .infinity) grows the window's split"
    echo "  view past its own bounds and pushes every control — Back included — off-screen."
    exit 1
fi

echo "  form bounds OK"
