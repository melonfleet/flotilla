import Foundation

// Value types for the enum-backed settings. String-backed so they survive a plist
// round trip and read sensibly in an exported profile.

/// The three appearances the user can pick. `auto` follows the system colour scheme.
/// Per `DECISIONS.md`: light and dark are both first-class, and the watermelon accent
/// is the single accent colour in both.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case auto, light, dark
}

/// What is actually stored. `notChosen` is deliberately distinct from `auto`:
/// `DECISIONS.md` says appearance is chosen **during first run** with `auto`
/// *pre-selected*, not defaulted — so onboarding has to be able to tell "the user
/// picked Auto" from "we haven't asked yet". Collapsing the two would either re-ask
/// forever or silently skip the question.
public enum AppearancePreference: String, SettingEnum, Codable {
    case notChosen, auto, light, dark

    /// Nil until the user (or a managed profile) has answered.
    public var chosen: AppearanceMode? {
        switch self {
        case .notChosen: nil
        case .auto: .auto
        case .light: .light
        case .dark: .dark
        }
    }

    /// What to render with before the question is answered — `auto`, matching the
    /// pre-selected option in onboarding, so the first paint doesn't change under
    /// the user when they confirm.
    public var effective: AppearanceMode { chosen ?? .auto }

    public var isChosen: Bool { self != .notChosen }

    public init(_ mode: AppearanceMode) {
        self = switch mode {
        case .auto: .auto
        case .light: .light
        case .dark: .dark
        }
    }

    /// The cases onboarding and Settings offer; `notChosen` is never a picker option.
    public static var selectable: [AppearancePreference] { [.auto, .light, .dark] }
}

/// One of the four themes. The same four exist in light and in dark, and the user picks one for
/// each: the light theme and the dark theme are two settings keys holding a value of this type.
///
/// A theme changes exactly two things — the window bar and the content background — and is named
/// after its bar (`design/THEMES.md`). There are two pickers rather than one because Auto switches
/// appearance at sunset, so the user chooses a pair and Auto moves between them. Picking Stripe
/// for both is a pair too.
///
/// The case names are the brand tokens, not display strings, so an exported profile says
/// `stripe` rather than something a translation could change. Declaration order is picker order.
public enum ThemeName: String, SettingEnum, Codable {
    case stripe, flesh, cantaloupe, canary

    public var title: String {
        switch self {
        case .stripe: "Stripe"
        case .flesh: "Flesh"
        case .cantaloupe: "Cantaloupe"
        case .canary: "Canary"
        }
    }
}

/// Client / host / both. A `UserDefaults`-backed key from day one so a Phase 6
/// profile can pin a mini to host mode without a code change.
public enum RunMode: String, SettingEnum, Codable {
    case client, host, both
}

/// **Retired.** Kept only so `SettingsStore.migrateLegacyKeys` can recognise a stored
/// `presentation` value written by an earlier build and carry the one distinction that was real
/// (`menuBar` meant "no Dock icon") over to `showDockIcon`.
///
/// Do not add a control for this. See `SettingsKeys.showDockIcon` for why three options were two
/// too many.
public enum AppPresentation: String, SettingEnum, Codable {
    case menuBar, dock, both
}

/// What to do when the `container` API service isn't running.
///
/// The default is **`.always`**, not `.ask`; the reasoning is on
/// `SettingsKeys.autoStartContainerService`, which is also the only place that reads this.
public enum ServiceAutostartPolicy: String, SettingEnum, Codable {
    case ask, always, never
}

/// Sparkle feed selection. Maps to `SUFeedURL` selection at the app layer.
public enum UpdateChannel: String, SettingEnum, Codable {
    case stable, prerelease
}
