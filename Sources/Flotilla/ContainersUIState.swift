import SwiftUI
import FlotillaCore

/// View state for the containers screen that must **survive navigating away and back**.
///
/// `NavigationSplitView`'s detail switches on the sidebar selection, so moving to Images and
/// returning destroys `ContainersView` and builds a new one. Anything held in its `@State`
/// resets — which silently threw away the user's column choices, sort order, filter tab and
/// search text every time they looked at another section.
///
/// the CLI owner's Docker Desktop study is what surfaced this: Docker shipped the same class of bug
/// (hidden columns re-enabling themselves, `docker/for-mac#6391`) and he flagged our surface
/// as overlapping directly. Checking found we had it too. Owning this state above the
/// navigation switch is the fix — `MainWindowView` is the window's root and is created once.
///
/// Deliberately **not** in `SettingsStore`: `research/FEATURES.md` keeps window and UI state
/// separate from preferences so that "reset preferences" cannot rearrange your table. This is
/// per-session state; persisting it across launches belongs with the window-state work, and
/// this class is the natural place to do it when that happens.
@MainActor
@Observable
final class ContainersUIState {

    var presentation: ContainersView.Presentation = .list
    /// Which states are shown. Both by default — see `ContainersView.StateFilter` for why
    /// this is a set rather than a one-of-three mode.
    var visibleStates: Set<ContainersView.StateFilter> = ContainersView.StateFilter.all
    var search = ""

    /// Running-first by default, per `DECISIONS.md` Q2 — the containers you can act on stay
    /// at the top rather than being buried alphabetically.
    var sortOrder = [KeyPathComparator(\Container.sortRank)]

    /// Which columns are shown, in what order and at what width.
    ///
    /// Two hidden by default:
    /// - **Host**, because with a single host it prints "This Mac" on every row, and a column
    ///   identical in every row is pure width. The cross-host dimension stays in the data.
    /// - **Created**, so the identifier and the live figures get the space first.
    var columnCustomization: TableColumnCustomization<Container> = {
        var customization = TableColumnCustomization<Container>()
        customization[visibility: "host"] = .hidden
        customization[visibility: "created"] = .hidden
        return customization
    }()
}
