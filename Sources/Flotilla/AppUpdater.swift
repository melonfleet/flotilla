import Combine
import Foundation
import Sparkle
import FlotillaCore

/// The admin Mac's own updates, through Sparkle (decision 13; DECISIONS Q40): an appcast on GitHub
/// Pages, signed and notarised zips on GitHub releases, every update checked against the EdDSA key
/// whose public half is in Info.plist.
///
/// **Consent, not a default.** Flotilla promises no phone-home, and an automatic check reaches
/// GitHub. So the four update settings are handed to Sparkle only when the owner or a managed profile
/// has set them; left at their built-in defaults, Sparkle asks once, on the second launch, whether to
/// check automatically. "Check for Updates…" is always the owner's explicit request.
///
/// **Admins only.** A host-only Mac is updated by its admin (Q38), so it never checks Sparkle too;
/// the menu item says so there.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private let settings: SettingsStore
    private let activity: UpdateActivityCenter
    /// Whether the check in flight was asked for, so a quiet background check that finds nothing
    /// does not flash "up to date" at someone who did not ask.
    private var explicitCheck = false

    init(settings: SettingsStore, activity: UpdateActivityCenter) {
        self.settings = settings
        self.activity = activity
        super.init()
    }

    /// Whether this build can update itself: it carries a feed, which only a bundled build does.
    static var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    var isRunning: Bool { controller != nil }

    /// Starts or stops the updater for this Mac's role — and applies the settings — whenever the
    /// mode or a setting changes.
    func apply(isAdmin: Bool) {
        // SettingsStore is not observable by SwiftUI. Refresh update menus after settings
        // writes too, including channel changes that do not change any Sparkle KVO property.
        objectWillChange.send()
        guard Self.isConfigured, isAdmin else {
            observations = []
            controller = nil
            return
        }
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            if let updater = controller?.updater {
                // Bridge Sparkle's KVO into SwiftUI; values still come directly from Sparkle.
                observations = [
                    updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.objectWillChange.send() }
                    },
                    updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.objectWillChange.send() }
                    },
                    updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.objectWillChange.send() }
                    }
                ]
            }
        }
        guard let updater = controller?.updater else { return }
        if settings.source(of: SettingsKeys.automaticUpdateChecks) != .builtIn {
            updater.automaticallyChecksForUpdates = settings[SettingsKeys.automaticUpdateChecks]
        }
        if settings.source(of: SettingsKeys.automaticallyDownloadUpdates) != .builtIn {
            updater.automaticallyDownloadsUpdates = settings[SettingsKeys.automaticallyDownloadUpdates]
        }
        if settings.source(of: SettingsKeys.updateCheckIntervalSeconds) != .builtIn {
            updater.updateCheckInterval = TimeInterval(max(3_600, settings[SettingsKeys.updateCheckIntervalSeconds]))
        }
    }

    /// Whether Sparkle checks on its own schedule, as the About page reports it.
    var checksAutomatically: Bool { controller?.updater.automaticallyChecksForUpdates ?? false }

    /// Sparkle owns and persists this date; every update surface reads the same value.
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        guard canCheck, let controller else { return }
        explicitCheck = true
        // With an update window already open, Sparkle only brings it forward: no check runs, so
        // saying "Checking…" would spin until that window is dealt with (Kyle, 18 October).
        if !controller.updater.sessionInProgress { activity.report(.checking, from: .app) }
        controller.checkForUpdates(nil)
    }

    /// Delegate callbacks arrive on the main thread; this hops explicitly rather than assume it.
    private nonisolated func report(_ stage: UpdateStage, ifExplicit: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self, !ifExplicit || explicitCheck else { return }
            activity.report(stage, from: .app)
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Pre-releases are published on the `beta` channel; the stable channel sees only releases.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            settings[SettingsKeys.updateChannel] == .prerelease ? ["beta"] : []
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        report(.found(item.displayVersionString))
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        report(.upToDate(nil), ifExplicit: true)
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        report(.downloading(item.displayVersionString))
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        report(.downloaded)
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        report(.failed("Couldn't download the update: \(error.localizedDescription)"))
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        report(.extracting)
    }

    /// Unpacked: Sparkle now waits for Install and Relaunch, which may be never.
    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        report(.readyToInstall(item.displayVersionString))
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        report(.installing)
    }

    /// Sparkle also ends a check that found nothing, and a cancelled authorisation, through here:
    /// neither is a failure. A background check that can't reach GitHub stays quiet too.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain,
           [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(error.code) {
            return
        }
        report(.failed("Couldn't check: \(error.localizedDescription)"), ifExplicit: true)
    }

    /// The last word on a cycle. A failure or result already reported stays; a step still showing
    /// means the cycle ended without saying more (a dismissed dialog), so the step is cleared
    /// rather than left spinning.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            explicitCheck = false
            if activity.activity.isBusy(.app) { activity.clear(.app) }
        }
    }
}
