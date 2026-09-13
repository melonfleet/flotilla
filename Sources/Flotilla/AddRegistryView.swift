import SwiftUI
import AppKit
import FlotillaCore

/// Adding a registry to the list — a form with the guidance rail, like every other form in the
/// app, rather than the two-field sheet it started as.
///
/// **The rail follows the registry you pick**, which is the whole point of the owner's request.
/// Every registry authenticates differently and the differences are not small: GHCR takes only a
/// classic token, Red Hat's username contains a pipe, Quay wants a robot account, ECR's password
/// is minted by a CLI and lasts twelve hours. A single "username and password" form with one
/// generic hint sends people to look all of that up somewhere else. `FormScaffold` already
/// collects help from whichever fields are on screen, so a `FieldHelp` built from the chosen
/// registry rewrites the rail for free.
struct AddRegistryView: View {
    let model: AppModel
    let store: RegistryStore
    let dismiss: () -> Void

    /// Which **family** of registry this is. Not which catalogue row — see `RegistryKind`: the
    /// first version asked for a row and the answer set was empty, because every registry with a
    /// fixed hostname is already in the list and is never something you add.
    @State private var kind: RegistryKind = .other
    @State private var host = ""
    @State private var name = ""
    @State private var usesHTTP = false
    @State private var edits = FormEditTracker()

    /// The families you can actually add: the ones with no fixed hostname. A `Sign In…` for
    /// Docker Hub already exists on the list behind this form, so offering "add Docker Hub"
    /// could only ever produce a duplicate.
    private var addableKinds: [RegistryKind] {
        RegistryKind.allCases.filter { !$0.hostIsFixed }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hostProblem: String? {
        guard !trimmedHost.isEmpty else { return nil }
        return store.book.problem(withHost: trimmedHost)
    }

    private var canAdd: Bool { !trimmedHost.isEmpty && hostProblem == nil }

    private var editSignature: String {
        [kind.rawValue, host, name, usesHTTP ? "http" : "https"].joined(separator: "\u{1}")
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
        FormField("Kind",
                  help: FieldHelp(
                      "What sort of registry this is.",
                      detail: "It decides the guidance on the right — every family signs in "
                          + "differently, and the differences are not small. Docker Hub, GitHub, "
                          + "Quay and the other public registries are not here because they are "
                          + "already in the list.",
                      example: kind.summary)) {
            Picker("", selection: $kind) {
                ForEach(addableKinds) { option in
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

        // What signing in to this family will want, before you commit to adding it.
        if let hint = kind.credentialHint {
            FormSectionHeader(title: "Signing in",
                              note: "What this registry asks for when you sign in.")
            credentialGuidance(hint)
        }

        FormSectionHeader(title: "Connection",
                          note: "How Flotilla reaches it. Almost always the default.")

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
        }

        if usesHTTP {
            Label("Your password will be sent unencrypted.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Prose, then any command on its own line — the same split the sign-in sheet uses, because
    /// it is the same text.
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
            if let url = (kind.tokenURL ?? kind.docsURL).flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(kind.tokenURL != nil
                          ? "Create a token in your browser…"
                          : "Read \(kind.name)'s sign-in guide…",
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

    /// **Not a command preview** — adding a registry runs nothing. The rail's pinned slot shows
    /// what the row will be instead, which is the equivalent honesty: the thing you are about to
    /// create, before you create it.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will be added as", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(Theme.info)
            if trimmedHost.isEmpty {
                Text("Type the registry's server name.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name)
                    .font(.system(size: 13, weight: .medium))
                Text(trimmedHost)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(hostProblem == nil
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.danger))
                    .textSelection(.enabled)
                if usesHTTP {
                    Text("over HTTP").font(.caption).foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            // The backstop the network form gained: if the button is off and no field above has
            // said why, say it here rather than leaving a grey button with no explanation.
            if let hostProblem {
                Text(hostProblem).font(.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Button("Add") {
                store.add(host: trimmedHost, name: name, summary: kind.summary,
                          kind: kind, usesHTTP: usesHTTP)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
