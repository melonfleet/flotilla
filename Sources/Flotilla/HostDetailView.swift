import SwiftUI
import AppKit
import FlotillaCore
import FlotillaNet

/// The tabs of a Mac's page (the owner, 9 October): the same shape as a container's or a machine's.
enum HostDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case system = "System"
    case flotilla = "Flotilla"
    case settings = "Settings"
    case updates = "Updates"
    case activity = "Activity"
    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .system: "desktopcomputer"
        case .flotilla: "sailboat"
        case .settings: "slider.horizontal.3"
        case .updates: "arrow.down.circle"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

/// One page per Mac — This Mac or a paired host — with an inventory and everything Flotilla knows
/// and can do about it, in tabs like every other detail screen (the owner, 9 October).
///
/// What a host reports comes from its `.hostFacts` answer; an older host leaves the newer facts out
/// and the page says "—" rather than guessing. This Mac's Overview keeps its live charts under the
/// cards; a host's charts come in the next step, from its own `container stats` and counters.
struct HostDetailView: View {
    let model: AppModel
    let host: HostRef
    let go: (Section) -> Void

    @State private var tab: HostDetailTab = .overview
    @State private var confirmingRuntime = false
    @State private var actionMessage: String?

    private var hostMode: HostModeController { model.hostMode }
    private var peer: Peer? {
        guard case .peer(let fingerprint) = host else { return nil }
        return hostMode.hosts.first { $0.fingerprint == fingerprint }
    }
    private var fingerprint: PeerFingerprint? { if case .peer(let f) = host { f } else { nil } }
    private var facts: HostFacts? { model.hostFacts(on: host) }
    private var live: HostModeController.LiveStatus? { fingerprint.flatMap { hostMode.live[$0] } }
    private var name: String { hostMode.hostName(host, local: model.hostLabel) }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(items: HostDetailTab.allCases.map {
                .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage)
            }, selection: $tab)
            Group {
                switch tab {
                case .overview: overview
                case .system: scrolling { systemTab }
                case .flotilla: scrolling { flotillaTab }
                case .settings: HostSettingsTab(model: model, host: host)
                case .updates: scrolling { updatesTab }
                case .activity: scrolling { activityTab }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
            Button("OK") { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Overview

    @ViewBuilder
    /// The same page for every Mac (the owner, 9 October): a host cannot send live charts, so This
    /// Mac's were dropped rather than kept as the one page that differs.
    private var overview: some View {
        scrolling {
            overviewCards
            usageNowCard
        }
    }

    private var overviewCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            grid {
                card("State") {
                    HStack(spacing: 6) {
                        Circle().fill(stateColor).frame(width: 7, height: 7)
                        Text(stateText).font(.system(size: 13, weight: .medium))
                    }
                    row("Last check-in", lastCheckIn)
                    row("Up since", facts?.bootTime.map { RelativeDate.relativeToNow($0) } ?? "—")
                    row("container", containerState)
                }
                card("Hardware") {
                    row("Model", facts?.model ?? peer?.details.model ?? "—")
                    row("Chip", OverviewView.chip(facts))
                    row("Memory", OverviewView.memory(facts))
                    row("Disk", diskText)
                    row("macOS", facts?.macOSVersion ?? peer?.details.macOSVersion ?? "—")
                }
                card("Running here") {
                    link("Containers", counts.containers, .containers)
                    link("Images", counts.images, .images)
                    link("Volumes", counts.volumes, .volumes)
                    link("Networks", counts.networks, .networks)
                    link("Machines", counts.machines, .machines)
                }
                card("Versions") {
                    row("Flotilla", host.isLocal ? HostModeController.appVersion : (live?.appVersion ?? "—"))
                    row("container", host.isLocal ? (model.localContainerVersion ?? "—") : (live?.containerVersion ?? "—"))
                    row("Role", roleText)
                }
                // Where this Mac sits — what Hosts can group by (the owner, 9 October). Kept on this
                // admin Mac; the host is not told.
                card("Groups") {
                    row(HostCategoryBook.subnetName, model.subnet(of: host) ?? "—", monospaced: true)
                    ForEach(model.hostCategories.categories) { category in
                        HostCategoryValueField(store: model.hostCategories, category: category,
                                               host: fingerprint?.hex ?? HostRow.thisMacID)
                    }
                }
            }
            let attention = model.attentionItems.filter { $0.host == host }
            if !attention.isEmpty {
                DetailCard(title: "Needs attention", minHeight: nil) {
                    ForEach(attention) { item in
                        HStack(spacing: 8) {
                            Label(item.text, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(Theme.warning)
                            Spacer()
                            if let fix = item.fix {
                                Button(fix.title) { fix.run() }.controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A Mac's CPU, memory and disk as it last reported them.
    private var usageNowCard: some View {
        DetailCard(title: "Usage now", minHeight: nil) {
            row("CPU", facts?.cpuPercent.map { "\(Int($0.rounded()))% of all cores" } ?? "—")
            row("Memory used", facts.flatMap { f in f.memoryUsedBytes.map { used in
                "\(Self.gigabytes(used)) of \(OverviewView.memory(f))" } } ?? "—")
            row("Disk free", diskText)
            row("As of", lastCheckIn)
        }
    }

    // MARK: System

    @ViewBuilder
    private var systemTab: some View {
        grid {
            // Identity and security in one box (the owner, 9 October), each half under its own rule.
            card("General") {
                row("Computer name", host.isLocal ? HostModeController.computerName : name)
                row("Serial number", facts?.serialNumber ?? peer?.details.serialNumber ?? "—", monospaced: true)
                row("Model identifier", facts?.model ?? peer?.details.model ?? "—")
                row("macOS", facts?.macOSVersion ?? "—")
                row("Time zone", facts?.timeZone ?? "—")
                row("Up since", facts?.bootTime.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                Divider()
                row("FileVault", onOff(facts?.fileVault))
                row("Firewall", onOff(facts?.firewall))
            }
            card("Network and sharing") {
                row("Addresses", facts?.ipv4Addresses.map { $0.isEmpty ? "None" : $0.joined(separator: ", ") } ?? "—",
                    monospaced: true)
                serviceRow("Remote Login (SSH)", facts?.remoteLogin, .ssh)
                serviceRow("Screen Sharing (VNC)", facts?.screenSharing, .vnc)
                serviceRow("File Sharing (SMB)", facts?.fileSharing, .smb)
                row("Signed-in user", facts?.loginUser ?? "—", monospaced: true)
                // macOS's own ways in, not one of Flotilla's (the owner, 9 October) — `HostConnect`.
                // One above the other, each with Apple's guide to turning it on behind a ? (the owner).
                if let fingerprint {
                    HStack(spacing: 8) {
                        Text("Connect as").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField(facts?.loginUser ?? "user name", text: connectAsBinding)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 180)
                    }
                    let reachable = HostConnect.address(model, fingerprint) != nil
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(HostConnect.Kind.allCases, id: \.self) { kind in
                            HStack(spacing: 6) {
                                Button(kind.title) { HostConnect.open(kind, model, fingerprint) }
                                    .controlSize(.small)
                                    .frame(minWidth: 210, alignment: .leading)
                                    .disabled(!reachable)
                                guideButton(kind)
                            }
                        }
                    }
                    // What the ? icons are, for anyone who has not hovered one (the owner, 10 October).
                    Label("Click a ? to read Apple's guide to turning that on.", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            card("Power") {
                row("Power source", powerSource)
                row("Sleeps after", facts?.power?.sleepMinutes.map(Self.minutes) ?? "—")
                row("Display sleeps after", facts?.power?.displaySleepMinutes.map(Self.minutes) ?? "—")
                row("Wake for network access", onOff(facts?.power?.wakeOnNetwork))
                row("Power Nap", onOff(facts?.power?.powerNap))
                if let restart = facts?.power?.autoRestart { row("Restart after power failure", onOff(restart)) }
                if let awake = facts?.power?.sleepPreventedBy, !awake.isEmpty {
                    row("Kept awake by", awake.joined(separator: ", "))
                }
            }
        }
        if facts?.readAt == nil && !host.isLocal {
            Text("This host's Flotilla is older than this page, so it reports only its hardware. Update it to see the rest.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Flotilla

    @ViewBuilder
    private var flotillaTab: some View {
        grid {
            card("Flotilla") {
                row("Version", host.isLocal ? HostModeController.appVersion : (live?.appVersion ?? "—"))
                row("Installed at", facts?.appPath ?? "—", monospaced: true)
                row("Installed by", facts?.appOwnedByRoot.map { $0 ? "Installer package (owned by the system)" : "Copied by a person" } ?? "—")
                row("Role", roleText)
            }
            card("Flotilla Helper") {
                row("State", helperText)
                row("Version", facts?.helperVersion.map(String.init) ?? "—")
                if host.isLocal {
                    Button("Open Settings ▸ Advanced") { go(.settings) }.controlSize(.small)
                }
            }
            card("As a host") {
                row("Accepts updates from its admin", onOff(facts?.acceptsAdminUpdates))
                row("Installs container by itself", onOff(facts?.installsContainerItself))
                row("Kernel installed", facts?.kernelInstalled.map { $0 ? "Yes" : "No" } ?? "—")
            }
            card(host.isLocal ? "This Mac's identity" : "Pairing") {
                if let peer {
                    row("Fingerprint", HostModePane.shortFingerprint(peer.fingerprint), monospaced: true)
                    row("Joined by", peer.method == .enrolmentKey ? "Fleet enrolment key" : "Pairing code")
                    row("Enrolled", (peer.decidedAt ?? peer.requestedAt).formatted(date: .abbreviated, time: .shortened))
                } else if let identity = hostMode.identity {
                    row("Fingerprint", HostModePane.shortFingerprint(identity.fingerprint), monospaced: true)
                }
                row("Last inventory update", facts?.readAt.map(OverviewView.checkIn) ?? "—")
                row("Address block", model.addressBlock(for: host)?.description ?? "—", monospaced: true)
                row("DNS zone", model.fleetZones[host] ?? "—", monospaced: true)
            }
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesTab: some View {
        grid {
            card("Flotilla") {
                row("Installed", host.isLocal ? HostModeController.appVersion : (live?.appVersion ?? "—"))
                if let fingerprint {
                    row("This Mac (admin) has", HostModeController.appVersion)
                    row("State", flotillaUpdateText(model.updateState(fingerprint)))
                    row("Automatic updates", model.autoUpdateHosts ? "On, one host at a time" : "Off")
                    if model.updateState(fingerprint) == .available {
                        Button("Update Now") {
                            Task { if let failure = await model.updateHost(fingerprint) { actionMessage = failure } }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else {
                    row("Updated by", model.updater.isRunning ? "Sparkle, from GitHub" : "Its admin Mac")
                    if model.updater.isRunning {
                        Button("Check for Updates…") { model.updater.checkForUpdates() }.controlSize(.small)
                    }
                }
            }
            card("container") {
                row("Installed", host.isLocal ? (model.localContainerVersion ?? "Not installed") : (live?.containerVersion ?? "—"))
                row("This Flotilla expects", ContainerRuntime.expectedVersion)
                row("Kernel", facts?.kernelInstalled.map { $0 ? "Installed" : "Not installed" } ?? "—")
                runtimeAction
            }
        }
        .confirmationDialog("Upgrade container on \(name) to \(ContainerRuntime.expectedVersion)?",
                            isPresented: $confirmingRuntime, titleVisibility: .visible) {
            Button((live?.containersRunning ?? 0) > 0 ? "Stop Containers and Upgrade" : "Upgrade") {
                guard let fingerprint else { return }
                Task { if let failure = await model.setUpRuntime(on: fingerprint) { actionMessage = failure } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let running = live?.containersRunning ?? 0
            Text("\(name) downloads Apple's container installer, and its Flotilla Helper installs it after checking it is Apple's. "
                 + (running > 0 ? "container restarts there, which stops the \(running) running container\(running == 1 ? "" : "s")." : "Nothing is running there."))
        }
    }

    @ViewBuilder
    private var runtimeAction: some View {
        if let fingerprint {
            switch model.hostRuntimeState(fingerprint) {
            case .behind, .missing:
                Button(model.hostRuntimeState(fingerprint) == .missing ? "Install…" : "Upgrade…") { confirmingRuntime = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .working:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Setting up…").font(.caption) }
            default:
                EmptyView()
            }
        } else if model.needsContainerInstall {
            Button("Download and Install container \(ContainerRuntime.expectedVersion)") {
                Task { await model.installContainerInteractively() }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        } else if facts?.kernelInstalled == false {
            Button("Download Kernel") { Task { await model.installKernel() } }.controlSize(.small)
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activityTab: some View {
        let events = model.activity.filter { event in
            event.subject == name || (host.isLocal && (event.kind == .runtime || event.subject == "Flotilla"))
        }
        DetailCard(title: "What happened on \(name)", minHeight: nil) {
            if events.isEmpty {
                Text("Nothing has happened to this Mac since Flotilla started. Updates, pairing, container installs and "
                     + "runtime starts and stops appear here as they happen.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(events.prefix(100)) { event in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.color(forEventEndingIn: event.to)).frame(width: 6, height: 6)
                        Text(event.summary).font(.system(size: 12, weight: .medium))
                        Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Text(event.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    /// On, Off or "—", and on This Mac's own page — where there are no connect buttons — the guide.
    private func serviceRow(_ label: String, _ on: Bool?, _ kind: HostConnect.Kind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            row(label, onOff(on))
            if host.isLocal { guideButton(kind) }
        }
    }

    /// A question mark that opens Apple's guide; its tooltip names the guide.
    private func guideButton(_ kind: HostConnect.Kind) -> some View {
        Button { NSWorkspace.shared.open(kind.guide) } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Apple: \(kind.guideTitle)")
        .accessibilityLabel("Apple: \(kind.guideTitle)")
    }


    /// What the admin typed for this host in Connect as — kept by `HostConnect`, per host.
    @State private var connectAsRevision = 0

    private var connectAsBinding: Binding<String> {
        Binding(get: { _ = connectAsRevision; return fingerprint.map(HostConnect.typedUser) ?? "" },
                set: { value in
                    guard let fingerprint else { return }
                    HostConnect.setTypedUser(value, for: fingerprint)
                    connectAsRevision += 1
                })
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                            GridItem(.flexible(), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) { content() }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailCard(title: title, minHeight: 112, content: content)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .multilineTextAlignment(.trailing)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }

    /// A count that opens its section.
    private func link(_ label: String, _ value: String, _ section: Section) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(value) { go(section) }
                .buttonStyle(.plain).foregroundStyle(Theme.link)
                .font(.system(size: 12).monospacedDigit())
                .help("Open \(label)")
        }
    }

    private var counts: (containers: String, images: String, volumes: String, networks: String, machines: String) {
        if host.isLocal {
            let running = model.containers.filter(AppModel.isRunning).count
            return ("\(running) running of \(model.containers.count)", "\(model.images.count)",
                    "\(model.volumes.count)", "\(model.networks.count)", "\(model.machines.count)")
        }
        guard let fingerprint else { return ("—", "—", "—", "—", "—") }
        let containers = hostMode.fleetContainers.first { $0.host.fingerprint == fingerprint }?.snapshot.items
        let count = { (items: [Any]?) in items.map { "\($0.count)" } ?? "—" }
        return (containers.map { "\($0.filter(AppModel.isRunning).count) running of \($0.count)" } ?? "—",
                count(hostMode.fleetImages.first { $0.host.fingerprint == fingerprint }?.snapshot.items),
                count(hostMode.fleetVolumes.first { $0.host.fingerprint == fingerprint }?.snapshot.items),
                count(hostMode.fleetNetworks.first { $0.host.fingerprint == fingerprint }?.snapshot.items),
                live?.machines.map(String.init) ?? "—")
    }

    private var stateText: String {
        if host.isLocal { return RuntimeStatus.describe(model.preflight).title }
        switch live?.state {
        case .connected?: return "Connected"
        case .failed(let why)?:
            if let fingerprint, model.hostMissingContainer(fingerprint) { return "container isn't installed" }
            return "Not answering — \(why)"
        case .checking?, nil: return "Checking…"
        }
    }

    private var stateColor: Color {
        if host.isLocal { return model.runtimeUsable ? Theme.online : Theme.warning }
        switch live?.state {
        case .connected?: return Theme.online
        case .failed?:
            if let fingerprint, model.hostMissingContainer(fingerprint) { return Theme.warning }
            return Theme.danger
        default: return .secondary
        }
    }

    private var lastCheckIn: String {
        if host.isLocal { return model.lastRefresh.map(OverviewView.checkIn) ?? "—" }
        return peer?.lastSeen.map(OverviewView.checkIn) ?? "—"
    }

    private var containerState: String {
        if host.isLocal { return RuntimeStatus.describe(model.preflight).title }
        return live?.containerVersion.map { "\($0), answering" } ?? "—"
    }

    private var diskText: String {
        guard let total = facts?.diskTotalBytes, total > 0 else { return "—" }
        let free = facts?.diskFreeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free of " } ?? ""
        return free + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var roleText: String {
        guard let role = facts?.role.flatMap(RunMode.init(rawValue:)) else { return "—" }
        return role.title
    }

    private var helperText: String {
        switch facts?.helper {
        case .enabled?: "On"
        case .awaitingApproval?: "Waiting to be switched on in Login Items"
        case .notInstalled?: "Not installed"
        case .unavailable?: "Not available in this build"
        case nil: "—"
        }
    }

    private var powerSource: String {
        guard let facts, facts.hasBattery != nil else { return "—" }
        guard facts.hasBattery == true else { return "Power adapter (no battery)" }
        let charge = facts.batteryPercent.map { " · battery \($0)%" } ?? ""
        return (facts.onBattery == true ? "Battery" : "Power adapter") + charge
    }

    private func flotillaUpdateText(_ state: AppModel.HostUpdateState) -> String {
        switch state {
        case .current: "Up to date"
        case .ahead: "Newer than This Mac"
        case .unknown: "Not known yet"
        case .available: "An update is available"
        case .manualOnly: "Too old to update from here — install by hand"
        case .updating: "Updating…"
        case .failed(let why): "Failed: \(why)"
        }
    }

    private func onOff(_ value: Bool?) -> String { value.map { $0 ? "On" : "Off" } ?? "—" }

    private static func minutes(_ value: Int) -> String { value == 0 ? "Never" : "\(value) min" }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }
}
