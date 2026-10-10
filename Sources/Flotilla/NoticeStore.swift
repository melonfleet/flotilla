import SwiftUI
import OSLog
import FlotillaCore

/// The app's `NoticeBook`, kept on disk so a week of notifications survives a relaunch (the owner,
/// 10 October). Fed every few seconds from `AppModel.attentionItems` — what is wrong now — by
/// `startNoticeWatch()`.
@MainActor
@Observable
final class NoticeStore {
    private(set) var book: NoticeBook
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let log = Logger(subsystem: SettingsPersistence.domain, category: "notices")

    init(file: URL? = NoticeStore.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let book = try? JSONDecoder().decode(NoticeBook.self, from: data) {
            self.book = book
        } else {
            book = NoticeBook()
        }
        attention = book.attention
    }

    static var defaultFile: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(SettingsPersistence.domain).appendingPathComponent("notices.json")
    }

    /// What needs attention, for the badge, the banner and the menu bar. Stored rather than
    /// derived from `book` so it changes only when the list does: an open menu is rebuilt when what
    /// it reads changes, and one rebuilt under the pointer loses the click.
    private(set) var attention: [NoticeBook.Notice] = []

    /// - Returns: the notices this resolved.
    @discardableResult
    func reconcile(_ items: [AttentionItem], unsettled: Set<String>) -> [NoticeBook.Notice] {
        var updated = book
        let resolved = updated.reconcile(items.map(\.condition), at: Date(), unsettled: unsettled)
        guard updated != book else { return [] }
        book = updated
        changed()
        ended(resolved.map(\.id))
        return resolved
    }

    func dismiss(_ ids: Set<String>) {
        guard book.dismiss(ids, at: Date()) > 0 else { return }
        changed()
        ended(Array(ids))
    }

    func restore(_ ids: Set<String>) {
        book.restore(ids)
        changed()
    }

    // MARK: Notification Centre (Q48)

    /// Set by `AppModel`, so a notice that ends leaves Notification Centre with it.
    @ObservationIgnored var notifier: Notifier?
    /// When this minute's alerts went out, for at most three a minute.
    @ObservationIgnored private var recentAlerts: [Date] = []

    /// Sends whatever is due: one each, or several as one when more than three a minute are.
    func announce(hostName: (NoticeBook.Notice) -> String?, fix: (NoticeBook.Notice) -> String?) {
        guard let notifier else { return }
        let now = Date()
        recentAlerts.removeAll { now.timeIntervalSince($0) >= NoticeAlerts.window }
        let due = NoticeAlerts.due(book, at: now, enabled: notifier.isEnabled)
        let plan = NoticeAlerts.plan(due, recent: recentAlerts, at: now)
        guard !plan.isEmpty else { return }
        book.markAnnounced(Set(plan.flatMap(\.notices).map(\.id)), at: now)
        changed()
        for alert in plan {
            recentAlerts.append(now)
            switch alert {
            case .single(let notice):
                let thread = notice.host ?? "flotilla"
                let body = notice.detail ?? ""
                let fixTitle = fix(notice)
                Task { await notifier.postNotice(id: notice.id, title: notice.title, body: body, level: notice.level,
                                                 thread: thread, fix: fixTitle, dismissible: notice.dismissible) }
            case .combined(let notices):
                let id = "combined@\(Int(now.timeIntervalSince1970 * 1000))"
                let carried = notices.map(\.id)
                let text = NoticeAlerts.combinedText(notices, hostName: hostName)
                let level = notices.map(\.level).max() ?? .warning
                Task { await notifier.postNotice(id: id, title: text.title, body: text.body, level: level,
                                                 thread: "flotilla", fix: nil, dismissible: false, notices: carried) }
            }
        }
    }

    /// "Mac mini is answering again", for a host whose going quiet was announced — if that
    /// category is on, which it is not by default.
    func announceBack(_ resolved: [NoticeBook.Notice], hostName: (NoticeBook.Notice) -> String?) {
        guard let notifier, notifier.isEnabled(.hostOnline) else { return }
        for notice in resolved where notice.announced != nil
            && NotificationCategory.forNotice(key: notice.key) == .hostOffline {
            let name = hostName(notice) ?? notice.title
            Task { await notifier.postNotice(id: "back:" + notice.id, title: "\(name) is answering again",
                                             body: "", level: .good, thread: notice.host ?? "flotilla",
                                             fix: nil, dismissible: false) }
        }
    }

    /// Takes ended notices out of Notification Centre, and any alert that carried only ended ones.
    private func ended(_ ids: [String]) {
        guard let notifier, !ids.isEmpty else { return }
        let live = Set(book.notices.filter { $0.isActive && $0.dismissed == nil }.map(\.id))
        Task { await notifier.withdraw(ids, live: live) }
    }

    private func changed() {
        let now = book.attention
        // `lastSeen` alone moving is not a change to the list.
        func shape(_ list: [NoticeBook.Notice]) -> [String] { list.map { "\($0.id)|\($0.level)|\($0.dismissible)|\($0.text)" } }
        if shape(now) != shape(attention) { attention = now }
        save()
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(book).write(to: file, options: .atomic)
        } catch {
            log.error("Couldn't save notifications: \(String(describing: error), privacy: .public)")
        }
    }
}

extension AppModel {
    /// Turns what is wrong now into notices every five seconds, window or no window — the same
    /// cadence the menu bar's badge needs.
    func startNoticeWatch() {
        notices.notifier = notifier
        notifier.onResponse = { [weak self] id, response in self?.respond(to: id, response) }
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let resolved = self.notices.reconcile(self.attentionItems, unsettled: self.unsettledNoticeHosts)
                // A host Mac is usually a mini with no one at it: its troubles reach the admin.
                if self.hostMode.isAdmin {
                    self.notices.announceBack(resolved, hostName: self.noticeHostName)
                    self.notices.announce(hostName: self.noticeHostName, fix: { self.fix(for: $0)?.title })
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A click on a notice's macOS notification, or one of its buttons.
    private func respond(to id: String, _ response: Notifier.Response) {
        let notice = notices.book.notices.first { $0.id == id }
        switch response {
        case .fix:
            if let notice, let fix = fix(for: notice) { fix.run() }
        case .dismiss:
            if notice != nil { notices.dismiss([id]) }
        case .open:
            pendingNotice = notice?.id
            pendingSection = .notifications
            NSApp.activate(ignoringOtherApps: true)
            openMainWindow?()
        }
    }

    /// Macs whose state isn't known yet, by notice host id: This Mac before preflight answers, a
    /// host before its first reply. Their notices wait rather than resolve.
    var unsettledNoticeHosts: Set<String> {
        var ids = Set(hostMode.trustedHosts.filter { peer in
            switch hostMode.live[peer.fingerprint]?.state {
            case nil, .checking?: true
            default: false
            }
        }.map(\.fingerprint.hex))
        if preflight == nil { ids.insert(HostRow.thisMacID) }
        return ids
    }

    /// The live fix for a notice, while its situation lasts — a closure cannot be saved, so it is
    /// looked up from what is wrong now by the notice's key.
    func fix(for notice: NoticeBook.Notice) -> (title: String, run: @MainActor () -> Void)? {
        guard notice.isActive else { return nil }
        return attentionItems.first { $0.key == notice.key }?.fix
    }

    /// The Mac a notice is about, by name.
    func noticeHostName(_ notice: NoticeBook.Notice) -> String? {
        guard let id = notice.host else { return nil }
        if id == HostRow.thisMacID { return HostModeController.computerName }
        return hostMode.hosts.first { $0.fingerprint.hex == id }?.displayName ?? "A removed host"
    }
}

extension NoticeBook.Level {
    var colour: Color {
        switch self {
        case .good: Theme.online
        case .info: Theme.info
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var title: String {
        switch self {
        case .good: "Good"
        case .info: "Information"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}
