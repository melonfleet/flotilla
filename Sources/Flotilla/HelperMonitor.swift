import SwiftUI
import AppKit
import FlotillaCore
import FlotillaPrivileged

/// What the Flotilla Helper is doing right now, for Settings and the status bar (Q41, amended 19
/// October): macOS's registration plus a probe of the running copy, folded into one `HelperHealth`.
///
/// **Probed when something asks to show it, never on a timer.** Asking starts the daemon if it is not
/// running, so a tight loop would keep a root process alive for nothing. `refresh()` answers from a
/// 30-second cache; Settings and the footer menu call it when they appear, and the app calls it when it
/// comes to the front — the moment the owner is back from Login Items. The probe itself is awaited off
/// the main actor's critical path and bounded by a `Deadline`.
@MainActor
@Observable
final class HelperMonitor {
    private(set) var registration: HelperRegistration
    private(set) var probe: HelperProbe = .notAsked
    /// A restart, reinstall, install or remove is under way.
    private(set) var busy = false
    private(set) var problem: String?

    @ObservationIgnored private var lastProbe: Date?
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    var health: HelperHealth {
        HelperHealth.derive(registration: registration, probe: probe, current: HelperInterface.version)
    }

    init() {
        registration = PrivilegedHelper.status
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Re-reads macOS's registration (cheap) and, for an approved helper whose last answer is older
    /// than the cache, asks it for its version in the background.
    func refresh(force: Bool = false) {
        registration = PrivilegedHelper.status
        guard registration == .enabled else {
            probe = .notAsked
            lastProbe = nil
            return
        }
        guard force || !HelperProbeCache.isFresh(lastProbe: lastProbe, now: Date()) else { return }
        guard !probing else { return }
        probing = true
        Task {
            let version = await Deadline.value(within: .seconds(5)) { await PrivilegedHelper.runningVersion() }
            probing = false
            registration = PrivilegedHelper.status
            guard registration == .enabled else { probe = .notAsked; lastProbe = nil; return }
            probe = version.map { .answered(version: $0) } ?? .silent
            lastProbe = Date()
        }
    }

    // MARK: Buttons

    func install() {
        problem = nil
        do {
            try PrivilegedHelper.install()
        } catch {
            // Registration that is waiting for the owner's approval throws "Operation not permitted"
            // and still registers (measured 7 October): the status says what happened, so only a
            // status that did not move is a failure.
            if PrivilegedHelper.status == .notInstalled {
                problem = "Couldn't install the background service: \(error.localizedDescription)"
            }
        }
        refresh(force: true)
        if registration == .awaitingApproval { openLoginItems() }
    }

    func remove() {
        run("Couldn't remove the background service") { try await PrivilegedHelper.remove() }
    }

    func reinstall() {
        run("Couldn't reinstall the background service") { try await PrivilegedHelper.reinstall() }
    }

    func restart() {
        guard !busy else { return }
        busy = true
        problem = nil
        let known: Int? = if case .answered(let version) = probe { version } else { nil }
        Task {
            // Bounded: a helper that stays connected and never replies must not hold `busy`, which
            // disables Reinstall and Remove. At the limit the wait is cancelled and the connection
            // invalidated (`CancellableReply`); "" stands for success, since `nil` means timed out.
            let outcome = await Deadline.value(within: .seconds(10)) {
                await PrivilegedHelper.restart(knownVersion: known) ?? ""
            }
            switch outcome {
            case nil: problem = "Couldn't restart the background service: it didn't answer."
            case let failure? where !failure.isEmpty: problem = "Couldn't restart the background service: \(failure)"
            default: break
            }
            // It exits a moment after replying; the probe below starts the new copy.
            try? await Task.sleep(for: .seconds(1))
            busy = false
            refresh(force: true)
        }
    }

    func openLoginItems() { PrivilegedHelper.openLoginItems() }

    func perform(_ action: HelperHealth.Action) {
        switch action {
        case .install: install()
        case .remove: remove()
        case .restart: restart()
        case .reinstall: reinstall()
        case .openLoginItems: openLoginItems()
        }
    }

    private func run(_ failure: String, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        problem = nil
        Task {
            do { try await work() } catch { problem = "\(failure): \(error.localizedDescription)" }
            busy = false
            refresh(force: true)
        }
    }
}

extension HelperHealth {
    var tint: Color {
        switch tone {
        case .good: Theme.online
        case .warning: Theme.warning
        case .bad: Theme.danger
        case .neutral: .secondary
        }
    }

    var symbol: String {
        switch tone {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        case .bad: "xmark.circle"
        case .neutral: "circle"
        }
    }
}

extension HelperHealth.Action {
    var title: String {
        switch self {
        case .install: "Install"
        case .remove: "Remove"
        case .restart: "Restart"
        case .reinstall: "Reinstall"
        case .openLoginItems: "Open Login Items…"
        }
    }

    /// Reinstall says so: macOS may want the approval given again.
    var help: String? {
        switch self {
        case .reinstall: "Unregisters the background service and registers it again. macOS may ask you to approve it again."
        case .restart: "Quits the background service; macOS starts it again the next time Flotilla needs it."
        default: nil
        }
    }
}
