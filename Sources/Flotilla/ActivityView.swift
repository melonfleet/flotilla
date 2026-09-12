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
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        SectionToolbar(search: Binding(get: { ui.search }, set: { ui.search = $0 }),
                       searchPrompt: "Search activity…",
                       // No refresh time to show — this feed is appended to as things happen — so
                       // the row count takes that slot. It used to be printed in a hand-rolled
                       // band, which is how this screen's search field ended up 20pt narrower
                       // than every other one.
                       status: "\(filtered.count) of \(model.activity.count)",
                       leading: {
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
            SwiftUI.Table(filtered) {
                TableColumn("") { event in
                    Circle().fill(colour(for: event)).frame(width: 8, height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(event.summary)
                        .accessibilityLabel(event.summary)
                }
                .width(min: 26, ideal: 28, max: 34)

                TableColumn("Time") { event in
                    Text(RelativeDate.clockTime(event.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(event.date.formatted(date: .abbreviated, time: .standard))
                }
                .width(min: 76, ideal: 88)

                TableColumn("Kind") { event in
                    Label(event.kind.title, systemImage: event.kind.systemImage)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 96, ideal: 112)

                TableColumn("Subject") { event in
                    Button(event.subject) { open(event) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .help(openHelp(event))
                }
                .width(min: 130, ideal: 200)

                TableColumn("What happened") { event in
                    Text(event.summary).lineLimit(1)
                }
                .width(min: 110, ideal: 150)

                TableColumn("Detail") { event in
                    // The raw transition, and only when there is one. A performed action reads
                    // "running → running", which means nothing.
                    Text(event.action == nil ? "\(event.from) → \(event.to)" : "—")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .width(min: 110, ideal: 160)
            }
            .frame(maxHeight: .infinity)
            .contextMenu(forSelectionType: ContainerEvent.ID.self) { ids in
                if let event = filtered.first(where: { ids.contains($0.id) }) {
                    rowMenu(for: event)
                }
            } primaryAction: { ids in
                // Double-click does what the subject link does. Only when the activation names
                // exactly one row: `ids` is a `Set`, and opening an arbitrary member of a
                // multi-row activation is the bug the containers table was fixed for.
                guard ids.count == 1, let event = filtered.first(where: { ids.contains($0.id) })
                else { return }
                open(event)
            }
        }
    }

    /// Right-click offers what the row's own link offers, plus the two things you come to this
    /// feed wanting: the name, and everything else about that subject. The table had **no**
    /// context menu at all, which made it the one list in the app where right-clicking a row did
    /// nothing.
    @ViewBuilder
    private func rowMenu(for event: ContainerEvent) -> some View {
        Button(openHelp(event)) { open(event) }
        Divider()
        Button("Filter to \(event.subject)") {
            ui.subject = event.subject
            ui.kind = event.kind
        }
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
    var kind: ActivityKind?
    var subject: String?
    var search = ""
}
