import AppKit
import OSLog
import UserNotifications
import FlotillaCore

/// Delivers the per-category notifications the Settings screen has been offering toggles for
/// since the settings registry landed — with, until now, nothing behind them. There was no
/// `UNUserNotificationCenter` use anywhere in the app, so every switch on that pane was
/// decorative, including the mandatory Errors row that cannot be turned off.
///
/// **Requires an app bundle.** `UNUserNotificationCenter.current()` does not degrade
/// gracefully without one — it raises `bundleProxyForCurrentProcess is nil` and terminates
/// the process (verified 2026-07-30 against a bare SwiftPM binary). That is why
/// `Scripts/make-app.sh` exists, and why every entry point here is guarded: running
/// `swift run Flotilla` during development must stay possible, so with no bundle identifier
/// this becomes a no-op that logs instead of a crash.
///
/// Authorization is requested **lazily**, on the first notification we actually want to post,
/// rather than at launch. A permission prompt before the user has done anything is the
/// pattern people deny by reflex, and a denied prompt is far harder to recover from than a
/// late one.
///
/// **Notices (Q48).** `postNotice` sends one of Flotilla's notices with its id as the request's,
/// so `withdraw` can take it out of Notification Centre when it resolves or is dismissed, and its
/// buttons — the notice's fix, and Dismiss — come back through `onResponse`. Nothing is shown
/// while Flotilla is in front: the bell and Overview's banner already are.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Response { case open, fix, dismiss }

    /// A notification was clicked (`open`) or one of its buttons pressed, by notice id.
    var onResponse: ((String, Response) -> Void)?
    private var registered: [String: UNNotificationCategory] = [:]

    private let log = Logger(subsystem: "dev.melonfleet.Flotilla", category: "notifications")

    /// Nil when there is no bundle — i.e. `swift run` rather than the assembled app.
    private let center: UNUserNotificationCenter?

    private var categories: NotificationSettings
    private var granted = false
    private var authorizing: Task<Bool, Never>?

    init(categories: NotificationSettings = .defaults) {
        self.categories = categories
        // Bundle identifier is the tell. Checking it is what keeps `swift run` alive.
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
    }

    /// Becomes the centre's delegate, at launch, so a click that launched Flotilla still arrives.
    func activate() {
        center?.delegate = self
    }

    func isEnabled(_ category: NotificationCategory) -> Bool { categories.isEnabled(category) }

    /// Whether Flotilla is the app in front, when nothing is shown.
    var isFrontmost: Bool { NSApp.isActive }

    func updateCategories(_ preferences: NotificationSettings) {
        categories = preferences
    }

    /// Post one notification, if its category is enabled and we are permitted.
    ///
    /// `body` is caller-supplied text about a container or an operation. It is deliberately
    /// **not** logged: names and errors can carry paths and identifiers, and
    /// `FEATURES.md`'s logging rule is metadata and durations only.
    func post(_ category: NotificationCategory, title: String, body: String) async {
        guard let center else {
            log.debug("Skipping \(category.rawValue, privacy: .public) — no bundle, so no notification centre.")
            return
        }
        // Mandatory categories (errors) ignore the toggle; everything else respects it.
        guard category.isMandatory || categories.isEnabled(category) else { return }
        guard !isFrontmost else { return }
        guard await ensureAuthorized(center) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = category.rawValue      // groups repeats in Notification Centre
        content.interruptionLevel = category == .error ? .active : .passive

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            log.error("Failed to post \(category.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One notice, or several sent together, under `id`. `fix` names the notice's own button.
    /// `notices` names what a combined alert carries, kept on the notification itself so a later
    /// launch can still withdraw it.
    func postNotice(id: String, title: String, body: String, level: NoticeBook.Level, thread: String,
                    fix: String?, dismissible: Bool, notices: [String] = []) async {
        guard let center, !isFrontmost, await ensureAuthorized(center) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread                   // one group per Mac
        content.interruptionLevel = level == .good ? .passive : .active
        content.sound = level == .good ? nil : .default
        content.categoryIdentifier = register(fix: fix, dismissible: dismissible)
        if !notices.isEmpty { content.userInfo = ["notices": notices] }
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            log.error("Failed to post a notice: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes these out of Notification Centre, and any combined alert none of whose notices is
    /// still `live`.
    func withdraw(_ ids: [String], live: Set<String>) async {
        guard let center, !ids.isEmpty else { return }
        var gone = ids
        for delivered in await center.deliveredNotifications() {
            if let carried = delivered.request.content.userInfo["notices"] as? [String],
               live.isDisjoint(with: carried) {
                gone.append(delivered.request.identifier)
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: gone)
    }

    /// The buttons are fixed per category, so there is one per fix title and dismissibility.
    private func register(fix: String?, dismissible: Bool) -> String {
        let id = "notice|\(fix ?? "")|\(dismissible)"
        guard registered[id] == nil, let center else { return id }
        var actions: [UNNotificationAction] = []
        if let fix { actions.append(UNNotificationAction(identifier: "fix", title: fix)) }
        if dismissible { actions.append(UNNotificationAction(identifier: "dismiss", title: "Dismiss")) }
        registered[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
        center.setNotificationCategories(Set(registered.values))
        return id
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let kind: Response = switch response.actionIdentifier {
        case "fix": .fix
        case "dismiss": .dismiss
        default: .open
        }
        await MainActor.run { onResponse?(id, kind) }
    }

    /// In front, nothing shows: Flotilla's own banner and bell already do.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    /// Ask once, and only when the answer is not known. A grant is remembered; a refusal is read
    /// again each time — reading the setting never prompts, and that way turning notifications on
    /// in System Settings works without a relaunch.
    ///
    /// Posts arrive together (three errors at once, 10 October), so they share one request: each
    /// asking for itself raced the prompt, and two of three were lost as "not allowed" while it
    /// was still on screen.
    private func ensureAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        if granted { return true }
        if let authorizing { return await authorizing.value }
        let task = Task { [log] () -> Bool in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: return true
            case .notDetermined:
                do { return try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                    log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            default: return false
            }
        }
        authorizing = task
        let answer = await task.value
        authorizing = nil
        granted = answer
        return answer
    }
}
