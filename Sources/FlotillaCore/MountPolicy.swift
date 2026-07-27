import Foundation

/// Which host paths a bind mount may expose to a container.
///
/// Why this exists: the subcommand allowlist (`Allowlist`) validates the *shape* of a
/// command, but shape alone does not bound a bind mount. `--volume /Users:/host:ro`
/// is a perfectly well-formed mount spec that hands a container the owner's home
/// directories — SSH keys included. Over the wire that is arbitrary host file access,
/// i.e. exactly the "generic remote shell" outcome `DECISIONS.md` Q1 exists to prevent.
/// Found by an adversarial test before any of this shipped; see
/// `arbitraryHostBindMountCannotBypassTheRemoteExecutionBoundary`.
///
/// So mount *sources* are policy, not grammar. The policy is supplied by the side that
/// owns the filesystem — for a remote peer that is the **host**, never the client
/// (a client-supplied policy would be self-authorising and worthless). This is the
/// Phase 1 half of the host-side policy store that `DECISIONS.md` Q3 puts on the host.
///
/// Named volumes are always permitted: they are namespaced by the container runtime and
/// expose nothing of the host filesystem.
public struct MountPolicy: Sendable, Equatable {

    /// Absolute paths under which host bind mounts are permitted. Empty means no host
    /// path may be mounted at all.
    public let permittedRoots: [String]

    /// When true, any absolute path except `/` is accepted. Only appropriate when the
    /// caller already trusts the requester as much as it trusts itself — i.e. the local
    /// machine driving its own containers.
    public let allowsAnyHostPath: Bool

    private init(permittedRoots: [String], allowsAnyHostPath: Bool) {
        self.permittedRoots = permittedRoots
        self.allowsAnyHostPath = allowsAnyHostPath
    }

    /// **The default.** Named volumes only — no host path may be bind-mounted.
    /// Safe by default: a host that has expressed no policy grants no filesystem access.
    public static let denyHostPaths = MountPolicy(permittedRoots: [], allowsAnyHostPath: false)

    /// Any absolute host path except `/`. For **local** use only, where the requester is
    /// the machine owner. Must never be the policy applied to a remote peer's request.
    public static let unrestricted = MountPolicy(permittedRoots: [], allowsAnyHostPath: true)

    /// Permit host bind mounts only from within `roots` (and their subdirectories).
    /// Non-absolute or traversing roots are discarded rather than trusted.
    public static func roots(_ roots: [String]) -> MountPolicy {
        let clean = roots.filter { root in
            root.hasPrefix("/") && root != "/"
                && !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }.map(normalise)
        return MountPolicy(permittedRoots: clean, allowsAnyHostPath: false)
    }

    /// Whether `path` (an absolute host path) may be used as a bind-mount source.
    ///
    /// Containment is compared on **path-component boundaries**, so a permitted root of
    /// `/Users/shared` does not also permit `/Users/shared-secrets`. `Allowlist` has
    /// already rejected `.`/`..` components before this is reached, so no symlink-free
    /// canonicalisation is attempted here — resolving symlinks is the runtime's job at
    /// mount time, and doing it here would be a TOCTOU comfort blanket rather than a
    /// guarantee.
    public func allowsHostPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        if allowsAnyHostPath { return true }
        guard !permittedRoots.isEmpty else { return false }

        let candidate = Self.components(of: path)
        return permittedRoots.contains { root in
            let rootParts = Self.components(of: root)
            guard rootParts.count <= candidate.count else { return false }
            return Array(candidate.prefix(rootParts.count)) == rootParts
        }
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func normalise(_ path: String) -> String {
        "/" + components(of: path).joined(separator: "/")
    }
}
