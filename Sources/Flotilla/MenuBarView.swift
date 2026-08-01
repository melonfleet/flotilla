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
                thisMac
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
                if model.state == .loaded {
                    pill("\(model.running.count) running", dot: Theme.online, tint: Theme.online)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                metric(
                    title: model.hostLabel,
                    trailing: model.state == .loaded ? "\(model.running.count) running" : "—",
                    fraction: runningFraction,
                    detail: cpuAndMemory
                )

                Divider().frame(height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Fleet").font(.caption)
                        Spacer()
                        Text("not paired").font(.caption).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    Text("Remote hosts arrive in Phase 2")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var runningFraction: Double {
        guard !model.containers.isEmpty else { return 0 }
        return Double(model.running.count) / Double(model.containers.count)
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

    private func metric(title: String, trailing: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(trailing).font(.caption).monospacedDigit()
            }
            .foregroundStyle(.secondary)

            // A plain bar, not a `ProgressView`: this is a proportion of a known total, and
            // the stock indicator styles it as an operation in progress.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Theme.online)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .frame(height: 4)

            Text(detail)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: This Mac

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHead("This Mac", systemImage: "laptopcomputer", trailing: model.hostName)

            // Running first, then stopped, and capped: the popover is a glance. The overflow
            // row says how many are hidden rather than silently truncating.
            ForEach(visible) { container in
                containerRow(container)
            }
            if model.containers.count > Self.maxRows {
                Button {
                    open()
                } label: {
                    Text("Show all \(model.containers.count) in Flotilla")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let maxRows = 6

    private var visible: [Container] {
        (model.running + model.stopped).prefix(Self.maxRows).map { $0 }
    }

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
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(busy)
            .help(running ? "Stop \(container.id)" : "Start \(container.id)")
            .accessibilityLabel(running ? "Stop \(container.id)" : "Start \(container.id)")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .opacity(running ? 1 : 0.72)
        // The whole row opens the container, matching the mockup's `<a class="pop-row">`.
        .contentShape(.rect)
        .onTapGesture { open() }
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
            actionRow("Run…", systemImage: "plus", key: "n") { open(); model.requestRunSheet() }
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
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
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
