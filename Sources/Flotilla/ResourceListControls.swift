import SwiftUI
import FlotillaCore

/// List / Cards, per section.
enum ResourcePresentation: String, CaseIterable, Identifiable {
    case list = "List", cards = "Cards"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .cards: "square.grid.2x2"
        }
    }
}

/// One choice in a section's filter. `id` is what gets stored, so it must be stable.
struct ResourceFilterOption: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
}

/// The view switcher, columns picker and filter that sit to the left of a section's search
/// field — the cluster Containers and Machines already had and the other three did not.
///
/// Shared rather than copied three more times. Parity that lives in five files is parity
/// somebody has to remember, and this project has already lost that bet: switching to Cards once
/// silently cost the Copy menu because its definition was private to one view.
///
/// **The filter hides itself when there is nothing to choose between.** Options are derived from
/// the data on screen, so a volumes list where every volume has the same driver shows no filter
/// at all rather than a control whose every setting returns the same rows. A control that drives
/// nothing is the failure this project keeps re-learning, and "consistency" is not a reason to
/// ship one — the sections look the same when the data makes the same controls meaningful.
struct ResourceListControls<Row: Identifiable>: View {
    @Binding var presentation: ResourcePresentation
    @Binding var filterID: String
    @Binding var columnCustomization: TableColumnCustomization<Row>

    /// `(id, title)` per hideable column, in the order the popover should list them.
    let columns: [(id: String, title: String)]
    /// Empty, or **two or more** genuine choices. One choice is not a filter.
    let filters: [ResourceFilterOption]
    /// The Host section of the filter (PLAN.md Phase C): offered when there is a host to choose.
    var hostFilter: Binding<HostRef?>? = nil
    var hosts: [(ref: HostRef, name: String)] = []

    private var offersHosts: Bool { hostFilter != nil && hosts.count > 1 }

    @State private var showingColumns = false
    @State private var showingFilter = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $presentation) {
                ForEach(ResourcePresentation.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("\(option.rawValue) view")
                        .help("\(option.rawValue) view")
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            IconActionButton(systemImage: "rectangle.split.3x1", label: "Columns",
                             help: "Show or hide columns",
                             // Cards have no columns to configure.
                             disabled: presentation != .list) { showingColumns.toggle() }
                .popover(isPresented: $showingColumns, arrowEdge: .bottom) { columnsPopover }

            if filters.count > 1 || offersHosts {
                IconActionButton(systemImage: "line.3.horizontal.decrease",
                                 label: "Filter",
                                 help: filterHelp,
                                 active: filterID != "all" || hostFilter?.wrappedValue != nil) { showingFilter.toggle() }
                    .popover(isPresented: $showingFilter, arrowEdge: .bottom) { filterPopover }
            }
        }
    }

    private var filterHelp: String {
        var parts: [String] = []
        if let current = filters.first(where: { $0.id == filterID }), current.id != "all" {
            parts.append(current.title.lowercased())
        }
        if let host = hostFilter?.wrappedValue, let name = hosts.first(where: { $0.ref == host })?.name {
            parts.append("on " + name)
        }
        return parts.isEmpty ? "Filter this list" : "Showing " + parts.joined(separator: ", ") + " only"
    }

    private var columnsPopover: some View {
        ColumnVisibilityList(columns: columns, customization: $columnCustomization)
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filters.count > 1 {
                Picker("Show", selection: $filterID) {
                    ForEach(filters) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            // The same Host section Containers has: an independent question, so its own group.
            if offersHosts, let hostFilter {
                if filters.count > 1 { Divider() }
                Text("Host").font(.caption).foregroundStyle(.secondary)
                Picker("Host", selection: hostFilter) {
                    Label("All hosts", systemImage: "square.stack").tag(HostRef?.none)
                    ForEach(hosts, id: \.ref) { host in
                        Label(host.name, systemImage: host.ref.isLocal ? "laptopcomputer" : "desktopcomputer")
                            .tag(HostRef?.some(host.ref))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .padding(14)
    }

}

/// The columns picker's contents: a checkbox per column, then Hide All / Show All. One view for
/// every table that offers it — the resource sections and Overview's Hosts — so they cannot drift.
struct ColumnVisibilityList<Row: Identifiable>: View {
    let columns: [(id: String, title: String)]
    @Binding var customization: TableColumnCustomization<Row>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(columns, id: \.id) { column in
                Toggle(column.title, isOn: binding(for: column.id))
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
            Divider().padding(.vertical, 6)
            HStack {
                Button("Hide All") { setAll(.hidden) }
                Spacer()
                Button("Show All") { setAll(.visible) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
        .frame(width: 210)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { customization[visibility: id] != .hidden },
            set: { customization[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    private func setAll(_ visibility: Visibility) {
        for column in columns { customization[visibility: column.id] = visibility }
    }
}
