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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Controls

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: Binding(get: { ui.kind }, set: { ui.kind = $0 })) {
                Text("All kinds").tag(ActivityKind?.none)
                ForEach(ActivityKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(ActivityKind?.some(kind))
                }
            }
            .fixedSize()

            // Populated from the feed, not from the current inventory: something that has been
            // deleted is exactly what you may want to look up, and by then it is gone from the
            // lists.
            Picker("Subject", selection: Binding(get: { ui.subject }, set: { ui.subject = $0 })) {
                Text("Everything").tag(String?.none)
                ForEach(subjects, id: \.self) { subject in
                    Text(subject).tag(String?.some(subject))
                }
            }
            .fixedSize()
            .disabled(subjects.isEmpty)

            TextField("Search activity…",
                      text: Binding(get: { ui.search }, set: { ui.search = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Spacer()

            Text("\(filtered.count) of \(model.activity.count)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ToolbarIconButton(systemImage: "line.3.horizontal.decrease",
                                      label: "Clear filters") {
                        ui.kind = nil
                        ui.subject = nil
                        ui.search = ""
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    Button(event.subject) { go(event.kind.section) }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .help("Open \(event.kind.title)")
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
        }
    }

    private func colour(for event: ContainerEvent) -> Color {
        if event.isFailure { return Theme.danger }
        switch event.to.lowercased() {
        case "running", "present": return Theme.online
        case "stopped", "absent": return .secondary
        default: return Theme.warning
        }
    }
}

/// Filter state for the Activity feed, owned by `MainWindowView` like every other section's.
@Observable
final class ActivityUIState {
    var kind: ActivityKind?
    var subject: String?
    var search = ""
}
