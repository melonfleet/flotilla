import SwiftUI
import FlotillaCore

/// Suggestions for Containers: ready-made stacks, each created as a group (DECISIONS Q28).
///
/// Reached from the "+" menu and from the empty Containers list, as decided on 6 October. Embedded
/// like every other form, with Back. The cards are `ResourceCard`s, so they look like every other
/// card in the app (the owner's rule, 5 October).
struct SuggestionsView: View {
    let model: AppModel
    let dismiss: () -> Void
    /// Opened straight into one stack's form — from the empty state's quick picks.
    @State var chosen: StackSuggestion?

    var body: some View {
        if let chosen {
            StackFormView(model: model, stack: chosen, back: { self.chosen = nil }, done: dismiss)
                .id(chosen.id)
        } else {
            VStack(spacing: 0) {
                FormHeader(title: "Suggestions", systemImage: "sparkles",
                           hasUnsavedChanges: false, onBack: dismiss)
                Divider()
                Text("Ready-made stacks. Each is created as a group — its images pulled, its "
                     + "network and volumes made, its passwords generated into the Keychain — "
                     + "and left ready to start.")
                    .font(.callout).foregroundStyle(.secondary)
                    // Not `fixedSize(vertical:)`: with it, opening this screen blanked the whole
                    // window — bar, sidebar and all — the "one unbounded child" family in
                    // CLAUDE.md. Found by bisecting, 6 October.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12)
                ResourceCardGrid {
                    ForEach(StackSuggestion.catalogue) { stack in
                        ResourceCard(
                            title: stack.title,
                            badge: stack.licenceNote == nil ? nil : "licence",
                            fields: [("About", stack.summary),
                                     ("Services", stack.services.map(\.title).joined(separator: " · ")),
                                     ("Images", stack.images.map(Self.shortImage).joined(separator: ", "))],
                            showsTags: false,
                            onOpen: { chosen = stack }
                        ) {
                            Button("Use…") { chosen = stack }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// `docker.io/library/postgres:18.6` → `postgres:18.6`.
    static func shortImage(_ image: String) -> String {
        image.replacingOccurrences(of: "docker.io/library/", with: "")
            .replacingOccurrences(of: "docker.io/", with: "")
    }
}

/// One stack's form: what it will be called, where it goes, and its few choices — every one with a
/// working default, so Create works untouched (the owner, 6 October: fields the user can
/// pre-select, bound to the stack once built).
struct StackFormView: View {
    let model: AppModel
    let stack: StackSuggestion
    let back: () -> Void
    let done: () -> Void

    @State private var name = ""
    @State private var network: StackChoices.Network = .new
    @State private var webPorts: [String: String] = [:]
    @State private var options: [String: String] = [:]
    @State private var usedPorts: Set<Int> = []
    @State private var prepared = false
    @State private var edits = FormEditTracker()

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        guard !trimmedName.isEmpty else { return nil }
        return StackPlanner.nameProblem(trimmedName, stack: stack, network: network,
                                        taken: model.stackTaken,
                                        groupNames: Set(model.groups.book.groups.map(\.name)))
    }

    private func portProblem(_ role: String) -> String? {
        let text = (webPorts[role] ?? "").trimmingCharacters(in: .whitespaces)
        guard let port = Int(text), (1024...65535).contains(port) else {
            return "Use a port from 1024 to 65535."
        }
        if usedPorts.contains(port) { return "Something on this Mac already uses \(port)." }
        let others = webPorts.filter { $0.key != role }.compactMap { Int($0.value) }
        if others.contains(port) { return "Two pages can't share a port." }
        return nil
    }

    private func optionProblem(_ option: StackOption) -> String? {
        option.problem(with: (options[option.id] ?? option.defaultValue).trimmingCharacters(in: .whitespaces))
    }

    private var choices: StackChoices {
        StackChoices(name: trimmedName, network: network,
                     webPorts: webPorts.compactMapValues { Int($0.trimmingCharacters(in: .whitespaces)) },
                     options: options)
    }

    private var webServices: [StackService] { stack.services.filter { $0.webPort != nil } }

    private var canCreate: Bool {
        prepared && !trimmedName.isEmpty && nameProblem == nil
            && webServices.allSatisfy { portProblem($0.role) == nil }
            && stack.options.allSatisfy { optionProblem($0) == nil }
    }

    /// The plan as it will be, for the rail. A new network's gateway is not known until it exists,
    /// so the rail names it rather than guessing an address.
    private var previewPlan: StackPlan? {
        guard !trimmedName.isEmpty else { return nil }
        let wiring: StackWiring = model.stackWiringDomain.map { .names(domain: $0) }
            ?? .gateway(existingGateway ?? "gateway")
        return try? StackPlanner.plan(stack, choices: choices, wiring: wiring,
                                      usedHostPorts: model.stackTaken.hostPorts)
    }

    private var existingGateway: String? {
        guard case .existing(let id) = network else { return nil }
        return model.networks.first { $0.id == id }?.gateway.flatMap { Readiness.address(fromIPv4: $0) }
    }

    private var editSignature: String {
        [name, "\(network)", webPorts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(),
         options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined()]
            .joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: stack.title, systemImage: Section.groupSymbol,
                       hasUnsavedChanges: prepared && edits.isDirty(editSignature),
                       onBack: back)
            Divider()
            FormScaffold {
                VStack(alignment: .leading, spacing: 20) { fields }
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .task { await prepare() }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        FormField("Name",
                  help: FieldHelp(
                      "What the group is called, and the start of every name it creates.",
                      detail: "Containers are named after it and their role, and so are the volumes "
                          + "and the network: blog → blog-db, blog-site, blog-db-data, blog-net.",
                      example: "blog\nshop-dev"),
                  problem: nameProblem) {
            TextField(stack.id, text: $name)
                .textFieldStyle(.roundedBorder)
                .monospaced()
        }

        FormField("Network",
                  help: FieldHelp(
                      "Where the stack's containers live.",
                      detail: "A network of its own keeps the stack apart from everything else — "
                          + "networks are isolated from one another. Choose an existing one to put "
                          + "it beside containers already there.",
                      warning: "Fixed once the containers exist: moving it means recreating them.")) {
            Picker("", selection: $network) {
                Text("New: \(StackPlanner.networkName(trimmedName.isEmpty ? stack.id : trimmedName))")
                    .tag(StackChoices.Network.new)
                if !model.networks.isEmpty { Divider() }
                ForEach(model.networks, id: \.id) { existing in
                    Text(existing.id).tag(StackChoices.Network.existing(existing.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }

        ForEach(webServices) { service in
            FormField("\(service.title) on this Mac",
                      help: FieldHelp(
                          "The port its page opens on, at 127.0.0.1.",
                          detail: "This Mac only — not your network. Suggested as one nothing here uses yet.",
                          example: "http://127.0.0.1:\(webPorts[service.role] ?? "8080")"),
                      problem: prepared ? portProblem(service.role) : nil) {
                TextField("8080", text: Binding(get: { webPorts[service.role] ?? "" },
                                                set: { webPorts[service.role] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(width: 100)
            }
        }

        if !stack.options.isEmpty {
            FormSectionHeader(title: "Settings", note: "Each has a default that works.")
            ForEach(stack.options) { option in
                FormField(option.label, help: FieldHelp(option.help), problem: optionProblem(option)) {
                    TextField(option.defaultValue,
                              text: Binding(get: { options[option.id] ?? option.defaultValue },
                                            set: { options[option.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .frame(maxWidth: 320)
                }
            }
        }

        FormSectionHeader(title: "Wiring")
        FormField("Services find each other",
                  help: FieldHelp(
                      "Decided by this Mac's DNS setting, not per stack.",
                      detail: "container names every container under one domain for the whole Mac. "
                          + "With one in use, services reach each other by name; without one, "
                          + "Flotilla publishes each database on the network's gateway — reachable "
                          + "from this Mac and its containers, never from your network.")) {
            VStack(alignment: .leading, spacing: 6) {
                if let domain = model.stackWiringDomain {
                    Text("By name — \(StackPlanner.containerName(trimmedName.isEmpty ? stack.id : trimmedName, stack.services[0].role)), "
                         + "or \(StackPlanner.containerName(trimmedName.isEmpty ? stack.id : trimmedName, stack.services[0].role)).\(domain) from this Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Through the network's gateway: no DNS domain is in use for containers.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up a Domain…") { model.requestDNSForm() }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.link)
                }
            }
        }

        let secrets = GroupSecrets.secretNames(in: ContainerGroup(name: "", members: stack.services.map {
            GroupMember(name: $0.role, image: $0.image, secretEnv: $0.secretEnv)
        }))
        if !secrets.isEmpty {
            FormField("Passwords",
                      help: FieldHelp("Generated now and kept in this Mac's Keychain.",
                                      detail: "Shown on the group's screen with Copy. Never written "
                                          + "to Flotilla's settings, and never in an export.")) {
                Text(secrets.joined(separator: ", "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }

        if let licence = stack.licenceNote {
            Label(licence, systemImage: "doc.text")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rail and footer

    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will create", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if let plan = previewPlan {
                let lines: [String] =
                    (plan.createsNetwork ? ["network  \(plan.network)"] : [])
                    + plan.volumes.map { "volume   \($0)" }
                    + plan.group.members.map { "service  \($0.name)  \(SuggestionsView.shortImage($0.image))" }
                    + ["group    \(plan.group.name)"]
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let missing = stack.images.filter { image in !model.images.contains { $0.reference == image } }
                if !missing.isEmpty {
                    Text("Pulls first: \(missing.map(SuggestionsView.shortImage).joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Left ready to start, from its row in Containers.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("Give it a name to see what it creates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !prepared { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", action: back)
                .keyboardShortcut(.cancelAction)
            Button("Create") { create() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    /// Reads what the plan must avoid, then fills in defaults that avoid it.
    private func prepare() async {
        await model.prepareSuggestions()
        if model.imagesState != .loaded { await model.refreshImages() }
        let used = await model.stackUsedPorts(for: stack)
        usedPorts = used
        name = StackPlanner.suggestedName(for: stack, taken: model.stackTaken,
                                          groupNames: Set(model.groups.book.groups.map(\.name)))
        webPorts = StackPlanner.defaultWebPorts(for: stack, avoiding: used).mapValues(String.init)
        prepared = true
        edits.open(editSignature)
    }

    private func create() {
        guard canCreate else { return }
        let chosen = choices
        done()
        Task { await model.createStack(stack, choices: chosen) }
    }
}

/// Suggestions for Volumes, Networks and Clusters: the same gallery as Containers', where "Use…"
/// opens the section's own create form, filled in (Q28).
struct ResourceSuggestionsGallery<Suggestion: ResourceSuggestion>: View {
    let intro: String
    let items: [Suggestion]
    let use: (Suggestion) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Suggestions", systemImage: "sparkles",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            // No `fixedSize(vertical:)` here — see `SuggestionsView`.
            Text(intro)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 12)
            ResourceCardGrid {
                ForEach(items) { item in
                    ResourceCard(title: item.title,
                                 fields: [("About", item.summary)] + item.details.map { ($0.0, Optional($0.1)) },
                                 showsTags: false,
                                 onOpen: { use(item) }) {
                        Button("Use…") { use(item) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The empty-state row every section shares: a few suggestions by name, and "More…".
struct SuggestionQuickPicks: View {
    /// Title and action for each pick shown.
    let picks: [(title: String, action: () -> Void)]
    let more: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text("Or start from a suggestion:")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
                    Button(pick.title, action: pick.action)
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.link)
                }
                Button("More…", action: more)
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.link)
            }
        }
    }
}
