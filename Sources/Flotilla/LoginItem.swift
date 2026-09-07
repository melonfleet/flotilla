import AppKit
import ServiceManagement

/// Registers Flotilla as a login item, and reports honestly when it cannot.
///
/// ## Why this exists
///
/// `launchAtLogin` shipped in the settings registry with a summary that said
/// "Register Flotilla as a login item (SMAppService)" and **no code anywhere that called
/// `SMAppService`**. The toggle moved, persisted, survived a relaunch, and did nothing. That is the
/// worst kind of setting: it is indistinguishable from a working one until the day you reboot and
/// notice the app did not come back.
///
/// ## Why the status matters as much as the switch
///
/// `SMAppService.register()` does not simply succeed or fail. macOS can put the request into
/// `.requiresApproval`, where the registration exists but is switched off in
/// System Settings ▸ General ▸ Login Items until the user approves it. A toggle that flips itself on
/// and stays silent in that state is lying again, more subtly. So `LoginItem` reports a
/// `Status` and the Settings row shows it, including the sentence naming where to go.
///
/// ## The signing caveat, stated rather than discovered later
///
/// `SMAppService.mainApp` addresses the running app **bundle**. Run as a bare SwiftPM executable
/// (`swift run Flotilla`) there is no bundle identifier, so there is nothing Service Management can
/// register. A bundled build must still be allowed to try: signature or policy failures come back
/// from `register()` and belong in the Settings caption, not behind a disabled control.
@MainActor
enum LoginItem {

    /// What macOS currently thinks, translated into something a person can act on.
    enum Status: Equatable {
        case registered
        case notRegistered
        /// Registered, but the user has to approve it in System Settings before it takes effect.
        case awaitingApproval
        /// The process has no identifiable app bundle for `SMAppService` to register.
        case unavailable

        var summary: String {
            switch self {
            case .registered:       "Flotilla will open when you log in."
            case .notRegistered:    "Flotilla will not open at login."
            case .awaitingApproval: "Waiting for approval in System Settings ▸ General ▸ Login Items."
            case .unavailable:      "Launch at login requires Flotilla to run from an app bundle."
            }
        }

        /// Whether the toggle should read as on. `.awaitingApproval` counts as on: the user asked
        /// for it and the request stands, it just needs their approval elsewhere.
        var isOn: Bool { self == .registered || self == .awaitingApproval }
    }

    static var status: Status {
        // Bundle identifier is the same app-vs-bare-executable test used by `Notifier`. Without
        // one, `SMAppService.mainApp` has no stable application identity and can never work.
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }

        return switch SMAppService.mainApp.status {
        case .enabled:          .registered
        case .requiresApproval: .awaitingApproval
        case .notRegistered:    .notRegistered
        // `notFound` says the lookup found no service. A never-registered, correctly signed app can
        // start here, so absence is not evidence that registration is permanently unavailable.
        case .notFound:         .notRegistered
        // A future status is not evidence that this identifiable bundle can never be registered
        // either. Let the requested operation run; any refusal is surfaced by `reconcile`.
        @unknown default:       .notRegistered
        }
    }

    /// Makes the system state match `wanted`. Returns the resulting status.
    ///
    /// Throws only what the caller can act on: the message is surfaced, never swallowed. An early
    /// version of this ignored the throw the way `LocalHost` used to ignore exit codes, and the
    /// result is the same class of bug — a failure reported to nobody.
    @discardableResult
    static func apply(_ wanted: Bool) throws -> Status {
        let service = SMAppService.mainApp
        if wanted {
            // Registering an already-registered service throws on some macOS versions rather than
            // being a no-op, so ask first. `.requiresApproval` is already-registered too.
            if service.status != .enabled && service.status != .requiresApproval {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
        return status
    }

    /// Brings the system into line with the stored preference at launch.
    ///
    /// Needed because the two can drift without the app doing anything wrong: the user can remove
    /// Flotilla in System Settings ▸ Login Items, which changes the system and not our preference.
    /// Reconciling toward the **preference** is the right direction — it is the thing the user set
    /// inside the app — but a failure here is reported and not retried in a loop.
    static func reconcile(preference: Bool) -> (status: Status, failure: String?) {
        let current = status
        guard current != .unavailable else { return (current, nil) }
        guard current.isOn != preference else { return (current, nil) }
        do {
            return (try apply(preference), nil)
        } catch {
            return (status, error.localizedDescription)
        }
    }
}
