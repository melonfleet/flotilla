import Foundation
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
@MainActor
final class Notifier {

    private let log = Logger(subsystem: "dev.melonfleet.Flotilla", category: "notifications")

    /// Nil when there is no bundle — i.e. `swift run` rather than the assembled app.
    private let center: UNUserNotificationCenter?

    private var categories: NotificationSettings
    private var authorization: Authorization = .unknown

    private enum Authorization { case unknown, granted, denied }

    init(categories: NotificationSettings = .defaults) {
        self.categories = categories
        // Bundle identifier is the tell. Checking it is what keeps `swift run` alive.
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
    }

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

    /// Ask once, remember the answer. A denial is cached so we stop asking — repeatedly
    /// prompting someone who said no is how an app gets muted entirely.
    private func ensureAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch authorization {
        case .granted: return true
        case .denied: return false
        case .unknown: break
        }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorization = .granted
        case .denied:
            authorization = .denied
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                authorization = granted ? .granted : .denied
            } catch {
                log.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
                authorization = .denied
            }
        @unknown default:
            authorization = .denied
        }
        return authorization == .granted
    }
}
