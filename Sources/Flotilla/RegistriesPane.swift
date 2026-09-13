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

    /// The host the credential is filed under, which is what a sign-out has to name. Usually the
    /// row's own id; for Docker Hub it is `registry-1.docker.io`.
    var credentialHost: String { login?.id ?? id }

    /// Where to create the token this registry wants as a password, if there is such a page.
    var tokenURL: URL? { known?.tokenURL.flatMap(URL.init(string:)) }
    var browseURL: URL? { known?.browseURL.flatMap(URL.init(string:)) }

    /// Whether this registry has an account to sign in to at all.
    ///
    /// A row the user added is assumed to have one — it is their own registry and we know
    /// nothing about it, and withholding the control would be worse than offering one that
    /// might fail with the registry's own message.
    var canSignIn: Bool { known?.hasAccounts ?? true }

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
        // Keyed on the **canonical** host, not the stored one. `docker.io` signs in and comes
        // back as `registry-1.docker.io`; matching by exact string left the Docker Hub row
        // saying "Not signed in" and added a duplicate row at the bottom for the same account.
        // See `KnownRegistry.canonicalHost`.
        let byHost = Dictionary(logins.map { (KnownRegistry.canonicalHost($0.id), $0) },
                                uniquingKeysWith: { first, _ in first })
        var rows = store.all.map {
            RegistryRow(id: $0.id, known: $0, login: byHost[KnownRegistry.canonicalHost($0.id)])
        }
        let listed = Set(rows.map { KnownRegistry.canonicalHost($0.id) })
        rows += logins.filter { !listed.contains(KnownRegistry.canonicalHost($0.id)) }
            .map { RegistryRow(id: $0.id, known: nil, login: $0) }
        return rows
    }

    var body: some View {
        // Embedded, not modal — the same choice New Volume and New Network make, and for the
        // same reason: a form with a guidance rail needs the width, and a sheet inside the
        // Settings pane does not have it.
        Group {
            if showingAdd {
                AddRegistryView(model: model, store: store) { showingAdd = false }
            } else {
                Form { sections }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private var sections: some View {
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
            Picker("Default registry", selection: Binding(
                get: { model.settingsStore[SettingsKeys.defaultRegistryDomain] },
                set: { try? model.settingsStore.set($0, for: SettingsKeys.defaultRegistryDomain) }
            )) {
                ForEach(rows) { row in
                    Text("\(row.name) — \(row.id)").tag(row.id)
                }
            }
        } header: {
            Text("Default")
        } footer: {
            // **The smaller claim, said out loud.** `container` has a `[registry] domain`
            // property, but `container system property` offers only `list` — nothing Flotilla
            // can run will change it. So this is Flotilla's own default, and pretending
            // otherwise would put the app back where it was: a control that stores a value and
            // alters nothing.
            Text("Which registry Flotilla's own Pull form completes a bare name against — type "
                 + "myapp:1.0 and it becomes that registry's. It does not change what the "
                 + "container CLI does on its own: a bare name typed in a terminal still comes "
                 + "from Docker Hub.")
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
        .sheet(item: $signIn) { row in
            SignInSheet(model: model, row: row) { error in
                signIn = nil
                actionError = error
                Task { await reload() }
            }
        }
        .confirmationDialog(
            "Sign out of “\(pendingSignOut?.name ?? "")”?",
            isPresented: Binding(get: { pendingSignOut != nil },
                                 set: { if !$0 { pendingSignOut = nil } }),
            titleVisibility: .visible
        ) {
            if let row = pendingSignOut {
                Button("Sign Out", role: .destructive) {
                    Task {
                        // The **stored** host, not the row's. Docker Hub's row is `docker.io`
                        // and its credential lives under `registry-1.docker.io`; signing out of
                        // the wrong one would report success and leave the login in place.
                        actionError = await model.signOut(registry: row.credentialHost)
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
            // Three different situations, and they are genuinely different: a built-in comes
            // back by name from Add, one of your own has to be retyped, and either way a login
            // survives and keeps the row visible.
            Text(pendingRemove?.isSignedIn == true
                 ? "This only removes it from the list. You stay signed in, so it will still "
                   + "appear here as a sign-in until you sign out."
                 : (pendingRemove?.isUserAdded == true
                    ? "This only removes it from the list. Nothing is deleted, and you can add "
                      + "it again with Add Registry."
                    : "This only removes it from the list. Add Registry will offer it back "
                      + "under Removed."))
        }
    }

    private func registryRow(_ row: RegistryRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium))
                    // Two different facts, and they were one badge. `isImplicitDefault` is
                    // what the **runtime** resolves a bare name to and is not configurable;
                    // "default" here is the registry **Flotilla's** own forms complete against,
                    // which is. Showing one badge for both would have claimed the setting
                    // changes the runtime, which is the overclaim this whole screen avoids.
                    if row.id == defaultRegistry {
                        badge("default")
                    }
                    if row.known?.isImplicitDefault == true, row.id != defaultRegistry {
                        badge("CLI default")
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
                        // **Switching accounts is signing in again**, not signing out first.
                        // Measured: `container registry login` twice for one host leaves one
                        // credential — the second replaces the first — because the store is
                        // keyed by hostname. So there is no two-step dance to build, and no
                        // second account to hold: one registry, one signed-in account, and this
                        // button is how you change which.
                        Button("Switch…") { signIn = row }
                            .disabled(!model.runtimeUsable)
                            .help("Sign in as a different account. "
                                  + "\(row.name) holds one account at a time.")
                        Button("Sign Out") { pendingSignOut = row }
                    } else if row.canSignIn {
                        Button("Sign In…") { signIn = row }
                            .disabled(!model.runtimeUsable)
                    }
                    // Nothing at all where there is nothing to sign in to. Microsoft's registry
                    // and `registry.k8s.io` have no accounts, no token page and no credential —
                    // measured, `mcr.microsoft.com/v2/` answers 200 rather than 401. A greyed
                    // "Sign In…" would imply an account you could go and get; there isn't one.
                    if let url = row.browseURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accentText)
                        .accessibilityLabel("Browse \(row.name)")
                        .help("Browse \(row.name) in your browser")
                    }
                    // **Every row in the list can be removed now**, not only the user's own.
                    // A built-in is hidden rather than deleted and comes back through Add —
                    // refusing to remove one was defensible and wrong for the person using it:
                    // a list of ten registries where you use two is a list you stop reading.
                    //
                    // A row that is only here because you are signed in to it is not in the
                    // list to begin with, so there is nothing to remove.
                    if row.known != nil {
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
            // Two shades of the same fact: a registry with no accounts at all, and one that is
            // public but will still take a sign-in (ECR Public, where authenticating raises your
            // rate limit). Saying "No account" for the second would be wrong.
            Text(row.canSignIn ? "No sign-in needed" : "No account")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not signed in").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var defaultRegistry: String {
        model.settingsStore[SettingsKeys.defaultRegistryDomain]
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
    @State private var plaintext: Bool
    @State private var working = false

    init(model: AppModel, row: RegistryRow, finish: @escaping (String?) -> Void) {
        self.model = model
        self.row = row
        self.finish = finish
        // Seeded from the registry rather than always false: a registry the user added as HTTP
        // is HTTP every time, and making them re-assert it on each sign-in is how a warning
        // stops being read.
        _plaintext = State(initialValue: row.known?.usesHTTP ?? false)
    }

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
