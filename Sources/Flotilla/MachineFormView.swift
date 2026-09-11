import SwiftUI
import FlotillaCore

/// Create a machine — an **embedded screen**, not a modal.
///
/// This reverses the "forms are modal, places are navigable" rule recorded in `CLAUDE.md`, at
/// the owner's direction on 9 August, and the newer argument is better: once Machines grew an
/// embedded detail with a Back button and a tab strip, a floating card with its own close
/// button was the odd one out. Every other full-screen surface in the app is reached and left
/// the same way, so this is too — Back at the top left, Save at the bottom right.
///
/// It also disposes of a real complaint. The modal was a fixed 560×660, chosen by hand, which
/// meant copy had to be trimmed to fit rather than the container adapting to the content.
/// Embedded, it takes the window.
///
/// The thing this form has to teach, because it is genuinely surprising: **a machine is built
/// from a container image, not an installer.** `alpine:3.22`, pulled from the same registry as
/// any other image. The image supplies **userland only** — the kernel comes from the runtime,
/// verified by the image having no `/boot` at all. Someone who expects a Vagrant box will
/// otherwise draw the wrong conclusion from a familiar-looking field.
///
/// The second thing, which cost an hour to find out: **the choice of image is much narrower than
/// it looks.** In practice only Alpine boots — see `suggestions` for what was tried. The field
/// still accepts anything, because the constraint is the runtime's and may lift, but the form
/// says so up front rather than letting a pull succeed and a boot fail.
struct MachineFormView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var image = ""
    @State private var name = ""
    @State private var cpus: Int
    @State private var memoryGB: Int
    @State private var homeMount = "rw"
    @State private var creating = false
    @State private var edits = FormEditTracker()

    /// Everything a Back would throw away. Captured on appear rather than compared to defaults,
    /// because the resource defaults come from Settings ▸ Resources and are not constants here.
    private var editSignature: String {
        [image, name, homeMount, "\(cpus)", "\(memoryGB)"].joined(separator: "\u{1}")
    }

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        // **Not** half the host, which is what `machine create` defaults to.
        //
        // Matching the CLI sounded principled and produced 6 cores and 32 GB on this Mac — for
        // a VM you spin up to try something in. That is most of the machine handed to a
        // scratch workload, and the person clicking Save has no reason to expect it. A form's
        // default is a recommendation, and recommending half your Mac is bad advice.
        //
        // 2 cores and 4 GB instead: enough to boot Alpine, run a package manager and build
        // something small, and cheap enough to leave running. Both steppers go up to the full
        // host, so nothing is taken away — the difference is which end you start from.
        _cpus = State(initialValue: min(2, ProcessInfo.processInfo.processorCount))
        _memoryGB = State(initialValue: min(4, max(1, Self.hostMemoryGB())))
    }

    /// Suggestions, not a closed list — the field takes any image reference.
    ///
    /// The first draft of this list offered `ubuntu:24.04`, `debian:13` and `fedora:41` because
    /// those are the distributions people ask for. **Every one of them fails.** Tried against
    /// the live CLI on 3 August: each pulls, each creates a machine record, and each then dies
    /// on boot with `no PID data from sync pipe` or `cannot exec: container is not running`.
    /// `busybox:latest` fails the same way. Only Alpine boots — `3.22` and `latest` both do,
    /// which is presumably why `alpine:3.22` is the example in `machine create --help`.
    ///
    /// So the list is short because reality is short. Offering the three familiar names would
    /// have been a picker whose options mostly do not work, which is worse than no picker:
    /// the failure arrives a minute later, after a 100 MB pull, and looks like our bug.
    ///
    /// One caveat on the method, because it nearly produced the wrong answer: a single probe
    /// recorded `alpine:latest` as failing. It had not — the boot was still settling when the
    /// probe ran. Re-running it showed the machine running. Do not add or remove an entry here
    /// on one measurement.
    private static let suggestions: [(reference: String, note: String)] = [
        ("alpine:3.22", "verified — apk, musl libc"),
        ("alpine:latest", "verified — tracks the newest Alpine"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // `FormScaffold` owns the bounded scroll, the 640pt column and the explainer rail.
            // `Scripts/check-form-bounds.sh` enforces that every `FormHeader` screen has something
            // that bounds its height — without it the content grows the split view instead of
            // scrolling, which is the fault that blanked the Volumes and Networks forms.
            FormScaffold {
                machineSection
                resourcesSection
                homeSection
            } preview: {
                railPreview
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { edits.open(editSignature) }
    }

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The surprise a machine form has to get out of the way first. Someone expecting a
            // Vagrant box will otherwise draw the wrong conclusion from a familiar-looking
            // field, and find out only after a pull and a failed boot.
            FormSectionHeader(title: "Machine",
                              note: "Built from a container image, not an installer. The image "
                                  + "supplies the userland; `container` supplies the kernel.")
            FormField("Image reference",
                      help: FieldHelp(
                          "A machine boots from a container image, not an installer.",
                          detail: "The image supplies the userland; the kernel comes from Apple's runtime. That is why this pulls from Docker Hub, and why a machine's disk reads tens of megabytes rather than gigabytes.",
                          example: "alpine:3.22    verified\nalpine:latest  verified",
                          warning: "In practice only Alpine boots. Ubuntu, Debian, Fedora and BusyBox each pull around 100 MB, create a machine record, and then fail to boot.")) {
                TextField("alpine:3.22", text: $image)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            // Said before the pull, not after. Ubuntu, Debian, Fedora and BusyBox all pull
            // happily, create a machine, and then fail to boot; without this the user spends a
            // minute waiting to find that out.
            if !trimmedImage.isEmpty && !Self.isKnownGood(trimmedImage) {
                Label("Most images do not boot as a machine — Ubuntu, Debian, Fedora and "
                      + "BusyBox were each tried and each failed after pulling.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FormField("Verified images",
                      help: FieldHelp(
                          "Fills the field above.",
                          detail: "The list is short because reality is short — these are the images that have actually been booted successfully as a machine.",
                          example: "Want a full Ubuntu or Fedora VM?\nUse Lima, UTM or Vagrant. This is\nnot that, and will not become it.")) {
                Picker("", selection: $image) {
                    Text("Choose…").tag("")
                    ForEach(Self.suggestions, id: \.reference) { suggestion in
                        Text("\(suggestion.reference) — \(suggestion.note)")
                            .tag(suggestion.reference)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            FormField("Name",
                      help: FieldHelp(
                          "How you refer to the machine afterwards — shell, logs, stop, delete.",
                          example: "Letters, numbers, dots, dashes or\nunderscores. Must start with a letter\nor number. No spaces."),
                      optional: true) {
                TextField("dev", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }
        }
    }

    private var resourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Resources",
                              note: "This Mac has \(ProcessInfo.processInfo.processorCount) cores "
                                  + "and \(Self.hostMemoryGB()) GB.")

            FormField("CPUs",
                      help: FieldHelp(
                          "Virtual CPUs for this machine.",
                          detail: "1 to \(ProcessInfo.processInfo.processorCount) on this Mac. Two is enough to boot Alpine, run a package manager and build something small.")) {
                Stepper(value: $cpus, in: 1...ProcessInfo.processInfo.processorCount) {
                    Text("\(cpus)").monospacedDigit()
                }
                .fixedSize()
            }

            FormField("Memory",
                      help: FieldHelp(
                          "Memory for this machine, in whole gigabytes.",
                          detail: "1 to \(Self.hostMemoryGB()) GB on this Mac.",
                          warning: "`container` itself defaults this to half of system memory — \(max(1, Self.hostMemoryGB() / 2)) GB here, for a VM you spin up to try something in. This form starts at 4 GB instead.")) {
                Stepper(value: $memoryGB, in: 1...max(1, Self.hostMemoryGB())) {
                    Text("\(memoryGB) GB").monospacedDigit()
                }
                .fixedSize()
            }
        }
    }

    private var homeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormSectionHeader(title: "Home directory",
                              note: "Your Mac's home directory, mounted inside the machine.")

            FormField("Mount",
                      help: FieldHelp(
                          "Whether this Mac's home directory is visible inside the machine.",
                          example: """
                              Read-write   the CLI default
                              Read-only    visible, not writable
                              Not mounted  no access at all
                              """,
                          warning: "Read-write is a grant to everything running in the machine, not just to you at its shell.")) {
                Picker("", selection: $homeMount) {
                    Text("Read-write").tag("rw")
                    Text("Read-only").tag("ro")
                    Text("Not mounted").tag("none")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // The CLI defaults this to `rw`, so it is on unless you change it. That is a
            // filesystem grant to every container in the machine, and the review treats it as
            // more dangerous than a bind mount for exactly that reason.
            if homeMount == "rw" {
                Label("Writable from inside the machine, and so from every container "
                      + "running in it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What will run, plus the one thing this form cannot offer. Both live in the rail: the
    /// preview because it is the answer to "what is this about to do", and the limitation because
    /// the alternative is leaving someone to hunt for a control that cannot exist.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)

            HStack(alignment: .top, spacing: 8) {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(previewStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                CommandPreviewCopyButton(command: preview,
                                         help: "Copy the machine command to the clipboard")
            }

            Divider()
                .padding(.vertical, 2)

            Text("A machine cannot join a network or mount a volume — `container machine create` "
                 + "has no option for either. Only the home-directory mount above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Back, then the title — the same header shape as the machine and container detail
    /// screens, so leaving a form works exactly like leaving a detail.
    ///
    /// It used to carry an "Import Flotillafile…" button in `FormHeader`'s trailing slot. That is
    /// **withheld from this release** at the owner's direction: the format is not settled enough
    /// to put in front of testers, and a half-ready import is worse than none. The parser and its
    /// 35 tests stay in `FlotillaCore` untouched, so restoring this is a UI change and nothing
    /// more.
    private var header: some View {
        FormHeader(title: "New Machine", systemImage: "plus.rectangle.on.folder",
                   hasUnsavedChanges: edits.isDirty(editSignature), onBack: dismiss)
    }

    /// Save lives bottom-right, where a form's commit belongs on macOS.
    private var footer: some View {
        HStack(spacing: 8) {
            if creating {
                ProgressView().controlSize(.small)
                Text("Creating… this pulls the image and boots the VM.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Save") { Task { await create() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!previewIsValid || creating)
        }
        .padding(12)
    }

    // MARK: Preview

    /// Matches on the repository, not the whole reference, so `alpine:3.19` counts as known
    /// good too — the tag is not what decides it.
    private static func isKnownGood(_ reference: String) -> Bool {
        reference == "alpine" || reference.hasPrefix("alpine:")
    }

    private var trimmedImage: String { image.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Validated through the allowlist rather than string-formatted for display, so the preview
    /// cannot say one thing while the action does another — and an invalid field shows its real
    /// refusal instead of a generic "check your input".
    private var validated: Result<ValidatedCommand, AllowlistError> {
        var argv = ["machine", "create"]
        if !trimmedName.isEmpty { argv += ["-n", trimmedName] }
        // Bare `ro|rw|none` — `machine create --home-mount` does not take the `key=value`
        // form that `machine set` does. See `ValueShape.homeMountMode`.
        argv += ["--cpus", "\(cpus)", "--memory", "\(memoryGB)G", "--home-mount", homeMount]
        argv.append(trimmedImage)
        return Allowlist.validate(argv)
    }

    /// Red only for a *refusal*. An empty field is not an error yet, and colouring
    /// "Enter an image reference." as one greets you with a problem you have not caused.
    private var previewStyle: AnyShapeStyle {
        if trimmedImage.isEmpty || previewIsValid { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(Theme.danger)
    }

    private var previewIsValid: Bool {
        if case .success = validated { return true }
        return false
    }

    private var preview: String {
        guard !trimmedImage.isEmpty else { return "Enter an image reference." }
        switch validated {
        case .success(let command): return command.localPreview
        case .failure(let error): return String(describing: error)
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let succeeded = await model.createMachine(
            image: trimmedImage,
            name: trimmedName.isEmpty ? nil : trimmedName,
            cpus: cpus,
            memory: "\(memoryGB)G",
            homeMount: homeMount
        )
        if succeeded { dismiss() }
    }

    private static func hostMemoryGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}
