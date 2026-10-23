import SwiftUI
import FlotillaCore

/// The browser and a group's Add Service picker share the same row and library artwork.
struct SuggestionRow<Actions: View>: View {
    let item: SuggestionItem
    let model: AppModel
    @Binding var selection: Set<String>
    /// The service picker uses the library's ids; discovery uses the catalogue's namespaced ids.
    var selectionID: String? = nil
    @ViewBuilder var actions: () -> Actions

    private var id: String { selectionID ?? item.id }

    var body: some View {
        ResourceRow(title: item.title, detail: item.summary,
                    thirdLine: item.libraryEntry.map(SuggestionsView.stats) ?? item.details.map { "\($0.0): \($0.1)" }.joined(separator: " · "),
                    selected: selection.contains(id), check: RowCheck(id, in: $selection),
                    summary: "\(item.title), \(item.tab.rawValue), \(item.summary)",
                    leading: {
                        if let entry = item.libraryEntry {
                            SuggestionLogo(data: model.libraryLogo(for: entry),
                                           category: entry.categories.first)
                        } else {
                            Image(systemName: item.tab.systemImage).font(.title2).foregroundStyle(.secondary)
                        }
                    }, chips: {
                        Text(item.tab.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if item.libraryEntry?.licenceNote != nil { Text("Licence").font(.caption2) }
                    }, actions: actions)
    }
}
