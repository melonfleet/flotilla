import Foundation
import Testing
@testable import FlotillaCore

@Suite struct PageTabOrderTests {
    @Test func theOrderIsOverviewDataInspectThenTheWaysIn() {
        #expect(PageTabKind.allCases == [.overview, .view, .settings, .history, .inspect,
                                         .session, .files, .screen])
        #expect(PageTabKind.allCases.filter { $0.group == .data } == [.overview, .view, .settings, .history, .inspect])
        #expect(PageTabKind.allCases.filter { $0.group == .access } == [.session, .files, .screen])
    }

    /// Each page as it is now listed, which must already be canonical.
    @Test func everyPageShapeIsCanonical() {
        let container: [PageTabKind] = [.overview, .view, .history, .inspect, .session, .files]
        let remoteContainer: [PageTabKind] = [.overview, .view, .history, .inspect]
        let machine: [PageTabKind] = [.overview, .settings, .history, .inspect, .session]
        let host: [PageTabKind] = [.overview, .view, .view, .view, .settings, .history, .session, .files, .screen]
        let simple: [PageTabKind] = [.overview, .inspect]
        for page in [container, remoteContainer, machine, host, simple] {
            #expect(PageTabOrder.isCanonical(page))
        }
    }

    @Test func outOfOrderIsCaught() {
        // The order before 18 October: Terminal second on containers, Screen Sharing before Files.
        #expect(!PageTabOrder.isCanonical([.overview, .session, .history, .inspect, .view, .files]))
        #expect(!PageTabOrder.isCanonical([.overview, .session, .screen, .files]))
        #expect(!PageTabOrder.isCanonical([.inspect, .overview]))
    }

    @Test func arrangingIsStableWithinAKind() {
        let given: [(String, PageTabKind)] = [("Terminal", .session), ("Updates", .view), ("Overview", .overview),
                                              ("Inspect", .inspect), ("System", .view), ("Files", .files),
                                              ("Flotilla", .view), ("Logs", .history)]
        let arranged = PageTabOrder.arranged(given) { $0.1 }.map(\.0)
        #expect(arranged == ["Overview", "Updates", "System", "Flotilla", "Logs", "Inspect", "Terminal", "Files"])
    }

    @Test func oneDividerWhereTheWaysInBegin() {
        #expect(PageTabOrder.dividers([.overview, .view, .history, .inspect, .session, .files])
                == [false, false, false, false, true, false])
        // No ways in, no divider; only ways in, none either.
        #expect(PageTabOrder.dividers([.overview, .inspect]) == [false, false])
        #expect(PageTabOrder.dividers([.session, .files]) == [false, false])
        #expect(PageTabOrder.dividers([]) == [])
    }
}
