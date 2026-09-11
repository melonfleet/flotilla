import SwiftUI
import FlotillaCore

/// The sidebar's bottom band: whether `container` is running, and the few things you might want
/// to do about it.
///
/// It replaces the "Client mode / No paired hosts" footer, which described a client/host split
/// that does not exist in this build. The space is worth keeping — a runtime the whole app depends
/// on should say whether it is up without being asked, and the corner furthest from the toolbar is
/// where Docker Desktop puts the same thing.
///
/// **Nothing here reaches the network.** "Check for updates" opens Apple's releases page in the
/// browser rather than comparing versions, because Flotilla makes no requests of its own and a
/// background version check would be precisely the phone-home it promises it does not do. The
/// installed version is printed beside the link so the comparison takes one glance.
struct RuntimeStatusBand: View {
    let model: AppModel
    /// In rail mode the words go; the dot and the menu stay, and the sentence moves to the
    /// tooltip — the same trade the sidebar rows already make.
    let railed: Bool

    @Environment(\.openURL) private var openURL
    @State private var confirmingRestart = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, railed ? 8 : 12)
                .padding(.vertical, 8)
        }
        .confirmationDialog("Restart the container system?",
                            isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await model.restartRuntime() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every running container stops with it, and does not come back on its own.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if railed {
            VStack(spacing: 6) {
                indicator
                menu
            }
            .help(status.title)
        } else {
            HStack(spacing: 8) {
                indicator
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.caption)
                        .lineLimit(1)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                menu
            }
        }
    }

    /// A spinner while the runtime is being started or restarted — "busy" and "unavailable" are
    /// different states, and a dot that stays amber through a restart says neither.
    @ViewBuilder
    private var indicator: some View {
        if model.startingRuntime {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(status.tint)
                .frame(width: 7, height: 7)
                .accessibilityLabel(status.title)
        }
    }

    private var menu: some View {
        Menu {
            switch model.preflight {
            case .serviceStopped:
                Button("Start Container System") { Task { await model.startRuntime() } }
            case .ok:
                Button("Restart Container System…") { confirmingRestart = true }
            default:
                EmptyView()
            }

            Divider()
            Button("Settings…") { model.pendingSection = .settings }

            Divider()
            Button("Check for `container` Updates…") {
                openURL(ExternalLinks.appleContainerReleases)
            }
            Button("Apple `container` on GitHub") { openURL(ExternalLinks.appleContainer) }
            Button("Flotilla on GitHub") { openURL(ExternalLinks.flotilla) }
        } label: {
            // `RowOverflowLabel`, the same vertical dots every row menu in the app uses — and the
            // same reason they are a rotated `ellipsis`: `ellipsis.vertical` is not a real SF
            // Symbol, and an unknown name renders nothing at all.
            RowOverflowLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Runtime options")
        .disabled(model.startingRuntime)
    }

    /// What the band says, straight from the preflight the rest of the app already acts on — so it
    /// cannot claim the runtime is fine while the container list explains that it is not.
    private var status: (title: String, detail: String?, tint: Color) {
        switch model.preflight {
        case .ok(let version, _):
            ("Container system running", "container \(version)", Theme.online)
        case .serviceStopped(let version, _, _):
            ("Container system stopped", "container \(version)", Theme.warning)
        case .tooOld(let found, let required):
            ("container \(found) is too old", "needs \(required)", Theme.warning)
        case .missing:
            ("container is not installed", nil, Theme.danger)
        case .unusable:
            ("container is not usable", nil, Theme.danger)
        case nil:
            ("Checking the container system…", nil, .secondary)
        }
    }
}
