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
            Form {
                SwiftUI.Section("Context") {
                    HStack(spacing: 8) {
                        Text(context?.path ?? "No folder chosen")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(context == nil ? .tertiary : .primary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Choose…") { chooseContext() }
                    }
                    Label("Everything in this folder is sent to the builder, and the build may "
                          + "read all of it. Choosing it here is what grants access — Flotilla "
                          + "denies host paths otherwise.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SwiftUI.Section("Dockerfile") {
                    TextField("Dockerfile", text: $dockerfile,
                              prompt: Text("<context>/Dockerfile"))
                        .textFieldStyle(.roundedBorder)
                    Text("Leave blank to use the Dockerfile in the context folder. A path here "
                         + "must also sit inside that folder.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                SwiftUI.Section("Image") {
                    TextField("Tag", text: $tag, prompt: Text("myapp:latest"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Target stage", text: $target, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Platform", text: $platform, prompt: Text("linux/arm64"))
                        .textFieldStyle(.roundedBorder)
                    Toggle("Ignore the build cache", isOn: $noCache)
                }

                SwiftUI.Section("Command") {
                    Text(previewText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(previewStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
