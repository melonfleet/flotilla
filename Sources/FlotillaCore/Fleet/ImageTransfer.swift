import Foundation

/// Sending an image from the admin Mac to a host (PLAN.md Phase D, D2; research/WIRE-STREAMS-D2.md,
/// "After review" 4 and 8). The rules both ends apply before a byte moves.
public enum ImageTransfer {
    /// The oldest `container` a host may load a sent archive with: above both published advisories
    /// on `image load` (path traversal through 0.7.1, a symlinked blob read through 1.3.0).
    public static let minimumContainer = SoftwareVersion(major: 1, minor: 3, patch: 1)

    /// Whether a host running this `container` may receive an image. An unreadable version is a no:
    /// the floor exists because older loaders trust what is inside the archive.
    public static func hostCanLoad(containerVersion: String?) -> Bool {
        guard let containerVersion, let version = SoftwareVersion(containerVersion) else { return false }
        return version >= minimumContainer
    }

    /// The variant to save: `linux/arm64` when the image has one — every host is Apple silicon —
    /// otherwise `linux/amd64`, which `container` runs under Rosetta. `nil` when it has neither.
    public static func platform(for image: ContainerImage) -> String? {
        let platforms = (image.variants ?? []).compactMap(\.platform).filter { $0.os == "linux" }
        for architecture in ["arm64", "amd64"] where platforms.contains(where: { $0.architecture == architecture }) {
            return "linux/\(architecture)"
        }
        return nil
    }

    /// Whether `theirs` (a host's image of the same reference) already holds what a send of `mine`
    /// would deliver. The whole index matching says so; so does the sent variant's own digest,
    /// because a send carries one variant — the host's index then differs from this Mac's
    /// multi-platform one while holding exactly the same image (measured 7 October, grafana:13.2).
    public static func hostHasSame(_ mine: ContainerImage, as theirs: ContainerImage) -> Bool {
        if let digest = mine.configuration.descriptor?.digest, digest == theirs.configuration.descriptor?.digest {
            return true
        }
        guard let platform = platform(for: mine),
              let sent = variant(of: mine, platform: platform)?.digest else { return false }
        return variant(of: theirs, platform: platform)?.digest == sent
    }

    private static func variant(of image: ContainerImage, platform: String) -> ContainerImage.Variant? {
        let architecture = platform.split(separator: "/").last.map(String.init)
        return image.variants?.first { $0.platform?.os == "linux" && $0.platform?.architecture == architecture }
    }
}
