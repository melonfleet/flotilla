import Foundation
import FlotillaCore

/// **The only place Flotilla reaches the network itself.**
///
/// Everything else that leaves this Mac is `container` acting on an instruction you gave it —
/// pulling an image from a registry. This file is the exception, and it is deliberately one
/// file so that the About page's claim can be checked by reading it.
///
/// Three rules hold the "no phone-home" promise while still answering "am I on the latest?":
///
/// 1. **Only when asked.** Nothing here runs at launch, on a timer, or in the background. It
///    runs when someone clicks the version.
/// 2. **One destination, no payload.** A `GET` to GitHub's public releases endpoint for this
///    repository. No identifiers, no version number, no machine details — the comparison happens
///    here, on what comes back, not on a server.
/// 3. **Nothing is remembered.** The result lives in the view for as long as the window is open.
enum UpdateCheck {
    /// Whether this process has already asked. The automatic check is **once per launch**, so
    /// this is what stops "at launch" quietly becoming "every time the Dashboard appears".
    @MainActor static var hasCheckedThisLaunch = false

    /// The last answer, so leaving the Dashboard and coming back shows what was already learned
    /// instead of asking again for the same fact. Process lifetime only — nothing is written to
    /// disk, which is the third of the three rules above.
    @MainActor static var lastOutcome: Outcome?

    /// GitHub's own API for "the latest published release".
    static let endpoint = URL(string: "https://api.github.com/repos/melonfleet/flotilla/releases/latest")!

    enum Outcome: Equatable {
        /// The running version is the latest published release.
        case upToDate(SemanticVersion)
        /// A newer release exists, and where to read about it.
        case updateAvailable(SemanticVersion, URL)
        /// This build is newer than anything published — a development or pre-release build.
        case ahead(latest: SemanticVersion)
        /// There is a latest release but nothing to compare it against, because this build
        /// carries no version of its own.
        case latestIsKnown(SemanticVersion, URL)
        /// The repository has published no releases yet. Not a failure.
        case noReleases
        case failed(String)
    }

    /// Ask GitHub what the latest release is, and compare.
    ///
    /// `running` is nil for a build with no version — `swift run`, or a bundle from a repo with
    /// no tags, which `make-app.sh` stamps `0.0.0`. In that case nothing is claimed about being
    /// up to date; the latest release is simply named.
    static func run(running: SemanticVersion?) async -> Outcome {
        var request = URLRequest(url: endpoint)
        // GitHub asks for an explicit Accept and a User-Agent; without the latter it answers 403.
        // The agent names the app and nothing about the machine it is running on.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Flotilla", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // No caching: a check you asked for should not be able to answer from last week.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("No response.") }
            // 404 is the honest answer for a repository with no releases yet, which is exactly
            // where this project is today — it must not be dressed up as an error.
            if http.statusCode == 404 { return .noReleases }
            guard http.statusCode == 200 else {
                return .failed("GitHub answered \(http.statusCode).")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = SemanticVersion(release.tagName) else {
                return .failed("Couldn't read the latest release's version.")
            }
            let page = URL(string: release.htmlURL) ?? ExternalLinks.flotillaReleases

            guard let running, !running.isUnreleased else {
                return .latestIsKnown(latest, page)
            }
            if running == latest { return .upToDate(latest) }
            return running < latest ? .updateAvailable(latest, page) : .ahead(latest: latest)
        } catch is CancellationError {
            return .failed("Cancelled.")
        } catch {
            // Offline is the common case and deserves plain words, not an NSError dump.
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain {
                return .failed("Couldn't reach GitHub.")
            }
            return .failed(failure.localizedDescription)
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

/// This build's version, or nil when there isn't one.
///
/// `CFBundleShortVersionString` only exists once `Scripts/make-app.sh` has assembled a real
/// bundle; `swift run` has no bundle at all. A tagless repo is stamped `0.0.0`, which parses but
/// is not a release — `SemanticVersion.isUnreleased` is how that is told apart downstream.
enum AppVersion {
    static var short: String? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var semantic: SemanticVersion? { short.flatMap(SemanticVersion.init) }

    /// What to print beside the app's name. "Development build" rather than `0.0.0`, which is a
    /// placeholder and would read as a real, very old release.
    static var label: String {
        guard let version = semantic, !version.isUnreleased else { return "Development build" }
        return version.description
    }
}
