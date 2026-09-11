import SwiftUI
import AppKit
import FlotillaCore

/// One form for getting an image onto this Mac, however you get it: **Pull** it from a registry
/// or **Build** it from a Dockerfile.
///
/// They were two toolbar buttons and two screens — a hammer and a download arrow — which made
/// "add an image" two places to look for one intention, in a section where every other action is
/// a single control. Both forms are short: pull is two fields, build is five, and neither filled
/// the column it was given.
///
/// **The mode picker is the first thing in the column, not a tab bar above the form.** It is a
/// field like any other: it changes what the rest of the form asks for, which is exactly what
/// the fields below it do to each other. Putting it in the column also means the rail follows it
/// for free — `FormScaffold` collects help from whichever fields are on screen, so switching mode
/// re-writes the guidance with no second mapping to maintain.
struct NewImageView: View {
    let model: AppModel
    /// Which half to open on. The Images toolbar opens Pull; the menu bar's two commands and
    /// `AppModel.pendingBuildForm` still name a specific one, and a merged form that ignored
    /// that would answer "Build an image…" with a pull form.
    let initialMode: Mode
    let dismiss: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case pull = "Pull", build = "Build"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .pull: "arrow.down.circle"
            case .build: "hammer"
            }
        }
    }

    @State private var mode: Mode

    // Pull
    @State private var reference = ""
    /// HTTPS unless someone changes it, every time the form opens. Deliberately **not**
    /// remembered: a persisted "use plaintext" would apply to the next pull from a public
    /// registry too, and the one thing worse than no HTTP support is HTTP nobody asked for.
    @State private var scheme = ContainerCLI.RegistryScheme.default

    // Build
    @State private var context: URL?
    @State private var dockerfile = ""
    @State private var tag = ""
    @State private var target = ""
    @State private var platform = ""
    @State private var noCache = false
    @State private var building = false

    @State private var edits = FormEditTracker()

    init(model: AppModel, initialMode: Mode = .pull, dismiss: @escaping () -> Void) {
        self.model = model
        self.initialMode = initialMode
        self.dismiss = dismiss
        _mode = State(initialValue: initialMode)
    }

    /// Both halves, so switching mode with something typed still counts as unsaved work — the
    /// discard prompt is about the form, not about whichever half is showing.
    private var editSignature: String {
        [reference, scheme.rawValue, context?.path ?? "", dockerfile, tag, target, platform,
         "\(noCache)"].joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Image", systemImage: "plus",
                       hasUnsavedChanges: edits.isDirty(editSignature) && model.activePull == nil,
                       onBack: dismiss)
            Divider()
            if let pull = model.activePull {
                // The form *is* the progress screen while its pull runs. Dismissing on submit —
                // which this did once — reported a forty-second network operation by showing
                // nothing at all and then growing a row.
                ScrollView {
                    ImagePullStatus(pull: pull, compact: false)
                        .padding(20)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                FormScaffold {
                    form
                } preview: {
                    railPreview
                }
                Divider()
                footer
            }
        }
        .onAppear { edits.open(editSignature) }
    }

    // MARK: Fields

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormField("Source",
                      help: FieldHelp(
                          "Where the image comes from.",
                          // Plain text: `FieldHelp.detail` is rendered as-is, so markdown
                          // emphasis arrives as literal asterisks. Backticks are the one
                          // convention the rail already reads as code by eye.
                          detail: "Pull downloads one somebody else published. Build makes one "
                              + "from a Dockerfile on this Mac.",
                          example: "Pull for nginx or postgres\nBuild for your own project")) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { option in
                        Label(option.rawValue, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            switch mode {
            case .pull: pullFields
            case .build: buildFields
            }
        }
    }

    @ViewBuilder
    private var pullFields: some View {
        FormField("Reference",
                  help: FieldHelp(
                      "What to pull, and where from.",
                      detail: "A bare name is completed the way the CLI completes it — "
                          + "`nginx` becomes `docker.io/library/nginx:latest`. Lead with a "
                          + "registry host to pull from anywhere else.",
                      example: "nginx\nnginx:alpine\nghcr.io/owner/app:1.2.3\nalpine@sha256:…",
                      warning: "A tag can be moved by whoever published it. Pin a digest "
                          + "(`@sha256:…`) when you need the same bytes every time."),
                  problem: referenceProblem) {
            TextField("nginx:alpine", text: $reference)
                .textFieldStyle(.roundedBorder)
                .monospaced()
                .onSubmit(submit)
        }

        // An action, so it stays in the column rather than moving to the rail with the help.
        Link(destination: URL(string: "https://hub.docker.com/search?image_filter=official")!) {
            Label("Browse Docker Hub", systemImage: "arrow.up.right.square")
                .font(.callout)
        }
        // `Link` draws in the system accent, which made this the one blue thing in an app whose
        // links are all brand pink. Same reason `Theme.rowName` exists.
        .foregroundStyle(Theme.accentText)

        FormSectionHeader(title: "Registry",
                          note: "How Flotilla reaches it. Almost always the default.")

        FormField("Connect using",
                  help: FieldHelp(
                      "HTTPS, unless the registry has no TLS.",
                      detail: "`container` 1.4.1 removed the old `auto` scheme that fell back "
                          + "to plaintext on its own, so a development registry without TLS is "
                          + "unreachable unless you ask for HTTP here.",
                      example: "http is for localhost:5000\nand your own network — nothing\non the internet",
                      warning: "It must be an anonymous registry: `container` refuses to send "
                          + "credentials over HTTP even when you ask for it. The choice is not "
                          + "remembered, so the next pull is HTTPS again.")) {
            Picker("", selection: $scheme) {
                Text("HTTPS").tag(ContainerCLI.RegistryScheme.https)
                Text("HTTP").tag(ContainerCLI.RegistryScheme.http)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        if scheme == .http {
            // In the column as well as the rail: a warning that has to be read *before*
            // pressing Pull cannot live only where the reader may not be looking.
            Label("Image layers cross the network unencrypted.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buildFields: some View {
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

        FormSectionHeader(title: "Image")

        // The default is worth stating precisely: `container build -t` documents it as a UUID,
        // so an untagged build does not produce `<none>` you can find later — it produces a
        // random name.
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

    // MARK: Rail and footer

    /// Kept beside the active field because it is the answer to what the button will run, not
    /// another field to discover at the end of the form.
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

    private var footer: some View {
        HStack(spacing: 8) {
            if building {
                ProgressView().controlSize(.small)
                Text("Building… this can take minutes and pulls the base image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: dismiss)
            // Named for what it does rather than a generic Create: the two halves of this form
            // do genuinely different things and the button is the last chance to say which.
            Button(mode.rawValue, action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || building)
        }
        .padding(12)
    }

    // MARK: Validation and actions

    private var trimmedReference: String { reference.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDockerfile: String { dockerfile.trimmingCharacters(in: .whitespaces) }
    private var trimmedTag: String { tag.trimmingCharacters(in: .whitespaces) }

    /// The allowlist's own refusal, so the form cannot accept something the table will reject.
    private var referenceProblem: String? {
        guard !trimmedReference.isEmpty else { return nil }
        if case .failure(let error) = Allowlist.validate(
            ContainerCLI.pullArguments(trimmedReference, scheme: scheme)) {
            return error.description
        }
        return nil
    }

    private var buildPreview: Result<ValidatedCommand, AllowlistError> {
        AppModel.buildPreview(context: context,
                              dockerfile: trimmedDockerfile.isEmpty ? nil : trimmedDockerfile,
                              tag: trimmedTag.isEmpty ? nil : trimmedTag,
                              buildArgs: [], labels: [], noCache: noCache,
                              platform: platform.trimmingCharacters(in: .whitespaces),
                              target: target.trimmingCharacters(in: .whitespaces))
    }

    private var canSubmit: Bool {
        switch mode {
        case .pull:
            return !trimmedReference.isEmpty && referenceProblem == nil && model.activePull == nil
        case .build:
            if case .success = buildPreview { return true }
            return false
        }
    }

    /// Guidance before there is anything to run; the real refusal afterwards. Same rule as the
    /// Run form: an untouched form is not a broken one.
    private var previewText: String {
        switch mode {
        case .pull:
            let argv = ContainerCLI.pullArguments(
                trimmedReference.isEmpty ? "<reference>" : trimmedReference, scheme: scheme)
            return (["container"] + argv).joined(separator: " ")
        case .build:
            guard context != nil else { return "Choose a context folder to build the command." }
            switch buildPreview {
            case .success(let command): return command.localPreview
            case .failure(let error): return error.description
            }
        }
    }

    private var previewStyle: AnyShapeStyle {
        switch mode {
        case .pull:
            return referenceProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger)
        case .build:
            if context == nil || canSubmit { return AnyShapeStyle(.secondary) }
            return AnyShapeStyle(Theme.danger)
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

    private func submit() {
        guard canSubmit, !building else { return }
        switch mode {
        case .pull:
            // Returns to the list only on success, and only after `pullImage` has refreshed it,
            // so the image that was just pulled is present the moment the list appears. On
            // failure the form stays put with the reference intact: the likeliest cause is a
            // typo in it.
            let wanted = trimmedReference
            let using = scheme
            Task {
                if await model.pullImage(wanted, scheme: using) { dismiss() }
            }
        case .build:
            guard let context else { return }
            Task { await build(context: context) }
        }
    }

    private func build(context: URL) async {
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
