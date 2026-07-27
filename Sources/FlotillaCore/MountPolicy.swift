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
        let clean = roots.compactMap { root -> String? in
            guard root.hasPrefix("/") else { return nil }
            let parts = components(of: root)
            // Reject `.`/`..` rather than resolving them: a root is configuration, so a
            // malformed one is an operator mistake to surface, not something to guess at.
            guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            // `parts.isEmpty` catches "/", "//", "///" alike. Checking the *components*
            // rather than the string matters: `root != "/"` lets "//" through, and it then
            // normalises to "/" — a root of "/" permits the entire filesystem, which is
            // the precise opposite of what a permitted-roots list is for.
            guard !parts.isEmpty else { return nil }
            return "/" + parts.joined(separator: "/")
        }
        return MountPolicy(permittedRoots: clean, allowsAnyHostPath: false)
    }

    /// Whether `path` (an absolute host path) may be used as a bind-mount source.
    ///
    /// Containment is compared on **path-component boundaries**, so a permitted root of
    /// `/Users/shared` does not also permit `/Users/shared-secrets`.
    ///
    /// Both the candidate and the root are symlink-resolved first (see
    /// `resolvedComponents`), because lexical containment alone is defeated by a symlink
    /// placed inside a permitted root. That resolution is **best-effort, not a guarantee**:
    /// a link can be repointed between this check and the mount (TOCTOU), and a path that
    /// does not exist yet cannot be resolved at all. The runtime remains the last line of
    /// defence — this closes the easy case rather than claiming to close every case.
    ///
    /// Comparison is **case-sensitive** even though macOS volumes are usually
    /// case-insensitive. That fails *closed* (a differently-cased path is rejected, never
    /// wrongly accepted); matching case-insensitively would be unsafe on the case-sensitive
    /// volumes this may also run against. Configure roots in their real on-disk case.
    public func allowsHostPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let candidate = Self.components(of: path)
        // "/", "//" and friends have no components — never a valid mount source.
        guard !candidate.isEmpty else { return false }
        // This is `public`, so it must stand on its own: it cannot assume `Allowlist`
        // screened the caller. `/permitted/../outside` is lexically "under" /permitted
        // but resolves outside it, so refuse to answer rather than answer wrongly.
        // Rejecting (not resolving) keeps the function total and side-effect free.
        guard !candidate.contains(where: { $0 == "." || $0 == ".." }) else { return false }

        if allowsAnyHostPath { return true }
        guard !permittedRoots.isEmpty else { return false }

        // Lexical containment is not enough: a symlink *inside* a permitted root can point
        // anywhere, so `/permitted/escape/secret` can be textually contained while the
        // runtime mounts something outside. Resolve before comparing.
        //
        // This is best-effort, not a guarantee — the link can be repointed between this
        // check and the mount (TOCTOU), and resolution only means anything for paths that
        // already exist. It closes the easy case; the runtime remains the last line of
        // defence. Resolution is skipped when the path does not exist, so a mount source
        // created later is still judged lexically rather than being silently accepted.
        let effective = Self.resolvedComponents(of: path)
        if effective.contains(where: { $0 == "." || $0 == ".." }) { return false }
        return permittedRoots.contains { root in
            // Resolve the root the same way. Both sides must go through the identical
            // transform or they cannot be compared: on macOS `/tmp` is a symlink to
            // `/private/tmp`, so resolving only one side never matches.
            let rootParts = Self.resolvedComponents(of: root)
            guard rootParts.count <= effective.count else { return false }
            return Array(effective.prefix(rootParts.count)) == rootParts
        }
    }

    /// Components of `path` with symlinks resolved as far as the filesystem actually goes.
    ///
    /// A mount source often does not exist yet, and `resolvingSymlinksInPath()` on a
    /// non-existent path is a no-op — which would leave one side of the comparison
    /// resolved and the other literal. So resolve the deepest ancestor that *does* exist
    /// and keep the remainder verbatim. Both candidate and root go through this, so they
    /// are always compared in the same coordinate system.
    private static func resolvedComponents(of path: String) -> [String] {
        var head = components(of: path)
        var tail: [String] = []
        while !head.isEmpty {
            let prefix = "/" + head.joined(separator: "/")
            if FileManager.default.fileExists(atPath: prefix) {
                let real = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
                return components(of: real) + tail
            }
            tail.insert(head.removeLast(), at: 0)
        }
        return components(of: path)
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func normalise(_ path: String) -> String {
        "/" + components(of: path).joined(separator: "/")
    }
}
