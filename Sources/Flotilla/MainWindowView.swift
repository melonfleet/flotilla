import SwiftUI
import FlotillaCore

/// The main window: **the product**.
///
/// Q2 in `DECISIONS.md`: the container list is a **table** by default — running-first,
/// sortable, multi-select — with the card grid demoted to a toggle, because cards stop
/// scaling around twenty rows. The table is *cross-host* from the outset (`Host` column),
/// even though Phase 1 only talks to this Mac: the aggregate view is the differentiator no
/// comparable tool has, and retrofitting a host dimension later is far more painful than
/// carrying it from the start.
struct MainWindowView: View {
    let model: AppModel

    enum Presentation: String, CaseIterable, Identifiable {
        case list = "List"
        case cards = "Cards"
        var id: Self { self }
    }

    @State private var presentation: Presentation = .list
    @State private var selection = Set<Container.ID>()
    @State private var search = ""

    private var visible: [Container] {
        guard !search.isEmpty else { return model.containers }
        let needle = search.lowercased()
        return model.containers.filter {
            $0.id.lowercased().contains(needle) || $0.status.state.lowercased().contains(needle)
        }
    }

    /// Start/stop/restart/delete for one container. Attached to both the table rows and
    /// the cards so the two views offer the same capabilities — a toggle that changes what
    /// you can *do*, not just how it looks, is a trap.
    @ViewBuilder
    private func actions(for container: Container) -> some View {
        let busy = model.busy.contains(container.id)
        if AppModel.isRunning(container) {
            Button("Stop") { Task { await model.perform(.stop, on: container) } }.disabled(busy)
            Button("Restart") { Task { await model.perform(.restart, on: container) } }.disabled(busy)
        } else {
            Button("Start") { Task { await model.perform(.start, on: container) } }.disabled(busy)
        }
        Divider()
        // Destructive, and deliberately only in the main window — never the popover.
        Button("Delete", role: .destructive) {
            Task { await model.perform(.delete, on: container) }
        }.disabled(busy)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .alert("Action failed",
               isPresented: Binding(get: { model.actionError != nil },
                                    set: { if !$0 { model.clearActionError() } })) {
            Button("OK") { model.clearActionError() }
        } message: {
            Text(model.actionError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $presentation) {
                ForEach(Presentation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            TextField("Search containers…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable(let reason), .failed(let reason):
            // Distinguish "cannot see the fleet" from "the fleet is empty". Showing an
            // empty table on a failed poll is the exact class of bug that made an
            // unreachable printer look healthy in a sibling tool.
            ContentUnavailableView(
                "Can't reach the container runtime",
                systemImage: "exclamationmark.triangle",
                description: Text(reason)
            )

        case .loaded where visible.isEmpty:
            ContentUnavailableView(
                search.isEmpty ? "No containers" : "No matches",
                systemImage: "tray",
                description: Text(search.isEmpty
                                  ? "Nothing is running on this Mac yet."
                                  : "No container matches “\(search)”.")
            )

        case .loaded:
            if presentation == .list { table } else { cards }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("State") { c in
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppModel.isRunning(c) ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(c.status.state.capitalized)
                }
            }
            .width(min: 90, ideal: 100)

            TableColumn("Name") { c in
                Text(c.id)
                    .lineLimit(1)
                    .contextMenu { actions(for: c) }
            }
            TableColumn("Image") { c in
                Text(c.configuration.image.reference).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Host") { _ in Text(model.hostLabel).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(visible) { container in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(AppModel.isRunning(container) ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(container.id).font(.headline).lineLimit(1)
                        }
                        Text(container.configuration.image.reference)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.hostLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .contextMenu { actions(for: container) }
                }
            }
            .padding(12)
        }
    }
}
