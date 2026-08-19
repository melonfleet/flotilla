import SwiftUI

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

            if filters.count > 1 {
                IconActionButton(systemImage: "line.3.horizontal.decrease",
                                 label: "Filter",
                                 help: filterHelp,
                                 active: filterID != "all") { showingFilter.toggle() }
                    .popover(isPresented: $showingFilter, arrowEdge: .bottom) { filterPopover }
            }
        }
    }

    private var filterHelp: String {
        guard let current = filters.first(where: { $0.id == filterID }), current.id != "all" else {
            return "Filter this list"
        }
        return "Showing \(current.title.lowercased()) only"
    }

    private var columnsPopover: some View {
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

    private var filterPopover: some View {
        Picker("Show", selection: $filterID) {
            ForEach(filters) { option in
                Label(option.title, systemImage: option.systemImage).tag(option.id)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .padding(14)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { columnCustomization[visibility: id] != .hidden },
            set: { columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }

    private func setAll(_ visibility: Visibility) {
        for column in columns { columnCustomization[visibility: column.id] = visibility }
    }
}
