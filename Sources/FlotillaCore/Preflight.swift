import Foundation

/// Detects whether `container` is usable on this machine, per the checklist in
/// `research/FEATURES.md` §2.2: binary present → version → service status.
/// Returns `Models.swift`'s `PreflightResult` — shared with the diagnostics snapshot and,
/// eventually, the Wire layer.
///
/// **Not this file's job:** the guided install (needs user authorisation and the system
/// installer — the app owner's, macOS-only; see `DECISIONS.md` "never silent/privileged").
///
/// **Kernel detection is this file's job now** (5 October). The note here used to say there was
/// no CLI operation for it, which is still true — `system property list` prints the kernel
/// configuration whether or not a kernel exists — but the kernel is a file, and the file can be
/// checked without running anything. See `kernelPath(for:)`.
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
    /// Whether a file exists at a path, following symlinks. Injected for the same reason as
    /// `locate`: the kernel check must be testable on a machine with no `container`, and on Linux.
    private let fileExists: @Sendable (String) -> Bool

    public init(cli: ContainerCLI,
                minimumVersion: VersionTriple = Preflight.defaultMinimumVersion,
                locate: @escaping @Sendable (String) -> String? = { Preflight.locateBinary($0) },
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.cli = cli
        self.minimumVersion = minimumVersion
        self.locate = locate
        self.fileExists = fileExists
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
            return .unusable(reason: "could not read container system version: \(error)")
        }
        guard let component = versions.first(where: { $0.appName == "container" }) else {
            return .unusable(reason: "container system version did not report a container component")
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
            return .unusable(reason: "could not read container system status: \(error)")
        }
        // **Its own case, not `.unusable`.** "Installed but the service is stopped" is the
        // single commonest state after a reboot, it is one command from working, and the app can
        // fix it without the user typing anything — so the UI has to be able to tell it apart
        // from "unusable" rather than parse it out of an English sentence.
        guard status.isRunning else {
            return .serviceStopped(version: component.version, path: path, status: status.status)
        }
        // Running, and running the *wrong build*. See `SystemStatus.hasVersionSkew` — this is
        // what a `container` upgrade leaves behind until the service is restarted, and in that
        // state no container can start even though everything here says it should.
        if status.hasVersionSkew, let server = status.server {
            return .needsRestart(cli: component.version,
                                 service: SystemStatus.shortVersion(server.version),
                                 path: path)
        }

        // Running, the right build, and nothing to run containers *with*. Checked after the skew
        // because a restart is the cheaper repair and a skewed service may not answer for its
        // kernel honestly; once restarted, the next preflight gets here.
        if let expected = Self.kernelPath(for: status), !fileExists(expected) {
            return .needsKernel(version: component.version, path: path, expected: expected)
        }

        return .ok(version: component.version, path: path)
    }

    /// Where `container` keeps the kernel it boots containers and machines with, or `nil` when the
    /// status does not say enough to know.
    ///
    /// `<appRoot>/kernels/default.kernel-<arch>`: a symlink that `system kernel set` points at the
    /// kernel it installed (on this Mac, `vmlinux-6.18.35-197-debug` beside it). Measured on
    /// 1.5.0, 5 October. `fileExists` follows the link, so a link left pointing at a deleted kernel
    /// counts as no kernel, which is the truth.
    ///
    /// **`nil` means "do not judge"**, never "missing": a status without `appRoot` or an
    /// architecture (the flat stopped-service payload, or a future format) must not make Flotilla
    /// claim the kernel is gone and offer a download nobody needs.
    public static func kernelPath(for status: SystemStatus) -> String? {
        guard let root = status.appRoot, !root.isEmpty,
              let arch = status.host?.architecture, !arch.isEmpty else { return nil }
        let base = root.hasSuffix("/") ? root : root + "/"
        return base + "kernels/default.kernel-" + arch
    }

    /// Where `container` is installed, searched after `PATH`.
    ///
    /// Not a guess: `container system status` reports `installRoot /usr/local/`, and the binary
    /// on this machine is `/usr/local/bin/container`.
    public static let installDirectories = ["/usr/local/bin"]

    /// Resolves `binary` on `PATH` first, then in `installDirectories`.
    ///
    /// **The fallback is the whole point, and the old docstring here argued against it on a
    /// false premise.** It said that if a binary is not on `PATH` then `ContainerHost` could not
    /// run it either, so reporting it findable would mislead. That was true of the old
    /// `/usr/bin/env container` launch and is the reason both halves changed together: a
    /// GUI-launched app does **not** inherit a login shell's `PATH`. Flotilla launched from the
    /// Dock (or relaunched by macOS after a restart) gets exactly
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — measured with `ps eww` on the running process — which
    /// does not contain `/usr/local/bin`. So `container` was reported **not installed** on a
    /// machine where it was installed and running, and no amount of `container system start`
    /// could change that verdict. It only ever worked when launched from a terminal, which is
    /// how every one of my own screenshots had been taken.
    ///
    /// - Parameters:
    ///   - path: the `PATH` to search. `nil` reads the process environment; tests pass one in,
    ///     because a test that read the ambient `PATH` would carry this bug's own blind spot —
    ///     it would pass under `swift test` (a terminal's rich `PATH`) and prove nothing about
    ///     the environment the shipped app actually runs in.
    ///   - directories: where to look when `path` does not answer.
    public static func locateBinary(_ binary: String,
                                   path: String? = nil,
                                   directories: [String] = installDirectories) -> String? {
        if let onPath = locateOnPath(binary, path: path) { return onPath }
        for directory in directories {
            let candidate = "\(directory)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Every directory a lookup consults, for the "not installed" message. A diagnosis that names
    /// where it looked can be checked by the person reading it; "isn't installed" cannot.
    public static func searchedDirectories(path: String? = nil,
                                           directories: [String] = installDirectories) -> [String] {
        let pathVariable = path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let entries = pathVariable.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        // Deduplicated, so a `PATH` that already contains the install directory does not print it
        // twice in the message.
        return entries + directories.filter { !entries.contains($0) }
    }

    /// Searches `PATH` for an executable named `binary`, the way a shell would.
    public static func locateOnPath(_ binary: String, path: String? = nil) -> String? {
        guard let pathVariable = path ?? ProcessInfo.processInfo.environment["PATH"],
              !pathVariable.isEmpty else {
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
