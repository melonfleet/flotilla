import Foundation

/// The handful of web addresses the app offers to open.
///
/// One place, because the same three are reachable from the sidebar's runtime menu and from the
/// app menus, and two copies of a URL is two things to get wrong. Nothing here is ever fetched —
/// these are handed to the browser on an explicit click.
///
/// That distinction is the whole reason "check for updates" opens a page rather than comparing
/// versions: Flotilla makes no network requests of its own, and a background version check would
/// be exactly the phone-home the app promises it does not do. The releases page plus the version
/// we already read locally is the honest version of the feature — you compare, not us.
enum ExternalLinks {
    /// Flotilla's own repository.
    static let flotilla = URL(string: "https://github.com/melonfleet/flotilla")!

    /// Apple's `container`, which Flotilla drives.
    static let appleContainer = URL(string: "https://github.com/apple/container")!

    /// The suite's own site.
    static let melonfleet = URL(string: "https://melonfleet.dev")!

    /// Where a newer `container` would appear. The installed version is shown beside the link so
    /// the comparison takes one glance.
    static let appleContainerReleases = URL(string: "https://github.com/apple/container/releases")!

    /// Flotilla's own releases. Updates themselves come through Sparkle (DECISIONS Q40).
    static let flotillaReleases = URL(string: "https://github.com/melonfleet/flotilla/releases")!

    /// Apple's own instructions for the two ways into a Mac that a host's page offers (Q44): Flotilla
    /// opens macOS's tools rather than carrying a remote shell of its own. Checked 9 October.
    static let appleRemoteLogin = URL(string: "https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac")!
    static let appleScreenSharing = URL(string: "https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac")!
    static let appleFileSharing = URL(string: "https://support.apple.com/guide/mac-help/set-up-file-sharing-on-mac-mh17131/mac")!
}
