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
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    /// Whether this build can update itself: it carries a feed, which only a bundled build does.
    static var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    var isRunning: Bool { controller != nil }

    /// Starts or stops the updater for this Mac's role — and applies the settings — whenever the
    /// mode or a setting changes.
    func apply(isAdmin: Bool) {
        guard Self.isConfigured, isAdmin else {
            controller = nil
            return
        }
        if controller == nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
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

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    /// Pre-releases are published on the `beta` channel; the stable channel sees only releases.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            settings[SettingsKeys.updateChannel] == .prerelease ? ["beta"] : []
        }
    }
}
