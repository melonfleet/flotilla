import SwiftUI
import SwiftTerm
import FlotillaCore

/// Which pane of the machine detail is showing.
///
/// Four, not six. The containers set has Processes, Files and Configuration; a machine has no
/// `machine ps`, no `machine copy` and no per-machine config file, so those tabs would be
/// controls with nothing behind them. `Settings` replaces them because `machine set` is real.
enum MachineDetailTab: String, CaseIterable, Identifiable {
    // Overview, Terminal, Logs, Inspect in the same order as the container detail, so the two
    // screens do not shuffle the tabs under you. Settings is the one only a machine has — `machine
    // set` is real, where a container cannot be changed after creation — so it comes last, behind
    // a divider.
    case overview = "Overview"
    case shell = "Terminal"
    case logs = "Logs"
    case inspect = "Inspect"
    case settings = "Settings"
    var id: Self { self }

    /// True for the four tabs the container detail also has. See `DetailTab.isShared`.
    var isShared: Bool {
        switch self {
        case .overview, .shell, .logs, .inspect: true
        case .settings: false
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .shell: "terminal"
        case .logs: "doc.text"
        case .settings: "slider.horizontal.3"
        case .inspect: "curlybraces"
        }
    }
}

/// Detail for one machine, embedded in the window like the container detail it mirrors.
struct MachineDetailView: View {
    let model: AppModel
    let machine: ContainerMachine

    @State private var tab: MachineDetailTab

    /// The `machine inspect` record, loaded on appear. `machine` itself comes from
    /// `machine list` and is missing image, start time, home-mount and platform.
    @State private var enriched: ContainerMachine?

    /// What the Overview reads. Falls back to the list row, so the screen is complete
    /// immediately and simply gains detail a moment later rather than flashing empty.
    private var detail: ContainerMachine { enriched ?? machine }

    /// Seeded from the model so returning to a machine returns you to the tab you left it on,
    /// and defaulting to Overview the first time this run — same rule as containers, and stored
    /// in memory only so a restart forgets.
    /// A tab the caller explicitly asked for — "Edit Settings…" from the row menu — which wins
    /// over the remembered one. Nil means "wherever this machine was left".
    let requestedTab: MachineDetailTab?

    init(model: AppModel, machine: ContainerMachine, requestedTab: MachineDetailTab? = nil) {
        self.model = model
        self.machine = machine
        self.requestedTab = requestedTab
        _tab = State(initialValue: requestedTab ?? model.lastMachineTab[machine.id] ?? .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch tab {
                case .overview: overview
                case .shell: MachineShellTab(model: model, machine: machine)
                case .logs: LogViewer(model: model, source: .machine(machine.id))
                // `detail`, not `machine`. The list row has no `homeMount` at all — verified
                // against `machine ls --format json`, which returns eight fields and not that one —
                // so this tab was seeding its picker from nil and defaulting the display to
                // "Read-write" on a machine this Mac reports as `ro`. It showed a setting the
                // machine did not have, on the one control here that grants filesystem access.
                case .settings: MachineSettingsTab(model: model, machine: detail)
                case .inspect: MachineInspectTab(model: model, machine: machine)
                }
            }
            // `.topLeading`, not `.top`. SwiftUI's `.top` is *horizontally centred* and only
            // vertically top — which is why the Inspect tab's JSON sat as a floating block in
            // the middle of the pane instead of reading as a document from the top-left. It
            // applies to every tab here, so the one word fixes all of them.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: tab) { _, newTab in model.lastMachineTab[machine.id] = newTab }
        // `init`'s seed only applies when SwiftUI installs the view. Arriving here from a detail
        // that is already on screen skips it, which is how an explicit "open the Settings tab"
        // request got dropped. Keyed on both values so asking for the same tab on a different
        // machine still fires.
        .onChange(of: [machine.id, requestedTab?.rawValue ?? ""]) { _, _ in
            if let requestedTab { tab = requestedTab }
        }
        // Keyed on the id so stepping to the next machine reloads rather than showing the
        // previous machine's image and start time under the new machine's name.
        .task(id: machine.id) {
            enriched = nil
            enriched = await model.inspectMachine(machine.id)
        }
    }

    /// The same underline strip as the container detail, from the same stylesheet numbers.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(MachineDetailTab.allCases.enumerated()), id: \.element.id) { index, candidate in
                if index > 0, MachineDetailTab.allCases[index - 1].isShared, !candidate.isShared {
                    Divider().frame(height: 16).padding(.horizontal, 6)
                }
                let selected = candidate == tab
                Button { tab = candidate } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.systemImage).font(.system(size: 12))
                        Text(candidate.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(height: 34)
                    .padding(.horizontal, 11)
                    .overlay(alignment: .bottom) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.accent)
                                .frame(height: 2).padding(.horizontal, 8)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    card("State") {
                        HStack(spacing: 6) {
                            Circle().fill(MachinesView.stateColor(machine)).frame(width: 7, height: 7)
                            Text(machine.status.capitalized)
                                .font(.system(size: 13, weight: .medium))
                        }
                        row("Started", RelativeDate.relative(detail.startedDate))
                        row("Created", RelativeDate.relative(machine.createdDate))
                        row("Default", machine.isDefault == true ? "Yes" : "No")
                    }

                    card("Resources") {
                        row("CPUs", "\(machine.cpus)")
                        row("Memory", MachinesView.bytes(machine.memory))
                        row("Disk", MachinesView.bytes(machine.diskSize))
                        // Stated here because it is a filesystem grant, not a preference. `rw` is the
                        // CLI's own default, so a machine you created without thinking about it has
                        // your home directory mounted writable.
                        if let homeMount = detail.homeMount {
                            row("Home mount", homeMountLabel(homeMount))
                        }
                    }

                    card("Network") {
                        row("IP address", machine.ipAddress ?? "—")
                        if let platform = detail.platform {
                            row("Platform", [platform.os, platform.architecture]
                                .compactMap { $0 }.joined(separator: "/"))
                        }
                    }

                    card("Image") {
                        if let image = detail.image {
                            row("Reference", image.reference)
                            if let digest = image.descriptor?.digest {
                                row("Digest", digest, monospaced: true)
                            }
                        } else {
                            Text("Loading the full record…")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The kernel is the runtime's, not the image's — verified: the image has no
                        // /boot at all. Worth saying, because "Ubuntu machine" means Ubuntu
                        // userland on `container`'s kernel, not Ubuntu's kernel.
                        Text("A machine boots a container image's userland on the runtime's own "
                             + "kernel — the image supplies no kernel.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                }

                // Full width **beneath** the grid, exactly as the container detail places its own —
                // a timeline reads badly in a narrow column. Inside the `LazyVGrid` it took one
                // cell and came out half width: `gridCellColumns` is a `Grid` modifier and does
                // nothing in a `LazyVGrid`, silently, which is how it looked plausible in code and
                // wrong on screen.
                //
                // Machines record activity exactly as containers do, so this card was simply never
                // added: the two detail screens are built to the same shapes and this was the one
                // shape only one of them had.
                eventsCard
            }
            .padding(12)
        }
    }

    /// What Flotilla watched happen to this machine, this run.
    ///
    /// Says so plainly rather than implying a complete history — there is no store, and a
    /// timeline that starts at app launch while presenting itself as complete is the lie of
    /// omission the container detail's copy already refuses to tell.
    private var eventsCard: some View {
        DetailCard(title: "Recent events", minHeight: nil) {
            let events = model.events(for: machine.id, kind: .machine)
            if events.isEmpty {
                Text("Nothing has changed since Flotilla started. State changes appear here as "
                     + "they happen; history from before launch is not recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(events.prefix(8)) { event in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.color(forEventEndingIn: event.to))
                            .frame(width: 6, height: 6)
                        Text(event.summary).font(.system(size: 12, weight: .medium))
                        Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Text(event.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if events.count > 8 {
                    Text("+ \(events.count - 8) earlier this session")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func homeMountLabel(_ mode: String) -> String {
        switch mode.lowercased() {
        case "rw": "Read-write — your home directory is writable inside this VM"
        case "ro": "Read-only"
        case "none": "Not mounted"
        default: mode
        }
    }

    // MARK: Building blocks — same card/row idiom as the container detail

    /// `DetailCard`, now genuinely the same one: this was a line-for-line copy of the container
    /// detail's private builder, and the comment above claiming they shared an idiom was the
    /// only thing keeping them together. 112 rather than 132 because the heading now sits
    /// outside the box.
    private func card<Content: View>(_ title: String,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
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
                .help(value)
        }
    }
}

// MARK: - Terminal

/// A shell inside the machine, via `machine run`.
///
/// **Differs from the container Terminal tab on purpose**, and the CLI owner found the reason in the
/// CLI's own description: `machine run` boots the machine *if necessary*. So this must not
/// refuse when the machine is stopped the way `TerminalTab` refuses for a stopped container —
/// doing so would contradict the runtime and train people to start machines by hand that the
/// shell would have started anyway. It says what will happen instead.
///
/// Sessions live in `model.machineTerminals`, a **second** store — see the note there for why
/// sharing one with containers would have collided on identically-named entries.
private struct MachineShellTab: View {
    let model: AppModel
    let machine: ContainerMachine

    @State private var failure: String?

    var body: some View {
        Group {
            if let current = model.machineTerminals.current(for: machine.id) {
                VStack(spacing: 0) {
                    shellStrip(current: current)
                    Divider()
                    MachineTerminalSurface(store: model.machineTerminals, session: current)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Cannot open a shell", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { open() }
                }
            } else {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: {
                    Text(MachinesView.isRunning(machine)
                         ? "Opens a login shell inside the machine “\(machine.id)”. This is the "
                           + "VM itself, not a container — changes here affect every container "
                           + "running in it."
                         : "The machine is stopped. Opening a shell will start it first, which "
                           + "`machine run` does automatically.")
                } actions: {
                    Button(MachinesView.isRunning(machine) ? "Open shell" : "Start and open shell") {
                        open()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shellStrip(current: TerminalSession) -> some View {
        HStack(spacing: 4) {
            ForEach(model.machineTerminals.sessions(for: machine.id)) { session in
                let isCurrent = session.id == current.id
                HStack(spacing: 5) {
                    Circle().fill(Theme.online).frame(width: 5, height: 5)
                    Text(session.title)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    Button {
                        model.machineTerminals.close(session, in: machine.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close \(session.title)")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                .background(isCurrent ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(.rect)
                .onTapGesture { model.machineTerminals.select(session, in: machine.id) }
            }
            Button { open() } label: { Image(systemName: "plus").font(.system(size: 10)) }
                .buttonStyle(.plain).padding(4)
                .help("Open another shell in \(machine.id)")
                .accessibilityLabel("New shell")
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// Built through the allowlist, never by string interpolation — same rule as the container
    /// terminal, and `machine run` has its own `CommandSpec` with `-n` rather than a positional
    /// name, which is exactly the per-leaf asymmetry the specs encode.
    private func open() {
        failure = nil
        do {
            let validated = try Allowlist.validated(
                ["machine", "run", "-n", machine.id, "-i", "-t"],
                execPolicy: model.cli.execPolicy
            )
            guard let executable = model.containerExecutable else {
                failure = model.containerExecutableMissingReason
                return
            }
            model.machineTerminals.open(containerID: machine.id,
                                        executable: executable,
                                        argv: validated.arguments) { reason in
                if let reason { failure = reason }
            }
        } catch {
            failure = "Flotilla would not permit that command: \(error)"
            model.record("Refused to open a machine shell in \(machine.id): \(error)",
                         subsystem: "machines")
        }
    }
}

/// Same re-parenting trick as the container terminal: the store owns the view so it outlives
/// any tab switch, and the representable owns only an empty host.
private struct MachineTerminalSurface: NSViewRepresentable {
    let store: TerminalSessionStore
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) { attach(to: host) }

    private func attach(to host: NSView) {
        guard let terminal = store.view(for: session) else { return }
        for existing in host.subviews where existing !== terminal { existing.removeFromSuperview() }
        guard terminal.superview !== host else { return }
        terminal.removeFromSuperview()
        terminal.frame = host.bounds
        terminal.autoresizingMask = [.width, .height]
        host.addSubview(terminal)
        DispatchQueue.main.async { host.window?.makeFirstResponder(terminal) }
    }
}

// MARK: - Settings

/// `machine set`, with the restart requirement designed in rather than flagged.
///
/// The CLI states plainly that these take effect after a restart. A form that writes silently
/// and appears to have done nothing is the trap the CLI owner's spec called out, so this shows the
/// running value against the pending one and offers the restart as part of the action.
private struct MachineSettingsTab: View {
    let model: AppModel
    let machine: ContainerMachine

    @State private var cpus: Int
    @State private var memoryGB: Int
    @State private var homeMount: String
    @State private var applied = false
    /// Set when Apply would escalate the home mount to read-write. Carries the restart intent so
    /// the confirmation can complete the action the user actually pressed.
    @State private var confirmingHomeMountEscalation: Bool?

    init(model: AppModel, machine: ContainerMachine) {
        self.model = model
        self.machine = machine
        _cpus = State(initialValue: machine.cpus)
        _memoryGB = State(initialValue: max(1, Int(machine.memory / 1_073_741_824)))
        _homeMount = State(initialValue: machine.homeMount ?? "rw")
    }

    /// Re-seeds the picker when `machine inspect` lands.
    ///
    /// `@State` seeded in `init` does not update when the parent passes a new value — the struct is
    /// recreated, the state is not. So without this the tab would keep whatever it read on first
    /// build, which for the first moment of a fresh detail view is the incomplete list row. Skipped
    /// once the user has touched anything, because overwriting an edit in progress with freshly
    /// arrived server state is worse than showing it a moment late.
    private func reseedFromInspect() {
        guard !changed, let known = machine.homeMount else { return }
        homeMount = known
    }

    private var changed: Bool {
        cpus != machine.cpus
            || memoryGB != max(1, Int(machine.memory / 1_073_741_824))
            || homeMount != (machine.homeMount ?? "rw")
    }

    var body: some View {
        Form {
            SwiftUI.Section("Configuration") {
                Stepper(value: $cpus, in: 1...ProcessInfo.processInfo.processorCount) {
                    LabeledContent("CPUs", value: "\(cpus)")
                }
                Stepper(value: $memoryGB, in: 1...256) {
                    LabeledContent("Memory", value: "\(memoryGB) GB")
                }
                Picker("Home directory", selection: $homeMount) {
                    Text("Read-write").tag("rw")
                    Text("Read-only").tag("ro")
                    Text("Not mounted").tag("none")
                }
            }

            SwiftUI.Section {
                // The whole point of this tab's design. Says it before you press, not after.
                //
                // Note what this does **not** say: that the machine has to be stopped first. It
                // does not. Verified against the live CLI on a running machine — `container
                // machine set -n probe-alpine cpus=3` succeeded, printed "Note: Changes will take
                // effect after stopping and restarting", and `machine ls` reported cpus=3
                // immediately while the VM kept running on 2. So the honest message is "saved,
                // not yet in effect", and a dialog demanding a stop first would invent a
                // restriction the CLI does not have.
                Label("Changes apply when the machine next starts. `container` has no way to "
                      + "resize a running machine.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)

                // The list will show the new numbers the moment this is applied, while the
                // running machine is still on the old ones — and nothing in the CLI reports the
                // in-effect values, so the app cannot detect that drift and flag it later. The
                // only place it can be said is here, before the button is pressed.
                if MachinesView.isRunning(machine) && changed {
                    Label("“\(machine.id)” is running. Applying now saves these values and "
                          + "leaves the machine on its current ones until it restarts — the list "
                          + "will show the new numbers before they take effect. "
                          + "Apply and Restart does both.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }

                if homeMount == "rw" {
                    Label("Read-write means every container in this machine can modify your "
                          + "home directory.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }

                HStack {
                    Button("Apply") { request(restart: false) }
                        .disabled(!changed)
                    Button("Apply and Restart") { request(restart: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!changed || !MachinesView.isRunning(machine))
                    Spacer()
                    if applied {
                        // Names the state the machine is actually in, not just that a write
                        // succeeded. "Saved" alone is what makes a running machine look like
                        // nothing happened.
                        Text(MachinesView.isRunning(machine)
                             ? "Saved — still running on the previous values"
                             : "Saved — applies on next start")
                            .font(.caption).foregroundStyle(Theme.online)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: machine.homeMount) { reseedFromInspect() }
        .confirmationDialog(
            "Give every container in “\(machine.id)” write access to your home directory?",
            isPresented: Binding(get: { confirmingHomeMountEscalation != nil },
                                 set: { if !$0 { confirmingHomeMountEscalation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mount Home Read-Write", role: .destructive) {
                let restart = confirmingHomeMountEscalation ?? false
                confirmingHomeMountEscalation = nil
                Task { await apply(restart: restart) }
            }
            Button("Cancel", role: .cancel) { confirmingHomeMountEscalation = nil }
        } message: {
            Text("Anything running in this machine will be able to read and change every file in "
                 + "your home directory, including SSH keys, credentials and browser data. It "
                 + "applies from the machine's next start and stays until you change it back.")
        }
    }

    /// Confirms first **only when this Apply escalates the home mount to read-write**.
    ///
    /// The audit asked for a confirmation on `home-mount=rw`, and the shape of it matters. Two
    /// wrong versions were easy to reach for:
    ///
    /// * Confirming whenever `rw` is *selected* would nag on every CPU or memory change made on a
    ///   machine that already mounts home read-write — which is the default. A dialog that appears
    ///   when nothing dangerous is changing is a dialog people learn to dismiss unread, and it
    ///   would train that habit on the one dialog here that matters.
    /// * Confirming on any change to the home mount would ask when *tightening* it to `ro` or
    ///   `none`, which needs no permission from anyone.
    ///
    /// So the trigger is the escalation itself: currently not read-write, about to be. The inline
    /// warning stays regardless, because it describes a standing state rather than a change.
    ///
    /// Note this is not routed through `DeletePolicy`. It is not a delete, and it must not be
    /// switchable off by a preference about deleting things — granting write access to a home
    /// directory is a capability grant, and the audit put it in the same bracket as
    /// `machine set-default` for that reason.
    private func request(restart: Bool) {
        // `machine.homeMount` nil means inspect has not answered yet, and the answer is unknown
        // rather than "rw" — so an unknown current state **confirms**. Defaulting the comparison to
        // "rw" the way the picker's initial value does would have made this dialog unreachable:
        // `"rw" != "rw"` is false for every machine, so the confirmation the audit asked for would
        // have been dead code that passed review by existing.
        let escalating = homeMount == "rw" && machine.homeMount != "rw"
        if escalating {
            confirmingHomeMountEscalation = restart
        } else {
            Task { await apply(restart: restart) }
        }
    }

    private func apply(restart: Bool) async {
        let memory = "\(memoryGB)G"
        guard await model.applyMachineSettings(machine.id, cpus: cpus, memory: memory,
                                              homeMount: homeMount) else { return }
        applied = true
        if restart {
            // One implementation. This used to open-code stop-then-start, which meant a failed
            // stop was still followed by a start, and the row action would have been a second
            // copy of the same idea.
            await model.perform(.restart, on: machine)
            applied = false
        }
    }
}

// MARK: - Inspect

private struct MachineInspectTab: View {
    let model: AppModel
    let machine: ContainerMachine

    @State private var json: String?
    @State private var failure: String?
    @State private var loading = false
    @State private var search = ""
    @State private var presentation: InspectPresentation = .table

    /// Narrowed exactly as the container Inspect tab is: image digests are public content
    /// hashes, not fingerprints, and mount paths are the point of inspecting. Secrets still go —
    /// and here that matters especially, because `machine inspect` carries `userSetup.username`,
    /// the host user's own name.
    private static let redactor = Redactor(excluding: [.fingerprint, .homePath,
                                                       .temporaryPath, .email])

    /// The same control band as the container Inspect tab, member for member. This panel used
    /// to be JSON-only — not by design, but because the flattening it needed was private to
    /// `ContainerDetailView`. `machine inspect` is nested enough (`userSetup`, `platform`,
    /// `image.descriptor`) that scanning for one value in raw JSON is real work, so the Table
    /// view earns its place here at least as much as it does on the containers side.
    var body: some View {
        // `alignment: .leading`: a `VStack` centres its children, and the JSON view is a
        // `ScrollView` sized to its content — so a payload narrower than the pane was centred in
        // it, reading as a floating block of text rather than as a document.
        VStack(alignment: .leading, spacing: 0) {
            // Member for member, and now in the same order as the container panel and the Logs
            // band: actions in the cluster, the view switch, then the field.
            HStack(spacing: 12) {
                ActionCluster {
                    IconActionButton(systemImage: "doc.on.doc", label: "Copy JSON",
                                     help: "Copy the inspect output, with secrets redacted",
                                     disabled: json == nil) {
                        if let json { Clipboard.copy(json) }
                    }
                    Divider().frame(height: 14)
                    IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                     help: "Reload", busy: loading) {
                        Task { await load() }
                    }
                }

                Picker("View", selection: $presentation) {
                    ForEach(InspectPresentation.allCases) {
                        // The word survives as the accessibility label and the tooltip; only the
                        // drawing changes.
                        Label($0.rawValue, systemImage: $0.symbol)
                            .labelStyle(.iconOnly)
                            .help($0.rawValue)
                            .tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField("Filter keys", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                if !search.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                // The command it ran, so the panel is reproducible in a terminal.
                Text("container machine inspect \(machine.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            content

            redactionNote
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            ContentUnavailableView("Cannot inspect", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if loading && json == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation == .table {
            InspectTableView(json: json, search: search)
        } else if let json {
            JSONTextView(json: json, search: search)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Matching lines only, when a filter is set. Kept simple deliberately: this is a reading
    /// aid, and dropping the enclosing braces would produce text that looks like JSON and is
    /// not, which is worse than a list of lines.
    private static func filtered(_ json: String, search: String) -> String {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return json }
        let matching = json.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
        return matching.isEmpty ? "No line matches “\(query)”." : matching.joined(separator: "\n")
    }

    /// Says that what you are reading has been filtered. `machine inspect` carries
    /// `userSetup.username` — the host user's own name — so a redaction the reader cannot see
    /// is the difference between "this machine has no such field" and "we hid it".
    private var redactionNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.caption2)
            Text("Secrets are redacted. Values shown as `<redacted:…>` are present on the "
                 + "machine but hidden here and in Copy JSON.")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    /// Matching lines, for the count beside the filter field — counted the same way the
    /// container panel counts them, on the same redacted text both views render.
    private var matchCount: Int {
        guard let json, !search.isEmpty else { return 0 }
        return json.split(separator: "\n", omittingEmptySubsequences: false)
            .count { $0.localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        failure = nil
        do {
            let machineID = machine.id
            let raw = try await Task.detached { [cli = model.cli] in
                try cli.rawMachineInspectJSON(machineID)
            }.value
            json = Self.redactor.redact(raw)
        } catch {
            failure = String(describing: error)
        }
    }
}
