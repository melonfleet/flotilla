import SwiftUI

/// A recent-activity band across the bottom of a section list, the way vCenter keeps a task
/// pane under the inventory.
///
/// The dashboard already has an activity card and each container and machine has its own event
/// list, but neither answers the question you actually have while looking at a list: *what just
/// happened here?* the owner asked for it on both Containers and Machines, and it earns its place
/// because a restart is otherwise invisible — the row starts running and ends running, so the
/// list looks identical before and after.
///
/// **Collapsible, and collapsed state is the caller's**, so it survives a trip to another
/// section like every other bit of list state. It defaults open: a pane that hides the thing
/// it was added for has to be discovered before it helps.
///
/// It shows only what it has. There is no "no activity yet" fabrication of a first sighting —
/// `recordTransitions` deliberately ignores the containers present at launch, so an app just
/// opened has an empty strip, and that is honest rather than broken.
struct ActivityStrip: View {
    struct Entry: Identifiable {
        let id: UUID
        let subject: String
        let event: ContainerEvent
    }

    let title: String
    let entries: [Entry]
    @Binding var isExpanded: Bool
    /// Called when a row is clicked, so the strip can take you to the thing that changed.
    let open: (String) -> Void

    private static let visibleRows = 4

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if isExpanded {
                Divider()
                content
            }
        }
        .background(.clear)
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if !entries.isEmpty {
                    Text("\(entries.count)")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let newest = entries.first {
                    Text(RelativeDate.relativeToNow(newest.event.date))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide recent activity" : "Show recent activity")
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            Text("Nothing has changed since Flotilla started. State changes appear here as they "
                 + "happen; history from before launch is not recorded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                        Divider().padding(.leading, 12)
                    }
                }
            }
            // Four rows' worth. A band that grows with its content would push the list around
            // as things happen, which is the opposite of a calm status area.
            .frame(height: CGFloat(Self.visibleRows) * 26)
        }
    }

    private func row(_ entry: ActivityStrip.Entry) -> some View {
        Button { open(entry.subject) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(colour(for: entry.event))
                    .frame(width: 6, height: 6)
                Text(RelativeDate.clockTime(entry.event.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.subject)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                Text(entry.event.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // The raw transition, because `summary` folds several states into one word and
                // "exited (137)" is not the same event as a clean stop.
                Text("\(entry.event.from) → \(entry.event.to)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(MenuRowStyle())
    }

    private func colour(for event: ContainerEvent) -> Color {
        switch event.to.lowercased() {
        case "running": Theme.online
        case "stopped": .secondary
        default:
            event.to.lowercased().contains("exit") || event.to.lowercased().contains("dead")
                ? Theme.danger : Theme.warning
        }
    }
}
