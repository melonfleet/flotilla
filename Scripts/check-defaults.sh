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

# Deliberate escape hatch for the screenshot loop, because the alternative is worse: without
# one, verifying a form means hand-assembling a bundle around the guard, which is how the
# scaffold shipped in the first place. It is loud, it is per-invocation, and it never persists.
if [ "${ALLOW_SCAFFOLD:-0}" = "1" ]; then
    echo "  ⚠️  ALLOW_SCAFFOLD=1 — packaging a build that may contain a screenshot scaffold."
    echo "     Do NOT leave this build installed. Revert, rebuild WITHOUT the flag, relaunch."
    exit 0
fi

fail=0
require() {   # require <file> <exact line, trimmed>
    if ! grep -qF -- "$2" "$1"; then
        echo "  ✗ $1"
        echo "      expected: $2"
        fail=1
    fi
}

require Sources/Flotilla/MainWindowView.swift    '@State private var selection: Section? = .overview'
# The window opens with its labels showing. A `railed = true` default is the icons-only
# screenshot scaffold, and it looks exactly like a broken sidebar.
require Sources/Flotilla/MainWindowView.swift    '@AppStorage("sidebarRailed") private var railed = true'
require Sources/Flotilla/MachinesView.swift      '@State private var showingCreate = false'
# One view per section since Q56 (17 October): the rows, drawn unconditionally. This used to pin
# `presentation = .list` on Containers and Machines; with Cards scrapped there is no toggle to
# default, so the known-good state is the list branch itself.
#
# A bare `rowsList` line is not enough: it passed with Machines' `rowsList` wrapped in
# `if Bool.random()` (Kyle, 17 October), because the line was still there, just one level deeper.
# So this pins what the line is *nested under* — every `if`, `else`, `switch` and `case` between
# it and `content`, read by indentation — and each section's chain is the known-good one: the
# loaded state, or the non-empty side of the empty check. A condition added around it, a view
# switch (`if … { rowsList } else { cards }`, either way round), or `rowsList` moved somewhere else
# changes the chain and fails here.
chain() {   # chain <file> [line]: what the bare `rowsList` (or [line]) is nested under, outermost first
    LINE="${2:-rowsList}" perl -e '
        my @l = <>; chomp @l;
        my $want = $ENV{LINE};
        my ($at) = grep { $l[$_] =~ /^\s*\Q$want\E\s*$/ } 0..$#l;
        exit 2 unless defined $at;
        sub ind { $_[0] =~ /^(\s*)/; length $1 }
        # Blank lines, comments and modifier or argument continuations are not branches.
        sub skip { $_[0] =~ /^\s*$/ || $_[0] =~ /^\s*\/\// || $_[0] =~ /^\s*[.)\]]/ }
        sub trim { (my $s = $_[0]) =~ s/^\s+|\s+$//g; $s }
        my @chain; my $cur = ind($l[$at]); my $i = $at;
        while (--$i >= 0) {
            next if skip($l[$i]);
            my $n = ind($l[$i]); next unless $n < $cur;
            my $s = trim($l[$i]);
            unshift @chain, $s;
            last if $s =~ /\b(var|func)\b/;
            # A labelled trailing closure (`} detail: {`): name the call it belongs to — the nearest
            # line above at the same depth that does not itself close something.
            if ($s =~ /^\}\s*\w+:\s*\{$/) {
                for (my $j = $i - 1; $j >= 0; $j--) {
                    next if skip($l[$j]) || ind($l[$j]) != $n;
                    next if trim($l[$j]) =~ /^\}/;
                    unshift @chain, trim($l[$j]); $i = $j; last;
                }
            }
            # A later branch (`} else {`, `case`, `default:`): name the `if` or `switch` it belongs to.
            elsif ($s =~ /^(\}|case |default:)/) {
                for (my $j = $i - 1; $j >= 0; $j--) {
                    next if skip($l[$j]) || ind($l[$j]) != $n;
                    if (trim($l[$j]) =~ /^(if |switch )/) { unshift @chain, trim($l[$j]); $i = $j; last }
                }
            }
            $cur = $n;
        }
        print join(" > ", @chain), "\n";
    ' "$1"
}
expect_rows() {   # expect_rows <section> <chain>
    local f="Sources/Flotilla/$1View.swift" got
    got=$(chain "$f")
    if [ $? -eq 2 ]; then
        echo "  ✗ $f"
        echo "      expected: the list drawn unconditionally — a line that is just \`rowsList\`"
        fail=1
    elif [ "$got" != "$2" ]; then
        echo "  ✗ $f: \`rowsList\` is not where the one view belongs"
        echo "      expected: $2"
        echo "      found:    $got"
        fail=1
    fi
}
expect_rows Containers 'private var content: some View { > switch model.state { > case .loaded:'
expect_rows Machines   'private var content: some View { > switch model.machinesState { > default:'
expect_rows Images     'private var content: some View { > switch model.imagesState { > case .loaded:'
expect_rows Volumes    'private var content: some View { > switch model.volumesState { > case .loaded:'
expect_rows Networks   'private var content: some View { > switch model.networksState { > case .loaded:'
expect_rows Hosts      'private var content: some View { > if displayedRows.isEmpty { > } else {'
expect_rows Registries 'private var content: some View { > if displayedRows.isEmpty { > } else { > VStack(spacing: 0) {'
expect_rows DNS        'private var content: some View { > if case .unavailable(let reason) = model.dnsState { > } else { > VStack(spacing: 0) {'
expect_rows Clusters   'private var content: some View { > switch model.clustersState { > case .loaded:'
# Hosts' category headings use Containers' disclosure gutter and icon badge, rather than a
# List Section header or a separate dot. Members keep ResourceRow's indent (checkbox outside).
for s in Containers Hosts; do
    require "Sources/Flotilla/${s}View.swift" 'RowGroupMark {'
    require "Sources/Flotilla/${s}View.swift" 'RowGroupDisclosure('
done
require Sources/Flotilla/HostsView.swift 'RowTypeMark(systemImage: groupSymbol, kind: groupNoun) {'
require Sources/Flotilla/HostsView.swift 'indent: grouping == .none ? 0 : 28,'
require Sources/Flotilla/HostsView.swift 'if row.header != nil { headerRow(row) } else { hostRow(row) }'
# Q58 (17 October): every row section is a split — the list on the left, the selected row's page on
# the right. Pinned the same way as the rows: what the bare `content` line (the list's pane) and the
# bare `page` line (the page) are nested under. The known-good shape is the split as the **last
# branch** of the section's form chain, so a form still takes the whole width; the list's pane is the
# split's first closure and the page its `detail:`. A split wrapped in a condition, the page drawn
# instead of the list, or the list back on its own changes a chain and fails here.
expect_split() {   # expect_split <section> <key> <the chain down to the split, without it>
    local f="Sources/Flotilla/$1View.swift" got split
    split=$(grep -m1 -oE "SplitPanes\(list: \"$2\", pane: ui\.pane, showing: [A-Za-z]+(\?\.id)?\) \{" "$f")
    if [ -z "$split" ]; then
        echo "  ✗ $f: no \`SplitPanes(list: \"$2\", pane: ui.pane, …)\` — the section is not a split"
        fail=1; return
    fi
    for part in "content|VStack(spacing: 0) {" "page|} detail: {"; do
        local line="${part%%|*}" inner="${part#*|}" want
        want="$3 > $split > $inner"
        got=$(chain "$f" "$line")
        if [ "$got" != "$want" ]; then
            echo "  ✗ $f: \`$line\` is not where the split puts it"
            echo "      expected: $want"
            echo "      found:    $got"
            fail=1
        fi
    done
}
expect_split Containers containers 'var body: some View { > Group { > if showingRun { > } else {'
expect_split Machines   machines   'var body: some View { > Group { > if showingCreate { > } else {'
expect_split Images     images     'var body: some View { > Group { > if let target = runImage { > } else {'
expect_split Volumes    volumes    'var body: some View { > Group { > if let volume = pushing { > } else {'
expect_split Networks   networks   'var body: some View { > Group { > if let network = pushing { > } else {'
expect_split Hosts      hosts      'var body: some View { > Group { > if showingAdd || pairing != nil { > } else {'
expect_split Registries registries 'var body: some View { > Group { > if let form { > } else {'
expect_split DNS        dns        'private var screens: some View { > Group { > if let form { > } else {'
expect_split Clusters   clusters   'var body: some View { > Group { > if showingCreate { > } else {'
# The page follows the selection, and both start empty: a section that opens on a selected row is
# a section that opens on a page, which is the split's screenshot scaffold (the old `detailTarget`
# pinned below was the slide-in's). The selection reaches the page only through the form guard.
# And one row stays selected while it exists at all, filtered out or not: a filter hides rows in the
# list, never the page that's open, and a form page lost its draft to a search (Kyle, 17 October).
for s in Containers Machines Images Volumes Networks Hosts Registries DNS Clusters; do
    f="Sources/Flotilla/${s}View.swift"
    for v in selection shown; do
        if ! grep -qE "^    @State private var $v = Set<[A-Za-z.]+>\(\)$" "$f"; then
            echo "  ✗ $f: \`$v\` does not start as an empty set"
            fail=1
        fi
    done
    require "$f" '.paneFollows($selection, into: $shown, guard: model.formGuard, existing: existingIDs)'
    require "$f" 'showing: existingIDs)'
done
# A row's actions are drawn on hover and on selection only (17 October), so a row that starts
# hovered is a screenshot scaffold: every row in the list would show its buttons. And the bulk bar
# appears from two rows, as the page's summary does — at one, the page beside it is that row.
require Sources/Flotilla/ResourceRow.swift '@State private var hovering = false'
for s in Containers Machines Images Volumes Networks Hosts Registries DNS Clusters; do
    f="Sources/Flotilla/${s}View.swift"
    if ! grep -B3 -F 'BulkActionBar(title:' "$f" | grep -qE '^        if selection\.count > 1, '; then
        echo "  ✗ $f: the bulk bar is not held back to a selection of two or more"
        fail=1
    fi
done
# The split opens as a split: not widened over the list, and not showing the list over the page.
require Sources/Flotilla/SplitPanes.swift '    var expanded = false'
require Sources/Flotilla/SplitPanes.swift '    var compactShowsList = false'
# And nothing for a second presentation to be: no grid, no card type and no view-mode state in a
# section or its UI state. `ResourceCard` lives on in the Suggestions galleries, which are not
# sections. Comments are skipped — this file's own history is written in them.
for f in Sources/Flotilla/{Containers,Machines,Images,Volumes,Networks,Hosts,Registries,DNS,Clusters}View.swift \
         Sources/Flotilla/*UIState.swift; do
    hits=$(grep -nE '\b(LazyVGrid|LazyHGrid|ResourceCard|ContainerCard|ListPresentation|[A-Za-z]*ViewMode|viewMode|presentation)\b' "$f" \
           | grep -vE '^[0-9]+:[[:space:]]*//')
    if [ -n "$hits" ]; then
        echo "  ✗ $f: a second presentation of the list"
        echo "$hits" | sed 's/^/      /'
        fail=1
    fi
done
# A detail view opens on Overview unless the *caller* asked for a specific tab. The pinned
# substring is the tail of the expression, so it keeps asserting the fallback while allowing the
# explicit `requestedTab` in front of it — that parameter exists because routing the request
# through `lastMachineTab` alone silently dropped it whenever the view was already installed.
require Sources/Flotilla/MachineDetailView.swift 'model.lastMachineTab[machine.id] ?? .overview)'
# `.table`, not `.json`. Inspect opens on the readable form — one row per path, searchable —
# and JSON is what you switch to for the raw payload; it was `.json` only because that view
# existed first. Pinned for the same reason the old value was: a default that drifts back is a
# regression nobody notices until they open the tab.
# One assertion now, not one per screen: the panel is `InspectPane`, shared by the container,
# machine, volume and network detail screens. It used to be a copy in each of the first two —
# which is exactly why this check named two files, and why adding volumes and networks would have
# meant naming four.
require Sources/Flotilla/InspectPane.swift '@State private var presentation: InspectPresentation = .table'
require Sources/Flotilla/ContainerDetailView.swift 'model.lastDetailTab[host.rowID(container.id)] ?? .overview'
# The two new detail screens open on Overview, for the same reason the other two do.
require Sources/Flotilla/VolumeDetailView.swift 'requestedTab ?? .overview'
require Sources/Flotilla/NetworkDetailView.swift 'requestedTab ?? .overview'
# Settings opens on General, as a sidebar of sections beside the pane (18 October; it was a top tab
# strip). A `section` default of anything else is the scaffold that opens Settings on a pane you
# did not ask for, and the sidebar line is the one that says the strip has not come back.
require Sources/Flotilla/SettingsView.swift '@State private var section: Section = .general'
require Sources/Flotilla/SettingsView.swift 'SettingsSidebar(groups: sidebarGroups, selection: $section)'

# A tab request that opens pre-populated is a scaffold too: it would open its page on a tab. (Until
# Q58 this was `detailTarget`, which opened the slide-in page itself.)
for f in Sources/Flotilla/{Containers,Machines,Images,Volumes,Networks}View.swift; do
    if grep -nE 'var request: DetailTarget\? *=' "$f" >/dev/null; then
        echo "  ✗ $f: request has an initial value — that is a scaffold"
        fail=1
    fi
done

# Q59: window chrome is always below the split, rather than inside a section or sidebar.
require Sources/Flotilla/MainWindowView.swift '            WindowStatusBar(model: model)'
require Sources/Flotilla/WindowStatusBar.swift '        .frame(height: 23)'
require Sources/Flotilla/WindowStatusBar.swift '            .layoutPriority(1)'

if [ "$fail" -ne 0 ]; then
    echo
    echo "Refusing to package: a screenshot scaffold is still in the source."
    exit 1
fi
echo "  defaults OK"
