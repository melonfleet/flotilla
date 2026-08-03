#!/bin/bash
# Refuse to package a build that still carries a screenshot scaffold.
#
# Twice now a temporary `@State` default — `showingCreate = true`, then
# `initialValue: .inspect` — has been reverted in source, rebuilt, and still reached the owner,
# because the *running* app was never replaced. Both times it read as a product bug and cost a
# round trip. A note in CLAUDE.md did not prevent the second one, so this is a mechanism instead.
#
# It asserts the known-good default is *present*, rather than blacklisting the scaffolds anyone
# might write — a blacklist only catches the mistakes already made.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
require() {   # require <file> <exact line, trimmed>
    if ! grep -qF -- "$2" "$1"; then
        echo "  ✗ $1"
        echo "      expected: $2"
        fail=1
    fi
}

require Sources/Flotilla/MainWindowView.swift    '@State private var selection: Section? = .dashboard'
require Sources/Flotilla/MachinesView.swift      '@State private var showingCreate = false'
require Sources/Flotilla/MachinesUIState.swift   'var presentation: MachinesView.Presentation = .list'
require Sources/Flotilla/ContainersUIState.swift 'var presentation: ContainersView.Presentation = .list'
require Sources/Flotilla/MachineDetailView.swift '_tab = State(initialValue: model.lastMachineTab[machine.id] ?? .overview)'
require Sources/Flotilla/MachineDetailView.swift '@State private var presentation: InspectPresentation = .json'
require Sources/Flotilla/ContainerDetailView.swift '_tab = State(initialValue: model.lastDetailTab[container.id] ?? .overview)'
require Sources/Flotilla/ContainerDetailView.swift '@State private var presentation: InspectPresentation = .json'

# A detail target that opens pre-populated is always a scaffold: both screens navigate to it.
for f in Sources/Flotilla/MachinesView.swift Sources/Flotilla/ContainersView.swift; do
    if grep -nE 'var detailTarget: DetailTarget\? *=' "$f" >/dev/null; then
        echo "  ✗ $f: detailTarget has an initial value — that is a scaffold"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "Refusing to package: a screenshot scaffold is still in the source."
    exit 1
fi
echo "  defaults OK"
