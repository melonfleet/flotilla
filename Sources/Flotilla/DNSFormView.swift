import SwiftUI
import FlotillaCore

/// What the DNS form is for: a new domain, or one already in the table.
enum DNSFormTarget: Identifiable, Hashable {
    case add
    case manage(String)

    var id: String {
        switch self {
        case .add: "add"
        case .manage(let name): name
        }
    }
}

/// New Domain, and a domain's own page, in one embedded form like every other section's.
///
/// **The rail shows the exact administrator command** before the password prompt can appear, with
/// a Copy button — so the prompt never asks for a password to run something the screen did not
/// say, and anyone who would rather type it into Terminal can.
struct DNSFormView: View {
    let model: AppModel
    let target: DNSFormTarget
    /// Set when a suggestion opened the form (Q28): its domain and kind fill the fields.
    var prefill: DNSSuggestion? = nil
    let dismiss: () -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case containers = "Container names"
        case hostAlias = "Host alias"
        var id: Self { self }
    }

    @State private var kind: Kind = .containers
    @State private var domain = ""
    @State private var address = ""
    @State private var useForContainers = false
    @State private var working = false
    @State private var problem: String?
    @State private var pendingChange: ContainerDomainChange?
    @State private var confirmingDelete = false
    /// "Set Up on This Mac…" with the DNS helper on — see `dnsSetUpConfirmation`.
    @State private var pendingSetUp: String?

    @State private var edits = FormEditTracker()

    /// Apple's own example in the `container` documentation, offered when the field is empty: an
    /// address from the range reserved for documentation (RFC 5737), so it is never a real host.
    static let exampleHostAlias = (domain: "host.container.internal", address: "203.0.113.113")

    private var managed: LocalDNSDomain? {
        guard case .manage(let name) = target else { return nil }
        return model.dnsDomains.first { $0.id == name }
    }

    private var isAdd: Bool { target == .add }

    private var trimmedDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var command: Result<ValidatedCommand, AllowlistError> {
        ContainerCLI.dnsCreateCommand(domain: trimmedDomain,
                                      localhost: kind == .hostAlias ? trimmedAddress : nil)
    }

    private var domainProblem: String? {
        guard !trimmedDomain.isEmpty else { return nil }
        if case .failure = ContainerCLI.dnsDeleteCommand(domain: trimmedDomain) {
            return ValueShape.dnsDomain.rule
        }
        if let reserved = LocalDNS.reservedProblem(trimmedDomain) { return reserved }
        if model.dnsDomains.contains(where: { $0.name == trimmedDomain && $0.resolverInstalled }) {
            return "“\(trimmedDomain)” already exists."
        }
        return nil
    }

    private var addressProblem: String? {
        guard kind == .hostAlias, !trimmedAddress.isEmpty else { return nil }
        if case .failure = Allowlist.validate(["system", "dns", "create", "--localhost",
                                               trimmedAddress, "x"]) {
            return ValueShape.ipv4Address.rule
        }
        return nil
    }

    private var canCreate: Bool {
        guard !working, !trimmedDomain.isEmpty, domainProblem == nil, addressProblem == nil
        else { return false }
        if kind == .hostAlias, trimmedAddress.isEmpty { return false }
        if case .success = command { return true }
        return false
    }

    private var editSignature: String {
        [kind.rawValue, domain, address, "\(useForContainers)"].joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: managed?.name ?? (isAdd ? "New Domain" : "Domain"),
                       systemImage: Section.dns.systemImage,
                       hasUnsavedChanges: isAdd && edits.isDirty(editSignature),
                       onBack: dismiss)
            Divider()
            FormScaffold {
                VStack(alignment: .leading, spacing: 20) {
                    if isAdd { addFields } else { manageFields }
                }
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .onAppear {
            // Suggested, not imposed: with no domain in use, the first one is almost certainly
            // meant for containers.
            if isAdd { useForContainers = model.containerDNSDomain == nil }
            if isAdd, let prefill {
                kind = prefill.hostAddress == nil ? .containers : .hostAlias
                domain = prefill.baseName
                address = prefill.hostAddress ?? ""
            }
            edits.open(editSignature)
        }
        .containerDomainConfirmation($pendingChange, model: model) { change in
            if isAdd { create(thenUse: true) } else { apply(change) }
        }
        .dnsSetUpConfirmation($pendingSetUp) { _ in createManaged() }
        .confirmationDialog("Delete the local domain “\(managed?.name ?? "")”?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(model.dnsHelperEnabled ? "Delete" : "Delete…", role: .destructive) { deleteManaged() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DNSCopy.deleteMessage(managed.map { [$0] } ?? [], helper: model.dnsHelperEnabled))
        }
    }

    // MARK: New domain

    @ViewBuilder
    private var addFields: some View {
        FormField("Kind",
                  help: FieldHelp(
                      "What the domain is for.",
                      detail: "**Container names** gives containers names under the domain — a "
                          + "container called web is reached as web.test, from this Mac and from "
                          + "other containers. **Host alias** is a single name that, inside a "
                          + "container, reaches a service running on this Mac.",
                      example: "Container names: test, dev, shop.test\nHost alias: "
                          + Self.exampleHostAlias.domain)) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: kind) { _, new in
                if new == .hostAlias, domain.isEmpty, address.isEmpty {
                    domain = Self.exampleHostAlias.domain
                    address = Self.exampleHostAlias.address
                }
            }
        }

        FormField("Domain",
                  help: FieldHelp(
                      "The name, in lowercase.",
                      detail: "Letters, numbers and hyphens, with dots between parts.",
                      example: kind == .hostAlias ? Self.exampleHostAlias.domain : "test\ndev\nshop.test",
                      warning: "Avoid a real domain you also use on the internet — this Mac "
                          + "would send its lookups to the container runtime instead."),
                  problem: domainProblem) {
            TextField(kind == .hostAlias ? Self.exampleHostAlias.domain : "test", text: $domain)
                .textFieldStyle(.roundedBorder)
                .monospaced()
        }

        if kind == .hostAlias {
            FormField("Address",
                      help: FieldHelp(
                          "An IPv4 address that stands for this Mac inside containers.",
                          detail: "Containers that look up the name get this address, and the "
                              + "runtime sends what reaches it to this Mac's own localhost. Pick "
                              + "one nothing on your network uses.",
                          example: "203.0.113.113 (reserved for\ndocumentation, so never a real host)"),
                      problem: addressProblem) {
                TextField(Self.exampleHostAlias.address, text: $address)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(maxWidth: 200)
            }
        } else {
            FormField("Containers",
                      help: FieldHelp(
                          "Whether containers are named under it.",
                          detail: "One domain at a time names containers. Choosing it restarts "
                              + "container, which stops every running container, and only "
                              + "containers created afterwards get names.",
                          warning: model.containerDNSDomain.map {
                              "Containers are named under “\($0)” now; turning this on replaces it."
                          })) {
                Toggle("Name containers under this domain", isOn: $useForContainers)
                    .toggleStyle(.checkbox)
            }
        }

        Text(model.dnsHelperEnabled
             ? "Creating a domain changes this Mac’s DNS settings, through Flotilla’s DNS helper."
             : "Creating a domain changes this Mac’s DNS settings, so macOS asks for an "
               + "administrator password.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: An existing domain

    @ViewBuilder
    private var manageFields: some View {
        if let managed {
            FormField("Kind", help: FieldHelp(DNSCopy.addressHelp(managed))) {
                Text(DNSCopy.kindTitle(managed))
            }
            FormField("Address") {
                Text(DNSCopy.address(managed))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            FormField("Status", help: FieldHelp(DNSCopy.statusHelp(managed))) {
                DNSStatusLabel(row: managed)
            }
            if managed.resolverInstalled {
                FormField("On this Mac",
                          help: FieldHelp("Where macOS reads it from.",
                                          detail: "Written by container as root. Delete removes it.")) {
                    Text(DNSResolverFile.directory + "/" + DNSResolverFile.filenamePrefix + managed.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !managed.isHostAlias {
                FormSectionHeader(title: "Containers",
                                  note: "One domain at a time names containers.")
                HStack(spacing: 8) {
                    if managed.registersContainers {
                        Button("Stop Using for Containers…") { pendingChange = .stop(managed.name) }
                    } else {
                        Button("Use for Containers…") { pendingChange = .use(managed.name) }
                            .disabled(!managed.resolverInstalled)
                    }
                    if !managed.resolverInstalled {
                        Button("Set Up on This Mac…") {
                            if model.dnsHelperEnabled { pendingSetUp = managed.name } else { createManaged() }
                        }
                    }
                }
                .disabled(working)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ContentUnavailableView("Domain unavailable",
                                   systemImage: "questionmark.square.dashed",
                                   description: Text("It is no longer set up on this Mac."))
        }
    }

    // MARK: Rail and footer

    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAdd {
                Label("Runs as administrator", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Theme.info)
                if trimmedDomain.isEmpty {
                    Text("Type a domain to see the command.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let line: String = switch command {
                    case .success(let validated): AdminScript.displayLine(validated)
                    case .failure:
                        (["sudo", "container", "system", "dns", "create"]
                         + (kind == .hostAlias
                            ? ["--localhost", trimmedAddress.isEmpty ? "<address>" : trimmedAddress]
                            : [])
                         + [trimmedDomain]).joined(separator: " ")
                    }
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        // Red only for a real refusal: an address not typed yet is not one.
                        .foregroundStyle(domainProblem == nil && addressProblem == nil
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CommandPreviewCopyButton(command: line,
                                             help: "Copy the command, to run it in Terminal instead")
                    if kind == .containers, useForContainers {
                        Text("Then sets [dns] domain = \"\(trimmedDomain)\" in container’s "
                             + "settings and restarts container.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let managed {
                Label("In the table as", systemImage: Section.dns.systemImage)
                    .font(.caption).foregroundStyle(Theme.info)
                Text(managed.name).font(.system(size: 13, weight: .medium))
                Text(DNSCopy.statusText(managed))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            if isAdd {
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                // "…" when something follows — the password prompt, or the restart warning.
                Button(model.dnsHelperEnabled && !(kind == .containers && useForContainers)
                       ? "Create" : "Create…", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            } else {
                if managed?.resolverInstalled == true {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                        .disabled(working)
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    /// Asks about the restart **before** the password prompt, so every decision is made up front
    /// and a cancelled restart never leaves a domain half-created behind it.
    private func submit() {
        guard canCreate else { return }
        problem = nil
        if kind == .containers, useForContainers {
            pendingChange = .use(trimmedDomain)
        } else {
            create(thenUse: false)
        }
    }

    private func create(thenUse: Bool) {
        let name = trimmedDomain
        let localhost = kind == .hostAlias ? trimmedAddress : nil
        working = true
        Task {
            let result = await model.createDNSDomain(name, localhost: localhost)
            switch result {
            case nil:
                if thenUse, case .failed(let message)? = await model.setContainerDNSDomain(name) {
                    working = false
                    problem = "The domain was created, but containers aren’t named under it: \(message)"
                    return
                }
                working = false
                dismiss()
            case .cancelled?:
                working = false
            case .failed(let message)?:
                working = false
                problem = message
            }
        }
    }

    private func createManaged() {
        guard let managed else { return }
        working = true
        problem = nil
        Task {
            let result = await model.createDNSDomain(managed.name, localhost: nil)
            working = false
            if case .failed(let message)? = result { problem = message }
        }
    }

    private func apply(_ change: ContainerDomainChange) {
        working = true
        problem = nil
        Task {
            let result = await model.setContainerDNSDomain(change.newDomain)
            working = false
            if case .failed(let message)? = result { problem = message }
        }
    }

    private func deleteManaged() {
        guard let managed else { return }
        working = true
        problem = nil
        Task {
            let result = await model.deleteDNSDomains([managed.name])
            working = false
            switch result {
            case nil: dismiss()
            case .cancelled?: break
            case .failed(let message)?: problem = message
            }
        }
    }
}
