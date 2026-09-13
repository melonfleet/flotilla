import SwiftUI
import AppKit
import FlotillaCore

/// One row of the Registries table: a catalogue entry, a login, or both.
///
/// Both halves are kept because they answer different questions. The catalogue says what the
/// registry *is*; the login says whether this Mac has credentials for it. A row can have either
/// alone — a registry you have never signed in to, or a login to something not in the list —
/// and the table has to show both or it is lying about one of them.
struct RegistryRow: Identifiable, Equatable {
    let id: String
    let known: KnownRegistry?
    let login: RegistryLogin?

    var name: String { known?.name ?? id }
    var summary: String {
        known?.summary
            ?? "Signed in from the command line; not in your list. Add it to keep it here."
    }
    var isUserAdded: Bool { known?.isUserAdded ?? false }
    var isSignedIn: Bool { login != nil }
    var username: String? { login?.username }

    /// Where to create the token this registry wants as a password, if there is such a page.
    var tokenURL: URL? { known?.tokenURL.flatMap(URL.init(string:)) }

    /// What to put in the two fields. The catalogue's own wording where there is one; otherwise
    /// the cloud-CLI recipe, matched on the host — which is how a per-account registry the
    /// catalogue cannot list still gets useful instructions.
    var credentialHint: String? {
        known?.credentialHint ?? KnownRegistry.cloudCredentialHint(forHost: id)
    }
}

/// Settings → **Registries**: what Flotilla can pull from, and which of them this Mac is signed
/// in to.
///
/// **The honest framing matters more than the table.** Apple's `container` has no supported-
/// registry list — it pulls from anything that speaks the OCI distribution API, and the host in
/// the image reference is the only thing that decides where an image comes from. So this screen
/// says that out loud, and the list is a convenience: the registries you do not have to remember
/// the hostname of, plus your own, plus whatever you are actually signed in to. Presenting a
/// curated list as a compatibility matrix would be the kind of confident wrongness this app has
/// spent weeks removing.
///
/// **In Settings rather than beside Containers**, and not inside Resources. Resources is
/// "defaults for new containers" — CPUs and memory — and a registry is neither a default nor a
/// resource. It sits beside Tags for the same reason Tags does: it is something you configure
/// once and then forget, not an inventory you work in.
///
/// Written as `Form` sections, because `SettingsView.pane(for:)` wraps every pane in a grouped
/// `Form`.
struct RegistriesPane: View {
    let model: AppModel
    let store: RegistryStore

    @State private var logins: [RegistryLogin] = []
    @State private var loading = false
    @State private var showingAdd = false
    @State private var signIn: RegistryRow?
    @State private var pendingRemove: RegistryRow?
    @State private var pendingSignOut: RegistryRow?
    @State private var actionError: String?

    /// Catalogue ∪ user-added ∪ actual logins, in that order, de-duplicated by host.
    ///
    /// The third set is what stops this being a pretty list that disagrees with the machine: a
    /// registry you signed in to with `container registry login` in a terminal appears here,
    /// marked as not being in your list, rather than being invisible.
    private var rows: [RegistryRow] {
        let byHost = Dictionary(logins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = store.all.map { RegistryRow(id: $0.id, known: $0, login: byHost[$0.id]) }
        let listed = Set(rows.map(\.id))
        rows += logins.filter { !listed.contains($0.id) }
            .map { RegistryRow(id: $0.id, known: nil, login: $0) }
        return rows
    }

    var body: some View {
        SwiftUI.Section {
            ForEach(rows) { row in
                registryRow(row)
            }
        } header: {
            HStack {
                Text("Registries")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
        } footer: {
            // The sentence the whole screen exists to prevent someone getting wrong.
            // Plain prose. `Text` parses Markdown only in a string literal, and this is built
            // with `+` — the first version rendered "**any**" and the backticks verbatim.
            VStack(alignment: .leading, spacing: 3) {
                Text("Flotilla can pull from any OCI registry — this list is not a restriction. "
                     + "Write the host in the image reference and it works:")
                Text("ghcr.io/apple/container-builder-shim/builder:0.13.1")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Text("A reference with no host, such as alpine:latest, comes from Docker Hub.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        SwiftUI.Section {
            HStack {
                Button("Add Registry…") { showingAdd = true }
                Spacer()
                Button("Refresh") { Task { await reload() } }
                    .disabled(loading || !model.runtimeUsable)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption).foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Private registries are usually per-account, so they are not in the list above: "
                 + "Amazon ECR is <account>.dkr.ecr.<region>.amazonaws.com, Azure is "
                 + "<name>.azurecr.io, Google Artifact Registry is <region>-docker.pkg.dev. "
                 + "Add yours, and a self-hosted Harbor or registry:2, here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await reload() }
        .sheet(isPresented: $showingAdd) {
            AddRegistrySheet(store: store) { showingAdd = false }
        }
        .sheet(item: $signIn) { row in
            SignInSheet(model: model, row: row) { error in
                signIn = nil
                actionError = error
                Task { await reload() }
            }
        }
        .confirmationDialog(
            "Sign out of “\(pendingSignOut?.id ?? "")”?",
            isPresented: Binding(get: { pendingSignOut != nil },
                                 set: { if !$0 { pendingSignOut = nil } }),
            titleVisibility: .visible
        ) {
            if let row = pendingSignOut {
                Button("Sign Out", role: .destructive) {
                    Task {
                        actionError = await model.signOut(registry: row.id)
                        await reload()
                    }
                    pendingSignOut = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingSignOut = nil }
        } message: {
            Text("The stored credential is deleted from this Mac’s Keychain. Pulling public "
                 + "images from this registry still works.")
        }
        .confirmationDialog(
            "Remove “\(pendingRemove?.id ?? "")” from the list?",
            isPresented: Binding(get: { pendingRemove != nil },
                                 set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            if let row = pendingRemove {
                Button("Remove", role: .destructive) {
                    store.remove(host: row.id)
                    pendingRemove = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            // Says what it does *not* do. Removing a row and destroying a credential are
            // different decisions, and a row that vanished while the login survived would be a
            // login you can no longer see.
            Text(pendingRemove?.isSignedIn == true
                 ? "This only removes it from the list. You stay signed in, so it will still "
                   + "appear here as a sign-in until you sign out."
                 : "This only removes it from the list. Nothing is deleted and you can add it "
                   + "again.")
        }
    }

    private func registryRow(_ row: RegistryRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium))
                    if row.known?.isImplicitDefault == true {
                        badge("default")
                    }
                    if row.isUserAdded { badge("yours") }
                    if row.known == nil { badge("not in your list") }
                }
                Text(row.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                status(row)
                HStack(spacing: 6) {
                    if row.isSignedIn {
                        Button("Sign Out") { pendingSignOut = row }
                    } else {
                        Button("Sign In…") { signIn = row }
                            .disabled(!model.runtimeUsable)
                    }
                    if row.isUserAdded {
                        IconActionButton(systemImage: "trash",
                                         label: "Remove \(row.id) from the list",
                                         help: "Remove from the list. Does not sign out.",
                                         destructive: true) {
                            pendingRemove = row
                        }
                    }
                }
            }
        }
    }

    /// Three states, not two. "Not signed in" and "no sign-in needed" are different facts, and
    /// showing the first for `mcr.microsoft.com` would send someone looking for an account they
    /// do not need.
    @ViewBuilder
    private func status(_ row: RegistryRow) -> some View {
        if let username = row.username, !username.isEmpty {
            Label("Signed in as \(username)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.online).labelStyle(.titleAndIcon)
        } else if row.isSignedIn {
            // A login with no username: real, and observed — the record carries `username` as
            // optional. Say what is known rather than printing an empty name.
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.online).labelStyle(.titleAndIcon)
        } else if row.known?.anonymousPullWorks == true {
            Text("No sign-in needed").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not signed in").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func reload() async {
        guard model.runtimeUsable else { logins = []; return }
        loading = true
        logins = await model.registryLogins()
        loading = false
    }
}

/// Adding a registry to the list. Says why it is refusing while you type.
struct AddRegistrySheet: View {
    let store: RegistryStore
    let dismiss: () -> Void

    @State private var host = ""
    @State private var name = ""

    private var problem: String? {
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : store.book.problem(withHost: host)
    }
    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem == nil
    }

    var body: some View {
        ModalCard(title: "Add Registry", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 14) {
                field("Server", placeholder: "registry.example.com:5000", text: $host,
                      monospaced: true)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The host only — no scheme such as https://, and no repository path.")
                    .font(.caption).foregroundStyle(.secondary)

                field("Name", placeholder: "Optional", text: $name, monospaced: false)
                Text("What to call it in the list. Defaults to the server name.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Add") {
                        store.add(host: host, name: name)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                }
            }
            .frame(width: 360)
            .padding(16)
        }
    }

    private func field(_ label: String, placeholder: String,
                       text: Binding<String>, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 12, design: .monospaced) : nil)
        }
    }
}

/// Signing in to a registry.
///
/// **The password is never stored by Flotilla and never reaches argv.** It is held in `@State`
/// for as long as the sheet is open, handed to `container registry login --password-stdin`, and
/// dropped. The Keychain entry that results is written by `container`, not by this app, and
/// signing out deletes it.
struct SignInSheet: View {
    let model: AppModel
    let row: RegistryRow
    /// Called with the CLI's complaint, or nil on success.
    let finish: (String?) -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var plaintext = false
    @State private var working = false

    private var canSubmit: Bool {
        !working && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        ModalCard(title: "Sign in to \(row.name)", onClose: { finish(nil) }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Username").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Password or token").font(.system(size: 12)).foregroundStyle(.secondary)
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canSubmit { submit() } }
                    // **What to type, in this registry's own terms.** "Username and password" is
                    // wrong for most of them: GHCR wants a `read:packages` token and a GitHub
                    // password simply fails, which is a dead end the form used to leave you in.
                    // A hint may end with a command on its own line — the cloud registries
                    // issue short-lived tokens and the command is the useful part. Split on the
                    // blank line so the command reads as one, and can be copied.
                    let hint = row.credentialHint
                        ?? "Most registries want an access token here, not your account password."
                    let parts = hint.components(separatedBy: "\n\n")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(parts[0])
                        ForEach(parts.dropFirst(), id: \.self) { command in
                            Text(command)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.raisedSurface,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Theme.hairline))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // **The browser half, and the only half there is.**
                //
                // `container registry login` takes a username and a password on stdin — no
                // device code, no OAuth grant, no callback, checked against the 1.4.1 binary and
                // its leaf help. The OCI distribution spec has no interactive grant either. So
                // Flotilla cannot hand the sign-in to a browser and get back something the
                // runtime can use.
                //
                // What it can do is take you to the page where the token is made, which is where
                // the browser genuinely belongs: on almost every registry here the password is a
                // token, not an account password. Shown only when such a page exists — a button
                // that leads nowhere is the control this app keeps deleting.
                if let url = row.tokenURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Create a token in your browser…", systemImage: "safari")
                    }
                    .buttonStyle(.link)
                    // `.link` hardcodes the system blue and ignores the scene tint — the trap
                    // `Theme.rowName` was written for. Measured here: the link rendered stock
                    // macOS blue, the one hue with no place in this palette, on a sheet where
                    // everything else is the brand orange.
                    .foregroundStyle(Theme.accentText)
                    .help(url.absoluteString)
                }

                Toggle("This registry has no TLS (http)", isOn: $plaintext)
                if plaintext {
                    // Named plainly, at the moment of choosing. `--scheme http` sends the
                    // credential in the clear; that is a legitimate choice for a loopback or LAN
                    // development registry and a bad one for anything else.
                    Label("Your password will be sent unencrypted. Only do this for a registry "
                          + "on your own machine or network.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Flotilla does not store your password. It is passed to "
                     + "container registry login, which saves it in this Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                    Button("Sign In", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
            .frame(width: 380)
            .padding(16)
        }
    }

    private func submit() {
        working = true
        Task {
            let error = await model.signIn(registry: row.id, username: username,
                                           password: password,
                                           scheme: plaintext ? "http" : nil)
            // Cleared before the sheet closes rather than relying on the view being torn down.
            password = ""
            working = false
            finish(error)
        }
    }
}
