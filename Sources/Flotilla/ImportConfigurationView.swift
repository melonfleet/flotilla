import SwiftUI
import FlotillaCore

/// The review screen for a `.flotilla` file (DECISIONS Q29). Nothing is pulled, created or started
/// until Import — the file came from somewhere else and is treated as untrusted input.
///
/// Every clash is decided here, per item (the owner's choice): skip it, rename what the file
/// brings, or replace what is here. Replace is destructive and the final confirmation names
/// everything it will delete.
struct ImportConfigurationView: View {
    let model: AppModel
    let url: URL
    let dismiss: () -> Void

    @State private var file: ConfigurationFile?
    @State private var loadError: String?
    @State private var existing = ConfigurationImport.Existing()
    @State private var items: [ConfigurationImport.Item] = []
    @State private var resolutions: [String: ConfigurationImport.Resolution] = [:]
    /// Secret values: need id → name → value. An absent value means "generate".
    @State private var typed: [String: [String: String]] = [:]
    @State private var typing: Set<String> = []          // "needID/name" pairs the user types
    @State private var useDefaultRegistry = false
    @State private var useContainerDomain = false
    @State private var confirmingReplace = false

    private var problems: [String: String] {
        ConfigurationImport.problems(items, resolutions: resolutions, existing: existing)
    }

    private var resolved: ConfigurationFile? {
        file.map { ConfigurationImport.resolve($0, resolutions: resolutions, existing: existing) }
    }

    private var replacing: [ConfigurationImport.Item] {
        items.filter { resolutions[$0.id] == .replace }
    }

    private var missingTyped: Bool {
        typing.contains { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return (typed[parts[0]]?[parts[1]] ?? "").isEmpty
        }
    }

    private var canImport: Bool { file != nil && problems.isEmpty && !missingTyped && !(resolved?.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Import “\(url.lastPathComponent)”", systemImage: "square.and.arrow.down",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            if let loadError {
                ContentUnavailableView("This file can't be imported", systemImage: "doc.badge.ellipsis",
                                       description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let file {
                FormScaffold {
                    VStack(alignment: .leading, spacing: 22) { review(file) }
                } preview: {
                    rail
                }
            } else {
                ProgressView("Reading the file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await load() }
        .confirmationDialog("Replace \(replacing.count) thing\(replacing.count == 1 ? "" : "s") on this Mac?",
                            isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace and Import", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These are deleted first, then built from the file:\n"
                 + replacing.map { "• \($0.kind.title) \($0.name)" + ($0.kind == .volume ? " — its data is lost" : "") }
                    .joined(separator: "\n"))
        }
    }

    // MARK: Review

    @ViewBuilder
    private func review(_ file: ConfigurationFile) -> some View {
        Text("Nothing is pulled, created or started until you press Import. Containers are created "
             + "stopped and groups are saved ready to start.")
            .font(.callout).foregroundStyle(.secondary)

        ForEach(ConfigurationImport.Kind.allCases, id: \.self) { kind in
            let ofKind = items.filter { $0.kind == kind }
            if !ofKind.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Hosts carry their own explanation in the header: they arrive as rows to pair.
                    FormSectionHeader(title: kind.title + (ofKind.count == 1 ? "" : "s"),
                                      note: kind == .host
                                          ? "They arrive unpaired: the file holds no trust and no keys. Pair each "
                                              + "from Hosts — pairing is refused if a Mac presents a different key "
                                              + "from the one in this file."
                                          : nil)
                    ForEach(ofKind) { item in itemRow(item, file: file) }
                }
            }
        }

        let needs = ConfigurationImport.secretNeeds(resolved ?? file)
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FormSectionHeader(title: "Passwords",
                                  note: "The file names these but can't carry them. Each is generated unless you type one — type it if a volume or service already uses a known password.")
                ForEach(needs) { need in secretRows(need) }
            }
        }

        let images = ConfigurationImport.images(resolved ?? file)
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                FormSectionHeader(title: "Images", note: "Pulled if this Mac doesn't have them.")
                ForEach(images, id: \.reference) { image in
                    Text(image.reference).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }

        if let registries = file.registries, !registries.entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FormSectionHeader(title: "Registries",
                                  note: "Added to your list if missing. Never signed in — the file holds no sign-ins.")
                Text(registries.entries.map(\.host).joined(separator: ", "))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                if let host = registries.defaultRegistry, host != model.defaultRegistry {
                    Toggle("Make \(host) the default registry", isOn: $useDefaultRegistry).toggleStyle(.checkbox)
                }
            }
        }

        if let dns = resolved?.dns ?? file.dns {
            VStack(alignment: .leading, spacing: 6) {
                if !dns.domains.isEmpty {
                    FormSectionHeader(title: "DNS",
                                      note: "Adding \(dns.domains.map(\.name).joined(separator: ", ")) "
                                          + (model.helperEnabled ? "goes through the Flotilla Helper."
                                                                    : "asks for an administrator password, once."))
                }
                if let domain = dns.containerDomain, domain != model.containerDNSDomain {
                    Toggle("Name containers under “\(domain)”", isOn: $useContainerDomain).toggleStyle(.checkbox)
                    Text("Restarts container afterwards, which stops every running container.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private func itemRow(_ item: ConfigurationImport.Item, file: ConfigurationFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.name).fontWeight(.medium)
                Text(item.kind == .host
                     ? (item.clashes ? "already known here — left as it is" : "added to Hosts, to pair")
                     : (item.clashes ? "already on this Mac" : "new"))
                    .font(.caption)
                    .foregroundStyle(item.clashes ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                Spacer()
                if item.clashes && item.canRename {
                    Picker("", selection: Binding(
                        get: { choice(item) },
                        set: { new in
                            switch new {
                            case "skip": resolutions[item.id] = .skip
                            case "rename": resolutions[item.id] = .rename(
                                ConfigurationImport.suggestedRename(item, existing: existing, file: file))
                            case "replace": resolutions[item.id] = .replace
                            default: resolutions[item.id] = nil
                            }
                        })) {
                        Text("Choose…").tag("")
                        Text("Skip").tag("skip")
                        Text("Rename").tag("rename")
                        if item.canReplace { Text("Replace").tag("replace") }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if case .rename(let name)? = resolutions[item.id] {
                TextField("New name", text: Binding(get: { name },
                                                    set: { resolutions[item.id] = .rename($0) }))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(maxWidth: 280)
                if item.kind == .group {
                    Text("Services whose names are taken are renamed too, and settings that name them follow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if resolutions[item.id] == .replace {
                Text(item.kind == .volume
                     ? "Deletes the volume here, and everything in it."
                     : "Deletes the one here first.")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            if let problem = problems[item.id], resolutions[item.id] != nil {
                Text(problem).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func choice(_ item: ConfigurationImport.Item) -> String {
        switch resolutions[item.id] {
        case .skip?: "skip"
        case .rename?: "rename"
        case .replace?: "replace"
        default: ""
        }
    }

    @ViewBuilder
    private func secretRows(_ need: ConfigurationImport.SecretNeed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch need.owner {
            case .group(let name): Text("Group \(name)").font(.callout.weight(.medium))
            case .container(let name): Text("Container \(name)").font(.callout.weight(.medium))
            }
            ForEach(need.names, id: \.self) { name in
                let key = "\(need.id)|\(name)"
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 12, design: .monospaced)).frame(width: 220, alignment: .leading)
                    Toggle("Type it", isOn: Binding(get: { typing.contains(key) },
                                                    set: { on in if on { typing.insert(key) } else { typing.remove(key) } }))
                        .toggleStyle(.checkbox)
                    if typing.contains(key) {
                        SecureField("Password", text: Binding(get: { typed[need.id]?[name] ?? "" },
                                                              set: { typed[need.id, default: [:]][name] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    } else {
                        Text("generated").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Rail and footer

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will build", systemImage: "hammer")
                .font(.caption).foregroundStyle(Theme.info)
            if let resolved {
                let counts: [(String, String, Int)] = [
                    ("group", "groups", resolved.groups.count),
                    ("container", "containers", resolved.containers.count),
                    ("network", "networks", resolved.networks.count),
                    ("volume", "volumes", resolved.volumes.count),
                    ("machine", "machines", resolved.machines.count),
                    ("cluster", "clusters", resolved.clusters.count),
                    ("host to pair", "hosts to pair", resolved.hosts.count),
                    ("host category", "host categories", resolved.hostCategories?.count ?? 0),
                ]
                let lines: [String] = counts.filter { $0.2 > 0 }.map { "\($0.2) \($0.2 == 1 ? $0.0 : $0.1)" }
                Text(lines.isEmpty ? "Nothing — everything is skipped." : lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if !replacing.isEmpty {
                Text("Replaces \(replacing.count): \(replacing.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !problems.isEmpty {
                Text("\(problems.count) to decide before importing.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(replacing.isEmpty ? "Import" : "Import…") {
                if replacing.isEmpty { start() } else { confirmingReplace = true }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func load() async {
        do {
            let data = try Data(contentsOf: url)
            let parsed = try ConfigurationFile.parse(data)
            existing = await model.importExisting()
            items = ConfigurationImport.items(parsed, existing: existing)
            resolutions = ConfigurationImport.initialResolutions(items)
            file = parsed
        } catch let error as ConfigurationFileError {
            loadError = error.description
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func start() {
        guard let resolved else { return }
        // Generated wherever nothing was typed.
        var secrets: [String: [String: String]] = [:]
        for need in ConfigurationImport.secretNeeds(resolved) {
            for name in need.names {
                let key = "\(need.id)|\(name)"
                secrets[need.id, default: [:]][name] = typing.contains(key)
                    ? (typed[need.id]?[name] ?? "") : GroupSecrets.generatePassword()
            }
        }
        let choices = AppModel.ImportChoices(file: resolved, replacing: replacing, secrets: secrets,
                                             useDefaultRegistry: useDefaultRegistry,
                                             useContainerDomain: useContainerDomain)
        let source = url.lastPathComponent
        dismiss()
        Task { await model.runImport(choices, source: source) }
    }
}
