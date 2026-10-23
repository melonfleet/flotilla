import SwiftUI
import FlotillaCore

/// The Overview's live `OverviewLayout`, persisted to the preference domain (DECISIONS Q67).
///
/// **Content, not configuration**, for the reasons `TagStore` gives: an admin seeding or locking
/// someone's widget arrangement is not a capability worth building, and the layout has no place in
/// Settings or the Jamf key list. So it is not in `SettingsStore`, and it is written the way tags
/// are — plist-native, under one key of its own, readable with
///
/// ```
/// defaults read dev.melonfleet.Flotilla overviewLayout
/// ```
///
/// **Per Mac**, because the preference domain is: a 32-inch display and a laptop want different
/// pages, and nothing here travels over the wire.
///
/// **Absent and empty are different**, as in `TagStore`. Absent is a Mac that has never arranged
/// its Overview, which gets the recommended layout — and keeps getting the *current* recommended
/// layout until the owner changes something, because nothing is written until then. Empty is an
/// owner who removed every widget, who gets "Make the Overview yours", not the defaults back.
@MainActor
@Observable
final class OverviewLayoutStore {
    @ObservationIgnored
    private let defaults: UserDefaults?

    private(set) var layout: OverviewLayout

    static let key = "overviewLayout"
    /// The old Get started card's X (9 October). Read once, for a Mac with no layout yet, so a card
    /// the owner closed does not come back as a widget.
    static let legacyGetStartedDismissedKey = "getStartedDismissed"

    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        if let stored = defaults?.array(forKey: Self.key) {
            layout = OverviewLayout(storage: stored.compactMap { $0 as? [String: String] })
        } else {
            let dismissed = defaults?.bool(forKey: Self.legacyGetStartedDismissedKey) ?? false
            layout = .recommended(includingGetStarted: !dismissed)
        }
    }

    /// Whether the page shows what it would for a new Mac — Reset to Recommended has nothing to do.
    var isRecommended: Bool { layout == .recommended }

    /// Every change goes through here, so every change is written.
    func update(_ change: (inout OverviewLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        layout = next
        defaults?.set(layout.storage, forKey: Self.key)
    }
}
