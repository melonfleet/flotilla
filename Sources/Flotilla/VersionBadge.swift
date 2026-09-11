import SwiftUI
import FlotillaCore

/// The version, bottom-right of the dashboard, and the one control that tells you whether it is
/// the latest.
///
/// Modelled on Docker Desktop's own corner, from the owner's screenshot: a small mark and a
/// version number at the far bottom-right, in the accent colour, with the mark carrying the
/// state — a tick beside `v4.90.0` meaning "this is current". The version *is* the control
/// there; there is no separate "check" word, and the same applies here.
///
/// **It checks only when clicked.** Flotilla makes no network connections of its own otherwise —
/// not at launch, not on a timer — and that is a published claim, on the About page and in the
/// README. A badge that quietly asked GitHub every time you opened the dashboard would make both
/// of them false, which is a worse trade than one click. See `UpdateCheck` for the three rules
/// that keep it honest.
struct VersionBadge: View {
    let model: AppModel

    @State private var outcome: UpdateCheck.Outcome?
    @State private var checking = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: act) {
            HStack(spacing: 5) {
                if checking {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                        .frame(width: 11, height: 11)
                } else if let symbol {
                    Image(systemName: symbol.name)
                        .font(.system(size: 11))
                        .foregroundStyle(symbol.tint)
                }
                Text(title)
            }
            .font(.caption)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(helpText)
        .task { await checkAtLaunchIfAsked() }
        // The result survives leaving the Dashboard and coming back, because the answer has not
        // changed and asking again would be a second request for the same fact.
        .onAppear { outcome = UpdateCheck.lastOutcome }
    }

    /// The automatic check, and everything that stops it becoming a poll.
    ///
    /// Off unless the setting says otherwise, and then **once for the life of the process** —
    /// not once per visit to the Dashboard, which is the shape that turns "at launch" into "every
    /// time you click Dashboard".
    private func checkAtLaunchIfAsked() async {
        guard model.settingsStore[SettingsKeys.checkForNewReleasesOnLaunch],
              !UpdateCheck.hasCheckedThisLaunch else { return }
        await check()
    }

    // MARK: What it says

    private var title: String {
        switch outcome {
        case .updateAvailable(let latest, _): "Flotilla \(latest) available"
        case .latestIsKnown(let latest, _): "Latest release is \(latest)"
        case .noReleases: "Flotilla \(AppVersion.label) · no releases yet"
        case .failed(let reason): "Flotilla \(AppVersion.label) · \(reason)"
        case .upToDate, .ahead, .none: "Flotilla \(AppVersion.label)"
        }
    }

    private var symbol: (name: String, tint: Color)? {
        switch outcome {
        // The tick is the whole point of Docker's version corner: one glance says current.
        case .upToDate: ("checkmark.circle.fill", Theme.online)
        case .updateAvailable: ("arrow.down.circle.fill", Theme.accentText)
        case .latestIsKnown: ("arrow.up.right.circle", Theme.accentText)
        // A development build is ahead of every release, which is neither current nor behind.
        case .ahead: ("hammer.circle", .secondary)
        case .noReleases, .failed: ("exclamationmark.circle", .secondary)
        case .none: nil
        }
    }

    private var tint: Color {
        switch outcome {
        // Once checked, the line is a statement rather than an invitation — quiet unless there
        // is something to do about it.
        case .updateAvailable, .latestIsKnown: Theme.accentText
        case .none: Theme.accentText
        default: .secondary
        }
    }

    private var helpText: String {
        switch outcome {
        case .updateAvailable(let latest, _): "Open the release notes for \(latest)"
        case .latestIsKnown: "Open the releases page"
        case .none:
            "Check whether a newer Flotilla has been released. Asks GitHub only when you click; "
            + "nothing about you or this Mac is sent."
        default: "Check again"
        }
    }

    /// One control, two meanings — the same as Docker's: when there is a release to look at,
    /// clicking opens it; otherwise clicking checks (again).
    private func act() {
        switch outcome {
        case .updateAvailable(_, let page), .latestIsKnown(_, let page):
            openURL(page)
        default:
            Task { await check() }
        }
    }

    private func check() async {
        checking = true
        UpdateCheck.hasCheckedThisLaunch = true
        let result = await UpdateCheck.run(running: AppVersion.semantic)
        UpdateCheck.lastOutcome = result
        outcome = result
        checking = false
    }
}
