import SwiftUI
import FlotillaCore

/// The version, bottom-right of This Mac's page — and, on the Mac that manages the fleet, the way
/// to ask whether it is the latest.
///
/// Modelled on Docker Desktop's corner, from the owner's screenshot: a small version number at
/// the far bottom-right, in the accent colour, where the version *is* the control.
///
/// **A click is Sparkle's Check for Updates** (the owner, 8 October). It used to run Flotilla's
/// own GitHub release lookup, a second update mechanism beside Sparkle (DECISIONS Q40) that could
/// disagree with it; that lookup is gone. A host-only Mac is updated by its admin (Q38), so there
/// the version is just a label that says so.
struct VersionBadge: View {
    let model: AppModel

    private var updatesHere: Bool { model.updater.isRunning }

    var body: some View {
        Button {
            model.updater.checkForUpdates()
        } label: {
            Text("v\(HostModeController.appVersion)")
                .font(.caption)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(updatesHere ? Theme.link : Color.secondary)
        .disabled(!updatesHere)
        .help(updatesHere ? "Check for Updates…"
                          : (AppUpdater.isConfigured ? "Updated by your admin Mac" : "A development build"))
    }
}
