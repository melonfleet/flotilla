import Foundation

/// Detects whether `container` is usable on this machine, per the checklist in
/// `research/FEATURES.md` §2.2: binary present → version → service status.
/// Returns `Models.swift`'s `PreflightResult` — shared with the diagnostics snapshot and,
/// eventually, the Wire layer.
///
/// **Not this file's job:** the guided install (needs user authorisation and the system
/// installer — the app owner's, macOS-only; see `DECISIONS.md` "never silent/privileged") and
/// kernel-install detection (no CLI operation for it yet).
public struct Preflight: Sendable {
    /// The version floor below which Flotilla will not consider `container` usable.
    /// `1.0.0` is the version every fixture in this repo was captured against.
    public static let defaultMinimumVersion = VersionTriple(1, 0, 0)

    private let cli: ContainerCLI
    private let minimumVersion: VersionTriple
    /// Resolves an executable's absolute path, or `nil` if it can't be found. Defaults to
    /// a real `PATH` search; tests inject a fake so this runs without a `container`
    /// install (or any install at all, on Linux).
    private let locate: @Sendable (String) -> String?

    public init(cli: ContainerCLI,
                minimumVersion: VersionTriple = Preflight.defaultMinimumVersion,
                locate: @escaping @Sendable (String) -> String? = Preflight.locateOnPath) {
        self.cli = cli
        self.minimumVersion = minimumVersion
        self.locate = locate
    }

    /// Runs the checklist once. Synchronous and side-effect-free beyond the `container`
    /// invocations `cli` itself makes — safe to call from onboarding, a settings pane's
    /// "Re-run" button, or the diagnostics snapshot alike.
    public func run() -> PreflightResult {
        guard let path = locate("container") else { return .missing }

        let versions: [VersionComponent]
        do {
            versions = try cli.versions()
        } catch {
            return .unusable(reason: "could not read `container system version`: \(error)")
        }
        guard let component = versions.first(where: { $0.appName == "container" }) else {
            return .unusable(reason: "`container system version` did not report a `container` component")
        }
        guard let found = VersionTriple(parsing: component.version) else {
            return .unusable(reason: "could not parse version '\(component.version)'")
        }
        // A prerelease of the minimum's own version does not satisfy it — only a
        // strictly newer core, or an exact release-grade match, does.
        let meetsMinimum = found > minimumVersion || (found == minimumVersion && !found.isPrerelease)
        guard meetsMinimum else {
            return .tooOld(found: component.version, required: minimumVersion.description)
        }

        let status: SystemStatus
        do {
            status = try cli.systemStatus()
        } catch {
            return .unusable(reason: "could not read `container system status`: \(error)")
        }
        guard status.isRunning else {
            return .unusable(reason: "the container system service is not running (status: \(status.status))")
        }

        return .ok(version: component.version, path: path)
    }

    /// Searches `PATH` for an executable named `binary`, the way a shell would.
    /// Deliberately does not fall back to hardcoded install locations
    /// (`reference/container-cli.md` names `/usr/local/bin`): if it isn't on `PATH`,
    /// `ContainerHost` (which shells out via `/usr/bin/env`) couldn't run it either, so
    /// reporting it findable would be misleading.
    public static func locateOnPath(_ binary: String) -> String? {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"], !pathVariable.isEmpty else {
            return nil
        }
        for directory in pathVariable.split(separator: ":") {
            guard !directory.isEmpty else { continue }
            let candidate = "\(directory)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// A bare `major.minor.patch`, parsed leniently from whatever `container system version`
/// reports (a pre-release suffix like `-beta.1` is tolerated and ignored for comparison).
/// Kept separate from `String` so "is this new enough" is a real comparison, not a
/// lexicographic one — `"1.9.0" < "1.10.0"` is false as strings, true as versions.
public struct VersionTriple: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Whether the parsed string carried a `-prerelease` suffix (as opposed to only
    /// `+build` metadata, which does not affect precedence). Not part of `==`/`<` —
    /// those compare the numeric core only, matching this type's existing semantics —
    /// but `Preflight.run()` consults it so a prerelease never satisfies the exact
    /// release it is a prerelease of.
    public let isPrerelease: Bool

    public init(_ major: Int, _ minor: Int, _ patch: Int, isPrerelease: Bool = false) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = isPrerelease
    }

    /// Parses a strict `<int>.<int>.<int>` core, optionally followed by a
    /// `-prerelease` and/or `+build` suffix (semver §9/§10). `nil` if the core is not
    /// exactly three non-negative integer components — a malformed core is never
    /// papered over by a suffix.
    public init?(parsing string: String) {
        let suffixStart = string.firstIndex(where: { $0 == "-" || $0 == "+" })
        let core = suffixStart.map { string[string.startIndex..<$0] } ?? Substring(string)
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isPrerelease = suffixStart.map { string[$0] == "-" } ?? false
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func == (lhs: VersionTriple, rhs: VersionTriple) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public static func < (lhs: VersionTriple, rhs: VersionTriple) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
