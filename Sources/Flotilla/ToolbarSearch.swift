import SwiftUI
import AppKit
import FlotillaCore

/// The one search box in the window bar (DECISIONS Q55): it filters the list on the page you are on,
/// goes to any section or any named thing, and runs commands such as Run Container…, all from one field.
/// The owner's words: *"like VS Code, where I can either search for stuff, filter for stuff that's on
/// the page that I'm on, or bring up commands like Run Container. All from that one search box."*
///
/// It replaces two things: the floating ⌘K palette, whose items (`paletteItems()`), ranking and
/// guarded open it keeps, and the search field every list screen used to carry in its own band.
///
/// **The filter belongs to the page.** A page that has a list registers its own filter text here
/// (`searchesFromToolbar`), which is the same `ui.search` its field used to bind, so each section
/// keeps its own filter and the box shows it when you come back. A page with no list (a form, a
/// detail, the dashboard) registers nothing, and the box keeps a scratch line of its own for commands
/// and places. The box keeps its own copy of the text and writes the page's; it never reads the
/// page's `Binding` back, for the reason given on `SearchBox.State`. The rules (what `>` means, the
/// ranking, Escape's steps and focus at launch) are `SearchBox` in `FlotillaCore`, tested there.
@MainActor
@Observable
final class ToolbarSearch {
    /// What the page on screen lends the box: its filter text, and how to describe it.
    struct Scope {
        let id: UUID
        /// The field's placeholder: "Search containers". Names the noun, so the box says what it filters.
        let prompt: String
        /// The page's grammar on hover, where it has one (Containers' `SearchQuery`).
        let help: String?
        /// The page's filter. Written to, never read back: see `SearchBox.State`.
        var text: Binding<String>
        /// How many rows the filter leaves, for the dropdown's "12 on this page".
        var matches: Int?
        /// Return's job when no entry is highlighted. Only the Docker Hub browser has one: it searches
        /// a remote catalogue rather than filtering a list.
        let submit: (() -> Void)?
        /// What the dropdown's top line says about `submit`: "Return searches Docker Hub".
        let submitNote: String?
    }

    private(set) var scope: Scope?
    /// The text, focus, highlight and whether the dropdown is open.
    private(set) var state = SearchBox.State()
    /// What the dropdown can reach: rebuilt as the box gains focus and as the text changes, and
    /// emptied as it loses focus (`SearchBox.Entries`), so no list outlives the focus it was built for.
    private var list = SearchBox.Entries<PaletteItem>()
    var entries: [PaletteItem] { list.items }

    /// One-shot requests for the field, consumed by `ToolbarSearchField`. Flags rather than calls,
    /// so ⌘K from the menu still lands if the window is being opened by the same command.
    var focusRequested = false
    var releaseRequested = false

    /// Where the field and the dropdown are, in window coordinates, for `watchClicks`.
    @ObservationIgnored var fieldFrame: CGRect = .zero
    @ObservationIgnored var dropdownFrame: CGRect = .zero
    /// The window the box is focused in. A sheet over it — the unsaved-changes question, an operation's
    /// progress — is a window of its own, and its Escape and Return are its own business.
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var clickMonitor: Any?

    /// What the box shows. Typing writes it through to the page's filter, except after a `>`.
    var text: String {
        get { state.text }
        set {
            if let page = state.type(newValue) { scope?.text.wrappedValue = page }
        }
    }

    var input: SearchBox.Input { state.input }
    var prompt: String { scope?.prompt ?? "Search or run a command" }
    var isFocused: Bool { state.isFocused }
    var highlighted: Int? { state.highlighted }
    var dropdownShown: Bool { state.dropdownShown }

    var results: SearchBox.Results {
        SearchBox.results(for: text, among: entries.map {
            SearchBox.Candidate(title: $0.title, subtitle: $0.subtitle, isCommand: $0.kind == .action || (input.slashMode && $0.kind == .section),
                                isSection: $0.kind == .section, scope: $0.scope, completion: $0.completion,
                                slugs: $0.slugs, libraryEntry: $0.libraryEntry)
        }, browsing: state.browsing)
    }

    /// The highlight Return would open. With no arrow pressed, the first entry — except where Return
    /// has a job of its own (`Scope.submit`), which it keeps until an arrow picks something.
    func activeIndex(in results: SearchBox.Results) -> Int? {
        let count = results.all.count
        if let highlighted = state.highlighted, highlighted < count { return highlighted }
        guard count > 0 else { return nil }
        if entries[results.all[0]].completion != nil { return 0 }
        return scope?.submit != nil && !input.commandsOnly && input.scope == nil ? nil : 0
    }

    // MARK: Scope

    /// `pageText` is read in the page's own body, where its binding is current, not read here.
    func attach(_ new: Scope, pageText: String) {
        scope = new
        state.attach(pageText: pageText)
    }

    func update(_ id: UUID, matches: Int?) {
        guard scope?.id == id else { return }
        scope?.matches = matches
    }

    /// The page's filter changed, by the box's own write or by the page. `text` is the page's latest
    /// binding, kept so a write never goes through one the page has since replaced.
    func pageChanged(_ id: UUID, to value: String, text: Binding<String>) {
        guard scope?.id == id else { return }
        scope?.text = text
        state.pageChanged(value)
    }

    /// Only the scope that is still registered: the next page may have attached before this one left.
    func detach(_ id: UUID) {
        guard scope?.id == id else { return }
        scope = nil
        state.detach()
    }

    // MARK: Focus

    /// ⌘K, ⌘F and View ▸ Go To…: focus the box and select its text. `browsing` (⌘K, Go To…) also
    /// opens the dropdown on its commands and sections straight away; ⌘F only places the cursor.
    func focus(browsing: Bool = false) {
        if browsing { state.browse() }
        focusRequested = true
    }
    /// Give focus back to the page.
    func release() { releaseRequested = true }

    /// Accept focus from any source and keep the dropdown and event monitors in sync.
    @discardableResult
    func focusChanged(_ focused: Bool, entries: @autoclosure () -> [PaletteItem]) -> Bool {
        guard state.focusChanged(focused) else { return false }
        list.focusChanged(focused, load: entries)
        window = focused ? NSApp.keyWindow ?? NSApp.mainWindow : nil
        watchKeys(focused)
        watchClicks(focused)
        return true
    }

    func refresh(_ entries: @autoclosure () -> [PaletteItem]) { list.refresh(entries) }

    // MARK: Keys

    /// Escape, Return and the arrows are taken **before the window sees them**, while the box has
    /// focus. A form's Cancel is `.cancelAction` and its Save is often `.defaultAction`, and AppKit
    /// gives key equivalents to the window ahead of the focused field. So without this, Escape in the
    /// box cancelled the form under it and Return saved it. That is the bug class the palette's
    /// `.disabled` overlay existed to stop, and the box cannot disable the page it filters.
    private func watchKeys(_ on: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard on else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isFocused, event.window === self.window else { return event }
            // An input method composing text owns Return and Escape until it is done.
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// What a pick does, set by the field: `pick` through the model's `FormGuard`.
    @ObservationIgnored var open: ((PaletteItem) -> Void)?

    /// True when the key was the box's to handle, and must not reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53:  // Escape
            switch SearchBox.escape(dropdownOpen: dropdownShown, text: text) {
            case .closeDropdown: state.dropdownClosed = true
            case .clearText: text = ""
            case .leaveBox: release()
            }
            return true
        case 48: // Tab accepts a scope completion or runs a slash command.
            guard dropdownShown, input.slashMode || !SearchBox.scopeCompletions(for: text).isEmpty,
                  let index = activeIndex(in: results), results.all.indices.contains(index) else { return false }
            let item = entries[results.all[index]]
            guard input.slashMode || item.completion != nil else { return false }
            open?(item)
            return true
        case 36, 76:  // Return, Enter
            let results = results
            if dropdownShown, let index = activeIndex(in: results),
               results.all.indices.contains(index), entries.indices.contains(results.all[index]) {
                open?(entries[results.all[index]])
            } else if let submit = scope?.submit, !input.commandsOnly, input.scope == nil {
                state.dropdownClosed = true
                submit()
            }
            // Swallowed either way: a Return that fell through would press the form's default button.
            return true
        case 125, 126:  // ↓, ↑
            guard dropdownShown || !text.isEmpty else { return false }
            if !dropdownShown { state.dropdownClosed = false; return true }
            // From the entry already drawn highlighted, so the first ↓ moves off the first entry.
            state.highlighted = SearchBox.move(activeIndex(in: results), by: event.keyCode == 125 ? 1 : -1,
                                         count: results.all.count)
            return true
        default:
            return false
        }
    }

    /// A click anywhere but the box or its dropdown gives focus back to the page (the owner, 10 October,
    /// for the per-page fields this replaces): macOS leaves a field focused when you click something
    /// that cannot take focus, so the cursor stayed after you had clearly moved on.
    private func watchClicks(_ on: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        guard on else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = event.window, window === self.window,
                  let content = window.contentView else { return event }
            // AppKit counts from the bottom; SwiftUI's global space from the top.
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            let inside = self.fieldFrame.insetBy(dx: -2, dy: -2).contains(point)
                || (self.dropdownShown && self.dropdownFrame.contains(point))
            if !inside { self.release() }
            return event
        }
    }

    /// Picking an entry: the box lets go first, then the pick goes through the form guard exactly as
    /// the palette's did, so nothing it opens skips the unsaved-changes question. The text is cleared
    /// only if the pick goes ahead. It was a query for the dropdown, and Keep Editing leaves it.
    func pick(_ item: PaletteItem, formGuard: FormGuard) {
        if let completion = item.completion {
            text = completion.rawValue + ":"
            return
        }
        release()
        formGuard.confirmLeaving { [weak self] in
            self?.text = ""
            item.run()
        }
    }
}

extension View {
    /// Lends this page's filter to the window bar's search box while the view is on screen.
    ///
    /// Build `text` from the page's state object, captured weakly in both closures. Capturing a
    /// view here also captures its model, which owns this box and keeps the binding even on blur.
    /// Apply it to the branch that shows the list, not to the section as a whole: a detail or a form
    /// in the same section has nothing to filter, and the box should say so.
    func searchesFromToolbar(prompt: String, help: String? = nil, text: Binding<String>, matches: Int?,
                             submit: (() -> Void)? = nil, submitNote: String? = nil) -> some View {
        modifier(ToolbarSearchScope(prompt: prompt, help: help, text: text, matches: matches,
                                    submit: submit, submitNote: submitNote))
    }
}

private struct ToolbarSearchScope: ViewModifier {
    let prompt: String
    let help: String?
    let text: Binding<String>
    let matches: Int?
    let submit: (() -> Void)?
    let submitNote: String?

    /// Optional, like `FormGuard`: a view drawn outside the main window has no box to lend to.
    @Environment(ToolbarSearch.self) private var box: ToolbarSearch?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        // Read here, in the body the binding was just made for, where its value is current.
        let current = text.wrappedValue
        content
            .onAppear {
                box?.attach(.init(id: id, prompt: prompt, help: help, text: text, matches: matches,
                                  submit: submit, submitNote: submitNote), pageText: current)
            }
            .onChange(of: current) { _, now in box?.pageChanged(id, to: now, text: text) }
            .onChange(of: matches) { _, now in box?.update(id, matches: now) }
            .onDisappear { box?.detach(id) }
    }
}

/// An empty `@Observable` box for a page whose filter used to be view-local `@State`. A `Binding`
/// into it is read by the window bar, and an observed property is what makes that read update.
@Observable
final class PageSearchText {
    var value = ""
    /// Bumped by the box's Return on a page whose box submits (Docker Hub). The page watches it, so
    /// the submit closure the box keeps holds this object weakly instead of the page's view.
    var submissions = 0
}

/// Gives the page the initial text cursor without restricting later accessibility or Tab focus.
/// Lives in the main window's background so it observes that window, never a sheet or another app.
struct InitialPageFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResetView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ResetView: NSView {
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window, !scheduled else { return }
            if window.isKeyWindow {
                resetOnce()
            } else {
                NotificationCenter.default.addObserver(self, selector: #selector(resetOnce),
                                                      name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }

        @objc private func resetOnce() {
            guard let window, !scheduled else { return }
            scheduled = true
            NotificationCenter.default.removeObserver(self)
            // AppKit can restore the search field as first responder while opening the window.
            // Clear it on the next turn once, then leave all subsequent focus alone.
            DispatchQueue.main.async { [weak window] in
                window?.makeFirstResponder(nil)
            }
        }
    }
}

// MARK: - The field

/// The field itself, centred in `WindowBar`. A light glass capsule like the bar's button cluster
/// (`BarGlass`), with the magnifying glass, a placeholder that names the page and a ⌘K hint.
struct ToolbarSearchField: View {
    let model: AppModel
    @FocusState private var focused: Bool
    /// Increase Contrast: the ink at full strength, as `BarGlass` does.
    @Environment(\.colorSchemeContrast) private var contrastSetting

    private var box: ToolbarSearch { model.toolbarSearch }
    private var ink: Color { contrastSetting == .increased ? Theme.barFullInk : Theme.barSoftInk }

    var body: some View {
        @Bindable var search = model.toolbarSearch
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            TextField("Search", text: $search.text, prompt: Text(box.prompt).foregroundStyle(ink.opacity(0.75)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.barFullInk)
                .focused($focused)
                .accessibilityLabel(Text(box.prompt))
                .accessibilityAddTraits(.isSearchField)
                .accessibilityHint(Text("Filters this page as you type, and lists commands and places. Type / or > for commands, or type: for scopes (for example volume:)."))
            if box.text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            } else {
                Button { box.text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ink)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassEffect(.regular.tint(.white.opacity(0.2)), in: .capsule)
        .environment(\.colorScheme, .light)
        .help((box.scope?.help.map { $0 + " " } ?? "")
              + "⌘K or ⌘F to search. Type / or > for commands; type: for scopes, such as volume:.")
        .anchorPreference(key: ToolbarSearchAnchor.self, value: .bounds) { $0 }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { box.fieldFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in box.fieldFrame = frame }
        })
        .onChange(of: focused) { _, now in
            guard box.focusChanged(now, entries: model.paletteItems()) else {
                focused = false
                (NSApp.keyWindow ?? NSApp.mainWindow)?.makeFirstResponder(nil)
                return
            }
        }
        .onChange(of: box.text) { _, _ in box.refresh(model.paletteItems()) }
        .onChange(of: box.focusRequested, initial: true) { _, requested in
            guard requested else { return }
            box.focusRequested = false
            focused = true
            // On the next turn, once the field editor exists, so ⌘K replaces what is there.
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .onChange(of: box.releaseRequested) { _, requested in
            guard requested else { return }
            box.releaseRequested = false
            focused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: box.highlighted) { _, index in announce(index) }
        .onAppear {
            box.open = { [weak search = model.toolbarSearch, formGuard = model.formGuard] item in
                search?.pick(item, formGuard: formGuard)
            }
        }
        .onDisappear { box.focusChanged(false, entries: []) }
    }

    /// VoiceOver reads the highlighted entry as the arrows move, since focus stays in the field.
    private func announce(_ index: Int?) {
        let results = box.results
        guard let index, results.all.indices.contains(index),
              box.entries.indices.contains(results.all[index]) else { return }
        let item = box.entries[results.all[index]]
        let words = [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", ")
        AccessibilityNotification.Announcement("\(words), \(index + 1) of \(results.all.count)").post()
    }
}

/// Where the field is, for the dropdown that `MainWindowView` draws over the whole window.
struct ToolbarSearchAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: - The dropdown

/// The list under the box: a line saying what the page is doing, then **Commands** and **Go to**.
///
/// Drawn by `MainWindowView` over everything, below the field, rather than inside `WindowBar`, so it
/// can hang over the page without the bar's 52pt clipping it. It never takes focus: the arrows and
/// Return reach it through the field (`ToolbarSearch.handle`), and a click on a row picks it.
struct ToolbarSearchDropdown: View {
    let model: AppModel
    /// The rows' own height, measured, so a short list gets a short dropdown and a long one scrolls
    /// at 360. Not a row count times a guessed row height, and not `fixedSize` (see `CLAUDE.md`).
    @State private var contentHeight: CGFloat = 0
    @State private var showingTips = false

    private var box: ToolbarSearch { model.toolbarSearch }

    var body: some View {
        let results = box.results
        let active = box.activeIndex(in: results)
        VStack(alignment: .leading, spacing: 0) {
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .accessibilityAddTraits(.isHeader)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack, not lazy: results are capped, and a lazy stack's content
                    // closure did not re-run as the query changed in the palette, leaving stale rows.
                    VStack(alignment: .leading, spacing: 2) {
                        if results.isEmpty {
                            Text(box.input.query.isEmpty ? "Type to search commands." : "Nothing matches “\(box.input.query)”.")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        group("Scopes", items: shown(results.completions), offset: 0, active: active)
                        group("Commands", items: shown(results.commands), offset: results.completions.count, active: active)
                        group("Go to", items: shown(results.places), offset: results.completions.count + results.commands.count, active: active)
                    }
                    .padding(6)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in contentHeight = height }
                    })
                }
                .onChange(of: active) { _, now in
                    if let now, results.all.indices.contains(now) { proxy.scrollTo(results.all[now]) }
                }
            }
            .frame(height: min(max(contentHeight, 1), 360))
            Divider()
            Button("Search tips", systemImage: "questionmark.circle") { showingTips.toggle() }
                .buttonStyle(.plain)
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 5)
                .popover(isPresented: $showingTips) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search tips").font(.headline)
                        Text("Plain text filters this page and finds places. Use / or > for commands. Use type: for a kind across all Macs; Tab completes a scope or runs a slash command.")
                        Text(SearchBox.Scope.allCases.map { $0.rawValue + ":" }.joined(separator: " · "))
                        Text("For example: volume: data, suggestion: database, /run-container")
                    }
                    .font(.callout).padding().frame(width: 340)
                }
            Text("↑↓ · Return opens · Esc closes · / commands · type: scopes")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { box.dropdownFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in box.dropdownFrame = frame }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results, a list of \(results.all.count) entries")
    }

    /// The top line: whether the page is being filtered, and by how much.
    private var status: String {
        if let scope = box.input.scope { return "Searching \(scope.plural) on all Macs" }
        if box.text.isEmpty { return "Type / for commands or type: for scopes, such as volume:" }
        if box.input.commandsOnly { return "Commands only — this page is not filtered" }
        guard let scope = box.scope else { return "Nothing to filter on this page" }
        if let note = scope.submitNote { return note }
        if let matches = scope.matches { return "\(matches) on this page" }
        return "Filtering \(model.currentSection?.title ?? "this page")"
    }

    /// The entries behind `indexes`, resolved once while drawing. The entries are emptied when the box
    /// loses focus, and SwiftUI can draw this dropdown once more with indexes from before — quitting
    /// with it open did, every time — so an index that no longer resolves is skipped, never subscripted.
    private func shown(_ indexes: [Int]) -> [(index: Int, item: PaletteItem)] {
        let entries = box.entries
        return indexes.compactMap { entries.indices.contains($0) ? ($0, entries[$0]) : nil }
    }

    @ViewBuilder
    private func group(_ title: String, items: [(index: Int, item: PaletteItem)], offset: Int, active: Int?) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.element.index) { position, entry in
                let item = entry.item
                row(item, isSelected: active == offset + position)
                    .id(entry.index)
                    .onTapGesture { box.open?(item) }
                    .accessibilityAction { box.open?(item) }
            }
        }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            if let entry = item.libraryEntry {
                SuggestionLogo(data: entry.icon.flatMap { model.libraryUpdater.icons[$0.sha256] },
                               category: entry.categories.first)
                    .scaleEffect(0.5).frame(width: 22, height: 22)
            } else {
                Image(systemName: item.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 8)
            if let slug = item.slugs.first {
                Text(slug).font(.caption2.monospaced())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            } else if item.kind == .section {
                Text("Section").font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(isSelected ? Color.white : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
