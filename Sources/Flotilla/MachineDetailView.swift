import SwiftUI
import SwiftTerm
import FlotillaCore

/// Which pane of the machine detail is showing.
///
/// Four, not six. The containers set has Processes, Files and Configuration; a machine has no
/// `machine ps`, no `machine copy` and no per-machine config file, so those tabs would be
/// controls with nothing behind them. `Settings` replaces them because `machine set` is real.
enum MachineDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case shell = "Shell"
    case logs = "Logs"
    case settings = "Settings"
    case inspect = "Inspect"
    var id: Self { self }

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
    init(model: AppModel, machine: ContainerMachine) {
        self.model = model
        self.machine = machine
        _tab = State(initialValue: model.lastMachineTab[machine.id] ?? .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch tab {
                case .overview: overview
                case .shell: MachineShellTab(model: model, machine: machine)
                case .logs: MachineLogsTab(model: model, machine: machine)
                case .settings: MachineSettingsTab(model: model, machine: machine)
                case .inspect: MachineInspectTab(model: model, machine: machine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: tab) { _, newTab in model.lastMachineTab[machine.id] = newTab }
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
            ForEach(MachineDetailTab.allCases) { candidate in
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
            .padding(12)
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

    private func card<Content: View>(_ title: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).kerning(0.5)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
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

// MARK: - Shell

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
                    Label("Shell", systemImage: "terminal")
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
            model.machineTerminals.open(containerID: machine.id,
                                        executable: Self.containerBinary,
                                        argv: validated.arguments) { reason in
                if let reason { failure = reason }
            }
        } catch {
            failure = "Flotilla would not permit that command: \(error)"
            model.record("Refused to open a machine shell in \(machine.id): \(error)",
                         subsystem: "machines")
        }
    }

    private static var containerBinary: String {
        let candidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
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

// MARK: - Logs

private struct MachineLogsTab: View {
    let model: AppModel
    let machine: ContainerMachine

    @State private var text = ""
    @State private var boot = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // `machine logs --boot` is a genuinely different log, not a filter of the same
                // one, so this is a mode switch rather than a checkbox on one stream.
                Picker("", selection: $boot) {
                    Text("Machine").tag(false)
                    Text("Boot").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading).help("Refresh")
            }
            .padding(12)
            Divider()

            if let failure {
                ContentUnavailableView("Cannot read logs",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if text.isEmpty {
                ContentUnavailableView(loading ? "Loading…" : "No log output",
                                       systemImage: "doc.text")
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .task(id: boot) { await load() }
    }

    private func load() async {
        loading = true
        failure = nil
        do {
            let chunk = try await model.machineLogs(for: machine.id, lines: 500, boot: boot)
            text = chunk.lines.map(\.text).joined(separator: "\n")
        } catch {
            text = ""
            failure = String(describing: error)
        }
        loading = false
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

    init(model: AppModel, machine: ContainerMachine) {
        self.model = model
        self.machine = machine
        _cpus = State(initialValue: machine.cpus)
        _memoryGB = State(initialValue: max(1, Int(machine.memory / 1_073_741_824)))
        _homeMount = State(initialValue: machine.homeMount ?? "rw")
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
                Label("Changes apply when the machine next starts. `container` has no way to "
                      + "resize a running machine.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)

                if homeMount == "rw" {
                    Label("Read-write means every container in this machine can modify your "
                          + "home directory.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning)
                }

                HStack {
                    Button("Apply") { Task { await apply(restart: false) } }
                        .disabled(!changed)
                    Button("Apply and Restart") { Task { await apply(restart: true) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!changed || !MachinesView.isRunning(machine))
                    Spacer()
                    if applied {
                        Text("Saved — restart to apply")
                            .font(.caption).foregroundStyle(Theme.online)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
    @State private var presentation: InspectPresentation = .json

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View", selection: $presentation) {
                    ForEach(InspectPresentation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField("Filter…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                // The command it ran, so the panel is reproducible in a terminal.
                Text("container machine inspect \(machine.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // `IconActionButton` on both detail panels, icon-only. These two tabs disagreed:
                // the machine panel drew Copy JSON icon-only and the container panel drew it with
                // the word, and neither used the shared button, so neither shaded on hover while
                // the toolbar controls above them did. Same control, same tab, two screens.
                IconActionButton(systemImage: "doc.on.doc", label: "Copy JSON",
                                 help: "Copy the inspect output, with secrets redacted",
                                 disabled: json == nil) {
                    if let json { Clipboard.copy(json) }
                }

                IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                 help: "Reload", busy: loading) {
                    Task { await load() }
                }
                .disabled(loading)
                .help("Reload")
                .accessibilityLabel("Reload")
            }
            .padding(12)
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
            ScrollView([.vertical, .horizontal]) {
                // Filtering the JSON view by line keeps the two presentations answering the
                // same question — a filter that only worked in one of them would be worse
                // than no filter, because you would trust the empty result.
                Text(Self.filtered(json, search: search))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
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
