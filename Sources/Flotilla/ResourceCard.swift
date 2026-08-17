import SwiftUI

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
    let onOpen: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let onOpen {
                    Button(title, action: onOpen)
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .help(title)
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .help(title)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2).fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

/// The grid the three sections drop their cards into, so column widths and spacing match.
struct ResourceCardGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                content
            }
            .padding(12)
        }
    }
}
