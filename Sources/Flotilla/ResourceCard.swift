import SwiftUI
import FlotillaCore

/// The Cards presentation for Volumes, Networks and Images.
///
/// Deliberately a shared shell: title, an optional badge, a handful of label/value rows, and the
/// row's own action cluster. The three sections differ only in which values they pass, and a
/// card that is built per-section is a card that drifts per-section — which is how the container
/// cards once ended up offering fewer actions than the rows.
///
/// **Identical capabilities to the row.** The actions slot takes the same `rowActions` the table
/// renders, so switching presentation cannot change what you are able to do. That rule exists
/// because it was broken once: the Cards toggle silently cost you the Copy menu.
struct ResourceCard<Actions: View>: View {
    let title: String
    var badge: String?
    /// Label/value pairs, in display order. A nil value renders as an em dash rather than being
    /// dropped, so cards for two items of the same kind stay the same height and the same shape.
    let fields: [(String, String?)]
    /// The row's tags, drawn as pills under the title.
    ///
    /// **A pill, not a tinted card** — the owner's call, and `TagPill` records why: colouring the
    /// whole card would put an arbitrary hue behind a name, a badge and four values, so a card
    /// tagged "Production" would read as a card in trouble.
    ///
    /// Four rather than the table's two: a card has the width, and the row of pills is the one
    /// part of a card that is worth reading before the fields are.
    var tags: [Tag] = []
    /// Whether this section tags its rows at all. See the pill row below.
    var showsTags: Bool = true
    let onOpen: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // One line, truncated in the middle, and given way to before the badge. A title
                // that could wrap was squeezed to nothing by a long badge and wrapped a character
                // per line — the Images card that filled the window (5 October).
                Group {
                    if let onOpen {
                        Button(action: onOpen) {
                            Text(title).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                    } else {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .foregroundStyle(Theme.link)
                .help(title)
                .layoutPriority(1)
                if let badge {
                    // Not `fixedSize`: a badge is never allowed to be wider than the card. It
                    // truncates instead, and the tooltip has it whole.
                    Text(badge)
                        .font(.caption2)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 160, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(badge)
                }
                Spacer(minLength: 0)
            }

            // The pill row's space is kept when there are no tags, so every card in a section
            // has its fields on the same line. `showsTags` is false where a section has no tags
            // at all (Images), so they do not carry an empty band.
            if !tags.isEmpty {
                TagPillRow(tags: tags, limit: 4)
            } else if showsTags {
                TagPillRow(tags: [CardSurface.placeholderTag], limit: 1).hidden()
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    GridRow {
                        Text(field.0).font(.caption2).foregroundStyle(.tertiary)
                        Text(field.1 ?? "—")
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()
            actions
        }
        .cardSurface()
    }
}

/// **One card surface for the whole app** (the owner, 5 October: "we shouldn't have two card
/// views"). `ResourceCard`, `ContainerCard`, `GroupCard` and the machine card all draw through
/// this, so they cannot drift apart again — there had been three: white with a hairline here, a
/// soft tint on containers and groups, and a fainter tint on machines.
///
/// It also makes every card in a `ResourceCardGrid` **the same height**: each reports its natural
/// height, the grid takes the tallest, and hands it back as a minimum. Measured before that
/// minimum is applied, so there is no feedback between the two.
struct CardSurface: ViewModifier {
    @Environment(\.cardMinHeight) private var minHeight

    /// Stands in for a tag where a card has none, so the reserved row is exactly a pill tall.
    static let placeholderTag = Tag(id: "card.placeholder", name: "Tag", color: .grey)

    func body(content: Content) -> some View {
        content
            .padding(11)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
            })
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

extension View {
    /// The app's one card surface. See `CardSurface`.
    func cardSurface() -> some View { modifier(CardSurface()) }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension EnvironmentValues {
    /// The height every card in the current grid is given. 0 outside a grid.
    @Entry var cardMinHeight: CGFloat = 0
}

/// The grid every section drops its cards into, so column widths, spacing, alignment and height
/// match everywhere — Containers and Machines included, which had grids of their own.
struct ResourceCardGrid<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .onPreferenceChange(CardHeightKey.self) { tallest in
                if tallest > cardHeight { cardHeight = tallest }
            }
            .environment(\.cardMinHeight, cardHeight)
        }
    }
}
