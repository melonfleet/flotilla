import SwiftUI
import FlotillaCore

/// Decorative, verified library artwork. There is no file or network access in a gallery tile.
struct SuggestionLogo: View {
    let data: Data?
    let category: String?
    var size: CGFloat = 44

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
                RoundedRectangle(cornerRadius: size * 9 / 44).fill(Color(hex: ThemePalette.cream))
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: size * 9 / 44).strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                Image(nsImage: image).resizable().scaledToFit().padding(size * 4 / 44)
            } else {
                RoundedRectangle(cornerRadius: size * 9 / 44).fill(.quaternary)
                Image(systemName: Self.categorySymbols[category ?? ""] ?? "square.grid.2x2")
                    .font(.system(size: size * 23 / 44)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 9 / 44))
        .accessibilityHidden(true)
    }
}

// Resolve artwork only from the updater's verified, in-memory PNGs.
extension AppModel {
    func libraryLogo(for image: String) -> Data? {
        suggestionLibrary.entry(forImage: image)?.icon.flatMap { libraryUpdater.icons[$0.sha256] }
    }

    func libraryLogo(for group: ContainerGroup) -> Data? {
        suggestionLibrary.entry(forGroup: group)?.icon.flatMap { libraryUpdater.icons[$0.sha256] }
    }

    func distributionLogo(for machine: ContainerMachine) -> Data? {
        Self.distributionLogo(for: machine, in: suggestionLibrary, icons: libraryUpdater.icons)
    }

    func registryLogo(for registry: RegistryRow) -> Data? {
        registryLogo(for: registry.id)
    }

    func registryLogo(for registry: KnownRegistry) -> Data? {
        registryLogo(for: registry.id)
    }

    func registryLogo(for host: String) -> Data? {
        Self.registryLogo(for: host, in: suggestionLibrary, icons: libraryUpdater.icons)
    }

    nonisolated static func distributionLogo(for machine: ContainerMachine,
                                             in library: SuggestionLibrary,
                                             icons: [String: Data]) -> Data? {
        if let distro = machine.distribution,
           let icon = library.artwork(for: distro.id)?.icon,
           let data = icons[icon.sha256] {
            return data
        }
        return library.artwork(for: LinuxDistribution.fallbackArtworkID)
            .flatMap { icons[$0.icon.sha256] }
    }

    nonisolated static func registryLogo(for host: String,
                                         in library: SuggestionLibrary,
                                         icons: [String: Data]) -> Data? {
        let normalised = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalised.isEmpty else { return nil }
        return library.artwork(for: "registry.\(normalised)")
            .flatMap { icons[$0.icon.sha256] }
    }
}
