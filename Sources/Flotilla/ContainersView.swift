import SwiftUI
import Foundation
import FlotillaCore

/// The containers section: **the product**.
///
/// Q2 in `DECISIONS.md`: the container list is a **table** by default — running-first,
/// sortable, multi-select — with the card grid demoted to a toggle, because cards stop
/// scaling around twenty rows. The table is *cross-host* from the outset (`Host` column),
/// even though Phase 1 only talks to this Mac: the aggregate view is the differentiator no
/// comparable tool has, and retrofitting a host dimension later is far more painful than
/// carrying it from the start.
///
/// Moved out of `MainWindowView` unchanged when the window became a `NavigationSplitView`
/// (Phase 1 UI contract), then extended here with filter tabs, a bulk-action bar, the
/// Created/IP columns, and the detail sheet hook.
struct ContainersView: View {
    let model: AppModel

    enum Presentation: String, CaseIterable, Identifiable {
        case list = "List"
        case cards = "Cards"
        var id: Self { self }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: Self { self }
    }

    @State private var presentation: Presentation = .list
    @State private var filter: Filter = .all
    @State private var selection = Set<Container.ID>()
    @State private var search = ""
    @State private var detailContainer: Container?
    @State private var confirmingBulkDelete = false
    @State private var showingRun = false

    private var filtered: [Container] {
        switch filter {
        case .all: model.containers
        case .running: model.running
        case .stopped: model.stopped
        }
    }

    private var visible: [Container] {
        guard !search.isEmpty else { return filtered }
        let needle = search.lowercased()
        return filtered.filter {
            $0.id.lowercased().contains(needle) || $0.status.state.lowercased().contains(needle)
        }
    }

    private var visibleIDs: Set<Container.ID> { Set(visible.map(\.id)) }

    /// What a bulk action may actually touch: the selection **intersected with what is on
    /// screen**.
    ///
    /// `selection` outlives the rows that produced it. Select three containers under
    /// `All`, switch the filter to `Running` so two of them are hidden, and the raw
    /// selection still holds all three — so a bulk Delete would destroy two containers the
    /// user cannot see and was never shown in the confirmation count. Searching hides rows
    /// the same way, and a deleted container leaves its id behind entirely. Every bulk
    /// path therefore acts on this, never on `selection`.
    private var actionable: Set<Container.ID> { selection.intersection(visibleIDs) }

    /// True while any actionable id has an action in flight — disables the bulk bar so a
    /// second click can't fire a duplicate operation on top of the first.
    private var selectionBusy: Bool { !actionable.isDisjoint(with: model.busy) }

    /// Start/stop/restart/delete for one container. Attached to both the table rows and
    /// the cards so the two views offer the same capabilities — a toggle that changes what
    /// you can *do*, not just how it looks, is a trap.
    @ViewBuilder
    private func actions(for container: Container) -> some View {
        let busy = model.busy.contains(container.id)
        Button("Details…") { detailContainer = container }
        Divider()
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
            bulkActionBar
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
        .sheet(item: $detailContainer) { container in
            ContainerDetailView(model: model, container: container)
        }
        .sheet(isPresented: $showingRun) {
            RunSheetView(model: model)
        }
        // `actionable` already stops a hidden row from being *acted on*; this stops one
        // from being *counted*. One observation covers all three ways the visible set
        // moves out from under the selection — filter change, search change, and the data
        // itself changing (a bulk delete leaves the dead ids behind otherwise, so the bar
        // would linger claiming rows that no longer exist).
        .onChange(of: visibleIDs) { _, ids in
            selection.formIntersection(ids)
        }
        .confirmationDialog(
            "Delete \(actionable.count) container\(actionable.count == 1 ? "" : "s")?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(actionable.count) Container\(actionable.count == 1 ? "" : "s")", role: .destructive) {
                Task { await model.performBulk(.delete, on: actionable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingRun = true
                } label: {
                    Label("Run Container…", systemImage: "plus")
                }
            }
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

            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
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

    /// Shown only while rows are multi-selected — the hook the `selection` state existed
    /// for but went unused before this.
    @ViewBuilder
    private var bulkActionBar: some View {
        if !actionable.isEmpty {
            HStack(spacing: 12) {
                Text("\(actionable.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start") { Task { await model.performBulk(.start, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Stop") { Task { await model.performBulk(.stop, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Restart") { Task { await model.performBulk(.restart, on: actionable) } }
                    .disabled(selectionBusy)
                Button("Delete", role: .destructive) { confirmingBulkDelete = true }
                    .disabled(selectionBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.3))
        }
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

    /// A macOS `Table` fills all available vertical space with alternating-background
    /// placeholder rows past the last real one, which looks broken with just a handful of
    /// containers. Cap the table to its content height for short lists and let a plain
    /// `Spacer` take the rest; once the list is long enough to need scrolling, let the
    /// table fill normally.
    private var table: some View {
        VStack(spacing: 0) {
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
                    Text(Self.imageLabel(c.configuration.image.reference))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(c.configuration.image.reference)
                }
                .width(min: 110, ideal: 190)
                TableColumn("Created") { c in
                    Text(Self.createdLabel(c.configuration.creationDate))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Self.createdTooltip(c.configuration.creationDate))
                }
                .width(min: 90, ideal: 120)
                TableColumn("Ports") { c in
                    // An em dash, not a blank cell: "publishes nothing" and "we couldn't
                    // read this" must not look the same.
                    Text(c.portSummary ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(c.portSummary == nil ? .tertiary : .secondary)
                        .help(c.portSummary ?? "No published ports")
                }
                .width(min: 90, ideal: 130)
                TableColumn("IP / Network") { c in
                    Text(Self.ipNetworkLabel(c))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 150)
                TableColumn("Host") { _ in Text(model.hostLabel).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 110)
            }
            .frame(maxHeight: isShortList ? shortListHeight : .infinity)

            if isShortList { Spacer(minLength: 0) }
        }
    }

    private var isShortList: Bool { visible.count < 12 }
    private var shortListHeight: CGFloat { CGFloat(visible.count) * 28 + 32 }

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
                        Text(Self.imageLabel(container.configuration.image.reference))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(container.configuration.image.reference)
                        // Cards have room for the ports the table has to compress.
                        if let ports = container.portSummary {
                            Text(ports).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(model.hostLabel).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .contextMenu { actions(for: container) }
                    .onTapGesture(count: 2) { detailContainer = container }
                }
            }
            .padding(12)
        }
    }

    /// `creationDate` is an ISO-8601 string from `container`, not a `Date` — parse it here
    /// for display only; `FlotillaCore` keeps the raw string.
    private static func createdLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else { return "—" }
        // Relative, not absolute. "Jul 27, 2026 at 5:56 PM" does not fit the column and
        // truncated to "Jul 27, 2026 at 5:56 P…" it wastes every character on parts that
        // never vary. Age is the question you actually ask of a container; the exact
        // timestamp stays available on hover.
        return date.formatted(.relative(presentation: .named))
    }

    /// The absolute timestamp, for the row's tooltip.
    private static func createdTooltip(_ iso: String?) -> String {
        guard let iso else { return "Creation date unknown" }
        let strict = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = strict.date(from: iso) ?? fractional.date(from: iso) else {
            return "Creation date unreadable (\(iso))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Shortening lives in `FlotillaCore` (`ContainerImage.shortReference`) so its awkward
    /// cases — digests, registry ports — are covered by tests this target cannot have.
    private static func imageLabel(_ reference: String) -> String {
        ContainerImage.shortReference(reference)
    }

    private static func ipNetworkLabel(_ c: Container) -> String {
        switch (c.ipv4, c.status.networks?.first?.network) {
        case let (ip?, network?): "\(ip) (\(network))"
        case let (ip?, nil): ip
        case let (nil, network?): network
        case (nil, nil): "—"
        }
    }
}
