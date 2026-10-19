import SwiftUI
import AppKit

/// Settings ▸ Advanced ▸ Flotilla Helper (Q41): Flotilla's background service for jobs that need
/// administrator rights. Its state is `HelperMonitor`'s, shared with the status bar.
///
/// Approval happens in System Settings, which tells the app nothing, so the monitor reads again
/// whenever Flotilla comes back to the front — the moment the owner returns from Login Items.
struct HelperSettingsSection: View {
    let monitor: HelperMonitor

    var body: some View {
        let health = monitor.health
        SettingsGroup("Flotilla Helper") {
            HStack(alignment: .firstTextBaseline) {
                Label(health.title, systemImage: health.symbol)
                    .foregroundStyle(health.tint)
                Spacer()
                ForEach(health.actions, id: \.self) { action in
                    Button(action.title) { monitor.perform(action) }
                        .disabled(monitor.busy)
                        .help(action.help ?? "")
                }
            }
            // What it is, then one line on where it stands (Kamal: the two notes read as one repeated).
            SettingsNote(verbatim: "Flotilla's background service for jobs that need administrator rights: "
                         + "DNS domains and names across Macs, installing Apple's container, and installing "
                         + "Flotilla updates on a host. A signed copy of Flotilla installs it by itself, and "
                         + "macOS asks you to approve it once in Login Items. Remove it and Flotilla leaves it "
                         + "removed; Reinstall may ask for that approval again. "
                         + health.explanation)
            if let problem = monitor.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
            }
        }
        .onAppear { monitor.refresh() }
    }
}
