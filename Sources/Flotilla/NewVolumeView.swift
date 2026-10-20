import SwiftUI
import FlotillaCore

/// The existing volume form, shared by Volumes and Suggestions (Q66).
struct NewVolumeView: View {
    let model: AppModel
    let dismiss: () -> Void
    var prefill: VolumeSuggestion? = nil
    var initialHost: HostRef = .local

    @State private var newVolumeName = ""
    @State private var suggestedMount: String?
    @State private var newSize = ""
    @State private var newLabels: [String] = []
    @State private var newDriverOptions: [String] = []
    @State private var newHost: HostRef = .local
    @State private var edits = FormEditTracker()
    @State private var formToken = UUID()

    private var editSignature: String {
        [newVolumeName, newSize, newHost.token, newLabels.joined(separator: ","),
         newDriverOptions.joined(separator: ",")].joined(separator: "\u{1}")
    }

    private var hostChoices: [(ref: HostRef, name: String)] {
        [(HostRef.local, model.hostLabel)]
            + model.hostMode.trustedHosts.map { (HostRef.peer($0.fingerprint), $0.displayName) }
    }

    /// Embedded, not modal — see `MachineFormView` for the 9 August reversal.
    ///
    /// **The `ScrollView` is load-bearing, and its absence blanked the whole window.**
    /// `maxHeight: .infinity` inside a parent that is itself unbounded does not mean "fill the
    /// window", it means "as tall as you like". This form's own content asks for a lot: two
    /// `.fixedSize(horizontal: false, vertical: true)` texts and a `DisclosureGroup`. Measured on
    /// a 720pt window, the enclosing `NavigationSplitView` grew to **2020pt** and dragged
    /// everything — sidebar, toolbar, form — off the top of the window at y=-90. The result is a
    /// blank window you cannot navigate out of, because the Back button is off-screen too, and
    /// the only way out is quitting the app. A tester lost three phases to it.
    ///
    /// The three create screens that never showed this — `MachineFormView`, `RunSheetView`,
    /// `BuildImageView` — all wrap their fields in a `Form`, which bounds its content the same
    /// way. Volumes and Networks were the only two with neither, and were the only two that
    /// broke. Anything with a `FormHeader` needs one or the other; `Scripts/check-form-bounds.sh`
    /// now enforces that.
    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "New Volume", systemImage: "externaldrive.badge.plus",
                       hasUnsavedChanges: edits.isDirty(editSignature),
                       onBack: dismiss, token: formToken,
                       actions: createActions)
            Divider()
            if let unclaimedProblem {
                FormBand {
                    Label(unclaimedProblem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }
            }
            FormScaffold {
                createForm
            } preview: {
                railPreview
            }
        }
        .onAppear {
            newHost = initialHost
            if let prefill {
                newVolumeName = ResourceSuggestions.uniqueName(prefill.baseName, taken: volumeNames(on: newHost))
                newSize = prefill.size
                suggestedMount = prefill.mountPath
            }
            edits.open(editSignature)
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let suggestedMount {
                Label("Mount it in the container at \(suggestedMount).", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if hostChoices.count > 1 {
                FormField("Create on",
                          help: FieldHelp("Which Mac the volume is created on.",
                                          detail: "A volume belongs to one Mac: a container mounts the volumes on its own Mac.")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $newHost) {
                            ForEach(hostChoices, id: \.ref) { Text($0.name).tag($0.ref) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        ContainerSkewNote(model: model, hosts: [newHost])
                    }
                }
            }
            FormField("Name",
                      help: FieldHelp(
                          "What the volume is called, and how you mount it into a container.",
                          detail: "In the Run form's Volumes field you write it as `name:/path`.",
                          example: "Letters, numbers, dots, dashes or\nunderscores. Must start with a letter\nor number. No spaces."),
                      problem: nameProblem) {
                TextField("my-data", text: $newVolumeName)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            FormField("Size",
                      help: FieldHelp(
                          "How large the volume may grow.",
                          detail: "A number with an optional K, M or G suffix.",
                          example: "64M\n2G\n512G",
                          warning: "Left empty, the driver provisions 512 GiB as a sparse image. It does not consume that — but the list shows it as 512 GB capacity, which is why an untouched volume looks alarming there."),
                      problem: sizeProblem,
                      optional: true) {
                TextField("64M, 2G, …", text: $newSize)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            // Expanded, not behind a disclosure triangle. There are two short lists here; hiding
            // them behind a chevron mostly hides that they exist.
            VStack(alignment: .leading, spacing: 14) {
                FormSectionHeader(title: "Advanced")

                FormField("Labels",
                          help: FieldHelp(
                              "Your own key=value metadata, carried on the volume.",
                              detail: "Up to eight. Nothing reads them but you and whatever you script.",
                              example: "team=infra\nenv=staging"),
                          optional: true) {
                    keyValueList($newLabels, title: nil, placeholder: "team=infra")
                }

                FormField("Driver options",
                          help: FieldHelp(
                              "Options passed straight through to the storage driver.",
                              detail: "Up to eight, again as key=value. What they mean is the driver's business, not Flotilla's.",
                              example: "type=fast"),
                          optional: true) {
                    keyValueList($newDriverOptions, title: nil, placeholder: "type=fast")
                }
            }
        }
    }

    /// The validated command, in the rail.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text((["container"] + ContainerCLI.createVolumeArguments(trimmedName, options: options))
                    .joined(separator: " "))
                .font(.system(size: 11, design: .monospaced))
                // Red when the command is refused, like the machine form's preview. It was
                // `.secondary` unconditionally, so a rejected command looked exactly like an
                // accepted one — which is how a disabled button ended up with no signal anywhere
                // on the screen.
                .foregroundStyle(anyProblem != nil && !trimmedName.isEmpty
                                 ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !newHost.isLocal {
                Label("Runs on \(model.hostMode.hostName(newHost, local: model.hostLabel))",
                      systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Names already taken on a Mac, so a suggestion never proposes one that exists there.
    private func volumeNames(on host: HostRef) -> Set<String> {
        switch host {
        case .local: Set(model.volumes.map(\.name))
        case .peer(let fingerprint): Set(model.hostMode.volumeSnapshots[fingerprint]?.items.map(\.name) ?? [])
        }
    }

    private var createActions: FormActions {
        FormActions(.startsJob("Create", isDisabled: trimmedName.isEmpty || anyProblem != nil) {
            let name = trimmedName
            let opts = options
            let host = newHost
            dismiss()
            Task { await model.createVolume(name, options: opts, host: host) }
        })
    }

    /// Repeatable `key=value` flags, capped at the `Allowlist`'s own maximum of 8 — shown
    /// rather than silently enforced.
    @ViewBuilder
    private func keyValueList(_ list: Binding<[String]>, title: String? = nil,
                              placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // `title` is nil when a `FormField` already supplies the label; the counter stays
            // either way, because the cap is the thing worth showing rather than enforcing
            // silently.
            HStack {
                if let title {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(list.wrappedValue.count)/8").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { list.wrappedValue.indices.contains(index) ? list.wrappedValue[index] : "" },
                        set: { if list.wrappedValue.indices.contains(index) { list.wrappedValue[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button { list.wrappedValue.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this entry")
                    .accessibilityLabel(Self.removeLabel(list.wrappedValue, at: index))
                }
            }
            Button { list.wrappedValue.append("") } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(list.wrappedValue.count >= 8)
        }
    }

    /// "Remove env=prod", not a bare "Remove" on every row of both lists.
    private static func removeLabel(_ entries: [String], at index: Int) -> String {
        let entry = entries.indices.contains(index)
            ? entries[index].trimmingCharacters(in: .whitespaces) : ""
        return entry.isEmpty ? "Remove empty entry \(index + 1)" : "Remove \(entry)"
    }

    private var options: ContainerCLI.VolumeOptions {
        ContainerCLI.VolumeOptions(
            size: newSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : newSize.trimmingCharacters(in: .whitespacesAndNewlines),
            labels: newLabels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            driverOptions: newDriverOptions.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }

    private var sizeProblem: String? {
        let value = newSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments("placeholder", options: .init(size: value)))
    }

    /// One pass over the whole command, so Create is disabled for any bad field — labels and
    /// driver options included, not just the two with their own messages.
    private var anyProblem: String? {
        problem(in: ContainerCLI.createVolumeArguments(
            trimmedName.isEmpty ? "placeholder" : trimmedName, options: options))
    }

    /// Why Create is refusing, when no field has claimed it — the same backstop the network form
    /// carries, and for the same reason: this form validates the whole command to disable the
    /// button and only two of its fields can explain themselves.
    private var unclaimedProblem: String? {
        guard let anyProblem, !trimmedName.isEmpty else { return nil }
        let claimed = [nameProblem, sizeProblem].compactMap { $0 }
        return claimed.contains(anyProblem) ? nil : anyProblem
    }

    private func problem(in args: [String]) -> String? {
        switch Allowlist.validate(args) {
        case .success: nil
        case .failure(let error): error.description
        }
    }

    private var trimmedName: String {
        newVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        return problem(in: ContainerCLI.createVolumeArguments(trimmedName))
    }

}
