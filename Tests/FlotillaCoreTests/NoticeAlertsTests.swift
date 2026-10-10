import Foundation
import Testing
@testable import FlotillaCore

@Suite struct NoticeAlertsTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let all: (NotificationCategory) -> Bool = { _ in true }

    func offline(_ name: String) -> NoticeBook.Condition {
        .init(key: "host-unreachable:\(name)", level: .warning, text: "\(name) isn't answering: Couldn't reach it",
              host: name, section: "hosts", dismissible: true)
    }

    @Test func aHostIsAnnouncedOnlyAfterTwoMinutes() {
        var book = NoticeBook()
        book.reconcile([offline("a")], at: t0)
        #expect(NoticeAlerts.due(book, at: t0 + 60, enabled: all).isEmpty)
        #expect(NoticeAlerts.due(book, at: t0 + NoticeAlerts.offlineGrace, enabled: all).count == 1)
    }

    @Test func otherNoticesAreAnnouncedAtOnceAndOnlyOnce() {
        var book = NoticeBook()
        book.reconcile([.init(key: "update-failed:a", level: .error, text: "a couldn't update", section: "hosts",
                              dismissible: false)], at: t0)
        let due = NoticeAlerts.due(book, at: t0, enabled: all)
        #expect(due.count == 1)
        book.markAnnounced(Set(due.map(\.id)), at: t0)
        #expect(NoticeAlerts.due(book, at: t0 + 5, enabled: all).isEmpty)
    }

    @Test func versionDifferencesAndDismissedNoticesStayInFlotilla() {
        var book = NoticeBook()
        book.reconcile([.init(key: "flotilla-skew:a", level: .warning, text: "a runs an older Flotilla", section: "hosts",
                              dismissible: true),
                        .init(key: "approval-waiting", level: .warning, text: "1 Mac is waiting", section: "hosts",
                              dismissible: true)], at: t0)
        book.dismiss([book.notices[1].id], at: t0)
        #expect(NoticeAlerts.due(book, at: t0, enabled: all).isEmpty)
    }

    @Test func aCategoryTurnedOffIsNotAnnounced() {
        var book = NoticeBook()
        book.reconcile([offline("a")], at: t0)
        #expect(NoticeAlerts.due(book, at: t0 + 600, enabled: { $0 != .hostOffline }).isEmpty)
    }

    @Test func moreThanThreeAMinuteGoOutAsOne() {
        var book = NoticeBook()
        book.reconcile((1...6).map { offline("m\($0)") }, at: t0)
        let due = NoticeAlerts.due(book, at: t0 + 120, enabled: all)
        #expect(NoticeAlerts.plan(Array(due.prefix(3)), recent: [], at: t0 + 120).count == 3)
        let plan = NoticeAlerts.plan(due, recent: [], at: t0 + 120)
        #expect(plan.count == 1 && plan[0].notices.count == 6)
        let text = NoticeAlerts.combinedText(due) { $0.host }
        #expect(text.title == "6 Macs stopped answering" && text.body == "m1, m2, m3, m4 and 2 more.")
    }

    @Test func aFullMinuteHoldsTheRestBack() {
        var book = NoticeBook()
        book.reconcile([offline("a"), offline("b")], at: t0)
        let due = NoticeAlerts.due(book, at: t0 + 120, enabled: all)
        let recent = [t0 + 100, t0 + 110, t0 + 115]
        #expect(NoticeAlerts.plan(due, recent: recent, at: t0 + 120).isEmpty)
        // One slot free: both go, together.
        #expect(NoticeAlerts.plan(due, recent: Array(recent.prefix(2)), at: t0 + 120) == [.combined(due)])
        // The minute over: one each.
        #expect(NoticeAlerts.plan(due, recent: recent, at: t0 + 176).count == 2)
    }

    @Test func oldNoticeFilesStillLoad() throws {
        let json = #"{"notices":[{"id":"x@1","key":"x","level":"warning","text":"t","section":"hosts","dismissible":true,"started":0,"lastSeen":0}]}"#
        let book = try JSONDecoder().decode(NoticeBook.self, from: Data(json.utf8))
        #expect(book.notices.first?.announced == nil)
    }
}
