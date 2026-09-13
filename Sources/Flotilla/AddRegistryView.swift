import SwiftUI
import AppKit
import FlotillaCore

/// Adding a registry — one form, with the guidance rail, like every other form in the app.
///
/// **One question, two answers.** Either you pick a registry Flotilla already knows, in which
/// case there is nothing to type and the rail explains that registry; or you describe one it
/// does not, in which case you say what kind it is and where it lives and the rail explains that
/// family. There is no third path, and in particular there is no "put back": a registry removed
/// from the list is simply not in the list, and adding it again is this same form.
///
/// That took three attempts. The first version listed every known registry permanently and had
/// an Add form with an empty picker, because everything addable was already there. The second
/// let you hide them. The third let you un-hide them, which added a second way to do the one
/// thing this form is for. All three were elaborations of one wrong idea — that the catalogue is
/// a list rather than a menu.
struct AddRegistryView: View {
    let model: AppModel
    let store: RegistryStore
    let dismiss: () -> Void

    /// A known registry's host, or nil for one Flotilla does not know.
    @State private var known: String?
    @State private var kind: RegistryKind = .other
    @State private var host = ""
    @State private var name = ""
    @State private var usesHTTP = false
    @State private var edits = FormEditTracker()

    /// Known registries not already in the list. A registry you have is not one to add, and
    /// offering it could only produce a duplicate.
    private var addable: [KnownRegistry] { store.addable }

    private var chosen: KnownRegistry? { addable.first { $0.id == known } }

    /// The families you describe by hand: the ones with no fixed hostname, so no catalogue entry
    /// could name them.
    private var customKinds: [RegistryKind] {
        RegistryKind.allCases.filter { !$0.hostIsFixed }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hostProblem: String? {
        guard chosen == nil, !trimmedHost.isEmpty else { return nil }
        return store.book.problem(withHost: trimmedHost)
    }

    private var canAdd: Bool {
        chosen != nil || (!trimmedHost.isEmpty && hostProblem == nil)
    }

    /// Whichever set of guidance applies to what is on screen.
    private var guidance: (summary: String, hint: String?, token: String?, docs: String?) {
        if let chosen {
            return (chosen.summary, chosen.credentialHint, chosen.tokenURL, chosen.kind.docsURL)
        }
        return (kind.summary, kind.credentialHint, kind.tokenURL, kind.docsURL)
    }

    private var editSignature: String {
        [known ?? "", kind.rawValue, host, name, usesHTTP ? "http" : "https"]
            .joined(separator: "\u{1}")
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
                          + "links come with it. Choose Something else to describe a private, "
                          + "self-hosted or per-account registry yourself.",
                      example: "Amazon ECR, Azure and Google Artifact\nRegistry are per-account, "
                          + "so they are\nalways Something else")) {
            Picker("", selection: $known) {
                ForEach(addable) { registry in
                    Text(registry.name).tag(Optional(registry.id))
                }
                if !addable.isEmpty { Divider() }
                Text("Something else…").tag(String?.none)
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        }

        if let chosen {
            // A known registry's host is its identity. A field you can only get wrong is not a
            // field, so it is shown rather than typed.
            FormField("Server", help: FieldHelp(chosen.summary,
                                                detail: "Fixed for a registry Flotilla knows.")) {
                Text(chosen.id)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else {
            FormField("Kind",
                      help: FieldHelp(
                          "What sort of registry this is.",
                          detail: "It decides the guidance on the right — every family signs in "
                              + "differently, and the differences are not small.",
                          example: kind.summary)) {
                Picker("", selection: $kind) {
                    ForEach(customKinds) { option in
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
                          detail: "Defaults to the server name, which is usually what you "
                              + "recognise a self-hosted registry by anyway."),
                      optional: true) {
                TextField(trimmedHost.isEmpty ? "Optional" : trimmedHost, text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        }

        // What signing in will want, before you commit to adding it.
        if let hint = guidance.hint {
            FormSectionHeader(title: "Signing in",
                              note: "What this registry asks for when you sign in.")
            credentialGuidance(hint)
        }

        // Only where it is a real choice. A known registry is HTTPS — every one in the catalogue
        // is a public registry on the internet — so a picker there would be a control with one
        // correct setting.
        if chosen == nil {
            FormSectionHeader(title: "Connection",
                              note: "How Flotilla reaches it. Almost always the default.")

            FormField("Connect using",
                      help: FieldHelp(
                          "HTTPS, unless the registry has no TLS.",
                          detail: "Remembered for this registry, unlike the Pull form's one-off "
                              + "switch: a development registry that has no TLS today will not "
                              + "have any tomorrow either.",
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

    /// **Not a command preview** — adding a registry runs nothing. The rail's pinned slot shows
    /// the row you are about to create instead, which is the equivalent honesty.
    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will be added as", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(Theme.info)
            if let chosen {
                Text(chosen.name).font(.system(size: 13, weight: .medium))
                Text(chosen.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if trimmedHost.isEmpty {
                Text("Pick a registry, or type a server name.")
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
            Text("You can sign in to it from the list afterwards.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
                if let chosen {
                    store.add(known: chosen)
                } else {
                    store.add(host: trimmedHost, name: name, summary: kind.summary,
                              kind: kind, usesHTTP: usesHTTP)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
