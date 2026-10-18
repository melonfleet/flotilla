import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SearchBoxTests {
    private let candidates: [SearchBox.Candidate] = [
        .init(title: "Run Container…", isCommand: true),
        .init(title: "New Group…", isCommand: true),
        .init(title: "Pull Image…", isCommand: true),
        .init(title: "Containers", isCommand: false, isSection: true),
        .init(title: "Images", isCommand: false, isSection: true),
        .init(title: "web", subtitle: "Container · running · nginx:latest", isCommand: false),
        .init(title: "redis:8", subtitle: "Image", isCommand: false),
    ]

    @Test func plainTextFiltersThePage() {
        let input = SearchBox.read("web ")
        #expect(!input.commandsOnly)
        #expect(input.pageFilter == "web ")
        #expect(input.query == "web")
    }

    /// `>` is commands only, and the page is left alone. `>run` must not empty the Containers list.
    @Test func aLeadingChevronIsCommandsOnlyAndDoesNotFilterThePage() {
        let input = SearchBox.read(">  run")
        #expect(input.commandsOnly)
        #expect(input.pageFilter == nil)
        #expect(input.query == "run")

        let results = SearchBox.results(for: ">", among: candidates)
        #expect(results.commands == [0, 1, 2])
        #expect(results.places.isEmpty)
        #expect(SearchBox.results(for: ">image", among: candidates) == .init(commands: [2]))
    }

    @Test func nothingTypedListsNothing() {
        #expect(SearchBox.results(for: "", among: candidates).isEmpty)
        #expect(SearchBox.results(for: "   ", among: candidates).isEmpty)
    }

    @Test func commandsAndPlacesAreGroupedInThatOrder() {
        let results = SearchBox.results(for: "con", among: candidates)
        #expect(results.commands == [0])
        // "Containers" starts with it, so it comes before "web", whose subtitle only contains it.
        #expect(results.places == [3, 5])
        #expect(results.all == [0, 3, 5])
    }

    @Test func everyWordMustMatchTitleOrSubtitle() {
        #expect(SearchBox.results(for: "web nginx", among: candidates).places == [5])
        #expect(SearchBox.results(for: "web postgres", among: candidates).isEmpty)
    }

    /// The palette's ranking: a title that starts with the text first, otherwise the order given.
    @Test func aTitlePrefixRanksFirstAndTheRestKeepTheirOrder() {
        let list: [SearchBox.Candidate] = [
            .init(title: "the image", isCommand: false),
            .init(title: "an image", isCommand: false),
            .init(title: "Images", isCommand: false),
        ]
        #expect(SearchBox.results(for: "image", among: list).places == [2, 0, 1])
    }

    @Test func limitsApplyPerGroup() {
        let many = (0..<50).map { SearchBox.Candidate(title: "web-\($0)", isCommand: false) }
            + [.init(title: "Web Command", isCommand: true)]
        let results = SearchBox.results(for: "web", among: many, commandLimit: 8, placeLimit: 40)
        #expect(results.commands == [50])
        #expect(results.places.count == 40)
    }

    @Test func arrowsWrapAndStartFromNothing() {
        #expect(SearchBox.move(nil, by: 1, count: 3) == 0)
        #expect(SearchBox.move(nil, by: -1, count: 3) == 2)
        #expect(SearchBox.move(2, by: 1, count: 3) == 0)
        #expect(SearchBox.move(0, by: -1, count: 3) == 2)
        #expect(SearchBox.move(5, by: 1, count: 3) == 0)
        #expect(SearchBox.move(0, by: 1, count: 0) == nil)
    }

    /// Escape closes the dropdown, then clears the text, then gives focus back.
    @Test func escapeClosesThenClearsThenLeaves() {
        #expect(SearchBox.escape(dropdownOpen: true, text: "web") == .closeDropdown)
        #expect(SearchBox.escape(dropdownOpen: false, text: "web") == .clearText)
        #expect(SearchBox.escape(dropdownOpen: false, text: "") == .leaveBox)
    }

    // MARK: State

    /// Focus can arrive from a shortcut, Tab, VoiceOver, or another accessibility client.
    private func focusedBox(pageText: String? = "") -> SearchBox.State {
        var state = SearchBox.State()
        if let pageText { state.attach(pageText: pageText) }
        let r1 = state.focusChanged(true)
        #expect(r1)
        return state
    }

    /// The stage 1 bug: on Containers, typing filtered the page and the dropdown never opened.
    /// The box must see its own keystrokes on a page that lends it a filter, not only on one that doesn't.
    @Test func typingOnAPageWithAListOpensTheDropdownAndWritesThePageFilter() {
        var state = focusedBox()
        #expect(!state.dropdownShown)
        let r2 = state.type("shop")
        #expect(r2 == "shop")
        #expect(state.text == "shop")
        #expect(state.dropdownShown)
        let r3 = state.type("shop-")
        #expect(r3 == "shop-")
        #expect(state.dropdownShown)
    }

    @Test func typingOnAPageWithNothingToFilterOpensTheDropdownAndWritesNothing() {
        var state = focusedBox(pageText: nil)
        let r4 = state.type("con")
        #expect(r4 == nil)
        #expect(state.dropdownShown)
    }

    /// The box writes the page's filter, and the page's echo of that write changes nothing.
    @Test func thePagesEchoOfTheBoxsOwnWriteIsANoOp() {
        var state = focusedBox()
        state.type("shop")
        state.highlighted = 1
        state.pageChanged("shop")
        #expect(state.text == "shop")
        #expect(state.highlighted == 1)
    }

    /// A page clearing its own filter (Clear Filters) clears the box too.
    @Test func thePageChangingItsFilterChangesTheBox() {
        var state = focusedBox()
        state.type("shop")
        state.pageChanged("")
        #expect(state.text.isEmpty)
        #expect(!state.dropdownShown)
    }

    /// Coming back to a section shows the filter it kept, and leaving it empties the box.
    @Test func attachShowsThePagesFilterAndDetachEmptiesTheBox() {
        var state = SearchBox.State()
        state.attach(pageText: "web")
        #expect(state.text == "web")
        state.detach()
        #expect(state.text.isEmpty)
        #expect(!state.hasPage)
        let r5 = state.type("x")
        #expect(r5 == nil)
    }

    /// `>` leaves the page unfiltered, and the page's resulting empty filter does not wipe the `>`.
    @Test func commandsModeClearsThePageFilterAndKeepsTheBoxText() {
        var state = focusedBox()
        state.type("web")
        let r6 = state.type(">run")
        #expect(r6 == "")
        state.pageChanged("")
        #expect(state.text == ">run")
        #expect(state.dropdownShown)
        // Unchanged page filter, nothing to write.
        let r7 = state.type(">ru")
        #expect(r7 == nil)
    }

    @Test func escapeClosesTheDropdownAndTypingOpensItAgain() {
        var state = focusedBox()
        state.type("shop")
        state.dropdownClosed = true
        #expect(!state.dropdownShown)
        state.type("shop-")
        #expect(state.dropdownShown)
    }

    @Test func losingFocusHidesTheDropdownAndKeepsTheText() {
        var state = focusedBox()
        state.type("shop")
        let r8 = state.focusChanged(false)
        #expect(r8)
        #expect(!state.dropdownShown)
        #expect(state.text == "shop")
    }

    /// VoiceOver may focus the box without an app-local click, key, or explicit search request.
    @Test func accessibilityFocusNeedsNoPriorInteraction() {
        var state = SearchBox.State()
        let firstFocus = state.focusChanged(true)
        #expect(firstFocus)
        #expect(state.isFocused)
        let blur = state.focusChanged(false)
        #expect(blur)
        #expect(!state.isFocused)
        let laterFocus = state.focusChanged(true)
        #expect(laterFocus)
        #expect(state.isFocused)
    }

    /// The entries hold closures that reach the model which owns the box, so they must not outlive
    /// focus: kept, they are a retain cycle (Kyle, stage 1 round 3).
    @Test func blurEmptiesTheEntriesAndNothingRefillsThem() {
        final class Owner {}
        weak var released: Owner?
        var list = SearchBox.Entries<() -> Void>()
        do {
            let owner = Owner()
            released = owner
            list.focusChanged(true) { [{ _ = owner }] }
            #expect(list.items.count == 1)
            list.refresh { [{ _ = owner }, { _ = owner }] }
            #expect(list.items.count == 2)
        }
        #expect(released != nil)
        list.focusChanged(false) { [{}] }
        #expect(list.items.isEmpty)
        #expect(released == nil)
        list.refresh { [{}] }
        #expect(list.items.isEmpty)
    }

    /// ⌘K lists every command and every section before a key is pressed (Kamal, 17 October); with no
    /// ⌘K, an empty box lists nothing, so a click or ⌘F to filter a page doesn't open a list.
    @Test func browsingListsCommandsAndSectionsBeforeTyping() {
        let browsing = SearchBox.results(for: "", among: candidates, browsing: true)
        #expect(browsing.commands == [0, 1, 2])
        #expect(browsing.places == [3, 4])
        #expect(SearchBox.results(for: "", among: candidates).isEmpty)
    }

    @Test func browseShowsTheDropdownWhileFocusedAndEndsOnBlur() {
        var state = SearchBox.State()
        state.browse()
        #expect(!state.dropdownShown)          // not until the box has focus
        _ = state.focusChanged(true)
        #expect(state.dropdownShown)
        _ = state.focusChanged(false)
        _ = state.focusChanged(true)
        #expect(!state.dropdownShown)          // a later click or ⌘F is not ⌘K
    }
}

@Suite struct SearchScopeTests {
    @Test func parsesEveryScopeAndAlias() {
        for scope in SearchBox.Scope.allCases {
            for alias in scope.aliases {
                let input = SearchBox.read("  \(alias.uppercased()):  data ")
                #expect(input.scope == scope)
                #expect(input.query == "data")
                #expect(input.pageFilter == nil)
                #expect(!input.commandsOnly)
            }
        }
    }

    @Test func unknownPrefixesAndEmbeddedPrefixesStayPlainText() {
        for text in ["unknown: web", "nginx:latest", "find volume: data"] {
            let input = SearchBox.read(text)
            #expect(input.scope == nil)
            #expect(input.pageFilter == text)
            #expect(input.query == text)
        }
    }

    @Test func slashAndChevronParseBeforeScopes() {
        for marker in ["/", ">"] {
            for suffix in ["", "run", " volume: data"] {
                let input = SearchBox.read(" \(marker)\(suffix)")
                #expect(input.commandsOnly)
                #expect(input.slashMode == (marker == "/"))
                #expect(input.scope == nil)
                #expect(input.pageFilter == nil)
                #expect(input.query == suffix.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @Test func slugsComeFromTitlesWithStableAliases() {
        let examples: [(String, [String])] = [
            ("Run Container…", ["/run-container"]), ("New Group…", ["/new-group"]),
            ("Pull Image…", ["/pull-image"]),
            ("Build Image from Dockerfile…", ["/build-image", "/build-image-from-dockerfile"]),
            ("New Volume…", ["/create-volume", "/new-volume"]),
            ("New Network…", ["/create-network", "/new-network"]),
            ("New Machine…", ["/new-machine"]), ("New Cluster…", ["/new-cluster"]),
            ("Add Registry…", ["/add-registry"]), ("New DNS Domain…", ["/new-dns-domain"]),
            ("Add Host…", ["/add-host"]),
            ("Import Configuration…", ["/import", "/import-configuration"]),
            ("Export Configuration…", ["/export", "/export-configuration"]),
            ("Settings", ["/settings"]), ("Greta", ["/greta"]),
            ("A Future Action!", ["/a-future-action"])
        ]
        for (title, slugs) in examples { #expect(SearchBox.commandSlugs(for: title) == slugs) }
    }

    @Test func scopeFiltersKindsAcrossHostsWithoutCommandsOrSections() {
        for scope in SearchBox.Scope.allCases {
            let list: [SearchBox.Candidate] = [
                .init(title: "data", isCommand: false, scope: scope),
                .init(title: "data", subtitle: "on Mini", isCommand: false, scope: scope),
                .init(title: "other", isCommand: false, scope: scope),
                .init(title: "data", isCommand: false),
                .init(title: "data", isCommand: true, scope: scope),
                .init(title: "data", isCommand: false, isSection: true, scope: scope)
            ]
            #expect(SearchBox.results(for: "\(scope.rawValue):data", among: list).all == [0, 1])
            #expect(SearchBox.results(for: "\(scope.rawValue):", among: list).all == [0, 1, 2])
        }
    }

    @Test func slashMatchesSlugComponentsAndAliases() {
        let list = ["Run Container…", "New Volume…", "Settings"].map {
            SearchBox.Candidate(title: $0, isCommand: true, slugs: SearchBox.commandSlugs(for: $0))
        } + [.init(title: "run-container", isCommand: false)]
        #expect(SearchBox.results(for: "/", among: list).commands == [0, 1, 2])
        #expect(SearchBox.results(for: "/run", among: list).all == [0])
        #expect(SearchBox.results(for: "/r-c", among: list).all == [0])
        #expect(SearchBox.results(for: "/create-vol", among: list).all == [1])
        #expect(SearchBox.results(for: "/new-vol", among: list).all == [1])
        #expect(SearchBox.results(for: ">volume", among: list).all == [1])
    }

    @Test func scopeNamesCompleteOnlyWhileTypingALeadingWord() {
        #expect(SearchBox.scopeCompletions(for: "vo") == [.volume])
        #expect(SearchBox.scopeCompletions(for: "IMG") == [.image])
        #expect(SearchBox.scopeCompletions(for: "volume:").isEmpty)
        #expect(SearchBox.scopeCompletions(for: "some vo").isEmpty)
        #expect(SearchBox.scopeCompletions(for: "/vo").isEmpty)
        let list: [SearchBox.Candidate] = [
            .init(title: "volume:", isCommand: false, completion: .volume),
            .init(title: "vo", isCommand: false, scope: .container),
            .init(title: "New Volume…", isCommand: true)
        ]
        #expect(SearchBox.results(for: "vo", among: list).completions == [0])
        #expect(SearchBox.results(for: "vo", among: list).all == [0, 2, 1])
        #expect(SearchBox.results(for: "volume:", among: list).isEmpty)
    }

    @Test func suggestionsUseLibraryMatchingBeyondTheirSubtitle() {
        let entry = LibraryEntry(id: "demo", title: "Example", summary: "A searchable summary",
                                 categories: ["Databases"], kind: .container,
                                 licenceNote: "Special licence")
        let list: [SearchBox.Candidate] = [
            .init(title: entry.title, isCommand: false, scope: .suggestion, libraryEntry: entry)
        ]
        for query in ["database", "summary", "license", "special"] {
            #expect(SearchBox.results(for: "suggestion:\(query)", among: list).places == [0])
        }
        #expect(SearchBox.results(for: "suggestion:missing", among: list).isEmpty)
    }

    @Test func scopedAndSlashModesLeavePageUnfilteredAndKeepTheirTextOnEcho() {
        for text in ["vol:data", "/run"] {
            var state = SearchBox.State()
            state.attach(pageText: "web")
            #expect(state.type(text) == "")
            state.pageChanged("")
            #expect(state.text == text)
            #expect(state.type(text + "x") == nil)
            #expect(state.type("plain") == "plain")
        }
    }
}
