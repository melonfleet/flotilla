import SwiftUI
import Foundation
import FlotillaCore

/// Detail sheet for one container: an overview pane plus a Logs tab.
///
/// Live streaming and `exec` are Phase 4 (`PHASE1-UI.md`) — the Logs tab is a bounded
/// fetch (`cli.logs(id, lines:)`) driven by an explicit Reload button, not a subscription.
struct ContainerDetailView: View {
    let model: AppModel
    let container: Container

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case logs = "Logs"
        var id: Self { self }
    }

    @State private var tab: Tab = .overview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            switch tab {
            case .overview: overview
            case .logs: LogsTab(model: model, containerID: container.id)
            }
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id).font(.headline)
                Text(container.configuration.image.reference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding(12)
    }

    private var overview: some View {
        Form {
            // `Navigation.swift` declares a top-level `Section` that shadows SwiftUI's —
            // must be spelled out here.
            SwiftUI.Section("Overview") {
                LabeledContent("State", value: container.status.state.capitalized)
                LabeledContent("Image", value: container.configuration.image.reference)
                LabeledContent("ID", value: container.id)
                LabeledContent("IP", value: container.ipv4 ?? "—")
                LabeledContent("Network", value: container.status.networks?.first?.network ?? "—")
                LabeledContent("Created", value: Self.createdLabel(container.configuration.creationDate))
            }
        }
        .formStyle(.grouped)
    }

    /// `creationDate` is an ISO-8601 string from `container`, not a `Date` — parse it here
    /// for display only.
    private static func createdLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Bounded log fetch with an explicit Reload — no live streaming (Phase 4). Owns its own
/// loading/error state rather than the shared `AppModel.actionError` alert: a failed log
/// reload is local to this tab and shouldn't pop a modal over the rest of the app.
private struct LogsTab: View {
    let model: AppModel
    let containerID: String

    @State private var chunk: LogChunk?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let chunk, chunk.truncated {
                    Label(
                        "Older lines exist — showing the most recent \(chunk.requestedLines).",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
            .padding(12)
            Divider()
            content
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && chunk == nil {
            ProgressView("Loading logs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView(
                "Couldn't load logs",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let chunk, !chunk.lines.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(chunk.lines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "No log output",
                systemImage: "doc.text",
                description: Text("This container hasn't produced any output yet.")
            )
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            chunk = try await model.fetchLogs(for: containerID)
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }
}
