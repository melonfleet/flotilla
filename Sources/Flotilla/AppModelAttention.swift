import Foundation
import FlotillaCore

/// One thing that needs the owner: a sentence, the section that deals with it, and — where
/// Flotilla already has one — the fix, as a button beside it.
struct AttentionItem: Identifiable {
    let text: String
    let section: Section
    var fix: (title: String, run: @MainActor () -> Void)?
    /// The Mac it is about, when it is about one — so a host's page lists only its own.
    var host: HostRef?
    var id: String { text }
    init(_ text: String, _ section: Section, host: HostRef? = nil, fix: (title: String, run: @MainActor () -> Void)? = nil) {
        self.text = text; self.section = section; self.host = host; self.fix = fix
    }
}

extension AppModel {
    /// Everything that needs attention, on This Mac and across the fleet — one list, read by
    /// Overview, the menu bar's Needs Attention menu and its icon's badge, so none of them can
    /// disagree about whether something is wrong.
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        // Stopped is attention, amber, with Start beside it (the owner, 8 October): it may be
        // deliberate, but nothing runs until it starts.
        if case .serviceStopped? = preflight {
            items.append(AttentionItem("container is stopped on \(hostLabel).", .hosts, host: .local,
                                       fix: ("Start", { [weak self] in Task { await self?.startRuntime() } })))
        } else if case .needsKernel? = preflight {
            items.append(AttentionItem("\(hostLabel) has no kernel, so containers can't start.", .hosts, host: .local,
                                       fix: ("Download Kernel", { [weak self] in Task { await self?.installKernel() } })))
        } else if !runtimeUsable && !needsContainerInstall && runtimeSetup == nil {
            // Missing or being installed is Overview's setup banner, not a line here.
            items.append(AttentionItem("The container runtime on \(hostLabel) isn't running.", .hosts, host: .local))
        }
        for network in disconnectedNetworks {
            items.append(AttentionItem("\(network) has lost its connection to \(hostLabel).", .networks, host: .local))
        }
        let fleet = hostMode
        // A paired host that has stopped answering, or is waiting to be let in.
        for peer in fleet.trustedHosts {
            if case .failed(let reason)? = fleet.live[peer.fingerprint]?.state {
                // Answering but without `container`: it is waiting for it, not unreachable.
                items.append(hostMissingContainer(peer.fingerprint)
                    ? AttentionItem("container isn\u{2019}t installed on \(peer.displayName).", .hosts, host: .peer(peer.fingerprint))
                    : AttentionItem("\(peer.displayName) isn\u{2019}t answering: \(reason)", .hosts, host: .peer(peer.fingerprint)))
            }
        }
        // Versions that differ from This Mac's: `container` by a minor release or more, which can
        // change what a command accepts, and Flotilla by any build (PLAN.md Phase C).
        for peer in fleet.trustedHosts {
            let host = HostRef.peer(peer.fingerprint)
            if let warning = containerSkewWarning(host) { items.append(AttentionItem(warning, .hosts, host: host)) }
            if let skew = appSkew(host), skew.level != .same,
               let theirs = fleet.live[peer.fingerprint]?.appVersion {
                switch updateState(peer.fingerprint) {
                case .available, .updating:
                    // An update waiting or under way is new work, not a fault: Overview's Updates
                    // block (Iris, 8 October). Left here, every routine rollout turned the
                    // menu-bar badge red.
                    break
                case .failed(let message):
                    items.append(AttentionItem("\(peer.displayName) couldn\u{2019}t update Flotilla: \(message)", .hosts, host: host))
                default:
                    items.append(AttentionItem("\(peer.displayName) runs \(skew.otherIsOlder ? "an older" : "a newer") Flotilla "
                                  + "(\(theirs); This Mac \(HostModeController.appVersion)).", .hosts, host: host))
                }
            }
        }
        let waiting = fleet.hosts.filter { $0.status == .pending }.count
        if waiting > 0 {
            items.append(AttentionItem("\(waiting) Mac\(waiting == 1 ? " is" : "s are") waiting for your approval.", .hosts))
        }
        let flagged = (containers + fleet.fleetContainers.flatMap(\.snapshot.items)).filter(\.needsAttention)
        if !flagged.isEmpty {
            items.append(AttentionItem("\(flagged.count) container\(flagged.count == 1 ? " is" : "s are") in an unknown state.", .containers))
        }
        // For looking at a long list without breaking anything: launched with
        // FLOTILLA_FAKE_ATTENTION=12, Flotilla adds that many made-up items. Nothing sets it.
        if let fake = ProcessInfo.processInfo.environment["FLOTILLA_FAKE_ATTENTION"].flatMap(Int.init), fake > 0 {
            let hosts = ["mini-01", "mini-02", "studio-lab", "rack2-mini-07", "build-host"]
            for n in 1...min(fake, 50) {
                items.append(AttentionItem("\(hosts[n % hosts.count])-\(n) isn\u{2019}t answering: Couldn't reach the host: "
                    + "the connection timed out after 30 seconds while waiting for a reply on port 7868.", .hosts))
            }
        }
        return items
    }

    /// The menu-bar badge: off when This Mac's `container` is stopped or missing, attention when
    /// anything above is on the list, running otherwise — and nothing until preflight answers.
    var menuBarStatus: MenuBarStatus {
        switch preflight {
        case nil: return .checking
        case .serviceStopped?, .missing?: return .off
        case .ok?: return attentionItems.isEmpty ? .running : .attention
        default: return .attention
        }
    }

    /// Keeps every paired host's status current for as long as Flotilla runs, window or no window.
    ///
    /// Until 8 October only the screens that show hosts asked them (Hosts every 30 seconds while
    /// open), so with the window closed the menu bar listed every host as "Checking…", its badge
    /// could not see a host stop answering, and the automatic host updates that run after each
    /// refresh (`onRefreshed`) never ran. Each host's own backoff (`HostBackoff`) still decides
    /// when it is due — every 30 seconds while it answers, less often while it doesn't — so this
    /// and an open Hosts screen never ask the same host twice in a window.
    func startFleetWatch() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.hostMode.refreshLiveStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}
