import Foundation

/// Which notices go to macOS Notification Centre, and how (Q48, the owner, 10 October).
///
/// A notice is announced once, when it becomes due: active, not dismissed, its category on, and,
/// for a host that stopped answering, two minutes old, so a blip never reaches the screen. At most
/// three alerts go out a minute. When more are due than that allows, they go out together as one,
/// "6 Macs stopped answering", because a switch failing takes forty hosts down at once. When the
/// minute is used up, they wait for it.
public enum NoticeAlerts {
    public static let window: TimeInterval = 60
    public static let perWindow = 3
    /// How long a host must go unanswered before it is announced.
    public static let offlineGrace: TimeInterval = 120

    public enum Alert: Equatable, Sendable {
        case single(NoticeBook.Notice)
        case combined([NoticeBook.Notice])

        public var notices: [NoticeBook.Notice] {
            switch self {
            case .single(let notice): [notice]
            case .combined(let notices): notices
            }
        }
    }

    /// The notices due an announcement now, oldest first.
    public static func due(_ book: NoticeBook, at now: Date,
                           enabled: (NotificationCategory) -> Bool) -> [NoticeBook.Notice] {
        book.notices.filter { notice in
            guard notice.isActive, notice.dismissed == nil, notice.announced == nil,
                  let category = NotificationCategory.forNotice(key: notice.key), enabled(category)
            else { return false }
            let grace = category == .hostOffline ? offlineGrace : 0
            return now.timeIntervalSince(notice.started) >= grace
        }
        .sorted { $0.started < $1.started }
    }

    /// What to send, given what is due and when the last alerts went out. Nothing, if this
    /// minute's three have been sent: the notices stay due and go next time.
    public static func plan(_ due: [NoticeBook.Notice], recent: [Date], at now: Date) -> [Alert] {
        guard !due.isEmpty else { return [] }
        let free = perWindow - recent.filter { now.timeIntervalSince($0) < window }.count
        if due.count <= free { return due.map(Alert.single) }
        return free > 0 ? [.combined(due)] : []
    }

    /// "6 Macs stopped answering" and the first few names, or "6 things need attention".
    public static func combinedText(_ notices: [NoticeBook.Notice], hostName: (NoticeBook.Notice) -> String?)
        -> (title: String, body: String) {
        let allOffline = notices.allSatisfy { NotificationCategory.forNotice(key: $0.key) == .hostOffline }
        let title = allOffline ? "\(notices.count) Macs stopped answering" : "\(notices.count) things need attention"
        let names = notices.map { allOffline ? (hostName($0) ?? $0.title) : $0.title }
        let shown = names.prefix(4).joined(separator: allOffline ? ", " : "; ")
        let more = names.count > 4 ? (allOffline ? " and \(names.count - 4) more" : "; and \(names.count - 4) more") : ""
        return (title, shown + more + ".")
    }
}
