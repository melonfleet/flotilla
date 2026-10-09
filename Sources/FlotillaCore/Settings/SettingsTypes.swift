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

/// The theme drawn whenever the app is **light**: eight of them, in two rows of four.
///
/// A theme changes exactly two things — the window bar and the content background — and is named
/// after its bar, plus its body when that body is the honeydew wash (`design/THEMES.md`). The owner,
/// 5 October: **one background per row.** The first four are the four brand bars on cream; the
/// second four are the same four bars, in the same order, on the honeydew wash. So `canary` is the
/// canary bar on cream, and `canaryHoneydew` is the same bar on the wash.
///
/// **Two types, not one, and that is the point.** Light has eight themes and dark has four (the
/// owner, 5 October: the honeydew row is light-only). With one shared enum, both keys would accept
/// all eight, and a managed profile could store `canaryHoneydew` for dark — a theme with no dark
/// form. Separate types make the dark key refuse it at the settings layer, with no check anyone
/// has to remember.
///
/// The raw values are the brand tokens, so an exported profile says `stripe`, and the four themes
/// both lists share keep the raw values they have always had. Declaration order is picker order,
/// and the picker lays it out four to a row, so the honeydew row lines up under the cream one.
public enum LightTheme: String, SettingEnum, Codable {
    case stripe, flesh, cantaloupe, canary
    case stripeHoneydew, fleshHoneydew, cantaloupeHoneydew, canaryHoneydew

    public var title: String {
        switch self {
        case .stripe: "Stripe"
        case .flesh: "Flesh"
        case .cantaloupe: "Cantaloupe"
        case .canary: "Canary"
        case .stripeHoneydew: "Stripe Honeydew"
        case .fleshHoneydew: "Flesh Honeydew"
        case .cantaloupeHoneydew: "Cantaloupe Honeydew"
        case .canaryHoneydew: "Canary Honeydew"
        }
    }
}

/// The theme drawn whenever the app is **dark**: four of them. See `LightTheme` for why this is a
/// separate type. Every dark body is seed, so a dark "honeydew" variant would only repeat dark
/// Canary or dark Flesh.
public enum DarkTheme: String, SettingEnum, Codable {
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

/// Client (shown as Admin) or host. A `UserDefaults`-backed key from day one so a Phase 6
/// profile can pin a mini to host mode without a code change.
///
/// **`both` is retired** (the owner, 9 October). Every Mac runs its own containers whatever its
/// mode — "host" only means another Mac may manage this one — so a Mac that manages others and is
/// itself managed by a different admin was rare and read as confusing. The case stays so a stored
/// or profile value still decodes: a stored one becomes `client` at load, a managed one is read as
/// `client` (`effective`).
public enum RunMode: String, SettingEnum, Codable {
    case client, host, both

    /// The modes Settings and first run offer.
    public static let offered: [RunMode] = [.client, .host]

    /// What the Mac does: `both` is treated as `client`.
    public var effective: RunMode { self == .both ? .client : self }
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
