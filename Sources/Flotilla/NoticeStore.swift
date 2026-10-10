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

    func reconcile(_ items: [AttentionItem], unsettled: Set<String>) {
        var updated = book
        updated.reconcile(items.map(\.condition), at: Date(), unsettled: unsettled)
        guard updated != book else { return }
        book = updated
        changed()
    }

    func dismiss(_ ids: Set<String>) {
        guard book.dismiss(ids, at: Date()) > 0 else { return }
        changed()
    }

    func restore(_ ids: Set<String>) {
        book.restore(ids)
        changed()
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
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.notices.reconcile(self.attentionItems, unsettled: self.unsettledNoticeHosts)
                try? await Task.sleep(for: .seconds(5))
            }
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
