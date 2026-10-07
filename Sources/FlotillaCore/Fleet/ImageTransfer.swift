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
}
