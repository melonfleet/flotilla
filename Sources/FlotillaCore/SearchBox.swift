import Foundation

/// The rules behind the one search box in the window bar (DECISIONS Q55): what a line of text in it
/// means, which commands and places it offers, and what Escape does next.
///
/// The box does two jobs at once. Its text filters the list on the current page through that page's
/// own `SearchQuery` matching, and the same text picks commands and places in the dropdown under it,
/// as the ⌘K palette did. A leading `>` means commands only, as in VS Code, and then the page is not
/// filtered at all. That is so `>run` cannot leave Containers showing nothing.
///
/// Foundation-only and free of the app's types, so the rules are tested here rather than by eye.
public enum SearchBox {
    /// A line of box text, read.
    public struct Input: Sendable, Equatable {
        /// True after a leading `>`: commands only, and the page left unfiltered.
        public var commandsOnly: Bool
        /// What to match the dropdown against: the text without the `>`, trimmed.
        public var query: String

        /// The page's filter text: everything typed, or nothing at all in commands mode.
        public var pageFilter: String?

        public var words: [String] { SearchQuery.tokens(query) }
    }

    public static func read(_ text: String) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return Input(commandsOnly: true, query: rest, pageFilter: nil)
        }
        return Input(commandsOnly: false, query: trimmed, pageFilter: text)
    }

    /// One thing the dropdown could offer, reduced to what matching needs.
    public struct Candidate: Sendable, Equatable {
        public var title: String
        public var subtitle: String?
        /// A command (Run Container…) rather than a place (a section, or a container by name).
        public var isCommand: Bool

        public init(title: String, subtitle: String? = nil, isCommand: Bool) {
            self.title = title; self.subtitle = subtitle; self.isCommand = isCommand
        }
    }

    /// Indexes into the candidates, in the order the dropdown shows them: commands, then places.
    public struct Results: Sendable, Equatable {
        public var commands: [Int]
        public var places: [Int]

        public init(commands: [Int] = [], places: [Int] = []) {
            self.commands = commands; self.places = places
        }

        /// Both groups as one list, which is what ↑↓ walk.
        public var all: [Int] { commands + places }
        public var isEmpty: Bool { commands.isEmpty && places.isEmpty }
    }

    /// What the dropdown lists for `text`.
    ///
    /// The palette's matching, unchanged: every word must appear in the title or the subtitle, and a
    /// title that starts with what was typed comes first, the rest staying in the order given. With
    /// nothing typed, nothing is listed, except after a `>`, which lists every command.
    public static func results(for text: String, among candidates: [Candidate],
                               commandLimit: Int = 8, placeLimit: Int = 40) -> Results {
        let input = read(text)
        let words = input.words
        if words.isEmpty && !input.commandsOnly { return Results() }

        let matching = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard !input.commandsOnly || candidate.isCommand else { return false }
            return words.allSatisfy {
                SearchQuery.contains(candidate.title, $0) || SearchQuery.contains(candidate.subtitle ?? "", $0)
            }
        }
        // Sorted on (rank, original position), because `sorted` is not stable and the order given
        // is the palette's own: the most likely command first.
        let ranked = matching.sorted {
            (rank(candidates[$0], input.query), $0) < (rank(candidates[$1], input.query), $1)
        }
        return Results(commands: Array(ranked.filter { candidates[$0].isCommand }.prefix(commandLimit)),
                       places: Array(ranked.filter { !candidates[$0].isCommand }.prefix(placeLimit)))
    }

    private static func rank(_ candidate: Candidate, _ query: String) -> Int {
        guard !query.isEmpty else { return 1 }
        return candidate.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil ? 0 : 1
    }

    /// The highlight after ↑ (`-1`) or ↓ (`+1`), wrapping at both ends. From no highlight, ↓ goes to
    /// the first entry and ↑ to the last.
    public static func move(_ current: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return step < 0 ? count - 1 : 0 }
        return (current + step % count + count) % count
    }

    /// What the box holds between keystrokes: its text, where that text goes, and whether the dropdown
    /// is showing. A value, so every transition is tested here rather than found by using the app.
    ///
    /// **The text is stored here, never read back from the page.** The page's filter arrives as a
    /// SwiftUI `Binding`, and a `Binding` read during a view update returns the value it was created
    /// with, without registering any dependency. The first version of the box read the page's binding
    /// for its own text, so on every page with a list the field's view never saw a keystroke: the
    /// dropdown never opened and the ⌘K hint never went away, while typing still filtered the page,
    /// because writes through a binding do work. The page's binding is now written to, and its
    /// changes are pushed in with `pageChanged(_:)`.
    public struct State: Sendable, Equatable {
        /// What the field shows.
        public private(set) var text = ""
        /// True while a page with a list lends the box its filter.
        public private(set) var hasPage = false
        public private(set) var isFocused = false
        /// Escape closed the dropdown; it opens again when the text changes or ↓ is pressed.
        public var dropdownClosed = false
        /// The highlighted entry, as an index into `Results.all`; nil until an arrow is pressed.
        public var highlighted: Int?
        public init() {}

        public var input: Input { SearchBox.read(text) }
        /// What the page should be filtering: the text, or nothing after a `>`.
        public var pageFilter: String { input.pageFilter ?? "" }
        public var dropdownShown: Bool { isFocused && !text.isEmpty && !dropdownClosed }

        /// The user typed. Returns the page's new filter when it changed, for the caller to write
        /// through, and nil when the page should be left alone.
        @discardableResult
        public mutating func type(_ new: String) -> String? {
            let before = pageFilter
            text = new
            highlighted = nil
            dropdownClosed = false
            return hasPage && pageFilter != before ? pageFilter : nil
        }

        /// A page with a list came on screen: the box shows that page's own filter.
        public mutating func attach(pageText: String) {
            hasPage = true
            text = pageText
            highlighted = nil
        }

        /// The page's filter changed from outside the box (a Clear Filters button, or the box's own
        /// write coming back). Its own echo, and the empty filter of `>` mode, change nothing.
        public mutating func pageChanged(_ value: String) {
            guard hasPage, value != pageFilter else { return }
            text = value
            highlighted = nil
        }

        /// The page went away. A form or a detail has nothing to filter, so the box starts empty.
        public mutating func detach() {
            hasPage = false
            text = ""
            highlighted = nil
        }

        /// Accept focus from any source, including accessibility, without requiring a click or key.
        /// The app gives the page initial focus once, when its window first becomes key.
        public mutating func focusChanged(_ focused: Bool) -> Bool {
            isFocused = focused
            dropdownClosed = false
            highlighted = nil
            return true
        }
    }

    /// What the dropdown can reach, held **only while the box has focus**.
    ///
    /// In the app an entry is a `PaletteItem` whose `run` closure reaches the `AppModel`, and the
    /// model owns the box, so entries that outlive focus are a retain cycle — the model kept alive
    /// for as long as the last list built for it. The first version filled the list on focus and
    /// never emptied it. This type cannot be filled while unfocused, and empties on blur.
    public struct Entries<Entry> {
        public private(set) var items: [Entry] = []
        public private(set) var isLive = false

        public init() {}

        /// Loads the list as focus arrives; drops it, and everything it captures, as focus leaves.
        public mutating func focusChanged(_ focused: Bool, load: () -> [Entry]) {
            isLive = focused
            items = focused ? load() : []
        }

        /// Rebuilds the list as the text changes. Ignored while unfocused, so a late change cannot
        /// refill a list that blur has emptied.
        public mutating func refresh(_ load: () -> [Entry]) {
            guard isLive else { return }
            items = load()
        }
    }

    /// What one press of Escape in the box does.
    public enum Escape: Sendable, Equatable {
        /// Close the dropdown, keeping the text and the page's filter.
        case closeDropdown
        /// The second press: clear the text, and with it the page's filter.
        case clearText
        /// Nothing left to close or clear: give focus back to the page.
        case leaveBox
    }

    public static func escape(dropdownOpen: Bool, text: String) -> Escape {
        if dropdownOpen { return .closeDropdown }
        return text.isEmpty ? .leaveBox : .clearText
    }
}
