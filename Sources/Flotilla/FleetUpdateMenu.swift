import SwiftUI
import FlotillaCore

/// Updating the fleet from the footer's version menu: Flotilla on hosts behind This Mac, and
/// `container` on hosts behind the version Flotilla expects, one line each however many hosts.
/// It replaced Overview's Updates card (Kamal, 19 October 2026), which repeated the footer's badge.
/// Shown only on an admin with something to update; an update is work to do, not a fault.
struct FleetUpdateMenuSection: View {
    let model: AppModel
    @Binding var confirmingContainerUpgrade: Bool

    var body: some View {
        let flotillaWaiting = model.hostsWithUpdates
        let containerWaiting = model.hostsWithContainerUpgrades
        let containerUnderWay = model.hostMode.settingUpRuntime.count
        if !flotillaWaiting.isEmpty || !containerWaiting.isEmpty {
            SwiftUI.Section("Your Macs") {
                if !flotillaWaiting.isEmpty {
                    Text("\(FleetUpdateText.hosts(flotillaWaiting.count, capitalised: true)) "
                         + "\(flotillaWaiting.count == 1 ? "runs" : "run") an older Flotilla than This Mac "
                         + "(\(HostModeController.appVersion))")
                        .disabled(true)
                    Button(model.hostMode.rollingOut ? "Updating…"
                           : "Update \(FleetUpdateText.hosts(flotillaWaiting.count, capitalised: true)) Now") {
                        Task { await model.rollOutUpdates(automatic: false) }
                    }
                    .disabled(model.hostMode.rollingOut)
                }
                if !containerWaiting.isEmpty {
                    Text("\(FleetUpdateText.hosts(containerWaiting.count, capitalised: true)) can upgrade "
                         + "container to \(ContainerRuntime.expectedVersion)")
                        .disabled(true)
                    Button(containerUnderWay > 0 ? "Upgrading…"
                           : "Upgrade \(FleetUpdateText.hosts(containerWaiting.count, capitalised: true))\u{2026}") {
                        confirmingContainerUpgrade = true
                    }
                    .disabled(containerUnderWay > 0)
                }
            }
        }
    }
}

/// The wording Overview's card used, kept so Hosts, the menu and the confirmation say the same.
enum FleetUpdateText {
    static func hosts(_ count: Int, capitalised: Bool = false) -> String {
        "\(count) \(capitalised ? "Host" : "host")\(count == 1 ? "" : "s")"
    }

    static func containerUpgradeQuestion(_ hosts: [PeerFingerprint]) -> String {
        "Upgrade container on \(Self.hosts(hosts.count)) to \(ContainerRuntime.expectedVersion)?"
    }

    /// Hosts' wording for one host, for several: what each does, and what stops, in all.
    @MainActor
    static func containerUpgradeMessage(_ hosts: [PeerFingerprint], model: AppModel) -> String {
        let running = model.runningContainers(on: hosts)
        var text = "Each host downloads Apple's container installer, and its Flotilla Helper installs it after "
            + "checking it is Apple's. One host at a time. container restarts on each, "
        text += running > 0
            ? "which stops the \(running) running container\(running == 1 ? "" : "s") on them in all; start them again afterwards. "
            : "and nothing is running on them. "
        return text + "Then the recommended kernel, if one has none."
    }
}
