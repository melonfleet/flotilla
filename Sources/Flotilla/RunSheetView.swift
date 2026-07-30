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
struct RunSheetView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var detach = true
    @State private var ports: [Row] = []
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
                SwiftUI.Section("Command") { commandField }
                SwiftUI.Section("Options") {
                    Toggle("Detach (run in background)", isOn: $detach)
                }
                SwiftUI.Section("Preview") { previewSection }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 560, height: 680)
        // Suggestions want the local image list; a user opening this sheet without ever
        // visiting Images otherwise sees none.
        .task { await model.refreshImages() }
    }

    private var header: some View {
        HStack {
            Text("Run Container").font(.headline)
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Run") {
                let ranImage = trimmedImage
                let ranOptions = options
                let ranCommand = command
                dismiss()
                Task { await model.runContainer(image: ranImage, options: ranOptions, command: ranCommand) }
            }
            .buttonStyle(.borderedProminent)
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
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(previewLine)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            switch preview {
            case .success:
                Label("Valid — ready to run.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let error):
                Label(error.description, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
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
        guard let error = previewError, Self.field(for: error) == field else { return nil }
        return error.description
    }

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
            detach: detach
        )
    }

    private var command: [String] {
        commandText.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
