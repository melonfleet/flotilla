import SwiftUI
import FlotillaCore

/// Overview — the fleet at a glance (the owner, 6 October). Numbers only: which hosts are
/// connected, what they hold in total, and what needs attention. Per-Mac charts and tables moved
/// to each host's landing page under Hosts.
///
/// Since Phase C the numbers are the fleet's: This Mac plus what each paired host last reported.
/// Groups, DNS domains, machines and clusters stay This Mac's until Phase D pushes them, and their
/// tiles say so once there is another Mac to confuse them with.
struct OverviewView: View {
    let model: AppModel
    let go: (Section) -> Void

    var body: some View {
        ScrollView {
            // Iris's order (8 October): is anything wrong, is anything ready to update, what does
            // the fleet hold, which Macs make it up.
            VStack(alignment: .leading, spacing: 22) {
                // Setting up `container` comes first and says what is happening (beta 2's test):
                // the same banner This Mac's page has.
                let setupBanner = model.runtimeSetup != nil || model.needsContainerInstall
                if setupBanner { RuntimeBanner(model: model) }
                // "Nothing needs attention" under a banner saying container isn't installed contradicts
                // it (the owner, on Tahoe, 10 October): with the banner up, the box shows only when
                // something else needs attention too.
                if !(setupBanner && model.attentionItems.isEmpty) { attention }
                getStarted
                updates
                totals
                hosts
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // This Mac's Flotilla and build, bottom-right, as Docker Desktop's corner (the owner, 10
        // October): one glance at a host says whether its update has landed. On an admin Mac it is
        // also Check for Updates. A strip of its own, so it never sits over the hosts table.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                VersionBadge(model: model)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        // The totals read lists the poll refreshes only every sixth tick or on a section's visit,
        // so Overview loads them itself rather than showing zeros on a fresh launch.
        // Paired hosts are asked alongside, not first: a host that is slow to answer must not hold
        // This Mac's numbers at zero.
        .task {
            async let hosts: Void = model.hostMode.refreshLiveStatus()
            await model.refreshImages()
            await model.refreshVolumes()
            await model.refreshNetworks()
            await model.refreshMachines()
            await model.refreshClusters()
            await model.refreshDNS()
            await hosts
        }
    }

    // MARK: Hosts

    /// One row per Mac: This Mac, then every paired host — a table, so thirty minis read as well as
    /// three (the owner, 8 October). The name opens that Mac's page under Hosts.
    struct HostLine: Identifiable {
        /// `HostRow`'s id: This Mac's fixed one, or a host's fingerprint.
        let id: String
        let name: String
        let state: String
        let color: Color
        let connected: Bool
        let facts: HostFacts?
        let model: String?
        let macOS: String?
        let flotilla: String?
        let container: String?
        /// When it last answered this Mac — kept through failures, so a silent host says since when.
        let lastCheckIn: Date?
    }

    /// Which columns show, kept per window across launches. Host stays: it is the row's name.
    @SceneStorage("overviewHostColumns") private var hostColumns = TableColumnCustomization<HostLine>()
    @State private var showingHostColumns = false

    private static let hostColumnSpecs: [(id: String, title: String)] = [
        ("tags", "Tags"), ("model", "Model"), ("cpu", "CPU"), ("memory", "Memory"), ("disk", "Disk"), ("macos", "macOS"),
        ("flotilla", "Flotilla"), ("container", "container"), ("checkin", "Last Check-in"),
    ]

    private var hostLines: [HostLine] {
        let local = model.localHostFacts()
        var lines = [HostLine(id: HostRow.thisMacID, name: HostModeController.computerName,
                              state: model.runtimeUsable ? "connected" : "runtime unavailable",
                              color: model.runtimeUsable ? Theme.online : Theme.warning,
                              connected: model.runtimeUsable, facts: local,
                              model: local.model, macOS: local.macOSVersion,
                              flotilla: HostModeController.appVersion, container: model.localContainerVersion,
                              lastCheckIn: model.lastRefresh)]
        for peer in model.hostMode.trustedHosts {
            let status = model.hostMode.live[peer.fingerprint]
            let (state, color, connected): (String, Color, Bool) = switch status?.state {
            case .connected?: ("connected", Theme.online, true)
            case .failed?: model.hostMissingContainer(peer.fingerprint)
                ? ("container isn't installed", Theme.warning, false)
                : ("not answering", Theme.danger, false)
            case .checking?, nil: ("checking…", Color.secondary, false)
            }
            let facts = model.hostMode.facts[peer.fingerprint]
            lines.append(HostLine(id: peer.fingerprint.hex, name: peer.displayName,
                                  state: state, color: color, connected: connected, facts: facts,
                                  model: facts?.model ?? peer.details.model,
                                  macOS: facts?.macOSVersion ?? peer.details.macOSVersion,
                                  flotilla: status?.appVersion, container: status?.containerVersion,
                                  lastCheckIn: peer.lastSeen))
        }
        return lines
    }

    private var hosts: some View {
        let lines = hostLines
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hosts").font(.headline)
                Spacer()
                Text("\(lines.filter(\.connected).count) of \(lines.count) connected")
                    .font(.caption).foregroundStyle(.secondary)
                IconActionButton(systemImage: "rectangle.split.3x1", label: "Columns",
                                 help: "Show or hide columns") { showingHostColumns.toggle() }
                    .popover(isPresented: $showingHostColumns, arrowEdge: .bottom) {
                        ColumnVisibilityList(columns: Self.hostColumnSpecs, customization: $hostColumns)
                    }
            }
            hostTable(lines)
                // As Utilisation's card: the table draws its own header and insets.
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    /// Up to ten rows, then it scrolls — the same height whatever the fleet, past ten.
    private func hostTable(_ lines: [HostLine]) -> some View {
        SwiftUI.Table(lines, columnCustomization: $hostColumns) {
            TableColumn("Host") { line in
                HStack(spacing: 7) {
                    Circle().fill(line.color).frame(width: 8, height: 8)
                        .help(line.state)
                        .accessibilityLabel(line.state)
                    Button(line.name) { model.requestDetail(kind: .host, subject: line.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.link)
                        .lineLimit(1)
                        .help("Open \(line.name)")
                }
            }
            .width(min: 130, ideal: 170)
            .customizationID("host")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Tags") { line in
                TagPillRow(tags: model.tags.tags(on: .host, line.id), compact: true,
                           builtIns: BuiltInHostTag.tags(isThisMac: line.id == HostRow.thisMacID, role: line.facts?.role))
            }
            .width(min: 90, ideal: 150)
            .customizationID("tags")
            TableColumn("Model") { line in
                Text(line.model ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 100)
            .customizationID("model")
            TableColumn("CPU") { line in
                Text(Self.chip(line.facts)).lineLimit(1)
                    .help(Self.chip(line.facts))
            }
            .width(min: 110, ideal: 140)
            .customizationID("cpu")
            TableColumn("Memory") { line in
                Text(Self.memory(line.facts)).monospacedDigit().lineLimit(1)
            }
            .width(min: 60, ideal: 70)
            .customizationID("memory")
            TableColumn("Disk") { line in
                Text(Self.disk(line.facts)).monospacedDigit().lineLimit(1)
                    .help("The startup disk's capacity")
            }
            .width(min: 70, ideal: 80)
            .customizationID("disk")
            TableColumn("macOS") { line in
                Text(line.macOS ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            .customizationID("macos")
            TableColumn("Flotilla") { line in
                Text(line.flotilla ?? "—").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .width(min: 110, ideal: 170)
            .customizationID("flotilla")
            TableColumn("container") { line in
                Text(line.container ?? "—").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .help("Version of Apple's container runtime")
            }
            .width(min: 60, ideal: 70)
            .customizationID("container")
            TableColumn("Last Check-in") { line in
                Group {
                    if let date = line.lastCheckIn {
                        Text(Self.checkIn(date)).help(date.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("—")
                    }
                }
                .foregroundStyle(line.connected ? Color.secondary : Theme.warning)
                .monospacedDigit().lineLimit(1)
            }
            .width(min: 80, ideal: 100)
            .customizationID("checkin")
        }
        // 24 a row plus the header and its rule, measured off the rendered table.
        .frame(height: CGFloat(min(max(lines.count, 1), 10)) * 24 + 40)
        // Only a fleet past ten rows scrolls; below that a scroller is a promise of rows not there.
        .scrollIndicators(lines.count > 10 ? .automatic : .never)
    }

    /// `just now`, `40 sec ago`, `12 min ago` — re-read on each poll, which redraws Overview.
    static func checkIn(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 5 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    /// `M1 · 8 cores`, `M3 Max · 4 vCores`. No "Apple" — every Mac's is — and a virtual Mac says
    /// so in its cores rather than a "(Virtual)" in the name: shorter, so the table has room (the
    /// owner, 8 October).
    static func chip(_ facts: HostFacts?) -> String {
        guard let facts else { return "—" }
        var name = facts.chip?.trimmingCharacters(in: .whitespaces)
        if let current = name, current.hasPrefix("Apple ") { name = String(current.dropFirst("Apple ".count)) }
        let virtual = name?.localizedCaseInsensitiveContains("(Virtual)") ?? false
        if virtual {
            name = name?.replacingOccurrences(of: "(Virtual)", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }
        let cores = facts.cores.map { "\($0) \(virtual ? "vCores" : "cores")" }
        let text = [name, cores].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? "—" : text
    }

    /// What the Mac has installed — `64 GB`, `8 GB` — and nothing about how much is in use: this is
    /// an overview (the owner, 8 October). Binary units, as Apple counts RAM.
    static func memory(_ facts: HostFacts?) -> String {
        guard let total = facts?.memoryTotalBytes, total > 0 else { return "—" }
        return "\(Int((Double(total) / Double(1 << 30)).rounded())) GB"
    }

    /// The startup disk's size — `995 GB`, `2 TB` — without free space, for the same reason.
    /// Decimal units, as Finder counts disks.
    static func disk(_ facts: HostFacts?) -> String {
        guard let total = facts?.diskTotalBytes, total > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: total)
    }

    // MARK: Totals

    private var totals: some View {
        let fleet = model.hostMode
        // This Mac's lists plus each paired host's last answer — the same rows the sections list.
        let containers = model.containers + fleet.fleetContainers.flatMap(\.snapshot.items)
        let running = containers.filter(AppModel.isRunning).count
        let images = model.images.count + fleet.fleetImages.reduce(0) { $0 + $1.snapshot.items.count }
        let volumes = model.volumes.count + fleet.fleetVolumes.reduce(0) { $0 + $1.snapshot.items.count }
        let networks = model.networks.count + fleet.fleetNetworks.reduce(0) { $0 + $1.snapshot.items.count }
        // "on 3 Macs" where the number spans the fleet; "on This Mac" where it does not yet.
        let macs = 1 + fleet.trustedHosts.count
        let across = macs > 1 ? " · \(macs) Macs" : ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("Across all hosts").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                tile("Containers", "\(running)", detail: "running of \(containers.count)" + across, .containers)
                tile("Images", "\(images)", detail: "stored" + across, .images)
                tile("Volumes", "\(volumes)", detail: String(across.dropFirst(3)), .volumes)
                tile("Networks", "\(networks)", detail: String(across.dropFirst(3)), .networks)
            }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String, _ section: Section) -> some View {
        Button { go(section) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: section.systemImage)
                    .font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Open \(section.title)")
    }

    // MARK: Attention

    /// What needs the owner, first, in a box like the others (the owner, 9 October) — a quiet
    /// grey line on the page background read as a footnote. When nothing does, one line that says so.
    private var attention: some View {
        attentionContent
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private var attentionContent: some View {
        let attentionItems = model.attentionItems
        if attentionItems.isEmpty {
            let hosts = model.hostMode.trustedHosts.count
            Label(hosts == 0 ? "Nothing needs attention" : "Nothing needs attention on \(hosts + 1) Macs",
                  systemImage: "checkmark.circle")
                .foregroundStyle(Theme.online)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(attentionItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Button { go(item.section) } label: {
                            // Up to three lines, then the rest on hover: one line cut each message off
                            // at the window's edge (10 October). A line limit, not a fixed size — see
                            // CLAUDE.md on fixedSize in a screen's top band.
                            Label(item.text, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.warning)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(item.text)
                        if let fix = item.fix {
                            Button(fix.title) { fix.run() }
                                .controlSize(.small)
                                .disabled(model.startingRuntime)
                        }
                    }
                }
            }
        }
    }

    /// The first things to do (Iris, 8 October; Add Host, the owner). Shown once `container` is
    /// usable — until then the top line is its setup — and **until the owner closes it** with the X
    /// (the owner, 9 October), which records `getStartedDismissed` in the preferences domain.
    /// Nothing else hides it: having containers already does not.
    @AppStorage("getStartedDismissed") private var getStartedDismissed = false

    @ViewBuilder
    private var getStarted: some View {
        if !getStartedDismissed, model.runtimeUsable, model.state == .loaded {
            // A card of its own, centred, with the first step in colour (the owner, beta 2's
            // test): left-aligned plain buttons under a small heading read as a footnote.
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.info)
                VStack(spacing: 4) {
                    Text("Get started").font(.title2.weight(.semibold))
                    Text("Run your first container, bring in an image, or add another Mac.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button { model.requestRunSheet() } label: {
                        Label("Run a Container\u{2026}", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.requestPullForm() } label: {
                        Label("Pull Image\u{2026}", systemImage: "arrow.down.circle")
                    }
                    if model.hostMode.isAdmin {
                        Button { model.requestAddHost() } label: {
                            Label("Add Host\u{2026}", systemImage: "desktopcomputer")
                        }
                    }
                    Button { model.requestSuggestions(.containers) } label: {
                        Label("Try a Suggested Stack\u{2026}", systemImage: "square.grid.2x2")
                    }
                }
                .controlSize(.large)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            // Closed for good, like after the first container (the owner, 9 October).
            .overlay(alignment: .topTrailing) {
                Button { getStartedDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("Close Get started")
                .accessibilityLabel("Close Get started")
            }
        }
    }

    /// What can be updated: Flotilla on hosts behind This Mac, and `container` on hosts behind the
    /// version Flotilla expects — one row each however many hosts, with the same actions as Hosts.
    /// Shown only when there is something; an update is work to do, not a fault.
    @State private var confirmingContainerUpgrade = false
    @State private var upgradeFailures: [String] = []

    @ViewBuilder
    private var updates: some View {
        let flotillaWaiting = model.hostsWithUpdates
        let flotillaUnderWay = model.hostMode.updating.count
        let containerWaiting = model.hostsWithContainerUpgrades
        let containerUnderWay = model.hostMode.settingUpRuntime.count
        if !flotillaWaiting.isEmpty || flotillaUnderWay > 0 || !containerWaiting.isEmpty || containerUnderWay > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates").font(.headline)
                VStack(spacing: 0) {
                    if !flotillaWaiting.isEmpty || flotillaUnderWay > 0 {
                        updateRow(underWay: flotillaUnderWay > 0
                                      ? "Updating Flotilla on \(Self.hosts(flotillaUnderWay))\u{2026}" : nil,
                                  text: "\(Self.hosts(flotillaWaiting.count)) \(flotillaWaiting.count == 1 ? "runs" : "run") "
                                      + "an older Flotilla than This Mac (\(HostModeController.appVersion)).") {
                            if !flotillaWaiting.isEmpty {
                                Button("Update \(Self.hosts(flotillaWaiting.count, capitalised: true)) Now") {
                                    Task { await model.rollOutUpdates(automatic: false) }
                                }
                                .disabled(model.hostMode.rollingOut)
                                .help(model.hostMode.rollingOut ? "An update is already running" : "")
                            }
                        }
                    }
                    if (!flotillaWaiting.isEmpty || flotillaUnderWay > 0) && (!containerWaiting.isEmpty || containerUnderWay > 0) {
                        Divider()
                    }
                    if !containerWaiting.isEmpty || containerUnderWay > 0 {
                        updateRow(underWay: containerUnderWay > 0
                                      ? "Upgrading container on \(Self.hosts(containerUnderWay))\u{2026}" : nil,
                                  text: "\(Self.hosts(containerWaiting.count)) can upgrade container to "
                                      + "\(ContainerRuntime.expectedVersion).") {
                            if !containerWaiting.isEmpty {
                                Button("Upgrade \(Self.hosts(containerWaiting.count, capitalised: true))\u{2026}") {
                                    confirmingContainerUpgrade = true
                                }
                                .disabled(containerUnderWay > 0)
                                .help(containerUnderWay > 0 ? "An upgrade is already running" : "")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
            }
            .confirmationDialog(containerUpgradeQuestion(containerWaiting),
                                isPresented: $confirmingContainerUpgrade, titleVisibility: .visible) {
                Button(model.runningContainers(on: containerWaiting) > 0 ? "Stop Containers and Upgrade" : "Upgrade") {
                    Task {
                        let failures = await model.upgradeContainer(on: containerWaiting)
                        if !failures.isEmpty { upgradeFailures = failures }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(containerUpgradeMessage(containerWaiting))
            }
            .alert("container wasn't upgraded everywhere",
                   isPresented: Binding(get: { !upgradeFailures.isEmpty }, set: { if !$0 { upgradeFailures = [] } })) {
                Button("OK") { upgradeFailures = [] }
            } message: {
                Text(upgradeFailures.joined(separator: "\n"))
            }
        }
    }

    private func updateRow(underWay: String?, text: String,
                           @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.info)
            if let underWay {
                Text(underWay)
                ProgressView().controlSize(.small)
            } else {
                Text(text)
            }
            Spacer()
            action()
        }
        .padding(12)
    }

    private func containerUpgradeQuestion(_ hosts: [PeerFingerprint]) -> String {
        "Upgrade container on \(Self.hosts(hosts.count)) to \(ContainerRuntime.expectedVersion)?"
    }

    /// Hosts' wording for one host, for several: what each does, and what stops, in all.
    private func containerUpgradeMessage(_ hosts: [PeerFingerprint]) -> String {
        let running = model.runningContainers(on: hosts)
        var text = "Each host downloads Apple's container installer, and its Flotilla Helper installs it after "
            + "checking it is Apple's. One host at a time. container restarts on each, "
        text += running > 0
            ? "which stops the \(running) running container\(running == 1 ? "" : "s") on them in all; start them again afterwards. "
            : "and nothing is running on them. "
        return text + "Then the recommended kernel, if one has none."
    }

    private static func hosts(_ count: Int, capitalised: Bool = false) -> String {
        "\(count) \(capitalised ? "Host" : "host")\(count == 1 ? "" : "s")"
    }
}
