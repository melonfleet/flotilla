import SwiftUI
import FlotillaCore

/// The inspect record for one resource, in a sheet.
///
/// Volumes and networks have no detail screen — see `AppModel.fetchVolumeInspectJSON` for why a
/// pane would mostly repeat the table — so this is how their authoritative record is read. It is
/// the same two presentations (JSON and flattened table) and the same filter the container and
/// machine Inspect tabs use, because a third dialect of "look at inspect output" is how the two
/// existing ones drifted apart in the first place: one drew Copy JSON icon-only, the other with a
/// label, and neither used the shared button.
struct InspectSheet: View {
    let title: String
    /// The command this reproduces, shown so the panel is not opaque — the same idea as the
    /// container Inspect tab's caption.
    let command: String
    let load: () async throws -> String
    let dismiss: () -> Void

    @State private var json: String?
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var presentation: InspectPresentation = .json

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.headline)
                Spacer()
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                IconActionButton(systemImage: "doc.on.doc", label: "Copy JSON",
                                 help: "Copy the inspect output", disabled: json == nil) {
                    if let json { Clipboard.copy(json) }
                }
                IconActionButton(systemImage: "arrow.clockwise", label: "Reload",
                                 help: "Reload", busy: loading) {
                    Task { await reload() }
                }
                IconActionButton(systemImage: "xmark", label: "Close", help: "Close") { dismiss() }
            }
            .padding(12)
            Divider()

            HStack(spacing: 10) {
                Picker("View", selection: $presentation) {
                    ForEach(InspectPresentation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter keys", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            content
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && json == nil {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            // The CLI's own sentence. For a volume that has just been deleted from another
            // window this is more useful than anything this view could invent.
            ContentUnavailableView("Couldn't inspect this",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if presentation == .table {
            InspectTableView(json: json, search: search)
        } else if let json {
            LineListView(lines: Self.displayLines(json), search: search, wrap: true)
        }
    }

    private static func displayLines(_ json: String) -> [DisplayLine] {
        json.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            DisplayLine(id: index, text: String(line), color: .primary)
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            json = try await load()
            error = nil
        } catch let failure {
            // Bound explicitly: the implicit `error` shadows this view's `@State error`, so the
            // obvious `error = error.localizedDescription` does not compile — and would have been
            // assigning the caught value to itself if it had.
            error = (failure as? ContainerCLIError)?.description ?? failure.localizedDescription
        }
    }
}
