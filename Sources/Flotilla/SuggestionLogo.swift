import SwiftUI

/// Decorative, verified library artwork. There is no file or network access in a gallery tile.
struct SuggestionLogo: View {
    let data: Data?
    let category: String?

    static let categorySymbols = [
        "Education": "graduationcap", "Business & Office": "briefcase",
        "Finance & Accounting": "banknote", "E-commerce": "cart",
        "Software Development": "chevron.left.forwardslash.chevron.right",
        "Databases": "externaldrive", "Data & Analytics": "chart.bar",
        "AI & Machine Learning": "brain", "Monitoring & Operations": "gauge.with.dots.needle.50percent",
        "Security & Identity": "lock.shield", "Networking & Web Servers": "network",
        "Content & Publishing": "doc.text", "Communication & Collaboration": "bubble.left.and.bubble.right",
        "Storage & Files": "folder", "Media & Photos": "photo", "Home & Personal": "house",
        "Science & Research": "atom", "Messaging & Queues": "tray.2",
    ]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let image = data.flatMap { NSImage(data: $0) }
        ZStack {
            // A logo sits on a light tile in both appearances: four official marks are dark with
            // no light version. `cream` is the palette's near-white; dark mode adds a hairline.
            if let image {
                RoundedRectangle(cornerRadius: 9).fill(Color(hex: ThemePalette.cream))
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                Image(systemName: Self.categorySymbols[category ?? ""] ?? "square.grid.2x2")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}
