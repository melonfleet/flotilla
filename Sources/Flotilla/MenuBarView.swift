import SwiftUI
import FlotillaCore

/// The menu-bar popover: **a glance, not the product**.
///
/// Per the approved design (`research/review/mockups/menubar.html`): status at a glance,
/// a short list, and a way into the real window. Deliberately no text entry and no
/// destructive confirmations here — a popover that can be dismissed by clicking away is the
/// wrong place to confirm deleting something.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            switch model.state {
            case .idle, .loading:
                Label("Loading…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .unavailable(let reason), .failed(let reason):
                // Never render an empty list as if the fleet were simply idle — an
                // unreachable runtime and a fleet with no containers look identical
                // otherwise, and that is exactly the failure the offline-detection bug
                // taught us to avoid.
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    // Wrap rather than clip: a truncated diagnosis ("…is installed but
                    // unusable: the c…") tells the user nothing they can act on.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded where model.containers.isEmpty:
                Label("No containers", systemImage: "tray")
                    .foregroundStyle(.secondary)
            case .loaded:
                ForEach(model.containers.prefix(8)) { container in
                    row(for: container)
                }
                if model.containers.count > 8 {
                    Text("+ \(model.containers.count - 8) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Open Flotilla") { openWindow(id: "main") }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Flotilla").font(.headline)
            Spacer()
            Text("\(model.running.count) running · \(model.stopped.count) stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(for container: Container) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AppModel.isRunning(container) ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(container.id)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(container.status.state)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
