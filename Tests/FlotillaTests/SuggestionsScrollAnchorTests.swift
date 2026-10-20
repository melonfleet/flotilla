import Foundation
import Testing
@testable import Flotilla

/// Kyle, 20 October, round 2: the Suggestions list is rebuilt after a form, so the state the window
/// owns keeps where it was — the first row at least half in view — for the list to restore.
@Suite @MainActor struct SuggestionsScrollAnchorTests {
    @Test func theAnchorIsTheFirstRowAtLeastHalfInView() {
        let ui = SuggestionsUIState()
        #expect(ui.scrollAnchor == nil)
        ui.rowMoved("redis", middle: -19)      // mostly scrolled off the top
        ui.rowMoved("postgres", middle: 19)
        ui.rowMoved("nginx", middle: 57)
        #expect(ui.scrollAnchor == "postgres")
        ui.rowMoved("postgres", middle: -19)   // scrolled on by a row
        ui.rowMoved("nginx", middle: 19)
        #expect(ui.scrollAnchor == "nginx")
    }

    @Test func tearingTheListDownForAFormKeepsThePlace() {
        let ui = SuggestionsUIState()
        ui.rowMoved("postgres", middle: 19)
        ui.rowMoved("nginx", middle: 57)
        ui.selection = ["nginx", "redis"]      // several selected: the anchor is not the selection
        for id in ["postgres", "nginx"] { ui.rowGone(id) }
        #expect(ui.scrollAnchor == "postgres")
        // The rebuilt list's rows report again once it is restored.
        ui.rowMoved("postgres", middle: 19)
        #expect(ui.scrollAnchor == "postgres")
    }
}
