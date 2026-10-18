import SwiftUI
import FlotillaCore

/// One feed of everything that has happened, across every resource kind.
///
/// The per-section strips answer "what just happened *here*". This answers "what has happened on
/// this Mac", which the app could not answer at all: containers and machines each kept their own
/// event list and images, volumes and networks recorded nothing.
///
/// **It is honest about its horizon.** Entries begin when Flotilla launched — a first sighting is
/// not an event, so a container that was already running is not announced as "started", and the
/// empty state says so rather than implying a complete history. Persisting the feed needs a real
/// store, which `DECISIONS.md` puts in Phase 4.
struct ActivityView: View {
    let model: AppModel
    let ui: ActivityUIState
    /// Set so a row can take you to the section its subject lives in.
    let go: (Section) -> Void

    @State private var showingFilters = false

    var body: some View {
        // Rows and a page, like every list (Q58), opening on the rows alone (`PaneMode`): a feed is
        // read top to bottom, and an entry's page is something you open over it.
        SplitPanes("activity", item: shown?.id, clearing: { ui.selected = nil }) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } detail: {
            detailPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The entry whose page is open. Looked up in the feed as filtered, so an entry filtered away
    /// or trimmed off the end of the 500 closes its page rather than leaving one with no row.
    private var shown: ContainerEvent? {
        guard let id = ui.selected else { return nil }
        return filtered.first { $0.id == id }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let event = shown {
            ActivityEventDetailView(event: event, openHelp: openHelp(event),
                                    open: { open(event) },
                                    filter: { filterToSubject(event) },
                                    filtered: ui.subject == event.subject)
                .id(event.id)
        } else {
            PaneEmptyState(title: "Choose an entry", systemImage: "clock.arrow.circlepath",
                           description: "What happened, when, and to what show here.")
        }
    }

    // MARK: Controls

    /// One filter icon beside the search field, like every other section.
    ///
    /// It was two **worded** pickers — "Kind / All kinds" and "Subject / Everything" — laid out
    /// before the search field, which pushed that field a long way right while every other screen
    /// starts it near the left. That is the same shape the Logs toolbar had before its two source
    /// controls collapsed into one filter, and the owner's standing rule applies identically:
    /// *"we don't want to use a lot of words instead of icons"*. Kind and subject are both "which
    /// entries", so they are one control, and the words move into the popover where they are read
    /// once rather than worn permanently.
    private var toolbar: some View {
        SectionToolbar(search: Binding(get: { [weak ui] in ui?.search ?? "" },
                                       set: { [weak ui] in ui?.search = $0 }),
                       searchPrompt: "Search activity…",
                       matches: filtered.count,
                       // No refresh time to show — this feed is appended to as things happen — so
                       // the row count takes that slot. It used to be printed in a hand-rolled
                       // band, which is how this screen's search field ended up 20pt narrower
                       // than every other one.
                       status: "\(filtered.count) of \(model.activity.count)",
                       leading: {
            PaneModeButton()
            // Filled when narrowed, hollow when not — the same signal every other filter gives.
            IconActionButton(systemImage: "line.3.horizontal.decrease", label: "Filter",
                             help: filterHelp, active: isFiltered) {
                showingFilters.toggle()
            }
            .popover(isPresented: $showingFilters, arrowEdge: .bottom) { filterPopover }
        }, trailing: {
            EmptyView()
        })
    }

    private var filterHelp: String {
        var parts: [String] = []
        if let kind = ui.kind { parts.append(kind.title) }
        if let subject = ui.subject { parts.append(subject) }
        return parts.isEmpty ? "Filter by kind or subject" : "Showing " + parts.joined(separator: " · ")
    }

    /// The subjects, newest first, as one radio group including "Everything".
    ///
    /// In a `ScrollView` rather than a plain stack: `subjects` is every subject the feed has
    /// mentioned, which grows without limit, and a popover as tall as that list is a popover
    /// taller than the window.
    @ViewBuilder
    private var subjectPicker: some View {
        ScrollView {
            Picker("Subject", selection: Binding(get: { ui.subject }, set: { ui.subject = $0 })) {
                Text("Everything").tag(String?.none)
                ForEach(subjects, id: \.self) { subject in
                    Text(subject).tag(String?.some(subject))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: Binding(get: { ui.kind }, set: { ui.kind = $0 })) {
                Text("All kinds").tag(ActivityKind?.none)
                ForEach(ActivityKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(ActivityKind?.some(kind))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            // Populated from the feed, not from the current inventory: something that has been
            // deleted is exactly what you may want to look up, and by then it is gone from the
            // lists.
            if !subjects.isEmpty {
                Divider()
                // Radio buttons, like the kinds above them — the owner's call, and right: a
                // pop-up button inside a popover is a menu inside a menu, and it read as a
                // different *kind* of control from the list it sat under.
                //
                // Scrolls past a handful rather than growing the popover to the height of the
                // feed's subject list, which is unbounded — every container, machine, image,
                // volume and network the feed has ever mentioned.
                subjectPicker
                    .frame(maxHeight: 180)
            }

            Divider()
            Button("Clear filters") {
                ui.kind = nil
                ui.subject = nil
                ui.search = ""
            }
            .disabled(!isFiltered)
        }
        .padding(14)
        .frame(minWidth: 200)
    }

    /// Whether anything is currently narrowing the feed — drives the accent tint on the clear
    /// button, so "there is a filter on" reads the same here as everywhere else.
    private var isFiltered: Bool {
        ui.kind != nil || ui.subject != nil || !ui.search.isEmpty
    }

    /// Every subject the feed mentions, newest first so the list is ordered by relevance rather
    /// than alphabetically — the thing you just touched is at the top.
    private var subjects: [String] {
        var seen = Set<String>()
        return model.activity.compactMap { seen.insert($0.subject).inserted ? $0.subject : nil }
    }

    private var filtered: [ContainerEvent] {
        var events = model.activity
        if let kind = ui.kind { events = events.filter { $0.kind == kind } }
        if let subject = ui.subject { events = events.filter { $0.subject == subject } }
        let query = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            events = events.filter {
                $0.subject.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.to.lowercased().contains(query)
                || $0.from.lowercased().contains(query)
            }
        }
        return events
    }

    // MARK: Feed

    @ViewBuilder
    private var content: some View {
        if model.activity.isEmpty {
            ContentUnavailableView {
                Label("No activity yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Changes appear here as they happen — containers starting and stopping, "
                     + "machines restarting, images pulled or built, volumes and networks "
                     + "created or deleted.\n\nHistory from before Flotilla launched is not "
                     + "recorded, so this stays empty until something changes.")
            }
        } else if filtered.isEmpty {
            ContentUnavailableView {
                Label("No matching activity", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text("\(model.activity.count) entries recorded, none matching the current "
                     + "filters.")
            } actions: {
                Button("Clear filters") { ui.kind = nil; ui.subject = nil; ui.search = "" }
            }
        } else {
            // Rows, no sort and **no checkboxes**: this feed has no bulk action to take a selection
            // to — it is read, opened and filtered, never acted on in batches — so a box on every
            // row would tick things for nothing. Selection is single, and is the page.
            List(filtered, selection: Binding(get: { ui.selected }, set: { ui.selected = $0 })) { event in
                row(event)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu(forSelectionType: ContainerEvent.ID.self) { ids in
                rowContextMenu(for: ids)
            }
        }
    }

    /// "Started web", the time on the trailing end, and the result under it.
    private func row(_ event: ContainerEvent) -> some View {
        ResourceRow(
            title: event.headline,
            trailingText: RelativeDate.clockTime(event.date),
            detail: detail(event),
            detailHelp: event.date.formatted(date: .abbreviated, time: .standard),
            selected: ui.selected == event.id,
            summary: "\(event.headline), \(detail(event)), \(RelativeDate.clockTime(event.date))",
            leading: {
                RowLeadingMark {
                    // The kind's glyph with the result's dot: where it ended up, as the table's first
                    // column coloured it.
                    RowTypeMark(systemImage: event.kind.systemImage, kind: event.kind.title) {
                        Circle().fill(colour(for: event))
                    }
                }
            },
            chips: {
                if let host = event.hostName {
                    ResourceChip(text: host, systemImage: "desktopcomputer")
                }
            },
            actions: {
                Menu {
                    menu(for: event)
                } label: {
                    RowOverflowLabel()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for \(event.headline)")
                .accessibilityLabel("More actions for \(event.headline)")
            })
    }

    /// The result: the raw transition when it was observed ("running → stopped"), or who did it
    /// when Flotilla performed it.
    private func detail(_ event: ContainerEvent) -> String {
        let how = event.transition ?? (event.action == nil ? "observed" : "done in Flotilla")
        return "\(event.kind.title) \u{00B7} \(how)"
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<ContainerEvent.ID>) -> some View {
        if ids.count == 1, let event = filtered.first(where: { ids.contains($0.id) }) {
            menu(for: event)
        }
    }

    private func filterToSubject(_ event: ContainerEvent) {
        ui.subject = event.subject
        ui.kind = event.kind
    }

    /// Right-click and `⋮` offer what the page offers, plus the two things you come to this feed
    /// wanting: the name, and everything else about that subject.
    @ViewBuilder
    private func menu(for event: ContainerEvent) -> some View {
        Button(openHelp(event)) { open(event) }
        Divider()
        Button("Filter to \(event.subject)") { filterToSubject(event) }
        .disabled(ui.subject == event.subject)
        CopyMenu([
            ("Subject", event.subject),
            ("What happened", event.summary),
            ("Time", event.date.formatted(date: .abbreviated, time: .standard)),
        ])
    }

    /// Opens the **subject**, not just its section, where a subject can be opened at all.
    ///
    /// The link used to call `go(event.kind.section)`, so clicking `web` on a row about `web`
    /// dropped you on the containers list to find it again — and the tooltip said so ("Open
    /// Containers"), which made the tooltip the bug report. Same fault the dashboard's
    /// utilisation table had, and `requestDetail(kind:subject:)` is the mechanism built for it.
    ///
    /// Only containers and machines have a detail screen, so only they get the subject; for the
    /// rest the section is genuinely all there is to open, and asking for a detail nothing
    /// consumes would leave the request set with no one to clear it. A subject that has since
    /// been deleted is fine — the detail screen says so by name, which is a better answer than a
    /// list.
    private func open(_ event: ContainerEvent) {
        switch event.kind {
        case .container, .machine: model.requestDetail(kind: event.kind, subject: event.subject)
        default: go(event.kind.section)
        }
    }

    private func openHelp(_ event: ContainerEvent) -> String {
        switch event.kind {
        case .container, .machine: "Open \(event.subject)"
        default: "Open \(event.kind.title)"
        }
    }

    private func colour(for event: ContainerEvent) -> Color {
        Theme.color(forEventEndingIn: event.to)
    }
}

/// Filter state for the Activity feed, owned by `MainWindowView` like every other section's.
@Observable
final class ActivityUIState {
    /// The entry whose page is open. Single: the feed has no bulk action, so no checkboxes.
    var selected: ContainerEvent.ID?
    var kind: ActivityKind?
    var subject: String?
    var search = ""
}

/// One entry's own page, in the right pane: the whole event.
struct ActivityEventDetailView: View {
    let event: ContainerEvent
    let openHelp: String
    let open: () -> Void
    let filter: () -> Void
    /// The feed is already narrowed to this subject.
    let filtered: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: event.kind.systemImage).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(event.headline).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                DetailCard(title: "Details", minHeight: nil) {
                    row("Time", event.date.formatted(date: .abbreviated, time: .standard)
                        + " (\(RelativeDate.relativeToNow(event.date)))")
                    HStack(alignment: .firstTextBaseline) {
                        Text("Subject").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        // The way in: the subject's own page where it has one, else its section.
                        Button(event.subjectName, action: open)
                            .buttonStyle(.link)
                            .foregroundStyle(Theme.link)
                            .font(.system(size: 12))
                            .help(openHelp)
                    }
                    row("Kind", event.kind.title)
                    row("Action", event.verb)
                    row("Result", event.transition ?? (event.action == nil ? "Observed" : "Done in Flotilla"))
                    row("Mac", event.hostName ?? "This Mac")
                }
                Text(event.action == nil
                     ? "Flotilla saw this change between two refreshes; it may have been made elsewhere."
                     : "Flotilla did this itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(openHelp, action: open)
        Button("Filter to \(event.subjectName)", action: filter).disabled(filtered)
        Button("Copy") {
            Clipboard.copy("\(event.headline) \u{2014} \(event.date.formatted(date: .abbreviated, time: .standard))")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
