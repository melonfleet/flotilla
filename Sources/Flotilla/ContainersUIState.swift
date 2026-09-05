import SwiftUI
import FlotillaCore

/// View state for the containers screen that must **survive navigating away and back**.
///
/// `NavigationSplitView`'s detail switches on the sidebar selection, so moving to Images and
/// returning destroys `ContainersView` and builds a new one. Anything held in its `@State`
/// resets — which silently threw away the user's column choices, sort order, filter tab and
/// search text every time they looked at another section.
///
/// The Docker Desktop study is what surfaced this: Docker shipped the same class of bug
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
    var filter: ContainersView.Filter = .all
    var search = ""

    /// Whether the recent-activity band at the bottom of the list is open. Here rather than in
    /// the view for the same reason everything else is: the section view is rebuilt on every
    /// sidebar change, so a collapse would silently undo itself.
    var activityExpanded = true

    /// **By name**, not running-first.
    ///
    /// This reverses the running-first default from `DECISIONS.md` Q2, at the owner's direction on
    /// 9 August. Q2's argument was that the containers you can act on should be at the top; the
    /// argument against it is that acting on one *moves it*, so the row you just clicked leaves
    /// the place you were looking. With a long list that turns every stop into a hunt.
    ///
    /// The state column remains sortable, so running-first is one click away. Q2's ordering of
    /// the table by relevance was a reasonable guess that using the thing disproved.
    /// Comparators over `ContainersView.ContainerRow`, not `Container` — the row carries the
    /// sampled CPU and memory figures, which is what makes those two columns sortable at all.
    var sortOrder = [KeyPathComparator(\ContainersView.ContainerRow.container.id)]

    /// Which columns are shown, in what order and at what width.
    ///
    /// Two hidden by default:
    /// - **Host**, because with a single host it prints "This Mac" on every row, and a column
    ///   identical in every row is pure width. The cross-host dimension stays in the data.
    /// - **Created**, so the identifier and the live figures get the space first.
    var columnCustomization: TableColumnCustomization<ContainersView.ContainerRow> = {
        var customization = TableColumnCustomization<ContainersView.ContainerRow>()
        customization[visibility: "host"] = .hidden
        customization[visibility: "created"] = .hidden
        return customization
    }()
}
