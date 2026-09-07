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

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Build Image", systemImage: "hammer", onBack: dismiss)
            Divider()
            // Left-aligned label, control, guidance — the shape `FormField` documents, and the
            // one the other create screens use. The grouped `Form` this replaced pushed every
            // control to the far right of the window.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        FormSectionHeader(title: "Context")

                        FormField("Folder",
                                  help: "Everything in it is sent to the builder, and the build "
                                      + "may read all of it. Choosing it here is what grants "
                                      + "access — Flotilla denies host paths otherwise.") {
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
                                  help: "Left empty, the Dockerfile in the context folder is "
                                      + "used. A path here must also sit inside that folder.",
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
                                  help: "Name for the built image. Left empty, `container` names "
                                      + "it with a random UUID.",
                                  optional: true) {
                            TextField("myapp:latest", text: $tag)
                                .textFieldStyle(.roundedBorder)
                                .monospaced()
                        }

                        FormField("Target stage",
                                  help: "The stage to stop at in a multi-stage Dockerfile — the "
                                      + "name after `FROM … AS`. Left empty, the last stage is "
                                      + "built.",
                                  optional: true) {
                            TextField("build", text: $target)
                                .textFieldStyle(.roundedBorder)
                                .monospaced()
                        }

                        FormField("Platform",
                                  help: "os/arch, optionally /variant. This Mac builds "
                                      + "linux/arm64 unless you say otherwise.",
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

                    VStack(alignment: .leading, spacing: 14) {
                        FormSectionHeader(title: "Command",
                                          note: "Built through the allowlist, so it cannot say "
                                              + "one thing while Build does another.")
                        Text(previewText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(previewStyle)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .formColumn()
                .padding(20)
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
