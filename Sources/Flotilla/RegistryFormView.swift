import SwiftUI
import AppKit
import FlotillaCore

/// What the registry form is for: adding one, or managing one already in the table.
enum RegistryFormTarget: Identifiable, Hashable {
    case add
    /// A row of the table, by host — signing in, switching account, signing out.
    case manage(String)

    var id: String {
        switch self {
        case .add: "add"
        case .manage(let host): host
        }
    }
}

/// Adding a registry, and signing in to one, in one embedded form (the owner, 5 October: "the
/// form will slide down the side just like everything else, and the user will sign in there").
///
/// Two jobs, one screen, because they are the same fields. **Add** opens as a single picker and
/// grows into whatever that answer needs. **Manage** is what clicking a registry's name opens: its
/// server, how much it needs a sign-in, who you are signed in as, and the same credential fields
/// to sign in or switch account. It replaced the sign-in *sheet* the Settings pane used, which was
/// the one modal left among the create forms.
///
/// **How much a registry needs a sign-in decides the button** (`SignInNeed`, the owner's rule):
///
/// - *Required*: the registry is not added until you have signed in. The button reads "Sign In
///   and Add", stays off until both fields are filled, and signs in **first** — a wrong password
///   adds nothing, rather than leaving a registry in the list that cannot be used.
/// - *Optional*: Add works on its own, and "Add and Sign In" when the fields are filled.
/// - *Not needed*: there is nothing to sign in to, so just Add.
///
/// **The password is never stored by Flotilla and never reaches argv.** It is held in `@State`
/// for as long as the form is open, handed to `container registry login --password-stdin`, and
/// cleared. The Keychain entry that results is written by `container`, not by this app.
struct RegistryFormView: View {
    let model: AppModel
    let target: RegistryFormTarget
    let dismiss: () -> Void

    // Add mode: what the first picker is set to. `nil` is "not answered yet", which is what keeps
    // the rest of the form off screen.
    @State private var choice: Choice?

    enum Choice: Hashable {
        /// A registry the catalogue describes, by host.
        case known(String)
        /// One it does not.
        case custom
    }

    @State private var kind: RegistryKind = .other
    @State private var host = ""
    @State private var name = ""
    @State private var usesHTTP = false
    /// The owner's question for a registry Flotilla does not know (5 October): ask, rather than
    /// guess or probe it. On by default, because required is the safe answer — see
    /// `RegistryBook.add(host:…)`.
    @State private var customRequiresSignIn = true

    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var signInError: String?
    @State private var confirmingSignOut = false

    @State private var edits = FormEditTracker()

    private var store: RegistryStore { model.registries }

    // MARK: What the form is about

    /// The table row being managed. Looked up live, so a sign-in elsewhere shows here.
    private var managed: RegistryRow? {
        guard case .manage(let id) = target else { return nil }
        return model.registryRows.first { $0.id == id }
    }

    private var isAdd: Bool { target == .add }

    private var chosen: KnownRegistry? {
        guard case .known(let id) = choice else { return nil }
        return store.addable.first { $0.id == id }
    }

    private var isCustom: Bool { choice == .custom }

    private var customTypes: [RegistryKind] {
        RegistryKind.allCases.filter { !$0.hostIsFixed }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The server a sign-in goes to.
    private var server: String {
        if let managed { return managed.id }
        return chosen?.id ?? trimmedHost
    }

    private var hostProblem: String? {
        guard isAdd, isCustom, !trimmedHost.isEmpty else { return nil }
        return store.book.problem(withHost: trimmedHost)
    }

    /// How much signing in this registry needs. See the type's note for what each answer does.
    private var need: SignInNeed? {
        if let managed { return managed.signInNeed }
        if let chosen { return chosen.signInNeed }
        if isCustom { return customRequiresSignIn ? .required : .optional }
        return nil
    }

    /// Whether this registry is reached over plain HTTP — which, since `container` 1.5.0, means it
    /// cannot be signed in to at all. See `RegistryRow.canSignIn` for the measurement.
    private var plaintext: Bool {
        if let managed { return managed.usesHTTP }
        if let chosen { return chosen.usesHTTP }
        return isCustom && usesHTTP
    }

    /// The registry has accounts, but this Mac cannot use them over HTTP.
    private var httpBlocksSignIn: Bool { plaintext && (need ?? .optional) != .notNeeded }

    private var canSignIn: Bool { (need ?? .optional) != .notNeeded && !plaintext }

    private var guidance: (hint: String?, token: String?, docs: String?) {
        if let managed {
            return (managed.credentialHint, managed.known?.tokenURL, managed.known?.kind.docsURL)
        }
        if let chosen { return (chosen.credentialHint, chosen.tokenURL, chosen.kind.docsURL) }
        return (kind.credentialHint ?? KnownRegistry.cloudCredentialHint(forHost: trimmedHost),
                kind.tokenURL, kind.docsURL)
    }

    private var hasCredentials: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private var canSubmit: Bool {
        guard !working else { return false }
        if managed != nil { return hasCredentials && model.runtimeUsable }
        guard choice != nil else { return false }
        guard chosen != nil || (!trimmedHost.isEmpty && hostProblem == nil) else { return false }
        // A required registry over HTTP can never be signed in to, so it cannot be added either:
        // it would be a row nothing can pull from.
        if need == .required, plaintext { return false }
        // The owner's rule: a registry that needs a sign-in is not added without one.
        if need == .required { return hasCredentials && model.runtimeUsable }
        if plaintext { return true }
        if hasCredentials { return model.runtimeUsable }
        return true
    }

    private var buttonTitle: String {
        if managed != nil { return managed?.isSignedIn == true ? "Switch Account" : "Sign In" }
        switch need {
        case .required: return "Sign In and Add"
        case .optional: return hasCredentials && !plaintext ? "Add and Sign In" : "Add"
        case .notNeeded, nil: return "Add"
        }
    }

    private var editSignature: String {
        [String(describing: choice), kind.rawValue, host, name,
         usesHTTP ? "http" : "https", "\(customRequiresSignIn)", username]
            .joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: managed?.name ?? (isAdd ? "Add Registry" : "Registry"),
                       systemImage: Section.registries.systemImage,
                       hasUnsavedChanges: edits.isDirty(editSignature),
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
        .onAppear { edits.open(editSignature) }
        .confirmationDialog("Sign out of “\(managed?.name ?? server)”?",
                            isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stored credential is deleted from this Mac’s Keychain."
                 + (need == .required ? "" : " Pulling public images from this registry still works."))
        }
    }

    // MARK: Add

    @ViewBuilder
    private var addFields: some View {
        FormField("Registry",
                  help: FieldHelp(
                      "Which registry to add.",
                      detail: "Pick one Flotilla knows and its server name, sign-in guidance and "
                          + "links come with it — there is nothing to type. Choose Custom to "
                          + "describe a private, self-hosted or per-account registry yourself.",
                      example: "Amazon ECR, Azure and Google Artifact\nRegistry are per-account, "
                          + "so they are\nalways Custom")) {
            Picker("", selection: $choice) {
                Text("Choose a registry…").tag(Choice?.none)
                Divider()
                ForEach(store.addable) { registry in
                    Text(registry.name).tag(Optional(Choice.known(registry.id)))
                }
                if !store.addable.isEmpty { Divider() }
                Text("Custom…").tag(Optional(Choice.custom))
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        }

        // Everything below is an answer to that picker, so none of it exists until it has one.
        if choice != nil {
            if let chosen {
                FormField("Server", help: FieldHelp(chosen.summary,
                                                    detail: "Fixed for a registry Flotilla knows.")) {
                    Text(chosen.id)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                customFields
            }
            signInSection
        }
    }

    @ViewBuilder
    private var customFields: some View {
        FormField("Type",
                  help: FieldHelp(
                      "What sort of registry this is.",
                      detail: "It decides the sign-in guidance below — every family "
                          + "authenticates differently, and the differences are not small.",
                      example: kind.summary)) {
            Picker("", selection: $kind) {
                ForEach(customTypes) { option in
                    Text(option.name).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        }

        FormField("Server",
                  help: FieldHelp(
                      "The registry's host name.",
                      detail: "The host only — no scheme such as https://, and no repository "
                          + "path. A port is allowed.",
                      example: kind.hostExample ?? "registry.internal:5000",
                      warning: kind == .gitea
                          ? "Gitea and Forgejo put the registry on the main site host, not a "
                            + "registry. subdomain."
                          : nil),
                  problem: hostProblem) {
            TextField(kind.hostExample ?? "registry.example.com:5000", text: $host)
                .textFieldStyle(.roundedBorder)
                .monospaced()
        }

        FormField("Name",
                  help: FieldHelp(
                      "What to call it in the list.",
                      detail: "Defaults to the server name, which is usually what you recognise "
                          + "a self-hosted registry by anyway."),
                  optional: true) {
            TextField(trimmedHost.isEmpty ? "Optional" : trimmedHost, text: $name)
                .textFieldStyle(.roundedBorder)
        }

        FormField("Connect using",
                  help: FieldHelp(
                      "HTTPS, unless the registry has no TLS.",
                      detail: "Remembered for this registry, unlike the Pull form's one-off "
                          + "switch: a development registry that has no TLS today will not have "
                          + "any tomorrow either.",
                      warning: "Over HTTP nothing can sign in: " + KnownRegistry.httpSignInRefusal)) {
            Picker("", selection: $usesHTTP) {
                Text("HTTPS").tag(false)
                Text("HTTP").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        // No warning here: the sign-in section below says what HTTP means for signing in, once.

        FormField("Signing in",
                  help: FieldHelp(
                      "Whether anything can be pulled from it without an account.",
                      detail: "Flotilla can't tell for a registry it doesn't know, and doesn't ask "
                          + "the registry. If signing in is required, the registry is added once "
                          + "you have signed in; if it's optional, you can add it now and sign in "
                          + "later.",
                      example: "A company or cloud registry:\nusually required.\nA public "
                          + "mirror: usually optional.")) {
            Toggle("Signing in is required", isOn: $customRequiresSignIn)
                .toggleStyle(.checkbox)
        }
    }

    // MARK: Manage

    @ViewBuilder
    private var manageFields: some View {
        if let managed {
            FormField("Server", help: FieldHelp(managed.summary,
                                                detail: "Where images with this host come from.")) {
                Text(managed.id)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }

            FormField("Signing in", help: FieldHelp(signInExplanation(managed.signInNeed))) {
                Text(managed.signInNeed.title)
            }

            FormField("Status") {
                HStack(spacing: 6) {
                    RegistryStatusLabel(row: managed)
                    if managed.isSignedIn {
                        Button("Sign Out…") { confirmingSignOut = true }
                            .disabled(working || !model.runtimeUsable)
                    }
                }
            }

            if !managed.isListed {
                Text("You're signed in to this registry from the command line, but it isn't in "
                     + "your list.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add to List") { addUnlisted(managed) }
            }

            signInSection
        } else {
            ContentUnavailableView("Registry unavailable",
                                   systemImage: "questionmark.square.dashed",
                                   description: Text("It is no longer in your list or signed in."))
        }
    }

    private func signInExplanation(_ need: SignInNeed) -> String {
        switch need {
        case .required: "Nothing can be pulled from it without an account."
        case .optional: "Public images pull without an account; signing in reaches private ones."
        case .notNeeded: "It has no accounts. Every image pulls with no credential."
        }
    }

    // MARK: Signing in

    @ViewBuilder
    private var signInSection: some View {
        if canSignIn {
            FormSectionHeader(title: managed?.isSignedIn == true ? "Switch account" : "Sign in",
                              note: sectionNote)

            if let hint = guidance.hint {
                credentialGuidance(hint)
            }

            FormField("Username",
                      help: FieldHelp("The account name this registry issues.",
                                      detail: "Not always a person: ECR's is literally AWS, Quay's "
                                          + "is a robot account, Google's is oauth2accesstoken."),
                      optional: need != .required && isAdd) {
                TextField("", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
            }

            FormField("Password or token",
                      help: FieldHelp("Usually a token rather than an account password.",
                                      detail: "Flotilla does not store it. It goes to `container "
                                          + "registry login`, which saves it in this Mac's Keychain.",
                                      warning: "Several registries issue short-lived tokens — "
                                          + "Amazon's lasts about 12 hours, Google's about one — "
                                          + "so expect to sign in again."),
                      problem: signInError,
                      optional: need != .required && isAdd) {
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canSubmit { submit() } }
            }

            if !model.runtimeUsable {
                Text("Signing in needs the container runtime, which isn't available right now.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        } else if httpBlocksSignIn {
            // Not a greyed-out sign-in that can only fail: the runtime will not do it.
            FormSectionHeader(title: "Sign in", note: "Not possible over HTTP.")
            Text(KnownRegistry.httpSignInRefusal
                 + (need == .required && isAdd
                    ? " Switch Connect using to HTTPS to add it."
                    : " Images that need no account still pull."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if need == .notNeeded {
            // Not a greyed-out sign-in: there is no account to grey out.
            FormSectionHeader(title: "Signing in", note: "Not needed here.")
            Text("\(managed?.name ?? chosen?.name ?? "This registry") has no accounts — public "
                 + "images pull with no credential at all.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectionNote: String {
        if managed?.isSignedIn == true {
            return "Signing in again replaces the account this Mac holds for it."
        }
        switch need {
        case .required where isAdd: return "Required. The registry is added once you have signed in."
        case .required: return "Required to pull anything from it."
        case .optional where isAdd: return "Optional. You can add it now and sign in whenever you like."
        default: return "Optional."
        }
    }

    /// Prose, then any command on its own line.
    private func credentialGuidance(_ hint: String) -> some View {
        let parts = hint.components(separatedBy: "\n\n")
        return VStack(alignment: .leading, spacing: 6) {
            Text(parts[0])
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(parts.dropFirst(), id: \.self) { command in
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            }
            if let url = (guidance.token ?? guidance.docs).flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(guidance.token != nil
                          ? "Create a token in your browser…"
                          : "Read the sign-in guide…",
                          systemImage: "safari")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .foregroundStyle(Theme.link)
                .help(url.absoluteString)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Rail and footer

    /// **Not a command preview** — adding a registry runs nothing until you sign in. The rail
    /// shows the row you are about to create, or the one you are looking at.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let managed {
                Label("In the table as", systemImage: Section.registries.systemImage)
                    .font(.caption).foregroundStyle(Theme.info)
                Text(managed.name).font(.system(size: 13, weight: .medium))
                Text(managed.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Sign-in \(managed.signInNeed.title.lowercased()) · \(managed.statusText)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Will be added as", systemImage: Section.registries.systemImage)
                    .font(.caption).foregroundStyle(Theme.info)
                if choice == nil {
                    Text("Choose a registry to begin.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if server.isEmpty {
                    Text("Type the registry's server name.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(chosen?.name
                         ?? (name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name))
                        .font(.system(size: 13, weight: .medium))
                    Text(server)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(hostProblem == nil
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger))
                        .textSelection(.enabled)
                    if usesHTTP, isCustom {
                        Text("over HTTP").font(.caption).foregroundStyle(Theme.warning)
                    }
                    if let need {
                        Text(railSignInLine(need))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func railSignInLine(_ need: SignInNeed) -> String {
        switch need {
        case .required:
            if plaintext { return "Can't be added over HTTP — it needs a sign-in." }
            return hasCredentials ? "Signing in as \(username), then adding"
                                  : "Sign in to add it — this registry needs an account."
        case .optional:
            if plaintext { return "No sign-in over HTTP; images that need no account pull." }
            return hasCredentials ? "Signing in as \(username)"
                                  : "Not signing in yet — you can do it any time."
        case .notNeeded:
            return "No sign-in: it has no accounts."
        }
    }

    private var footer: some View {
        HStack {
            if working { ProgressView().controlSize(.small) }
            // Why the button is off, when no field has said so. Given the footer's width and two
            // lines at most: marked to grow vertically beside a Spacer, it was squeezed to a
            // word per line and grew the footer until the window's bar went off the top (seen
            // choosing Red Hat Registry, 5 October).
            if let reason = disabledReason {
                Text(reason).font(.caption)
                    .foregroundStyle(hostProblem != nil ? Theme.danger : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            Button(isAdd ? "Cancel" : "Done", action: dismiss)
                .keyboardShortcut(.cancelAction)
            if canSignIn || isAdd {
                Button(buttonTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var disabledReason: String? {
        guard !canSubmit, !working else { return nil }
        if let hostProblem { return hostProblem }
        // A required registry over HTTP: the sign-in section already says why, so not twice.
        if isAdd, need == .required, plaintext { return nil }
        if isAdd, choice != nil, need == .required, !hasCredentials, !server.isEmpty {
            return "Enter a username and password or token — this registry is added once you have signed in."
        }
        return nil
    }

    // MARK: Actions

    private func submit() {
        guard canSubmit else { return }
        signInError = nil

        // Manage: sign in or switch account, nothing else.
        if managed != nil {
            signIn(then: { dismiss() })
            return
        }

        // Required: sign in first, and add only if it worked.
        if need == .required {
            signIn(then: {
                addChosen()
                dismiss()
            })
            return
        }

        // Optional or not needed: add, then sign in if credentials were given. A failed sign-in
        // does not undo the add — the registry is genuinely in the list, and a wrong password is
        // something to correct from its row.
        addChosen()
        guard hasCredentials else { dismiss(); return }
        signIn(then: { dismiss() })
    }

    private func addChosen() {
        if let chosen {
            model.addRegistry(known: chosen)
        } else {
            model.addRegistry(host: trimmedHost, name: name, summary: kind.summary, kind: kind,
                              usesHTTP: usesHTTP, signInRequired: customRequiresSignIn)
        }
    }

    private func addUnlisted(_ row: RegistryRow) {
        if let known = KnownRegistry.catalogue.first(where: {
            KnownRegistry.canonicalHost($0.id) == KnownRegistry.canonicalHost(row.id)
        }) {
            model.addRegistry(known: known)
        } else {
            model.addRegistry(host: row.id, name: "", summary: "", kind: RegistryKind.inferred(fromHost: row.id),
                              usesHTTP: false, signInRequired: true)
        }
    }

    private func signIn(then success: @escaping () -> Void) {
        working = true
        let server = self.server
        let scheme = plaintext ? "http" : nil
        Task {
            let error = await model.signIn(registry: server, username: username,
                                           password: password, scheme: scheme)
            working = false
            // Cleared either way: a rejected secret is one to retype, and leaving it in the field
            // invites pressing the button again unchanged.
            password = ""
            await model.refreshRegistries()
            if let error {
                signInError = error
            } else {
                success()
            }
        }
    }

    private func signOut() {
        guard let managed else { return }
        working = true
        Task {
            // The **stored** host, not the row's. Docker Hub's row is `docker.io` and its
            // credential lives under `registry-1.docker.io`.
            let error = await model.signOut(registry: managed.credentialHost)
            working = false
            await model.refreshRegistries()
            signInError = error
        }
    }
}

/// A registry's sign-in status, the same everywhere it is drawn: the table, the cards, the form.
struct RegistryStatusLabel: View {
    let row: RegistryRow

    var body: some View {
        if row.isSignedIn {
            Label(row.statusText, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.online).labelStyle(.titleAndIcon)
                .lineLimit(1)
        } else {
            Text(row.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
