import SwiftUI
import FlotillaCore

/// "Add Service" in a group: choose where the services come from before any form opens.
///
/// Suggestions (the library's single containers) and the images on this Mac are two lists in one
/// screen; Blank is today's empty form. Tick as many as you like — one opens the service form
/// filled in, several go straight into the group (`GroupFormView` builds them through
/// `GroupMembers`, the same mapping a stack uses).
///
/// This is not `SuggestionsView` in a mode: that screen is a Use… walk with a stack form, a detail
/// pane and its own header, and this one needs a second source on the same screen. It borrows the
/// parts that carry the look — `ResourceRow`, `RowCheck`, `SuggestionLogo`, the row's stats line.
struct GroupServicePickerView: View {
    let model: AppModel
    let place: HostRef
    let onBlank: () -> Void
    let onCancel: () -> Void
    let onAdd: ([GroupMembers.Pick]) -> Void

    private enum Source: Hashable { case suggestions, images }

    @State private var source = Source.suggestions
    @State private var suggestionSelection = Set<LibraryEntry.ID>()
    @State private var imageSelection = Set<String>()
    @State private var queryText = PageSearchText()
    @State private var formToken = UUID()

    private var query: String { queryText.value }
    private var library: SuggestionLibrary { model.suggestionLibrary }

    private var suggestions: [LibraryEntry] {
        library.entries.filter { $0.kind == .container && $0.container != nil && $0.matches(query) }
    }

    /// Every image once, in reference order; the tag is part of the reference.
    private var allImages: [String] {
        Array(Set(model.images(on: place).map(\.reference))).sorted()
    }

    private var images: [String] {
        allImages.filter { reference in
            query.split(whereSeparator: \.isWhitespace)
                .allSatisfy { reference.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    private var total: Int { suggestionSelection.count + imageSelection.count }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Add Services", systemImage: "shippingbox",
                       hasUnsavedChanges: false, onBack: onCancel, token: formToken,
                       actions: FormActions(.keepsChanges(
                           total >= 2 ? "Add \(total) Services" : total == 1 ? "Review Service" : "Add",
                           isDisabled: total == 0) { add() }))
            Divider()
            FormBand {
                Text(total >= 2
                     ? "These are added to the group as they are; edit any of them from the list."
                     : "Tick what you want in the group. One opens its form to review; several are added straight away.")
                    .foregroundStyle(.secondary)
                Button("Blank service…", action: onBlank)
                    .buttonStyle(.link).foregroundStyle(Theme.link)
            }
            HStack(spacing: 12) {
                Picker("Source", selection: $source) {
                    Text(suggestionSelection.isEmpty ? "Suggestions" : "Suggestions (\(suggestionSelection.count))")
                        .tag(Source.suggestions)
                    Text(imageSelection.isEmpty ? "Images on this Mac" : "Images on this Mac (\(imageSelection.count))")
                        .tag(Source.images)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            switch source {
            case .suggestions: suggestionList
            case .images: imageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .searchesFromToolbar(prompt: source == .suggestions ? "Search suggestions" : "Search images",
                             text: Binding(get: { [weak queryText] in queryText?.value ?? "" },
                                           set: { [weak queryText] in queryText?.value = $0 }),
                             matches: source == .suggestions ? suggestions.count : images.count)
        .task { if model.volumesState != .loaded { await model.refreshVolumes() } }
        .outsideSplitPane()
    }

    private var suggestionList: some View {
        List(selection: $suggestionSelection) {
            if !suggestions.isEmpty {
                selectAllRow(SelectAllCheckbox(selection: $suggestionSelection, ids: suggestions.map(\.id),
                                               noun: "suggestions"), count: suggestions.count, noun: "suggestions")
            }
            ForEach(suggestions) { entry in
            SuggestionRow(item: .library(entry), model: model, selection: $suggestionSelection,
                          selectionID: entry.id, actions: {})
            .tag(entry.id)
            .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.inset)
        .overlay { if suggestions.isEmpty { ContentUnavailableView.search(text: query) } }
    }

    private var imageList: some View {
        List(selection: $imageSelection) {
            if !images.isEmpty {
                selectAllRow(SelectAllCheckbox(selection: $imageSelection, ids: images, noun: "images"),
                             count: images.count, noun: "images")
            }
            ForEach(images, id: \.self) { reference in
            // Only a recipe for the same major version: the row says what `Pick` will do.
            let match = library.recipe(forImage: reference)
            ResourceRow(
                title: SuggestionsView.shortImage(reference),
                detail: match.map { "Starts from \($0.title)’s ports, variables and volumes" } ?? "Just the image",
                selected: imageSelection.contains(reference),
                check: RowCheck(reference, in: $imageSelection),
                summary: SuggestionsView.shortImage(reference),
                leading: {
                    SuggestionLogo(data: model.libraryLogo(for: reference), category: nil, size: 32)
                },
                chips: {},
                actions: {})
            .tag(reference)
            .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.inset)
        .overlay {
            if images.isEmpty {
                if allImages.isEmpty {
                    ContentUnavailableView("No images on this Mac", systemImage: "square.stack.3d.up",
                                           description: Text("Pull one from Images, or choose a suggestion."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    /// Select all, as the list's first row: in the rows' own inset and padding (`ResourceRow`'s 12),
    /// so its box sits in the column of the boxes it ticks (Kamal, 19 October). Untagged, so the
    /// List can't select it.
    private func selectAllRow(_ box: some View, count: Int, noun: String) -> some View {
        HStack(spacing: 10) {
            box
            Text("Select all \(count) \(noun)").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .listRowInsets(EdgeInsets())
        .selectionDisabled()
    }

    private func add() {
        // From everything, not what the search shows: a tick a later search hides is still a tick.
        let picks = library.entries.filter { suggestionSelection.contains($0.id) }.compactMap(GroupMembers.Pick.init(entry:))
            + allImages.filter { imageSelection.contains($0) }.map { GroupMembers.Pick(localImage: $0, in: library) }
        guard !picks.isEmpty else { return }
        onAdd(picks)
    }
}
