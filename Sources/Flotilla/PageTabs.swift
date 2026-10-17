import SwiftUI

/// The icon-only switcher every detail page wears, in a Liquid Glass pill centred under the header.
///
/// It replaced `DetailTabBar`, the underlined text strip. The glass is `ActionCluster`'s —
/// `GlassEffectContainer(spacing: 6)` and a plain `.regular` glass — in the window bar capsule's
/// shape, so it reads as the same chrome as the buttons at the top right. The selected tab is a
/// filled accent capsule inside the pill rather than more glass: glass goes on chrome only, never
/// on glass.
///
/// The tabs arrive as values rather than as a generic `CaseIterable` enum, because the thing
/// varying between screens is *which* tabs exist, not how they are drawn. Names are not drawn at
/// all: they are the tooltip and the VoiceOver label.
struct PageTabs<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let systemImage: String
        /// Draws a divider before this tab. The container and machine screens use it to fence
        /// off the tabs only one of them has, so the shared four always read as a set.
        var separatedFromPrevious = false

        var id: Tab { tab }
    }

    let items: [Item]
    @Binding var selection: Tab
    /// The pill's name for VoiceOver, e.g. "Container sections".
    var label = "Sections"
    /// ⌘1…⌘9 for the first nine tabs. Off by default: a page inside another page (the host's
    /// settings sources) would otherwise bind the same keys twice.
    var shortcuts = false

    @State private var hovered: Tab?

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if item.separatedFromPrevious {
                        Divider().frame(height: 16).padding(.horizontal, 3)
                    }
                    button(item, index: index)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .glassEffect(in: .capsule)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func button(_ item: Item, index: Int) -> some View {
        let selected = item.tab == selection
        let shortcut = shortcuts && index < 9 ? Character("\(index + 1)") : nil
        return Button { selection = item.tab } label: {
            Image(systemName: item.systemImage)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 26)
                .background {
                    if selected {
                        Capsule().fill(Theme.accent.opacity(0.25))
                    } else if hovered == item.tab {
                        Capsule().fill(.primary.opacity(0.08))
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = item.tab } else if hovered == item.tab { hovered = nil }
        }
        .help(shortcut.map { "\(item.title) (⌘\($0))" } ?? item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .background {
            // A hidden twin carries the shortcut, so the visible button keeps its plain style.
            if let shortcut {
                Button("") { selection = item.tab }
                    .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
                    .opacity(0).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }
}
