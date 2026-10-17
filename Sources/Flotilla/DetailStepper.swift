import SwiftUI

/// ↑ ↓ through the list beside a page, and the expand button — in the same glass clusters as the
/// action buttons, at the header's trailing edge.
///
/// **Up and down since the split (Q58).** It was ‹ › while a page replaced its list, like Back and
/// Forward in Finder; with the list beside the page and running top to bottom, stepping is Mail's
/// previous and next message. It moves the **list's selection**, so the highlight, the page and the
/// stepper always agree on which item is showing.
///
/// One view for every page, including a form shown as one (a registry, a domain, a group): the
/// section puts a `PaneStep` on its page and every header asks for `DetailStepper()`.
///
/// Steps through the items **as currently shown** — same filter, same search, same sort — so a
/// step never lands on a row the list is hiding. Deliberately not wrapping at the ends: the buttons
/// disable instead. Wrapping from the last item back to the first, silently, is how you lose track
/// of where you are in a list you are stepping through one at a time.
///
/// The position ("3 of 12 containers") is the tooltip and the accessibility value rather than a
/// caption: it is reference information, and the header has no room to spare for it.
///
/// **⌘[ and ⌘] stay.** ⌘↑ and ⌘↓ were the obvious keys for a vertical list, and they clash: they are
/// the system's move-to-start and move-to-end in every text field, and a page is full of them — the
/// Logs filter, Inspect's search, the registry and domain forms — while a button's shortcut takes
/// the key before the field ever sees it. ⌘[ and ⌘] are taken by nothing on these pages, and still
/// read as back and forward through the list.
///
/// **The expand button** (Kamal: like the Claude desktop app's) widens the page over the list to the
/// whole content width, and back. While widened, ↑ ↓ still walk the list, so you can step through
/// items at full width — which is what the Terminal and Logs tabs want. In a window too narrow for
/// both panes it swaps them instead: see `SplitPanes`.
struct DetailStepper: View {
    @Environment(\.paneStep) private var step
    @Environment(\.paneLayout) private var layout

    var body: some View {
        HStack(spacing: 6) {
            if let step {
                // The same `ActionCluster` as the action buttons beside it — one glass shape,
                // height and padding in the header.
                ActionCluster {
                    IconActionButton(systemImage: "chevron.up", label: "Previous \(step.singular)",
                                     help: tip("Previous \(step.singular)", step),
                                     disabled: step.index == nil || step.index == 0,
                                     action: step.previous)
                        .keyboardShortcut("[", modifiers: .command)
                    IconActionButton(systemImage: "chevron.down", label: "Next \(step.singular)",
                                     help: tip("Next \(step.singular)", step),
                                     disabled: step.index == nil || step.index == step.count - 1,
                                     action: step.next)
                        .keyboardShortcut("]", modifiers: .command)
                }
                .help(position(step))
                .accessibilityElement(children: .contain)
                .accessibilityValue(position(step))
            }
            if let layout {
                ActionCluster {
                    IconActionButton(systemImage: layout.isFull ? "arrow.down.right.and.arrow.up.left"
                                                                : "arrow.up.left.and.arrow.down.right",
                                     label: label(layout), help: label(layout),
                                     active: layout.isFull && !layout.isCompact,
                                     action: layout.toggle)
                }
            }
        }
        .fixedSize()
    }

    private func label(_ layout: PaneLayout) -> String {
        if layout.isCompact { return "Show the list" }
        return layout.isFull ? "Show the list beside this page" : "Widen this page over the list"
    }

    private func tip(_ label: String, _ step: PaneStep) -> String {
        let position = position(step)
        return position.isEmpty ? label : "\(label) — \(position)"
    }

    private func position(_ step: PaneStep) -> String {
        guard let index = step.index else { return "" }
        return "\(index + 1) of \(step.count) \(step.count == 1 ? step.singular : step.plural)"
    }
}

extension View {
    /// Puts a page in its list: the stepper in its header walks `order`, by moving `selection`.
    ///
    /// `order` is the list as shown, `current` the item the page is showing.
    func paneStep<ID: Hashable>(_ singular: String, _ plural: String, order: [ID], current: ID?,
                                select: @escaping (ID) -> Void) -> some View {
        let index = current.flatMap { order.firstIndex(of: $0) }
        return environment(\.paneStep, PaneStep(
            singular: singular, plural: plural, index: index, count: order.count,
            previous: { if let index, index > 0 { select(order[index - 1]) } },
            next: { if let index, index < order.count - 1 { select(order[index + 1]) } }))
    }
}
