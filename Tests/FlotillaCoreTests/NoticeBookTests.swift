import Foundation
import Testing
@testable import FlotillaCore

@Suite struct NoticeBookTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func host(_ fp: String, _ level: NoticeBook.Level = .warning, dismissible: Bool = true) -> NoticeBook.Condition {
        .init(key: "host-unreachable:\(fp)", level: level, text: "\(fp) isn't answering: Couldn't reach it",
              host: fp, section: "hosts", dismissible: dismissible)
    }

    @Test func aConditionStartsANoticeThatResolvesWhenItGoes() {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        #expect(book.notices.count == 1 && book.attention.count == 1)
        #expect(book.notices[0].title == "a isn't answering" && book.notices[0].detail == "Couldn't reach it")
        let before = book
        book.reconcile([host("a")], at: t0 + 30)
        #expect(book == before)                                 // nothing new: the book is untouched
        book.reconcile([host("a")], at: t0 + 61)
        #expect(book.notices.count == 1 && book.notices[0].lastSeen == t0 + 61)
        book.reconcile([], at: t0 + 90)
        #expect(book.notices[0].resolved == t0 + 90 && book.attention.isEmpty)
    }

    @Test func dismissHidesUntilTheSituationChanges() {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        #expect(book.dismiss([book.notices[0].id], at: t0 + 1) == 1)
        book.reconcile([host("a")], at: t0 + 30)
        #expect(book.attention.isEmpty)                         // still happening, still hidden
        book.reconcile([], at: t0 + 60)                         // answered
        book.reconcile([host("a")], at: t0 + 90)                // stopped again: a new notice
        #expect(book.notices.count == 2 && book.attention.count == 1)
    }

    @Test func errorsCannotBeDismissed() {
        var book = NoticeBook()
        book.reconcile([host("a", .error, dismissible: false)], at: t0)
        #expect(book.dismiss([book.notices[0].id], at: t0) == 0)
        #expect(book.attention.count == 1)
    }

    @Test func errorsComeFirstThenTheNewest() {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        book.reconcile([host("a"), host("b")], at: t0 + 10)
        book.reconcile([host("a"), host("b"), host("c", .error, dismissible: false)], at: t0 + 20)
        #expect(book.attention.map(\.host) == ["c", "b", "a"])
    }

    @Test func goodAndInfoNeverNeedAttention() {
        var book = NoticeBook()
        book.reconcile([.init(key: "x", level: .info, text: "An update is ready", section: "hosts", dismissible: true)], at: t0)
        #expect(book.attention.isEmpty && book.notices.count == 1)
    }

    @Test func historyIsKeptAWeekAndAtMost500() {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        book.reconcile([], at: t0 + 10)
        book.prune(at: t0 + NoticeBook.keepFor + 11)
        #expect(book.notices.isEmpty)
        for n in 0..<520 { book.reconcile([host("h\(n)")], at: t0 + Double(n)); book.reconcile([], at: t0 + Double(n) + 0.5) }
        #expect(book.notices.count == NoticeBook.maxKept)
        // An active, undismissed notice is never pruned however full the book is.
        book.reconcile([host("live")], at: t0 + 1000)
        #expect(book.notices.contains { $0.host == "live" && $0.isActive })
    }

    @Test func aHostStillBeingCheckedKeepsItsNotice() {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        book.reconcile([], at: t0 + 60, unsettled: ["a"])       // relaunched: a not asked yet
        #expect(book.notices[0].isActive && book.attention.count == 1)
        book.reconcile([host("a")], at: t0 + 90)                // still not answering: same notice
        #expect(book.notices.count == 1 && book.notices[0].started == t0)
        book.reconcile([], at: t0 + 120)                        // answered
        #expect(book.notices[0].resolved == t0 + 120)
    }

    @Test func survivesBeingSaved() throws {
        var book = NoticeBook()
        book.reconcile([host("a")], at: t0)
        let data = try JSONEncoder().encode(book)
        #expect(try JSONDecoder().decode(NoticeBook.self, from: data) == book)
    }
}
