import SwiftUI
import Foundation
import FlotillaCore

/// Creating or editing a group, and editing one service inside it.
///
/// **Nothing is written until Save.** The whole group lives in `draft` — including its members,
/// which is why validation goes through `GroupBook.draftProblem(...)` rather than the plain
/// `problem(withMemberName:)`: a service you have just typed is not in the book yet, and the
/// stored copy of the group you are editing must not report its own unchanged members as clashes.
struct GroupFormView: View {
    let model: AppModel
    let target: GroupFormTarget
    /// Supplied by the presenter rather than `@Environment(\.dismiss)`, for the reason
    /// `NewNetworkView.dismiss` gives.
    let dismiss: () -> Void

    @State private var draft: ContainerGroup
    /// The service being edited, or nil while the group itself is on screen. One screen at a
    /// time, with Back — the same shape as every other form in the app since 9 August.
    @State private var editingMember: GroupMember?
    /// Whether `editingMember` is new, so Back from a half-typed service does not leave one
    /// behind and Save knows to append rather than replace.
    @State private var memberIsNew = false
    @State private var edits = FormEditTracker()
    @State private var saveError: String?

    init(model: AppModel, target: GroupFormTarget, dismiss: @escaping () -> Void) {
        self.model = model
        self.target = target
        self.dismiss = dismiss
        switch target {
        case .new:
            _draft = State(initialValue: ContainerGroup(name: ""))
        case .existing(let id):
            _draft = State(initialValue: model.groups.group(id) ?? ContainerGroup(name: ""))
        }
    }

    private var isNew: Bool { if case .new = target { true } else { false } }

    var body: some View {
        Group {
            if let member = editingMember {
                GroupMemberFormView(
                    model: model,
                    member: member,
                    isNew: memberIsNew,
                    problem: { name in
                        model.groups.book.draftProblem(
                            withMemberName: name, excluding: member.id,
                            editing: isNew ? nil : draft.id, draftMembers: draft.members)
                    },
                    imageProblem: { model.groups.problem(withImage: $0) },
                    onCancel: { editingMember = nil },
                    onSave: { saved in
                        if let slot = draft.members.firstIndex(where: { $0.id == saved.id }) {
                            draft.members[slot] = saved
                        } else {
                            draft.members.append(saved)
                        }
                        editingMember = nil
                    })
            } else {
                groupScreen
            }
        }
        .onAppear { edits.open(editSignature) }
    }

    // MARK: The group itself

    private var groupScreen: some View {
        VStack(spacing: 0) {
            FormHeader(title: isNew ? "New Group" : "Edit Group",
                       systemImage: "rectangle.3.group",
                       hasUnsavedChanges: edits.isDirty(editSignature),
                       onBack: dismiss)
            Divider()
            FormScaffold {
                form
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
    }

    private var editSignature: String {
        ([draft.name, draft.network ?? ""]
            + draft.members.map { "\($0.id)\u{2}\($0.name)\u{2}\($0.image)\u{2}\($0.ports.joined(separator: ","))" })
            .joined(separator: "\u{1}")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormField("Name",
                      help: FieldHelp(
                          "What this set of containers is called.",
                          detail: "Yours alone — it is never passed to `container`, and no container is named after it."),
                      problem: nameProblem) {
                TextField("Shop", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormField("Network",
                      help: model.networks.isEmpty
                          ? FieldHelp(
                              "No networks yet.",
                              detail: "Create one in the Networks section and it will appear here.")
                          : FieldHelp(
                              "One network for every service in the group.",
                              detail: "Chosen once here rather than per service: networks are isolated from one another, so a group spread across two of them would be a group whose halves cannot talk.",
                              warning: "Applied when a service is first created. A service that already exists keeps the network it was created on — recreate it to move it."),
                      optional: true) {
                Picker("", selection: Binding(get: { draft.network ?? "" },
                                              set: { draft.network = $0.isEmpty ? nil : $0 })) {
                    Text("Default").tag("")
                    ForEach(model.networks, id: \.id) { available in
                        Text(available.name).tag(available.name)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.networks.isEmpty)
            }

            VStack(alignment: .leading, spacing: 14) {
                FormSectionHeader(
                    title: "Services",
                    note: "Started in this order, top to bottom, and stopped in reverse.")
                servicesList
            }
        }
    }

    @ViewBuilder
    private var servicesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.members.isEmpty {
                // Not an empty box with nothing in it: the sentence says what a service is,
                // because this is the first place the word appears.
                Text("No services yet. A service is one container — an image, a name, and the ports and volumes it needs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(draft.members.enumerated()), id: \.element.id) { index, member in
                serviceRow(member, at: index)
            }
            Button {
                memberIsNew = true
                editingMember = GroupMember(name: "", image: "")
            } label: {
                Label("Add Service", systemImage: "plus")
            }
            .buttonStyle(.link)
            .foregroundStyle(Theme.accentText)
            .padding(.top, 2)
        }
    }

    private func serviceRow(_ member: GroupMember, at index: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name).fontWeight(.medium)
                Text(member.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            IconActionButton(systemImage: "chevron.up", label: "Move \(member.name) earlier",
                             help: "Start \(member.name) earlier",
                             disabled: index == 0) {
                draft.members.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
            }
            IconActionButton(systemImage: "chevron.down", label: "Move \(member.name) later",
                             help: "Start \(member.name) later",
                             disabled: index == draft.members.count - 1) {
                draft.members.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
            }
            IconActionButton(systemImage: "pencil", label: "Edit \(member.name)",
                             help: "Edit \(member.name)") {
                memberIsNew = false
                editingMember = member
            }
            IconActionButton(systemImage: "minus.circle", label: "Remove \(member.name)",
                             help: "Remove \(member.name) from this group", destructive: true) {
                draft.members.removeAll { $0.id == member.id }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Validation and saving

    private var nameProblem: String? {
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }  // Empty is "not finished", not "wrong".
        return model.groups.problem(withName: trimmed, excluding: isNew ? nil : draft.id)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && nameProblem == nil
    }

    /// The sequence Start will issue, so the rail answers "what does this actually do".
    ///
    /// Every line is `container run`, unconditionally — unlike the progress panel's preview,
    /// which can see which containers already exist. A form is about what the group *is*, and a
    /// preview that changed depending on what happened to be running would be a moving target.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What Start will run", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            if draft.members.isEmpty {
                Text("Add a service to see the commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(draft.members.map { Self.preview(of: $0, network: draft.network) }
                        .joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("A service whose container already exists is started rather than re-created.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One member's command exactly as it would run — through `Allowlist`, so the separator the
    /// input grammar carries is stripped the same way execution strips it. A member that does not
    /// validate shows the refusal instead of a command that could never run.
    static func preview(of member: GroupMember, network: String?) -> String {
        switch AppModel.runPreview(image: member.image,
                                   options: member.runOptions(network: network),
                                   command: member.command) {
        case .success(let validated): validated.localPreview
        case .failure(let error): "\(member.name): \(error)"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", action: dismiss)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(12)
    }

    private func save() {
        var committed = draft
        committed.name = draft.name.trimmingCharacters(in: .whitespaces)
        do {
            try model.groups.commit(committed)
            dismiss()
        } catch {
            saveError = (error as? GroupBook.GroupError)?.description ?? String(describing: error)
        }
    }
}

/// One service, on its own screen.
///
/// The same fields the Run form collects, minus the two a group settles for you: Detach, because
/// members start in sequence and one holding the foreground would block the rest, and the network,
/// which belongs to the group. `ContainerGroup` says why neither is offered here.
struct GroupMemberFormView: View {
    let model: AppModel
    @State var member: GroupMember
    let isNew: Bool
    let problem: (String) -> String?
    let imageProblem: (String) -> String?
    let onCancel: () -> Void
    let onSave: (GroupMember) -> Void

    @State private var ports = ""
    @State private var env = ""
    @State private var volumes = ""
    @State private var command = ""
    @State private var cpus = ""
    @State private var memory = ""

    init(model: AppModel, member: GroupMember, isNew: Bool,
         problem: @escaping (String) -> String?,
         imageProblem: @escaping (String) -> String?,
         onCancel: @escaping () -> Void,
         onSave: @escaping (GroupMember) -> Void) {
        self.model = model
        _member = State(initialValue: member)
        self.isNew = isNew
        self.problem = problem
        self.imageProblem = imageProblem
        self.onCancel = onCancel
        self.onSave = onSave
        _ports = State(initialValue: member.ports.joined(separator: "\n"))
        _env = State(initialValue: member.env.joined(separator: "\n"))
        _volumes = State(initialValue: member.volumes.joined(separator: "\n"))
        _command = State(initialValue: member.command.joined(separator: " "))
        _cpus = State(initialValue: member.cpus.map(String.init) ?? "")
        _memory = State(initialValue: member.memory ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: isNew ? "Add Service" : "Edit Service",
                       systemImage: "shippingbox",
                       hasUnsavedChanges: false,
                       onBack: onCancel)
            Divider()
            FormScaffold {
                form
            } preview: {
                preview
            }
            Divider()
            footer
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormField("Name",
                      help: FieldHelp(
                          "The container's name, and the group's only handle on it.",
                          detail: "A group finds what it started by name, so this is required here even though the Run form leaves it optional.",
                          example: "db"),
                      problem: member.name.isEmpty ? nil : problem(member.name)) {
                TextField("db", text: $member.name)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            FormField("Image reference",
                      help: FieldHelp(
                          "What this service is made from. Pulled automatically if this Mac does not have it.",
                          detail: "Registry and tag are both optional — the defaults are Docker Hub and latest.",
                          example: "postgres:16"),
                      problem: member.image.isEmpty ? nil : imageProblem(member.image)) {
                TextField("postgres:16", text: $member.image)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            FormField("Ports",
                      help: FieldHelp(
                          "Published to this Mac, one per line.",
                          detail: "Also how the other services reach this one: there is no name resolution between containers, so an app finds a database at the network's gateway and this host port.",
                          example: "5432:5432\n127.0.0.1:8080:80"),
                      optional: true) {
                linesEditor($ports, placeholder: "5432:5432")
            }

            FormField("Environment variables",
                      help: FieldHelp("One KEY=VALUE per line.", example: "POSTGRES_PASSWORD=secret"),
                      optional: true) {
                linesEditor($env, placeholder: "KEY=VALUE")
            }

            FormField("Volumes",
                      help: FieldHelp(
                          "One per line, as source:/destination.",
                          detail: "A named volume or an absolute path on this Mac.",
                          example: "shop-data:/var/lib/postgresql/data"),
                      optional: true) {
                linesEditor($volumes, placeholder: "name:/path")
            }

            FormField("Command",
                      help: FieldHelp(
                          "Replaces what the image runs by default.",
                          detail: "Left empty, the image runs its own entrypoint.",
                          example: "python -m app"),
                      optional: true) {
                TextField("python -m app", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
            }

            VStack(alignment: .leading, spacing: 14) {
                FormSectionHeader(title: "Resources")
                FormField("CPUs",
                          help: FieldHelp("Whole cores.", detail: "Left empty, `container` applies its own default."),
                          optional: true) {
                    TextField("2", text: $cpus)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                FormField("Memory",
                          help: FieldHelp("With a K, M or G suffix.", example: "512M"),
                          optional: true) {
                    TextField("512M", text: $memory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }
        }
    }

    /// A plain multi-line field rather than the row-at-a-time editors the Run and Network forms
    /// use. Those two already disagree with each other (`Row` structs there, `[String]` here),
    /// and adding a third private copy to settle it is the wrong direction — one shared editor
    /// should replace all three, which is a change to those screens and not to this one.
    private func linesEditor(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .lineLimit(2...6)
    }

    private var built: GroupMember {
        var made = member
        made.name = member.name.trimmingCharacters(in: .whitespaces)
        made.image = member.image.trimmingCharacters(in: .whitespaces)
        made.ports = Self.lines(ports)
        made.env = Self.lines(env)
        made.volumes = Self.lines(volumes)
        made.command = command.split(separator: " ").map(String.init)
        made.cpus = Int(cpus.trimmingCharacters(in: .whitespaces))
        let trimmedMemory = memory.trimmingCharacters(in: .whitespaces)
        made.memory = trimmedMemory.isEmpty ? nil : trimmedMemory
        return made
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        let made = built
        return !made.name.isEmpty && !made.image.isEmpty
            && problem(made.name) == nil && imageProblem(made.image) == nil
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption)
                .foregroundStyle(Theme.info)
            Text(built.image.isEmpty
                 ? "Add an image to see the command."
                 : GroupFormView.preview(of: built, network: nil))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("The group's network is added when it starts, so it is not shown here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
            Button(isNew ? "Add" : "Save") { onSave(built) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(12)
    }
}
