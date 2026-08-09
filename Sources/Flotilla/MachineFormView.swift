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
            Form {
                // Image and name in one section rather than two. Five grouped sections did not
                // fit the sheet, and the command preview — the one part that tells you exactly
                // what is about to run — was the section that fell off the bottom.
                SwiftUI.Section("Machine") {
                    TextField("Image reference", text: $image, prompt: Text("alpine:3.22"))
                        .textFieldStyle(.roundedBorder)
                    Picker("Known good", selection: $image) {
                        Text("Choose…").tag("")
                        ForEach(Self.suggestions, id: \.reference) { suggestion in
                            Text("\(suggestion.reference) — \(suggestion.note)")
                                .tag(suggestion.reference)
                        }
                    }
                    // Kept to two lines. The first draft ran to four and pushed the home-mount
                    // warning and the command preview below the fold — the two things in this
                    // form most worth reading before pressing Create.
                    Label("Built from a container image, not an installer. The image supplies the "
                          + "userland; `container` supplies the kernel.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    // Said before the pull, not after. Ubuntu, Debian, Fedora and BusyBox all
                    // pull happily, create a machine, and then fail to boot; without this the
                    // user spends a minute waiting to find that out.
                    if !trimmedImage.isEmpty && !Self.isKnownGood(trimmedImage) {
                        Label("Most images do not boot as a machine — Ubuntu, Debian, Fedora and "
                              + "BusyBox were each tried and each failed after pulling.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    TextField("Name", text: $name, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                }

                SwiftUI.Section("Resources") {
                    Stepper(value: $cpus, in: 1...ProcessInfo.processInfo.processorCount) {
                        LabeledContent("CPUs", value: "\(cpus)")
                    }
                    Stepper(value: $memoryGB, in: 1...max(1, Self.hostMemoryGB())) {
                        LabeledContent("Memory", value: "\(memoryGB) GB")
                    }
                }

                SwiftUI.Section("Home directory") {
                    Picker("Mount", selection: $homeMount) {
                        Text("Read-write").tag("rw")
                        Text("Read-only").tag("ro")
                        Text("Not mounted").tag("none")
                    }
                    .pickerStyle(.radioGroup)
                    // The CLI defaults this to `rw`, so it is on unless you change it. That is
                    // a filesystem grant to every container in the machine, and the review's review
                    // treats it as more dangerous than a bind mount for exactly that reason.
                    if homeMount == "rw" {
                        Label("Writable from inside the machine, and so from every container "
                              + "running in it.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }

                SwiftUI.Section("Command") {
                    // The Run sheet's validated live preview, same convention: what will run,
                    // built through the allowlist, before you press anything.
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(previewStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            // The form takes the space it needs and the window scrolls it; no hand-picked
            // height to trim copy against.
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Back, then the title — the same header shape as the machine and container detail
    /// screens, so leaving a form works exactly like leaving a detail.
    private var header: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) { Image(systemName: "chevron.left") }
                .help("Back to Machines")
                .accessibilityLabel("Back to Machines")
            Image(systemName: "plus.rectangle.on.folder")
                .font(.system(size: 17)).foregroundStyle(.secondary)
            Text("New Machine").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        case .success(let command): return command.auditDescription
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
