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

/// Client / host / both. A `UserDefaults`-backed key from day one so a Phase 6
/// profile can pin a mini to host mode without a code change.
public enum RunMode: String, SettingEnum, Codable {
    case client, host, both
}

/// Menu-bar apps need this: `MenuBarExtra` alone leaves no Dock presence.
public enum AppPresentation: String, SettingEnum, Codable {
    case menuBar, dock, both
}

/// What to do when the `container` API service isn't running. Default is `ask` —
/// starting a launchd service behind the user's back is the same class of thing as
/// the silent privileged install `DECISIONS.md` rejects.
public enum ServiceAutostartPolicy: String, SettingEnum, Codable {
    case ask, always, never
}

/// Sparkle feed selection. Maps to `SUFeedURL` selection at the app layer.
public enum UpdateChannel: String, SettingEnum, Codable {
    case stable, prerelease
}
