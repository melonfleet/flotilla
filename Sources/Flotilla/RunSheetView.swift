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

    /// Built from an inspected container. `name` gets a suffix because the original still exists —
    /// `container run --name web` fails while `web` is there, and offering a name that cannot be
    /// used is a form that fails on submit.
    init(from container: Container, existingNames: Set<String>) {
        image = container.configuration.image.reference
        ports = container.publishedPorts.map(\.displayText)
        cpus = container.configuration.resources?.cpus
        memoryMB = container.configuration.resources?.memoryInBytes.map { Int($0 / 1_048_576) }
        mayHaveUncarriedSettings = true

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

    init(model: AppModel, initialImage: String = "", prefill: RunPrefill? = nil,
         dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        self.prefilled = prefill?.mayHaveUncarriedSettings ?? false
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
    /// Transient tick on the Copy button; reset whenever the command changes.
    @State private var copiedCommand = false

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
        .task { await model.refreshImages() }
    }

    /// Back then title, matching the detail screens and the machine form. Embedded rather than
    /// modal since 9 August — see `MachineFormView` for the reasoning; the short version is that
    /// once every other full-screen surface is reached and left the same way, a floating card
    /// with its own close button is the odd one out, and a hand-picked 560×680 frame meant the
    /// content had to fit the window rather than the other way round.
    private var header: some View {
        FormHeader(title: "Run Container", systemImage: "shippingbox", onBack: dismiss)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Form {
                SwiftUI.Section("Image") { imageField }
                SwiftUI.Section("Name") { nameField }
                SwiftUI.Section("Ports") {
                    rows($ports, placeholder: "8080:80", max: Self.maxPorts, field: .ports)
                }
                SwiftUI.Section("Environment") {
                    rows($env, placeholder: "KEY=VALUE", max: Self.maxEnv, field: .env)
                }
                SwiftUI.Section("Volumes") {
                    rows($volumes, placeholder: "data:/data", max: Self.maxVolumes, field: .volumes)
                }
                if prefilled {
                    SwiftUI.Section {
                        Label("Copied the image, name, ports and resource limits. **Environment "
                              + "variables and volumes were not copied** — `container inspect` "
                              + "does not separate the ones you set from the ones the image "
                              + "defines, so add any you need below.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                SwiftUI.Section("Command") { commandField }
                SwiftUI.Section("Options") {
                    Toggle("Detach (run in background)", isOn: $detach)
                    Toggle("Limit CPU and memory", isOn: $limitResources)
                    if limitResources {
                        Stepper(value: $cpus, in: 1...ProcessInfo.processInfo.processorCount) {
                            LabeledContent("CPUs", value: "\(cpus)")
                        }
                        Stepper(value: $memoryMB, in: 128...131_072, step: 128) {
                            LabeledContent("Memory", value: "\(memoryMB) MB")
                        }
                        Text("Defaults come from Settings ▸ Resources.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SwiftUI.Section("Preview") { previewSection }
            }
            .formStyle(.grouped)
            Divider()
            footer
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

    private var imageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Image reference, e.g. docker.io/library/nginx:latest", text: $image)
                .textFieldStyle(.roundedBorder)
            if !imageSuggestions.isEmpty {
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
            fieldMessage(.image)
        }
    }

    /// Local, pulled images — a convenience list, not a restriction; the field still
    /// accepts any reference the user types, pulled or not.
    private var imageSuggestions: [String] {
        var seen = Set<String>()
        return model.images.map(\.reference).filter { seen.insert($0).inserted }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Optional", text: $name)
                .textFieldStyle(.roundedBorder)
            fieldMessage(.name)
        }
    }

    private var commandField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Optional, space-separated — e.g. echo hello", text: $commandText)
                .textFieldStyle(.roundedBorder)
            Text("Splits on whitespace into up to \(Self.maxCommandTokens) tokens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            fieldMessage(.command)
        }
    }

    @ViewBuilder
    private func rows(_ list: Binding<[Row]>, placeholder: String, max: Int, field: Field) -> some View {
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
        fieldMessage(field)
    }

    @ViewBuilder
    private func fieldMessage(_ field: Field) -> some View {
        if let message = message(for: field) {
            Text(message).font(.caption).foregroundStyle(Theme.danger)
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

                // `FEATURES.md` wants "Copy `container` command" wherever a command is shown:
                // it teaches the CLI, and it doubles as the audit string you can paste into a
                // change record. Deliberately enabled even when the command is invalid —
                // copying it into a terminal to see the real error is a legitimate thing to
                // want, and the validation message is right underneath either way.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previewLine, forType: .string)
                    copiedCommand = true
                } label: {
                    Label(copiedCommand ? "Copied" : "Copy",
                          systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy the container command to the clipboard")
                // Reset on any edit, so the tick always refers to what is on screen now.
                .onChange(of: previewLine) { copiedCommand = false }
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
            memory: limitResources ? "\(memoryMB)M" : nil
        )
    }

    private var command: [String] {
        commandText.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
