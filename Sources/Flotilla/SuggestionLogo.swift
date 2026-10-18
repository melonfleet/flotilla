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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.quaternary)
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: Self.categorySymbols[category ?? ""] ?? "square.grid.2x2")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}
