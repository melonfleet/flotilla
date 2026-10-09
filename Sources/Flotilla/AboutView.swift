import SwiftUI
import FlotillaCore

/// The About/Privacy view, per `research/FEATURES.md`'s Phase 1 claim:
///
/// > No telemetry, no account, no activation — stated in the UI. Zero analytics/crash
/// > upload/phone-home; an About/Privacy view listing every network destination.
///
/// The claim was already true; nothing here makes Flotilla more private. What this view adds
/// is a place a person can check it, next to a complete list of what actually reaches the
/// network — which is what makes "no phone-home" a verifiable claim rather than marketing.
///
/// Everything below is written to be exactly as true as the code it describes, and no more
/// confident. If a future phase adds a destination, this view must be updated in the same
/// change — a stale privacy page is worse than none.
struct AboutView: View {
    let model: AppModel
    let dismiss: () -> Void

    var body: some View {
        ModalCard(title: "About flotilla", onClose: dismiss) {
            Form {
                SwiftUI.Section {
                    identity
                }

                SwiftUI.Section("Network destinations") {
                    networkDestinations
                }

                SwiftUI.Section("Stored locally") {
                    storage
                }

                SwiftUI.Section("Licence") {
                    licence
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Wordmark(size: 20)
            Text(versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// `CFBundleShortVersionString`/`CFBundleVersion` only exist once `Scripts/make-app.sh` has
    /// assembled a real bundle and stamped `git describe` into it — see that script's `VERSION`
    /// derivation. Running via `swift run` there is no bundle at all (the same tell `Notifier`
    /// uses for `UNUserNotificationCenter`), so this reads as "Development build" rather than
    /// as blank version fields.
    private var versionLine: String {
        guard Bundle.main.bundleIdentifier != nil,
              let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            return "Development build"
        }
        return "Version \(short) (\(build))"
    }

    // MARK: - Network destinations

    private var registryDomain: String {
        model.settingsStore[SettingsKeys.defaultRegistryDomain]
    }

    private var networkDestinations: some View {
        VStack(alignment: .leading, spacing: 12) {
            destinationRow(
                status: .noConnection,
                title: "flotilla itself",
                body: "No analytics, no crash reporting, no licence check, and nothing about this "
                    + "Mac sent anywhere. Every place it can reach is listed below, with when."
            )
            if model.updater.isRunning {
                destinationRow(
                    status: model.updater.checksAutomatically ? .active : .onRequest,
                    title: "Sparkle updates",
                    body: "Reads melonfleet.github.io/flotilla/appcast.xml for a newer flotilla and, "
                        + "if you install one, downloads it from github.com. Only on the Mac you "
                        + "manage your fleet from. "
                        + (model.updater.checksAutomatically
                           ? "Automatic checks are on; turn them off in Settings → Updates."
                           : "Only when you choose Check for Updates.")
                )
            }
            destinationRow(
                status: .onRequest,
                title: "Searching Docker Hub",
                body: "Images → Browse Docker Hub asks hub.docker.com for images and their tags when "
                    + "you open it or type a search. The request carries what you typed and nothing "
                    + "else: no account, no cookies, a plain \"flotilla\" user agent."
            )
            destinationRow(
                status: .active,
                title: "Apple's container CLI",
                body: "Reaches container registries when you pull an image — currently "
                    + "\(registryDomain), your configured default registry (Settings → "
                    + "Defaults for new containers). That is the container runtime acting on "
                    + "your instruction, not flotilla phoning home."
            )
            destinationRow(
                status: model.hostMode.trustedHosts.isEmpty ? .noConnection : .active,
                title: "Your other Macs",
                body: "Talks only to Macs you have paired, on your own network, each checked by its "
                    + "key — never through a server of ours. "
                    + (model.hostMode.trustedHosts.isEmpty ? "None are paired."
                       : "\(model.hostMode.trustedHosts.count) paired.")
            )
        }
        .padding(.vertical, 4)
    }

    private enum DestinationStatus {
        case noConnection, active, onRequest, future

        var label: String {
            switch self {
            case .noConnection: "No connection"
            case .active: "Active"
            // Its own status, not "Active": a destination that is only ever reached because
            // you pressed something is a different promise from one that is reached for you,
            // and collapsing the two is how a privacy page stops being worth reading.
            case .onRequest: "Only when you ask"
            case .future: "Not yet built"
            }
        }

        var color: Color {
            switch self {
            case .noConnection: .secondary
            case .active: Theme.warning
            case .onRequest: Theme.warning
            case .future: .secondary
            }
        }
    }

    private func destinationRow(status: DestinationStatus, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.medium)
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(status.color.opacity(0.12), in: Capsule())
            }
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `LocalizedStringKey`, so the backticks render as code: a `+`-joined literal is a
            // plain `String`, which `Text` shows verbatim (the same rule `FieldHelp` follows).
            Text(LocalizedStringKey("Preferences are stored in the `dev.melonfleet.Flotilla` UserDefaults domain, "
                + "on this Mac only — one key per setting, so `defaults read "
                + "dev.melonfleet.Flotilla` shows every choice you have made and "
                + "`defaults write` sets one."))
            Text("A configuration profile can seed or lock any of them through "
                + "/Library/Managed Preferences, which always outranks the values above.")
                .foregroundStyle(.secondary)
            Text("This local-only build does not create an analytics identifier or a "
                + "server-side identifier, and it does not store an identity in Keychain.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 4)
    }

    // MARK: - Licence

    /// Apache-2.0 obliges a distributed work to carry its notices, and an About panel is where a
    /// user looks for them. SwiftTerm is named because it is the one third-party component in the
    /// app and its MIT licence asks for attribution.
    private var licence: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("flotilla is a personal project, licensed under Apache-2.0.")
            Text("Terminal emulation by SwiftTerm (MIT).")
            Text("Drives Apple\u{2019}s container CLI, which is not bundled.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}
