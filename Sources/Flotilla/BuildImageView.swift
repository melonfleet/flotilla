import SwiftUI
import AppKit
import FlotillaCore

/// Build an image from a Dockerfile — an embedded form, like every other form since 9 August.
///
/// The context directory is **required and chosen through an `NSOpenPanel`**, which is not a
/// UI preference: that selection *is* the authorisation. `AppModel.buildImage` grants exactly
/// that directory for exactly this command, and the app's standing policy denies host paths
/// entirely. So there is no free-text path field here on purpose — typing a path would be a
/// grant the user never consciously made, and the panel makes the choice deliberate.
struct BuildImageView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var context: URL?
    @State private var dockerfile: String = ""
    @State private var tag = ""
    @State private var target = ""
    @State private var platform = ""
    @State private var noCache = false
    @State private var building = false
    @State private var edits = FormEditTracker()

    private var editSignature: String {
        [context?.path ?? "", dockerfile, tag, target, platform, "\(noCache)"]
            .joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Build Image", systemImage: "hammer",
                       hasUnsavedChanges: edits.isDirty(editSignature), onBack: dismiss)
            Divider()
            // The context grant and the CLI-specific defaults need more room than an inline
            // caption, while the bounded field column must still survive a narrow window.
            FormScaffold {
                VStack(alignment: .leading, spacing: 14) {
                    FormSectionHeader(title: "Context")

                    FormField("Folder",
                              help: FieldHelp(
                                  "The build context available to Dockerfile instructions.",
                                  detail: "Everything in this directory is sent to the builder, and the build may read all of it.",
                                  warning: "Choosing the folder grants access to that host path for this build; Flotilla otherwise denies host paths.")) {
                        HStack(spacing: 8) {
                            Text(context?.path ?? "No folder chosen")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(context == nil ? .tertiary : .primary)
                                .lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("Choose…") { chooseContext() }
                        }
                    }

                    FormField("Dockerfile",
                              help: FieldHelp(
                                  "Overrides the Dockerfile inside the context folder.",
                                  detail: "Left empty, the Dockerfile in the context folder is used.",
                                  example: "docker/release.Dockerfile",
                                  warning: "Any path entered here must stay inside the selected context folder."),
                              optional: true) {
                        TextField("<context>/Dockerfile", text: $dockerfile)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    FormSectionHeader(title: "Image")

                    // The default is worth stating precisely: `container build -t` documents
                    // it as a UUID, so an untagged build does not produce `<none>` you can
                    // find later — it produces a random name.
                    FormField("Tag",
                              help: FieldHelp(
                                  "A name and tag for finding the built image later.",
                                  detail: "The `container build -t` format is `name:tag`.",
                                  example: "myapp:latest",
                                  warning: "Left empty, `container` uses a random UUID, so the image is not findable by name afterwards."),
                              optional: true) {
                        TextField("myapp:latest", text: $tag)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                    }

                    FormField("Target stage",
                              help: FieldHelp(
                                  "Stops a multi-stage build at the named stage.",
                                  detail: "Use the name after `FROM … AS` in the Dockerfile. Left empty, the last stage is built.",
                                  example: "builder"),
                              optional: true) {
                        TextField("build", text: $target)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                    }

                    FormField("Platform",
                              help: FieldHelp(
                                  "Chooses the operating system and architecture to build for.",
                                  detail: "Use `os/arch[/variant]`. This Mac builds `linux/arm64` unless told otherwise.",
                                  example: "linux/amd64"),
                              optional: true) {
                        TextField("linux/arm64", text: $platform)
                            .textFieldStyle(.roundedBorder)
                            .monospaced()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Ignore the build cache", isOn: $noCache)
                        Text("Re-runs every layer instead of reusing what has not changed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } preview: {
                railPreview
            }

            Divider()
            HStack(spacing: 8) {
                if building {
                    ProgressView().controlSize(.small)
                    Text("Building… this can take minutes and pulls the base image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: dismiss)
                Button("Build") { Task { await build() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || building)
            }
            .padding(12)
        }
    }

    /// Kept beside the active field because it is the answer to what Build will run, not another
    /// field to discover at the end of the form.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text(previewText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(previewStyle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the build context — the folder sent to the builder"
        if panel.runModal() == .OK { context = panel.url }
    }

    private var trimmedDockerfile: String { dockerfile.trimmingCharacters(in: .whitespaces) }
    private var trimmedTag: String { tag.trimmingCharacters(in: .whitespaces) }

    private var preview: Result<ValidatedCommand, AllowlistError> {
        AppModel.buildPreview(context: context,
                              dockerfile: trimmedDockerfile.isEmpty ? nil : trimmedDockerfile,
                              tag: trimmedTag.isEmpty ? nil : trimmedTag,
                              buildArgs: [], labels: [], noCache: noCache,
                              platform: platform.trimmingCharacters(in: .whitespaces),
                              target: target.trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        if case .success = preview { return true }
        return false
    }

    /// Guidance before a folder is chosen; the real refusal afterwards. Same rule as the Run
    /// form: an untouched form is not a broken one.
    private var previewText: String {
        guard context != nil else { return "Choose a context folder to build the command." }
        switch preview {
        case .success(let command): return command.localPreview
        case .failure(let error): return error.description
        }
    }

    private var previewStyle: AnyShapeStyle {
        if context == nil || isValid { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(Theme.danger)
    }

    private func build() async {
        guard let context else { return }
        building = true
        defer { building = false }
        let succeeded = await model.buildImage(
            context: context,
            dockerfile: trimmedDockerfile.isEmpty ? nil : trimmedDockerfile,
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            buildArgs: [], labels: [], noCache: noCache,
            platform: platform.trimmingCharacters(in: .whitespaces),
            target: target.trimmingCharacters(in: .whitespaces))
        if succeeded { dismiss() }
    }
}
