import SwiftUI

/// The underline tab strip every detail screen wears.
///
/// Extracted for the reason `InspectPane` and `DetailCard` were: `ContainerDetailView` and
/// `MachineDetailView` each carried a copy, identical down to the 34pt height, the 11pt padding
/// and the 2pt underline inset, and the volume and network detail screens would have made four.
/// A strip that is retyped per screen is a strip that drifts per screen.
///
/// The tabs arrive as values rather than as a generic `CaseIterable` enum, because the thing
/// varying between screens is *which* tabs exist, not how they are drawn.
struct DetailTabBar<Tab: Hashable>: View {
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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                if item.separatedFromPrevious {
                    Divider().frame(height: 16).padding(.horizontal, 6)
                }
                let selected = item.tab == selection
                Button { selection = item.tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.systemImage).font(.system(size: 12))
                        Text(item.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(height: 34)
                    .padding(.horizontal, 11)
                    .overlay(alignment: .bottom) {
                        if selected {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.accent)
                                .frame(height: 2).padding(.horizontal, 8)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}
