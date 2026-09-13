import SwiftUI
import AppKit
import FlotillaCore

/// Adding a registry, and signing in to it, in one form.
///
/// **Nothing is on screen until you have answered the first question.** The form opens as a
/// single picker — Registry — and grows into whatever that answer needs: a known registry needs
/// only its own guidance and a sign-in, while one Flotilla does not know needs a type, a host and
/// a name as well. Showing all of it up front asked people to read past four fields that a
/// Microsoft Artifact Registry will never use.
///
/// **Sign-in happens here, not afterwards.** The first version added the registry and sent you
/// back to the list to sign in from a second sheet — two screens and a context switch for one
/// intention. Adding without signing in is still allowed: the credential fields are optional and
/// say so.
///
/// The catalogue is a menu, not a list — see `RegistryBook`. Three designs got that wrong before
/// this one.
struct AddRegistryView: View {
    let model: AppModel
    let store: RegistryStore
    let dismiss: () -> Void

    /// What the first picker is set to. `nil` is "not answered yet", which is what keeps the
    /// rest of the form off screen.
    @State private var choice: Choice?

    enum Choice: Hashable {
        /// A registry the catalogue describes, by host.
        case known(String)
        /// One it does not. Deliberately **not** called "something else": that is what the type
        /// picker used to call its fallback too, and seeing the same words twice on one screen
        /// reads as a mistake.
        case custom
    }

    @State private var kind: RegistryKind = .other
    @State private var host = ""
    @State private var name = ""
    @State private var usesHTTP = false

    // Sign-in, optional.
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    /// Set once the registry is in the list, so a failed sign-in does not look like a failed add
    /// and the button stops offering to add it twice.
    @State private var added = false
    @State private var signInError: String?

    @State private var edits = FormEditTracker()

    private var addable: [KnownRegistry] { store.addable }

    private var chosen: KnownRegistry? {
        guard case .known(let id) = choice else { return nil }
        return addable.first { $0.id == id }
    }

    private var isCustom: Bool { choice == .custom }

    /// The families you describe by hand: the ones with no fixed hostname, so no catalogue entry
    /// could name them.
    private var customTypes: [RegistryKind] {
        RegistryKind.allCases.filter { !$0.hostIsFixed }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var effectiveHost: String { chosen?.id ?? trimmedHost }

    private var hostProblem: String? {
        guard isCustom, !trimmedHost.isEmpty else { return nil }
        return store.book.problem(withHost: trimmedHost)
    }

    /// Whether this registry has an account to sign in to at all. A custom one is assumed to —
    /// it is the user's own and we know nothing about it.
    private var canSignIn: Bool { chosen?.hasAccounts ?? true }

    private var guidance: (hint: String?, token: String?, docs: String?) {
        if let chosen { return (chosen.credentialHint, chosen.tokenURL, chosen.kind.docsURL) }
        return (kind.credentialHint, kind.tokenURL, kind.docsURL)
    }

    private var hasCredentials: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private var canSubmit: Bool {
        guard !working else { return false }
        if added { return hasCredentials }
        guard choice != nil else { return false }
        return chosen != nil || (!trimmedHost.isEmpty && hostProblem == nil)
    }

    private var editSignature: String {
        [String(describing: choice), kind.rawValue, host, name,
         usesHTTP ? "http" : "https", username].joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Add Registry", systemImage: "shippingbox.and.arrow.backward",
                       hasUnsavedChanges: edits.isDirty(editSignature),
                       onBack: dismiss)
            Divider()
            FormScaffold {
                fields
            } preview: {
                railPreview
            }
            Divider()
            footer
        }
        .onAppear { edits.open(editSignature) }
    }

    @ViewBuilder
    private var fields: some View {
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
                ForEach(addable) { registry in
                    Text(registry.name).tag(Optional(Choice.known(registry.id)))
                }
                if !addable.isEmpty { Divider() }
                Text("Custom…").tag(Optional(Choice.custom))
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .disabled(added)
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

            if canSignIn {
                signInFields
            } else if let chosen {
                // Not a greyed-out sign-in: there is no account to grey out. Microsoft's
                // registry and `registry.k8s.io` have no credential of any kind.
                FormSectionHeader(title: "Signing in", note: "Not needed here.")
                Text("\(chosen.name) has no accounts — public images pull with no credential at "
                     + "all. Add it and start pulling.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            .disabled(added)
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
                .disabled(added)
        }

        FormField("Name",
                  help: FieldHelp(
                      "What to call it in the list.",
                      detail: "Defaults to the server name, which is usually what you recognise "
                          + "a self-hosted registry by anyway."),
                  optional: true) {
            TextField(trimmedHost.isEmpty ? "Optional" : trimmedHost, text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(added)
        }

        FormField("Connect using",
                  help: FieldHelp(
                      "HTTPS, unless the registry has no TLS.",
                      detail: "Remembered for this registry, unlike the Pull form's one-off "
                          + "switch: a development registry that has no TLS today will not have "
                          + "any tomorrow either.",
                      warning: "Over HTTP your password is sent in the clear. Only for a "
                          + "registry on your own machine or network.")) {
            Picker("", selection: $usesHTTP) {
                Text("HTTPS").tag(false)
                Text("HTTP").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(added)
        }

        if usesHTTP {
            Label("Your password will be sent unencrypted.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var signInFields: some View {
        FormSectionHeader(title: "Sign in",
                          note: "Optional. You can add it now and sign in whenever you like.")

        if let hint = guidance.hint {
            credentialGuidance(hint)
        }

        FormField("Username",
                  help: FieldHelp("The account name this registry issues.",
                                  detail: "Not always a person: ECR's is literally AWS, Quay's "
                                      + "is a robot account, Google's is oauth2accesstoken."),
                  optional: true) {
            TextField("", text: $username)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
        }

        FormField("Password or token",
                  help: FieldHelp("Usually a token rather than an account password.",
                                  detail: "Flotilla does not store it. It goes to `container "
                                      + "registry login`, which saves it in this Mac's Keychain.",
                                  warning: "Several registries issue short-lived tokens — "
                                      + "Amazon's lasts about 12 hours, Google's about one — so "
                                      + "expect to sign in again."),
                  problem: signInError,
                  optional: true) {
            SecureField("", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSubmit { submit() } }
        }
    }

    /// Prose, then any command on its own line — the same split the sign-in sheet uses.
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
                .foregroundStyle(Theme.accentText)
                .help(url.absoluteString)
            }
        }
        .textSelection(.enabled)
    }

    /// **Not a command preview** — adding a registry runs nothing until you sign in. The rail's
    /// pinned slot shows the row you are about to create instead.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(added ? "Added" : "Will be added as", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(added ? Theme.online : Theme.info)
            if choice == nil {
                Text("Choose a registry to begin.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if effectiveHost.isEmpty {
                Text("Type the registry's server name.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(chosen?.name
                     ?? (name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name))
                    .font(.system(size: 13, weight: .medium))
                Text(effectiveHost)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(hostProblem == nil
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger))
                    .textSelection(.enabled)
                if usesHTTP, isCustom {
                    Text("over HTTP").font(.caption).foregroundStyle(Theme.warning)
                }
                if canSignIn {
                    Text(hasCredentials ? "Signing in as \(username)"
                                        : "Not signing in yet — you can do it any time.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if working { ProgressView().controlSize(.small) }
            // The backstop the network form gained: if the button is off and no field has said
            // why, say it here rather than leaving a grey button with no explanation.
            if let hostProblem {
                Text(hostProblem).font(.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(added ? "Done" : "Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(buttonTitle, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var buttonTitle: String {
        if added { return "Sign In" }
        return hasCredentials ? "Add and Sign In" : "Add"
    }

    /// Adds, then signs in if credentials were given.
    ///
    /// **The add is not undone by a failed sign-in**, and the form says so rather than
    /// pretending nothing happened: the registry is genuinely in the list, and a wrong password
    /// is something to correct here rather than a reason to start over. `added` is what keeps the
    /// button from offering to add it a second time.
    private func submit() {
        guard canSubmit else { return }
        signInError = nil

        if !added {
            if let chosen {
                store.add(known: chosen)
            } else {
                store.add(host: trimmedHost, name: name, summary: kind.summary,
                          kind: kind, usesHTTP: usesHTTP)
            }
            added = true
            guard hasCredentials else { dismiss(); return }
        }

        working = true
        let server = effectiveHost
        let scheme = (chosen == nil && usesHTTP) ? "http" : nil
        Task {
            let error = await model.signIn(registry: server, username: username,
                                           password: password, scheme: scheme)
            working = false
            if let error {
                signInError = error
                // Cleared on failure too: a rejected secret is one to retype, and leaving it in
                // the field invites pressing the button again unchanged.
                password = ""
            } else {
                password = ""
                dismiss()
            }
        }
    }
}
