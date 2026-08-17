import SwiftUI
import FlotillaCore

/// The menu-bar popover: **a glance, not the product**.
///
/// Rebuilt to `research/review/mockups/menubar.html`. The previous version had the right
/// principles in its comments and almost none of them on screen: a title, a bare list of
/// names with the word "running" beside each, and three word-buttons in a row. What the
/// mockup argues for, and what this now does:
///
/// - **Fixed section order** — rollup, This Mac, Fleet, Needs attention, actions. The mockup
///   cites Tailscale's own post-mortem on their flat list; sectioning was the fix.
/// - **Every row is name + image + port**, never a bare identifier. OrbStack #691: users
///   could not tell rows apart when the primary label was generated.
/// - **Status is dot + glyph + text**, never colour alone. Podman filed #12908 against
///   themselves for exactly this.
/// - **Inline one-tap start/stop** on each row, so the common action does not need the window.
/// - **Quit says what it does to your containers.** `research/FEATURES.md` calls Docker
///   Desktop's ambiguous Quit its most-cited UX failure.
/// - **No text entry, no confirmations.** A popover dismisses on an outside click, so anything
///   destructive or multi-step escalates to the window.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The mockup's width. Wider than the old 320 because rows now carry two lines and a
    /// trailing control, and the whole point is that names are not truncated into ambiguity.
    private let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rollup
            separator

            switch model.state {
            case .idle, .loading:
                message("Loading…", systemImage: "hourglass", tint: .secondary)
            case .unavailable(let reason), .failed(let reason):
                // Never render an empty list as if the fleet were simply idle — an
                // unreachable runtime and a fleet with no containers look identical
                // otherwise, and that is exactly the failure the offline-detection bug
                // taught us to avoid.
                message(reason, systemImage: "exclamationmark.triangle", tint: Theme.warning)
            case .loaded where model.containers.isEmpty:
                message("No containers on this Mac", systemImage: "tray", tint: .secondary)
            case .loaded:
                needsAttention
            }

            separator
            actions
        }
        .frame(width: width)
        .padding(.vertical, 6)
    }

    // MARK: Rollup

    /// The glanceable header: brand, total running, and a metered summary.
    ///
    /// The mockup pairs "This Mac" with "Fleet". Fleet is Phase 2, so rather than draw an
    /// empty meter beside a real one — which would read as *zero hosts online* rather than
    /// *no fleet yet* — the second column states the phase plainly.
    private var rollup: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Wordmark(size: 13).fixedSize()
                Spacer()
                // Says out loud that the glance is live.
                //
                // the owner asked whether the popover was frozen, and the honest answer — that
                // both poll tasks start in `AppModel.init` and are never cancelled, so it is
                // not — is not something a user can see. A timestamp is checkable: if it
                // stops advancing while the popover is open, it really has stalled. That is
                // worth more than any assurance, and it is the same "Updated …" convention
                // the section toolbars already use.
                if let last = model.lastRefresh {
                    Text(last.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .help("Last refreshed. This updates while the popover is open.")
                }
                if model.state == .loaded {
                    pill("\(model.running.count) running", dot: Theme.online, tint: Theme.online)
                }
            }

            // This Mac's own figures, on one line. The two-column "This Mac | Fleet" layout
            // spent half the width saying pairing is a Phase 2 feature; that is one quiet
            // sentence, not a column.
            HStack(spacing: 6) {
                Circle().fill(hostDot).frame(width: 7, height: 7)
                Text(model.hostLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(cpuAndMemory)
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }

            // A box per kind, each a menu.
            //
            // the owner asked for hover to open them. That is `NSMenu` behaviour and a
            // window-style `MenuBarExtra` does not get it — SwiftUI's `Menu` opens on click.
            // Once open, the per-item submenus *do* reveal on hover, so the second level
            // behaves as asked; the first needs a click, and pretending otherwise would mean
            // hand-rolling menu behaviour that fights the system's own.
            // Stacked, not side by side: each box carries three lines and a graph, and two of
            // those squeezed into half a popover's width had nowhere to put any of it.
            VStack(spacing: 6) {
                MenuKindBox(title: "Containers",
                            systemImage: ActivityKind.container.systemImage,
                            running: model.running.count,
                            total: model.containers.count,
                            loaded: model.state == .loaded,
                            detail: containerUsage,
                            history: aggregateCPUHistory) {
                    containerMenuItems
                }
                MenuKindBox(title: "Machines",
                            systemImage: ActivityKind.machine.systemImage,
                            running: model.machines.filter { MachinesView.isRunning($0) }.count,
                            total: model.machines.count,
                            loaded: model.machinesState == .loaded,
                            detail: machineAllocation,
                            // **No graph, deliberately.** `container machine list` reports the
                            // cpus and memory a machine was *allocated*, not what it is using —
                            // there is no per-machine sampling anywhere in the runtime. A line
                            // drawn from allocations would look like usage and be fiction, so
                            // the box shows the allocation as text and a running/total bar.
                            history: nil) {
                    machineMenuItems
                }
            }

            // The fleet note, as a line rather than a column.
            Text("Fleet: not paired — remote hosts arrive in Phase 2")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// One summary box: kind, running/stopped counts, a proportion bar, and a menu.
    ///
    /// `loaded` rather than inferring from a zero count: an unvisited section and an empty one
    /// must not look the same, which is the same unknown-versus-zero rule the sidebar counts
    /// and the CPU column already follow.
    @ViewBuilder
    private func kindBox<Content: View>(
        _ kind: ActivityKind, running: Int, total: Int, loaded: Bool,
        @ViewBuilder items: () -> Content
    ) -> some View {
        Menu {
            items()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: kind.systemImage).font(.system(size: 11))
                    Text(kind.title).font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)

                if loaded {
                    HStack(spacing: 8) {
                        countPip(running, "running", Theme.online)
                        countPip(total - running, "stopped", .secondary)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Theme.online)
                            .frame(width: total > 0
                                   ? CGFloat(running) / CGFloat(total) * geo.size.width : 0)
                    }
                }
                .frame(height: 4)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("\(kind.title): \(running) running of \(total)")
    }

    private func countPip(_ value: Int, _ label: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text("\(value) \(label)").font(.caption).monospacedDigit()
        }
    }

    /// The container list inside the hover popover.
    ///
    /// Plain views, not `Menu` items: the actions sit **on** each row as icon buttons, so
    /// starting something is one click from pointing at the box rather than three from opening
    /// nested menus. That is the iStat Menus shape the owner pointed at.
    @ViewBuilder
    private var containerMenuItems: some View {
        if model.containers.isEmpty {
            emptyPopoverNote("No containers on this Mac.")
        } else {
            ForEach(model.running + model.stopped) { container in
                containerPopoverRow(container)
            }
        }
    }

    @ViewBuilder
    private var machineMenuItems: some View {
        if model.machines.isEmpty {
            emptyPopoverNote("No machines. Containers each run in their own VM; a named machine "
                             + "is one you create and can shell into.")
        } else {
            ForEach(model.machines) { machine in
                machinePopoverRow(machine)
            }
        }
    }

    /// Extracted from the `ForEach` bodies: the ten-argument call inline inside a `ViewBuilder`
    /// defeated the type-checker outright ("unable to type-check this expression in reasonable
    /// time"), which is this project's usual signal that a view body is doing too much at once.
    private func containerPopoverRow(_ container: Container) -> some View {
        let running = AppModel.isRunning(container)
        return popoverRow(name: container.id,
                          subtitle: ContainerImage.shortReference(container.imageReference),
                          dot: container.stateColor,
                          running: running,
                          busy: model.busy.contains(container.id),
                          start: { Task { await model.perform(.start, on: container) } },
                          stop: { Task { await model.perform(.stop, on: container) } },
                          restart: { Task { await model.perform(.restart, on: container) } },
                          openDetail: { open(section: .containers) })
    }

    private func machinePopoverRow(_ machine: ContainerMachine) -> some View {
        let memory = ByteCountFormatter.string(fromByteCount: machine.memory, countStyle: .memory)
        return popoverRow(name: machine.id,
                          subtitle: "\(machine.cpus) vCPU · \(memory)",
                          dot: MachinesView.stateColor(machine),
                          running: MachinesView.isRunning(machine),
                          busy: model.busyMachines.contains(machine.id),
                          start: { Task { await model.perform(.start, on: machine) } },
                          stop: { Task { await model.perform(.stop, on: machine) } },
                          restart: { Task { await model.perform(.restart, on: machine) } },
                          openDetail: { open(section: .machines) })
    }

    private func emptyPopoverNote(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(maxWidth: 260, alignment: .leading)
    }

    /// One row in a box's popover: state, name over detail, then the actions.
    ///
    /// Start and Stop swap rather than both showing — offering Stop on a stopped thing is a
    /// control that does nothing, which is the failure this project keeps re-learning. Restart
    /// appears only while running, for the same reason.
    private func popoverRow(
        name: String, subtitle: String, dot: Color, running: Bool, busy: Bool,
        start: @escaping () -> Void, stop: @escaping () -> Void,
        restart: @escaping () -> Void, openDetail: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 10)
            IconActionButton(systemImage: running ? "stop.fill" : "play.fill",
                             label: running ? "Stop \(name)" : "Start \(name)",
                             help: running ? "Stop \(name)" : "Start \(name)",
                             busy: busy, action: running ? stop : start)
            IconActionButton(systemImage: "arrow.clockwise",
                             label: "Restart \(name)", help: "Restart \(name)",
                             busy: busy, disabled: !running, action: restart)
            IconActionButton(systemImage: "arrow.up.forward.square",
                             label: "Open \(name) in Flotilla",
                             help: "Open in Flotilla", action: openDetail)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
    }

    /// Measured, summed across running containers. Em dashes when nothing has been sampled yet.
    private var containerUsage: String {
        let cpus = model.running.compactMap { model.cpuPercent(for: $0.id) }
        let bytes = model.running.compactMap { model.memoryBytes(for: $0.id) }
        guard !cpus.isEmpty || !bytes.isEmpty else { return "CPU — · Memory —" }
        let cpu = cpus.isEmpty ? "—" : String(format: "%.0f%%", cpus.reduce(0, +))
        let memory = bytes.isEmpty
            ? "—"
            : ByteCountFormatter.string(fromByteCount: bytes.reduce(0, +), countStyle: .file)
        return "CPU \(cpu) · \(memory)"
    }

    /// **Allocated**, and the wording says so. This is what the machines were given, not what
    /// they are consuming — the runtime does not report the latter.
    private var machineAllocation: String {
        let running = model.machines.filter { MachinesView.isRunning($0) }
        guard !running.isEmpty else { return "nothing running" }
        let cpus = running.reduce(0) { $0 + $1.cpus }
        let memory = running.reduce(Int64(0)) { $0 + $1.memory }
        return "\(cpus) vCPU · "
            + ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)
            + " allocated"
    }

    /// Total container CPU over time, summed per sample.
    ///
    /// A sample is `nil` when *no* container reported a figure for it — the first reading has no
    /// previous sample to diff against — which `Sparkline` renders as a gap rather than a zero.
    private var aggregateCPUHistory: [Double?] {
        let histories = model.running.map { model.cpuHistory(for: $0.id) }
        guard let length = histories.map(\.count).max(), length > 1 else { return [] }
        return (0..<length).map { index in
            let sample = histories.compactMap { history -> Double? in
                let offset = history.count - length + index
                guard offset >= 0, offset < history.count else { return nil }
                return history[offset]
            }
            return sample.isEmpty ? nil : sample.reduce(0, +)
        }
    }

    private var hostDot: Color {
        switch model.state {
        case .loaded: Theme.online
        case .unavailable, .failed: Theme.danger
        case .idle, .loading: .secondary
        }
    }

    /// Real sampled figures, or an em dash. Never a zero standing in for "not measured yet" —
    /// the same rule the table's CPU column follows.
    private var cpuAndMemory: String {
        let cpus = model.running.compactMap { model.cpuPercent(for: $0.id) }
        let bytes = model.running.compactMap { model.memoryBytes(for: $0.id) }
        guard !cpus.isEmpty || !bytes.isEmpty else { return "CPU — · Memory —" }
        let cpu = cpus.isEmpty ? "—" : String(format: "%.0f%%", cpus.reduce(0, +))
        let mem = bytes.isEmpty
            ? "—"
            : ByteCountFormatter.string(fromByteCount: bytes.reduce(0, +), countStyle: .file)
        return "CPU \(cpu) · \(mem)"
    }

    // MARK: This Mac

    /// One container: state dot, a glyph that varies by *kind*, name over image-and-port, the
    /// CPU figure, and a one-tap start/stop.
    private func containerRow(_ container: Container) -> some View {
        let running = AppModel.isRunning(container)
        let busy = model.busy.contains(container.id)

        return HStack(spacing: 8) {
            Circle().fill(container.stateColor).frame(width: 8, height: 8)

            Image(systemName: Self.glyph(for: container))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.id)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: container))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if running, let cpu = model.cpuPercent(for: container.id) {
                Text(String(format: "%.0f%%", cpu))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            // Start and stop swap; they never both show. Offering Stop on a stopped
            // container would be a control that does nothing.
            Button {
                Task { await model.perform(running ? .stop : .start, on: container) }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 10))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(MenuRowStyle())
            .foregroundStyle(.secondary)
            .disabled(busy)
            .help(running ? "Stop \(container.id)" : "Start \(container.id)")
            .accessibilityLabel(running ? "Stop \(container.id)" : "Start \(container.id)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .opacity(running ? 1 : 0.72)
        // The whole row opens the container, matching the mockup's `<a class="pop-row">`.
        // `menuRowHighlight` rather than a bare `onTapGesture`: the gesture worked and looked
        // like nothing, which reads as a dead row.
        .menuRowHighlight { open() }
    }

    /// Name plus image and port — never the identifier alone. Falls back to the state word
    /// when a stopped container has no port to show, so the second line is never empty.
    private func subtitle(for container: Container) -> String {
        let image = ContainerImage.shortReference(container.imageReference)
        if let ports = container.portSummary { return "\(image) · \(ports)" }
        if AppModel.isRunning(container) { return image }
        return "\(image) · \(container.status.state.lowercased())"
    }

    /// A glyph that differs by what the container *is*, so rows are distinguishable at a
    /// glance and state is never carried by colour alone. Inferred from the image name, which
    /// is a guess — hence a generic box as the default rather than a wrong specific icon.
    private static func glyph(for container: Container) -> String {
        let image = container.imageReference.lowercased()
        if image.contains("nginx") || image.contains("caddy") || image.contains("httpd")
            || image.contains("traefik") { return "globe" }
        if image.contains("redis") || image.contains("memcached") { return "memorychip" }
        if image.contains("postgres") || image.contains("mysql") || image.contains("maria")
            || image.contains("mongo") { return "cylinder.split.1x2" }
        return "shippingbox"
    }

    // MARK: Needs attention

    /// The mockup's third section, and the one with the strongest argument behind it: things
    /// that are *wrong* get their own place rather than being left for you to spot among the
    /// healthy rows.
    ///
    /// In the mockup these are unreachable and untrusted hosts, which are Phase 2. The Phase 1
    /// equivalent is real and already on screen elsewhere: a container that **exited non-zero**
    /// or is **stuck restarting**. A clean stop is not a problem and is deliberately excluded —
    /// a section that cries wolf about every stopped container is one people learn to ignore.
    ///
    /// Renders nothing when nothing is wrong. An always-present "Needs attention (0)" heading
    /// is noise, and worse, it makes the section itself unremarkable.
    @ViewBuilder
    private var needsAttention: some View {
        let troubled = model.containers.filter(Self.needsAttention)
        if !troubled.isEmpty {
            separator
            sectionHead("Needs attention", systemImage: "exclamationmark.triangle", trailing: nil)
            ForEach(troubled) { container in
                containerRow(container)
            }
        }
    }

    /// Failure, not idleness. `exited (0)` is a job that finished and is excluded by the
    /// zero-check; `exited (137)` is one that was killed and is not.
    private static func needsAttention(_ container: Container) -> Bool {
        let state = container.status.state.lowercased()
        if state.contains("restart") || state.contains("dead") || state.contains("fail") {
            return true
        }
        guard state.contains("exit") else { return false }
        return !state.contains("(0)") && !state.contains(" 0")
    }

    // MARK: Actions

    /// The footer, with the shortcuts the mockup shows beside each item.
    ///
    /// The shortcuts are **bound**, not drawn. A printed "⌘O" that does nothing is a label
    /// pretending to be a feature, and this project has enough of those in its history. They
    /// are live while the popover has focus, which is precisely when they are on screen.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow("Open Flotilla", systemImage: "macwindow", key: "o") { open() }
            // Two rows, not a menu. The `Menu` version sat further left than its neighbours
            // because `.menuStyle(.borderlessButton)` discards the row padding — the
            // misalignment the owner spotted. Two `actionRow`s are aligned by construction, and
            // each says plainly what it makes; "New…" made you open it to find out.
            actionRow("Run Container…", systemImage: "plus", key: "n") {
                open(); model.requestRunSheet()
            }
            actionRow("New Machine…", systemImage: "server.rack", key: "m") {
                open(); model.requestMachineForm()
            }
            actionRow("Settings…", systemImage: "gearshape", key: ",") { open(section: .settings) }
            actionRow("Refresh", systemImage: "arrow.clockwise", key: "r") {
                Task { await model.reload() }
            }
            .disabled(model.state == .loading)

            separator

            actionRow("Quit Flotilla", systemImage: "power", key: "q",
                      // The sentence Docker Desktop is criticised for not having.
                      subtitle: "Containers keep running") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func actionRow(
        _ title: String, systemImage: String, key: KeyEquivalent,
        subtitle: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionRowLabel(title, systemImage: systemImage, key: key, subtitle: subtitle)
        }
        .buttonStyle(MenuRowStyle())
        .keyboardShortcut(key, modifiers: .command)
    }

    /// The row's contents, without the `Button`.
    ///
    /// Extracted so the "New…" menu can wear the identical label. A menu that looked slightly
    /// different from the rows either side of it would read as a different kind of thing, when
    /// it is the same kind of thing that happens to offer two destinations.
    private func actionRowLabel(
        _ title: String, systemImage: String, key: KeyEquivalent, subtitle: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            Text("⌘\(String(key.character).uppercased())")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .contentShape(.rect)
    }

    // MARK: Plumbing

    /// The popover holds focus, so the window will not come forward without an explicit
    /// activate — without it "Open Flotilla" appears to do nothing.
    private func open(section: Section? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let section { model.requestSection(section) }
        openWindow(id: "main")
    }

    private func sectionHead(_ title: String, systemImage: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11))
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 11)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private func pill(_ text: String, dot: Color, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            // Wrap rather than clip: a truncated diagnosis ("…is installed but unusable:
            // the c…") tells the user nothing they can act on.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
