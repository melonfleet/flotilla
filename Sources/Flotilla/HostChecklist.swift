import SwiftUI
import FlotillaCore

/// Choosing Macs for an action that runs on several — Push to Hosts, Pull to — at fleet scale
/// (the owner, 7 October: "imagine someone managing 20 or 30 Mac minis").
///
/// A table, not a list of checkboxes: one row per Mac with what the action would do there, so the
/// state of every Mac is visible **before** it is chosen. Search matches the name, its tags and
/// that state, so typing a tag and then Select All Shown picks a whole tier at once. The table is
/// a fixed ten rows high and scrolls rather than paging: pages scatter a selection across views
/// you cannot see at once, and **Show Selected** answers "what have I ticked" directly.
///
/// The ticks are the selection. A Mac the action cannot run on is shown, with why, and cannot be
/// ticked.
struct HostChecklist: View {
    let model: AppModel
    /// The Macs to offer, in order.
    let hosts: [HostRef]
    @Binding var selection: Set<HostRef>
    /// Whether the action can run on this Mac now.
    let isSelectable: (HostRef) -> Bool
    /// What the action would do there, and whether that deserves a warning colour.
    let state: (HostRef) -> (text: String, warning: Bool)
    var stateTitle = "Status"
    /// An optional extra column — a pushed network's subnet on that Mac.
    var extraTitle: String? = nil
    var extra: (HostRef) -> String? = { _ in nil }

    @State private var search = ""
    @State private var show: Show = .all

    enum Show: String, CaseIterable, Identifiable {
        case all = "All", available = "Can be chosen", selected = "Selected"
        var id: Self { self }
    }

    /// One row of the table. Built fresh each render from the closures, so it is always current.
    struct Row: Identifiable {
        let id: HostRef
        let name: String
        let tags: [Tag]
        let state: String
        let warning: Bool
        let selectable: Bool
        let extra: String?
    }

    private var rows: [Row] {
        hosts.map { host in
            let state = state(host)
            return Row(id: host, name: model.hostMode.hostName(host, local: HostModeController.computerName),
                       tags: model.tags.tags(on: .host, tagID(host)),
                       state: state.text, warning: state.warning,
                       selectable: isSelectable(host), extra: extra(host))
        }
    }

    /// Hosts are tagged by fingerprint hex, This Mac by its row id — the keys the Hosts table uses.
    private func tagID(_ host: HostRef) -> String {
        switch host {
        case .local: HostRow.thisMacID
        case .peer(let fingerprint): fingerprint.hex
        }
    }

    private var shown: [Row] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            switch show {
            case .all: break
            case .available: if !row.selectable { return false }
            case .selected: if !selection.contains(row.id) { return false }
            }
            guard !needle.isEmpty else { return true }
            return row.name.lowercased().contains(needle)
                || row.state.lowercased().contains(needle)
                || row.tags.contains { $0.name.lowercased().contains(needle) }
        }
    }

    private var chosenCount: Int { rows.filter { selection.contains($0.id) && $0.selectable }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            table
                // Ten rows and a header, then it scrolls — the same height whether there are three
                // Macs or thirty, so the form below never moves as the fleet grows.
                .frame(height: 300)
                // Never sideways: the last column takes what is left and its text is short, so a
                // horizontal scroller here only ever appeared for a few points of rounding.
                .scrollIndicators(.never, axes: .horizontal)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline.opacity(0.3)))
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("", text: $search, prompt: Text("Search…"))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
            Picker("Show", selection: $show) {
                ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer()
            Text("\(chosenCount) of \(rows.filter(\.selectable).count) chosen")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button(allShownChosen ? "Clear Shown" : "Select All Shown") {
                let ids = shown.filter(\.selectable).map(\.id)
                if allShownChosen { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .controlSize(.small)
            .disabled(!shown.contains(where: \.selectable))
        }
    }

    private var allShownChosen: Bool {
        let selectable = shown.filter(\.selectable)
        return !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
    }

    private var table: some View {
        SwiftUI.Table(shown) {
            TableColumn("") { row in
                Toggle("", isOn: Binding(get: { selection.contains(row.id) && row.selectable },
                                         set: { on in if on { selection.insert(row.id) } else { selection.remove(row.id) } }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!row.selectable)
                    .accessibilityLabel("Choose \(row.name)")
            }
            .width(min: 24, ideal: 26, max: 30)

            TableColumn("Mac") { row in
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1)
                        .foregroundStyle(row.selectable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .layoutPriority(1)
                    if row.id.isLocal { ThisMacPill() }
                    // Only when there are some: an empty `TagPillRow` is a flexible clear view,
                    // which took half the cell and cut the name short.
                    if !row.tags.isEmpty { TagPillRow(tags: row.tags, compact: true, limit: 1) }
                    Spacer(minLength: 0)
                }
            }
            .width(min: 140, ideal: 200, max: 300)

            TableColumn(stateTitle) { row in
                Text(row.state)
                    .font(.callout)
                    .foregroundStyle(row.warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(row.state)
            }
            // The only column without a ceiling: it takes the width the form column has left, so
            // the table never scrolls sideways inside a 640-point form.
            .width(min: 100, ideal: 120)

            if let extraTitle {
                TableColumn(extraTitle) { row in
                    Text(row.extra ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 110, max: 130)
            }
        }
    }
}
