import SwiftUI

/// ‹ › through the list a detail page was opened from, in the same glass cluster as the action buttons, at the header's
/// trailing edge — like Back and Forward in Finder.
///
/// One view for all five detail pages; each used to carry its own copy with its own strings.
///
/// Steps through the items **as currently shown** — same filter, same search, same sort — so a
/// step never lands on a row the list is hiding.
///
/// Deliberately not wrapping at the ends: the buttons disable instead. Wrapping from the last
/// item back to the first, silently, is how you lose track of where you are in a list you are
/// stepping through one at a time.
///
/// The position ("3 of 12 containers") is the tooltip and the accessibility value rather than a
/// caption: it is reference information, and the header has no room to spare for it.
///
/// ⌘[ and ⌘] are Finder's Back and Forward. They live here, on the buttons, so every page has
/// them and they exist only while a detail page is on screen.
struct DetailStepper: View {
    /// "container" — used in "Previous container" and "3 of 12 containers".
    let singular: String
    let plural: String
    /// Position in the list as shown, or nil when the open item is not in it.
    let index: Int?
    let count: Int
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        // The same `ActionCluster` as the action buttons beside it — one glass shape, height and
        // padding in the header, not a rounded rectangle next to a capsule.
        ActionCluster {
            IconActionButton(systemImage: "chevron.left", label: "Previous \(singular)",
                             help: tip("Previous \(singular)"), disabled: index == nil || index == 0,
                             action: previous)
                .keyboardShortcut("[", modifiers: .command)
            IconActionButton(systemImage: "chevron.right", label: "Next \(singular)",
                             help: tip("Next \(singular)"), disabled: index == nil || index == count - 1,
                             action: next)
                .keyboardShortcut("]", modifiers: .command)
        }
        .fixedSize()
        .help(position)
        .accessibilityElement(children: .contain)
        .accessibilityValue(position)
    }

    private func tip(_ label: String) -> String {
        position.isEmpty ? label : "\(label) — \(position)"
    }

    private var position: String {
        guard let index else { return "" }
        return "\(index + 1) of \(count) \(count == 1 ? singular : plural)"
    }
}
