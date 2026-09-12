import SwiftUI
import FlotillaCore

/// The Inspect panel: one resource's authoritative record, as a flattened table or as JSON.
///
/// **One implementation, four subjects.** This was two near-identical private copies — one in
/// `ContainerDetailView`, one in `MachineDetailView` — differing only in the subject's type, the
/// command caption and their comments. They had already drifted once and been pulled back
/// together twice: the machine panel shipped JSON-only because the flattening was private to the
/// container file, and the two rendered JSON by different means, a line list against plain text.
/// Volumes and networks needed the same panel, which would have made four copies.
///
/// The subject enters as two closures and a caption rather than as a type, so a new kind needs no
/// new panel — only a way to fetch its JSON.
struct InspectPane: View {
    /// The command this reproduces, shown so the panel is not opaque: it turns a view into
    /// something you can run in a terminal yourself.
    let command: String
    /// What went wrong, in this subject's own words — "Couldn't inspect this volume".
    let failureTitle: String
    /// Fetches the raw record. Redaction happens here, not in the caller, so nothing unredacted
    /// can reach the view, the search index or the clipboard by a caller forgetting.
    let load: () async throws -> String

    @State private var json: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var presentation: InspectPresentation = .table

    /// Narrowed on purpose. The standard set is tuned for a support bundle **leaving the
    /// machine**; this is a panel you read on your own Mac, and applying the strict rules here
    /// rewrote every image digest as `<redacted:fingerprint>` — a digest is 64 hex characters and
    /// so is a certificate fingerprint. A digest is a public content hash and one of the more
    /// useful things in this output, so redacting it removed information and protected nothing.
    /// Mount paths go the same way: they are the point of inspecting.
    ///
    /// Everything that is actually a secret still goes: tokens, certificates, URL credentials and
    /// `KEY=value` secrets. That matters most on `machine inspect`, which carries
    /// `userSetup.username` — the host user's own name, and the third time a real username
    /// escaped through this app.
    private static let redactor = Redactor(excluding: [.fingerprint, .homePath,
                                                       .temporaryPath, .email])

    var body: some View {
        // `alignment: .leading`: a `VStack` centres its children, and the JSON view is a
        // `ScrollView` sized to its content — so a payload narrower than the pane was centred in
        // it, reading as a floating block of text rather than as a document.
        VStack(alignment: .leading, spacing: 0) {
            // The same order as the Logs band next door: actions in the cluster, then the
            // control that changes what you are looking at, then the field you search it with.
            // These tabs sit one click apart and used to read left-to-right in opposite
            // directions.
            HStack(spacing: 12) {
                ActionCluster {
                    IconActionButton(systemImage: "doc.on.doc", label: "Copy JSON",
                                     help: "Copy the inspect output, with secrets redacted",
                                     disabled: json == nil) {
                        // Copies exactly what is displayed — redacted. See `reload()`.
                        if let json { Clipboard.copy(json) }
                    }
                    Divider().frame(height: 14)
                    IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                     help: "Reload", busy: loading) {
                        Task { await reload() }
                    }
                }

                Picker("View", selection: $presentation) {
                    ForEach(InspectPresentation.allCases) {
                        // The word survives as the accessibility label and the tooltip; only the
                        // drawing changes.
                        Label($0.rawValue, systemImage: $0.symbol)
                            .labelStyle(.iconOnly)
                            .help($0.rawValue)
                            .tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField("Filter keys", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                if !search.isEmpty {
                    Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            content

            redactionNote
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView(failureTitle, systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if loading && json == nil {
            ProgressView("Loading inspect JSON…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation == .table {
            InspectTableView(json: json, search: search)
        } else if let json {
            JSONTextView(json: json, search: search)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Says that what you are reading has been filtered. A redaction the user cannot see is
    /// indistinguishable from a resource that had no secrets, and someone debugging a missing
    /// environment variable deserves to know the difference.
    private var redactionNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.caption2)
            Text("Secrets are redacted. Values shown as `<redacted:…>` are present on this Mac "
                 + "but hidden here and in Copy JSON.")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    /// Matching lines, for the count beside the filter field. Counted here rather than asked of
    /// the viewer, which filters rather than highlights — the two must agree, and the line is the
    /// unit both work in.
    private var matchCount: Int {
        guard let json, !search.isEmpty else { return 0 }
        return json.split(separator: "\n", omittingEmptySubsequences: false)
            .count { $0.localizedCaseInsensitiveContains(search) }
    }

    private func reload() async {
        loading = true
        error = nil
        do {
            // Redacted before it is ever assigned. `container inspect` includes
            // `configuration.initProcess.environment`, verified against the live CLI — on nginx
            // that is PATH and version strings, on Postgres it is POSTGRES_PASSWORD, and on an
            // application container whatever API keys were passed at run time.
            json = Self.redactor.redact(try await load())
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }
}
