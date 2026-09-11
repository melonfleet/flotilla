import SwiftUI
import Foundation
import FlotillaCore

/// The run sheet: build a `container run` invocation with a live, validated command
/// preview.
///
/// This view never assembles or approves an argv itself — that stays exactly where the
/// security boundary lives. `ContainerCLI.runArguments` builds the argv and
/// `AppModel.runPreview` validates it with the same `Allowlist` call `ContainerCLI` uses
/// for real execution, so what is shown here cannot drift from what `Run` would actually
/// do. Every field's inline message is just that same `AllowlistError` routed back to the
/// row that produced it.
/// A new container's fields, taken from one that already exists.
///
/// **There is no `container update`.** The subcommand list has `create`, `run`, `start`, `stop`,
/// `kill`, `delete`, `exec`, `copy`, `export`, `inspect`, `logs`, `stats` and `prune` — nothing that
/// changes an existing container's configuration. Docker has `docker update` for a few resource
/// limits; Apple's `container` has no equivalent. So a container's settings genuinely cannot be
/// edited, and an "Edit Settings…" item on the containers menu would be a screen that could never
/// save. The honest equivalent is to make the *next* container easy to get right, which is this.
///
/// **What it deliberately does not carry, and why that has to be visible:** environment variables
/// and volume mounts. `container inspect` returns `initProcess.environment` with the image's own
/// variables mixed in — nginx:alpine reports seven, none of them set by the user — and there is no
/// field distinguishing "passed with `--env`" from "baked into the image". Prefilling all of them
/// would present the image's defaults as the user's choices; prefilling none of them and saying so
/// is worse UX and better information. Same for mounts: `Container.Configuration` does not model
/// them, and guessing would be inventing data.
struct RunPrefill: Equatable {
    var image: String
    var name: String
    var ports: [String]
    var cpus: Int?
    var memoryMB: Int?
    /// True when the source container had env or mounts we could not carry, so the sheet can say
    /// so rather than letting the user discover it after the container starts.
    var mayHaveUncarriedSettings: Bool

    /// Host ports the source published that were left out because something else already holds
    /// them — almost always the original container, which is still running.
    var portsInUse: [Int]

    /// Built from an inspected container. `name` gets a suffix because the original still exists —
    /// `container run --name web` fails while `web` is there, and offering a name that cannot be
    /// used is a form that fails on submit.
    ///
    /// **The same reasoning applies to the host port, and it did not used to.** Copying
    /// `8080:80` verbatim while the original still publishes 8080 produces a container that
    /// cannot start: the runtime refuses with `bind(...): Address already in use (errno: 48)`.
    /// A tester hit exactly this and reported it as "container keeps stopping, won't stay
    /// running". So a host port already taken is dropped rather than prefilled, and named in
    /// `portsInUse` so the sheet says which and why instead of leaving a silent gap.
    init(from container: Container, existingNames: Set<String>, usedHostPorts: Set<Int> = []) {
        image = container.configuration.image.reference
        cpus = container.configuration.resources?.cpus
        memoryMB = container.configuration.resources?.memoryInBytes.map { Int($0 / 1_048_576) }
        mayHaveUncarriedSettings = true

        var carried: [String] = []
        var conflicts: [Int] = []
        for port in container.publishedPorts {
            if usedHostPorts.contains(port.hostPort) {
                conflicts.append(port.hostPort)
            } else {
                carried.append(port.displayText)
            }
        }
        ports = carried
        portsInUse = conflicts

        var candidate = "\(container.configuration.id)-copy"
        var counter = 2
        while existingNames.contains(candidate) {
            candidate = "\(container.configuration.id)-copy-\(counter)"
            counter += 1
        }
        name = candidate
    }
}

struct RunSheetView: View {
    let model: AppModel
    /// From the presenter, not `@Environment(\.dismiss)`: the sheet's own `isPresented`
    /// binding is the single source of truth for whether it is open, and two mechanisms for
    /// closing one thing is how a sheet gets stuck.
    let dismiss: () -> Void

    @State private var image: String

    /// `initialImage` lets the Images screen's **Run…** open the sheet already pointed at a
    /// reference. It pre-fills, it does not launch — the validated command preview still has
    /// the final say, so nothing starts without the user seeing exactly what will run.
    /// Set when the sheet was opened from an existing container, so it can say which settings it
    /// could not bring across.
    private let prefilled: Bool

    /// Host ports the source published that were deliberately not carried, because something
    /// already holds them. Named in the notice rather than silently missing.
    private let portsInUse: [Int]

    init(model: AppModel, initialImage: String = "", prefill: RunPrefill? = nil,
         dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        self.prefilled = prefill?.mayHaveUncarriedSettings ?? false
        self.portsInUse = prefill?.portsInUse ?? []
        _image = State(initialValue: prefill?.image ?? initialImage)
        _name = State(initialValue: prefill?.name ?? "")
        _ports = State(initialValue: (prefill?.ports ?? []).map { Row(value: $0) })
        _limitResources = State(initialValue: prefill?.cpus != nil || prefill?.memoryMB != nil)
        // Seeded from **Defaults for new containers**. Those two settings had no consumer at all:
        // the registry declared them, Settings offered steppers for them, and the run sheet had no
        // CPU or memory field to apply them to. `RunOptions` already carried `cpus`/`memory` and
        // `Allowlist` already permitted `--cpus`/`--memory` on `run` — the only missing piece was
        // the two controls, so wiring beat annotating.
        _cpus = State(initialValue: prefill?.cpus
                      ?? model.settingsStore[SettingsKeys.defaultContainerCPUs])
        _memoryMB = State(initialValue: prefill?.memoryMB
                          ?? model.settingsStore[SettingsKeys.defaultContainerMemoryMB])
    }
    @State private var name: String
    /// Empty means "leave it unset and let `container` decide". A network can only be chosen
    /// when the container is created — neither the CLI nor Flotilla can move an existing one.
    @State private var network = ""

    @State private var edits = FormEditTracker()

    /// Everything a Back would throw away, in one string. Compared against the value captured when
    /// the screen appeared — not against defaults, because a prefilled run sheet opens full and
    /// that is not the user's unsaved work.
    private var editSignature: String {
        [image, name, commandText, network,
         ports.map(\.value).joined(separator: ","),
         env.map(\.value).joined(separator: ","),
         volumes.map(\.value).joined(separator: ","),
         "\(detach)", "\(limitResources)", "\(cpus)", "\(memoryMB)"].joined(separator: "\u{1}")
    }

    @State private var detach = true
    @State private var cpus: Int
    @State private var memoryMB: Int
    /// Whether to pass the limits at all. Off by default, so the sheet's behaviour does not change
    /// for anyone who never opens this section: `container run` with no `--cpus` inherits the
    /// machine's own allowance, which is what happened before these fields existed. On when the
    /// sheet was prefilled from a container that had limits — dropping them silently would quietly
    /// change what the copy is.
    @State private var limitResources: Bool
    @State private var ports: [Row]
    @State private var env: [Row] = []
    @State private var volumes: [Row] = []
    @State private var commandText = ""

    /// Gives each list row a stable identity across add/remove — `Allowlist`'s own
    /// per-flag maxima (`maxPorts`/`maxEnv`/`maxVolumes` below) are just this view's
    /// mirror of `RunOptions`' documented repeatable limits.
    private struct Row: Identifiable {
        let id = UUID()
        var value: String
    }

    private static let maxPorts = 16
    private static let maxEnv = 24
    private static let maxVolumes = 16
    private static let maxCommandTokens = 24

    private enum Field: Equatable { case image, name, ports, env, volumes, command }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Suggestions want the local image list; a user opening this sheet without ever
        // visiting Images otherwise sees none.
        .onAppear { edits.open(editSignature) }
        .task { await model.refreshImages() }
        // Networks are refreshed by their own section and by every sixth poll tick, so a run
        // sheet opened from the File menu on a fresh launch would otherwise offer an empty list.
        .task { await model.refreshNetworks() }
    }

    /// Back then title, matching the detail screens and the machine form. Embedded rather than
    /// modal since 9 August — see `MachineFormView` for the reasoning; the short version is that
    /// once every other full-screen surface is reached and left the same way, a floating card
    /// with its own close button is the odd one out, and a hand-picked 560×680 frame meant the
    /// content had to fit the window rather than the other way round.
    private var header: some View {
        FormHeader(title: "Run Container", systemImage: "shippingbox",
                   hasUnsavedChanges: edits.isDirty(editSignature), onBack: dismiss)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // `FormScaffold` owns the bounded scroll, the 640pt column and the explainer rail.
            // See `Scripts/check-form-bounds.sh`: a `FormHeader` screen needs something that
            // bounds its height, or it grows the split view instead of scrolling.
            FormScaffold {
                prefillBanner
                imageSection
                networkingSection
                storageSection
                commandSection
                optionsSection
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
    }

    /// What a prefill copied and what it deliberately did not. At the top, because it describes
    /// the state of every field below it rather than any one of them.
    @ViewBuilder
    private var prefillBanner: some View {
        if prefilled {
            VStack(alignment: .leading, spacing: 8) {
                Label("Copied the image, name, ports and resource limits. **Environment "
                      + "variables and volumes were not copied** — `container inspect` "
                      + "does not separate the ones you set from the ones the image "
                      + "defines, so add any you need below.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if !portsInUse.isEmpty {
                    // Stated, not silently dropped. Copying a host port that is already
                    // bound gives a container that cannot start —
                    // `bind(...): Address already in use` — and the failure looks like
                    // the container "not staying running" rather than a port clash.
                    Label("Host port\(portsInUse.count == 1 ? "" : "s") "
                          + portsInUse.map(String.init).joined(separator: ", ")
                          + " \(portsInUse.count == 1 ? "is" : "are") already published by "
                          + "a running container, so \(portsInUse.count == 1 ? "it was" : "they were") "
                          + "left out. Pick a different host port, or stop the original first.",
                          systemImage: "network.slash")
                        .font(.caption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Image")

            FormField("Image reference",
                      help: FieldHelp(
                          "What the container is made from. Pulled automatically if this Mac does not have it.",
                          detail: "Registry and tag are both optional — the defaults are Docker Hub and latest.",
                          example: """
                              nginx                    docker.io/library/nginx:latest
                              nginx:alpine             a specific tag
                              ghcr.io/owner/app:1.2.3  another registry
                              alpine@sha256:…          pinned to a digest
                              """),
                      problem: message(for: .image)) {
                TextField("nginx:alpine", text: $image)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                if !imageSuggestions.isEmpty {
                    // Already on this Mac — a convenience list, not a restriction.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(imageSuggestions, id: \.self) { reference in
                                Button(ContainerImage.shortReference(reference)) { image = reference }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help(reference)
                            }
                        }
                    }
                }
            }

            FormField("Name",
                      help: FieldHelp(
                          "Used as the container ID.",
                          detail: "It is how you refer to this container everywhere else — logs, shell, stop, delete. Left empty, `container` assigns one for you.",
                          example: "Letters, numbers, dots, dashes or\nunderscores. Must start with a letter\nor number. No spaces."),
                      problem: message(for: .name),
                      optional: true) {
                TextField("web", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }
        }
    }

    private var networkingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Networking")

            // The three-part form is worth naming: it is the difference between a port
            // reachable from the whole network and one reachable only from this Mac, and the
            // allowlist accepts it (`isPortMapping`, case 3).
            FormField("Ports",
                      help: FieldHelp(
                          "Publishes a port inside the container to a port on this Mac.",
                          detail: "Without one, nothing outside the container can reach it.",
                          example: """
                              8080:80            host 8080 → container 80
                              8080:80/udp        UDP instead of TCP
                              127.0.0.1:8080:80  this Mac only
                              """,
                          warning: "Without a host IP the port is reachable from your whole network, not just this Mac. A bare port is refused — the CLI needs both halves."),
                      problem: message(for: .ports),
                      optional: true) {
                rows($ports, placeholder: "8080:80", max: Self.maxPorts)
            }

            // Until this existed the Networks section was write-only: you could create a network,
            // inspect it and delete it, and nothing in the app could ever join one. `RunOptions`
            // has carried a `network` field the whole time; no screen ever set it.
            FormField("Network",
                      help: model.networks.isEmpty
                          ? FieldHelp(
                              "No networks yet.",
                              detail: "Create one in the Networks section and it will appear here.")
                          : FieldHelp(
                              "Containers on the same network reach each other by name.",
                              detail: "So an app can talk to a database as `db` rather than by IP. Left as Default, `container` chooses.",
                              warning: "Creation time only. Neither the CLI nor Flotilla can move a container onto a network after it exists — choose it now, or recreate the container later."),
                      optional: true) {
                Picker("", selection: $network) {
                    Text("Default").tag("")
                    ForEach(model.networks, id: \.id) { available in
                        Text(available.name).tag(available.name)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.networks.isEmpty)
            }
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Environment and storage")

            FormField("Environment variables",
                      help: FieldHelp(
                          "Passed into the container as environment. One KEY=VALUE per row.",
                          example: """
                              POSTGRES_PASSWORD=secret
                              NODE_ENV=production
                              TZ=Europe/London
                              """,
                          warning: "The CLI also accepts a bare KEY to inherit that variable from this Mac. Flotilla refuses it deliberately — it exports your shell environment into the container without saying which values went."),
                      problem: message(for: .env),
                      optional: true) {
                rows($env, placeholder: "KEY=VALUE", max: Self.maxEnv)
            }

            FormField("Volumes",
                      help: FieldHelp(
                          "Storage that outlives the container.",
                          detail: "The source is either a named volume you created, or an absolute path on this Mac.",
                          example: """
                              web:/srv/data        a named volume
                              /Users/me/src:/app   a folder on this Mac
                              web:/srv/data:ro     read-only
                              """,
                          warning: "The destination cannot be `/`. Mounting over the container root is refused."),
                      problem: message(for: .volumes),
                      optional: true) {
                rows($volumes, placeholder: "data:/data", max: Self.maxVolumes)
                existingVolumeMenu
            }
        }
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Command")

            FormField("Command",
                      help: FieldHelp(
                          "Replaces whatever the image runs by default.",
                          detail: "Split on whitespace into up to \(Self.maxCommandTokens) tokens.",
                          example: "echo hello\nsh -c \"while true; do date; sleep 5; done\"",
                          warning: "Left empty, the image runs its own entrypoint — which is what you want most of the time."),
                      problem: message(for: .command),
                      optional: true) {
                TextField("echo hello", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Options")

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Detach (run in background)", isOn: $detach)
                Text("Returns as soon as the container starts. Without it the run waits for "
                     + "the container to exit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Limit CPU and memory", isOn: $limitResources)

            if limitResources {
                FormField("CPUs",
                          help: FieldHelp(
                              "How many virtual CPUs this container may use.",
                              detail: "1 to \(ProcessInfo.processInfo.processorCount) on this Mac. The default comes from Settings ▸ Resources.")) {
                    Stepper(value: $cpus, in: 1...ProcessInfo.processInfo.processorCount) {
                        Text("\(cpus)").monospacedDigit()
                    }
                    .fixedSize()
                }

                FormField("Memory",
                          help: FieldHelp(
                              "How much memory this container may use.",
                              detail: "In 128 MB steps. The default comes from Settings ▸ Resources.")) {
                    Stepper(value: $memoryMB, in: 128...131_072, step: 128) {
                        Text("\(memoryMB) MB").monospacedDigit()
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// The validated command, in the rail. It used to be the last thing on a long scroll — the
    /// one place a preview of what you are about to run is no use.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            previewSection
            Text("Built through the allowlist, so it cannot say one thing while Run does another.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Run") {
                let ranImage = trimmedImage
                let ranOptions = options
                let ranCommand = command
                dismiss()
                Task { await model.runContainer(image: ranImage, options: ranOptions, command: ranCommand) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(previewError != nil)
        }
        .padding(12)
    }

    // MARK: Fields

    /// Local, pulled images — a convenience list, not a restriction; the field still
    /// accepts any reference the user types, pulled or not.
    private var imageSuggestions: [String] {
        var seen = Set<String>()
        return model.images.map(\.reference).filter { seen.insert($0).inserted }
    }

    /// The volumes you have already created, offered instead of remembered.
    ///
    /// It fills in the half the app can know — the source — and leaves the destination to you,
    /// because the CLI needs `source:/destination` and only the source exists as a list. The free
    /// text row stays, because a source may equally be an absolute path on this Mac, and no
    /// picker can enumerate your filesystem.
    @ViewBuilder
    private var existingVolumeMenu: some View {
        if !model.volumes.isEmpty {
            Menu {
                ForEach(model.volumes, id: \.id) { volume in
                    Button(volume.name) { volumes.append(Row(value: "\(volume.name):/")) }
                }
            } label: {
                Label("Use an existing volume", systemImage: "externaldrive")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(volumes.count >= Self.maxVolumes)
        }
    }

    @ViewBuilder
    private func rows(_ list: Binding<[Row]>, placeholder: String, max: Int) -> some View {
        ForEach(list) { $row in
            HStack {
                TextField(placeholder, text: $row.value)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    list.wrappedValue.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        HStack {
            Button {
                list.wrappedValue.append(Row(value: ""))
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .disabled(list.wrappedValue.count >= max)
            Spacer()
            Text("\(list.wrappedValue.count)/\(max)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(previewLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CommandPreviewCopyButton(command: previewLine,
                                         help: "Copy the container command to the clipboard")
            }
            if !hasStarted {
                Label("Enter an image reference to build the command.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                switch preview {
                case .success:
                    Label("Valid — ready to run.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                case .failure(let error):
                    // Only if no field claimed it. Otherwise the identical sentence appeared
                    // twice — once under the offending field and again here — which reads as
                    // two separate problems.
                    if Self.field(for: error) == nil {
                        Label(error.description, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    } else {
                        Label("Fix the highlighted field to run this.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
    }

    /// The argv as it will be executed, one token-joined line — computed from the exact
    /// same construction the preview validates and `runContainer` runs, whether or not it
    /// currently validates, so the sheet never shows a lookalike command.
    private var previewLine: String {
        (["container"] + ContainerCLI.runArguments(image: trimmedImage, options: options, command: command))
            .joined(separator: " ")
    }

    private var preview: Result<ValidatedCommand, AllowlistError> {
        AppModel.runPreview(image: trimmedImage, options: options, command: command)
    }

    private var previewError: AllowlistError? {
        if case .failure(let error) = preview { return error }
        return nil
    }

    private func message(for field: Field) -> String? {
        // An untouched form is not a broken one. With no image typed yet the validator
        // legitimately fails, and reporting that as `'' isn't a valid imageReference` greets
        // you with two red errors for a form you have not filled in — the same "empty is not
        // an error yet" mistake the machine form's command preview had.
        guard hasStarted else { return nil }
        guard let error = previewError, Self.field(for: error) == field else { return nil }
        return error.description
    }

    /// True once there is anything to validate. Only the image is required, so it alone decides
    /// whether the form has been started.
    private var hasStarted: Bool { !trimmedImage.isEmpty }

    /// Routes an `AllowlistError` back to the row that produced it, using the same
    /// context strings `Allowlist` records for each flag/operand (`--name`, `--env`,
    /// `--publish`, `--volume`, `<imageReference>`, `command`). Errors with no fixed
    /// context (structural limits, an unknown flag that should never occur from this
    /// view's own construction) fall through to the general banner above instead of
    /// pointing at a field that may not be the cause.
    private static func field(for error: AllowlistError) -> Field? {
        switch error {
        case .invalidValue(let context, _, _), .pathTraversal(let context, _), .hostPathNotPermitted(let context, _):
            return field(forContext: context)
        case .unknownFlag(let key), .malformedFlag(let key), .flagRequiresValue(let key),
             .flagTakesNoValue(let key), .repeatedFlag(let key):
            return field(forContext: key)
        case .missingOperand:
            return .image
        default:
            return nil
        }
    }

    private static func field(forContext context: String) -> Field? {
        switch context {
        case "--name": .name
        case "--env": .env
        case "--publish": .ports
        case "--volume": .volumes
        case "<imageReference>": .image
        case "command": .command
        default: nil
        }
    }

    // MARK: Building the request

    private var trimmedImage: String { image.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var options: ContainerCLI.RunOptions {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContainerCLI.RunOptions(
            name: trimmedName.isEmpty ? nil : trimmedName,
            ports: ports.map(\.value).filter { !$0.isEmpty },
            env: env.map(\.value).filter { !$0.isEmpty },
            volumes: volumes.map(\.value).filter { !$0.isEmpty },
            detach: detach,
            cpus: limitResources ? cpus : nil,
            // `.memorySize` shape — digits plus an optional K/M/G suffix. The stepper is in MB, so
            // the suffix is fixed and cannot drift into something the allowlist would refuse.
            memory: limitResources ? "\(memoryMB)M" : nil,
            network: network.isEmpty ? nil : network
        )
    }

    private var command: [String] {
        commandText.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
