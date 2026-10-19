import Foundation

/// The report's `platform` section: what newer macOS releases fix, and what the kernel `container`
/// recommends fixes compared with an older one (follow-ups 2 and 5, Kamal, 19 October).
///
/// Built by `tools/platform_report.py` in the library repo, in the same signed daily report as the
/// image findings, from Apple's version feed (`gdmf.apple.com/v2/pmv`), Apple's security release
/// notes (`support.apple.com/100100`), apple/container's release source and OSV's Linux ecosystem.
/// **Optional and additive:** an app that predates it ignores the key, so `schema` stays 1.
///
/// Matching is local: `macOSAdvice(for:)` and `kernelAdvice(forRelease:)` take a host's version and
/// kernel release and read the report. Nothing about a host is sent anywhere, and nothing acts on
/// what this says. Structure is checked the way the rest of the report is (a bad section refuses the
/// whole file); the free text in it is cleaned by `displayText`. The caps are the builder's; change
/// both together (`test_caps_equal_the_apps` in the library repo reads them from this file).
extension VulnerabilityReport {
    public struct Platform: Codable, Sendable, Equatable {
        public static let maxReleases = 200
        public static let maxCVEsPerRelease = 1_000
        public static let maxExploitedPerRelease = 100
        public static let maxCurrentVersions = 20
        public static let maxKernels = 50
        public static let maxKernelTop = 5
        public static let maxVersion = 32

        public var macOS: MacOS?
        public var kernel: Kernel?

        public struct MacOS: Codable, Sendable, Equatable {
            /// When the sources were last read successfully; a day they couldn't be leaves this older.
            public var checked: String
            /// What Apple offers devices now, macOS 26 and later, newest first.
            public var current: [String]
            /// Every macOS 26 and later security release, newest first.
            public var releases: [Release]
        }

        public struct Release: Codable, Sendable, Equatable {
            public var version: String
            /// Apple's title, `macOS Tahoe 26.7.1`.
            public var name: String
            /// `YYYY-MM-DD`.
            public var released: String
            /// The CVEs its note lists; empty for a release Apple says has none.
            public var cves: [String]
            /// Those Apple says may have been exploited.
            public var exploited: [String]
        }

        public struct Kernel: Codable, Sendable, Equatable {
            public var checked: String
            /// The apple/container release whose recommendation this is.
            public var container: String
            public var recommended: Build
            /// Older kernels a `container` release recommended, and what the recommended one fixes in each.
            public var kernels: [Older]
        }

        public struct Build: Codable, Sendable, Equatable {
            /// `6.18.35`: what `uname -r` says in the VM.
            public var release: String
            /// `vmlinux-6.18.35-197-debug`: Kata's file name.
            public var binary: String
        }

        public struct Older: Codable, Sendable, Equatable {
            public var release: String
            public var binary: String
            /// CVEs scored 9.0 or more, and 7.0 to 8.9, that affect this kernel and not the recommended one.
            public var critical: Int
            public var high: Int
            /// The same, with no severity score yet: counted, never guessed at.
            public var unscored: Int
            /// The highest-scored few.
            public var top: [Issue]
            public var serious: Int { critical + high }
        }

        public struct Issue: Codable, Sendable, Equatable {
            public var id: String
            /// CVSS v3.1 base score.
            public var score: Double
            public var summary: String
        }
    }
}

// MARK: Checking

extension VulnerabilityReport.Platform {
    typealias R = VulnerabilityReport

    func problem() -> String? {
        if macOS == nil && kernel == nil { return "it is empty." }
        if let macOS, let why = macOS.problem() { return "macOS: \(why)" }
        if let kernel, let why = kernel.problem() { return "kernel: \(why)" }
        return nil
    }

    mutating func sanitiseFreeText() {
        if macOS != nil {
            for i in macOS!.releases.indices {
                macOS!.releases[i].name = R.displayText(macOS!.releases[i].name, required: true)
            }
        }
        if kernel != nil {
            for i in kernel!.kernels.indices {
                for j in kernel!.kernels[i].top.indices {
                    kernel!.kernels[i].top[j].summary = R.displayText(kernel!.kernels[i].top[j].summary)
                }
            }
        }
    }

    /// `26.0.1` as [26, 0, 1]; `26` as [26, 0, 0]. One to three groups of one to three digits.
    public static func macOSVersion(_ text: String) -> [Int]? {
        guard text.utf8.count <= maxVersion else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ (1...3).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    /// `6.18.35`, `6.19`, `6.19-rc1`: what a Kata kernel's release can be.
    public static func isKernelRelease(_ text: String) -> Bool {
        guard text.utf8.count <= maxVersion else { return false }
        var core = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            guard suffix.hasPrefix("rc"), (1...3).contains(suffix.dropFirst(2).count),
                  suffix.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
            core = text[..<dash]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let widths = [2, 3, 4, 4]
        guard (2...4).contains(parts.count) else { return false }
        for (index, part) in parts.enumerated() {
            guard (1...widths[index]).contains(part.utf8.count), part.utf8.allSatisfy({ (48...57).contains($0) }) else {
                return false
            }
        }
        return true
    }

    /// The release for a Kata kernel file name, by apple/container's own rule (its
    /// `TestCLIKernelSetSerial`): drop `vmlinux-`, then the first all-digit component after the
    /// release and everything past it. `vmlinux-6.18.35-197-debug` is `6.18.35`. The same rule as
    /// the builder's `kernel_release`, with the same examples in both test suites.
    public static func kernelRelease(fromBinary name: String) -> String? {
        guard isKernelBinary(name) else { return nil }
        var parts = name.dropFirst("vmlinux-".count).split(separator: "-", omittingEmptySubsequences: false)
        if let build = parts.indices.dropFirst().first(where: { index in
            !parts[index].isEmpty && parts[index].utf8.allSatisfy { (48...57).contains($0) }
        }) {
            parts = Array(parts[..<build])
        }
        let release = parts.joined(separator: "-")
        return isKernelRelease(release) ? release : nil
    }

    /// `vmlinux-` then a digit, then up to 119 of `A-Za-z0-9._-`.
    static func isKernelBinary(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard name.hasPrefix("vmlinux-"), (9...128).contains(bytes.count), (48...57).contains(bytes[8]) else { return false }
        return bytes.dropFirst(9).allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    /// `CVE-`, four digits, `-`, four to seven digits.
    public static func isCVE(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (13...16).contains(bytes.count), text.hasPrefix("CVE-"), bytes[8] == 45 else { return false }
        return bytes[4..<8].allSatisfy { (48...57).contains($0) } && bytes[9...].allSatisfy { (48...57).contains($0) }
    }

    /// `YYYY-MM-DD`, a real day.
    static func isDay(_ text: String) -> Bool {
        guard text.utf8.count == 10 else { return false }
        return R.date(text + "T00:00:00Z") != nil
    }

    /// `1.5.0`.
    static func isContainerVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) } }
    }
}

extension VulnerabilityReport.Platform.MacOS {
    func problem() -> String? {
        typealias P = VulnerabilityReport.Platform
        guard VulnerabilityReport.date(checked) != nil else { return "it has no valid date." }
        guard (1...P.maxCurrentVersions).contains(current.count), current.allSatisfy({ P.macOSVersion($0) != nil }),
              Set(current).count == current.count else { return "its current versions aren't valid." }
        guard releases.count <= P.maxReleases,
              Set(releases.compactMap { P.macOSVersion($0.version) }).count == releases.count else {
            return "its releases aren't valid."
        }
        for release in releases {
            guard P.macOSVersion(release.version) != nil, P.isDay(release.released),
                  VulnerabilityReport.isText(release.name, required: true) else { return "a release isn't described properly." }
            guard release.cves.count <= P.maxCVEsPerRelease, release.exploited.count <= P.maxExploitedPerRelease,
                  (release.cves + release.exploited).allSatisfy(P.isCVE), Set(release.cves).count == release.cves.count,
                  Set(release.exploited).isSubset(of: release.cves) else { return "a release's CVEs aren't valid." }
        }
        return nil
    }
}

extension VulnerabilityReport.Platform.Kernel {
    func problem() -> String? {
        typealias P = VulnerabilityReport.Platform
        guard VulnerabilityReport.date(checked) != nil, P.isContainerVersion(container) else {
            return "it has no valid date or release."
        }
        guard P.kernelRelease(fromBinary: recommended.binary) == recommended.release else {
            return "its recommended kernel isn't valid."
        }
        guard kernels.count <= P.maxKernels, Set(kernels.map(\.release)).count == kernels.count else {
            return "its kernels aren't valid."
        }
        for kernel in kernels {
            guard P.kernelRelease(fromBinary: kernel.binary) == kernel.release, kernel.release != recommended.release else {
                return "a kernel isn't described properly."
            }
            let range = 0...VulnerabilityReport.maxCount
            guard range.contains(kernel.critical), range.contains(kernel.high), range.contains(kernel.unscored) else {
                return "a kernel's counts aren't plausible."
            }
            guard kernel.top.count <= P.maxKernelTop,
                  kernel.top.allSatisfy({ P.isCVE($0.id) && (7.0...10.0).contains($0.score)
                                          && VulnerabilityReport.isText($0.summary) }) else {
                return "a kernel's issues aren't valid."
            }
            // The top few can't outnumber what the counts say exist.
            if kernel.top.filter({ $0.score >= 9.0 }).count > kernel.critical
                || kernel.top.filter({ $0.score < 9.0 }).count > kernel.high {
                return "a kernel lists more issues than it counts."
            }
        }
        return nil
    }
}

// MARK: Advice, matched on this Mac

/// What newer macOS releases fix for one installed version.
public struct MacOSAdvice: Sendable, Equatable {
    public var installed: String
    /// The newest release of the installed version's major, if it is newer than the installed one.
    public var newer: String?
    /// Distinct CVEs fixed by the releases after the installed one, and those of them exploited.
    public var fixes: Int
    public var exploited: Int
    /// The newest macOS of a later major, when there is one.
    public var nextMajor: String?
    /// When Apple's sources were last read (`checked`).
    public var asOf: Date?

    /// "26.7.1 fixes 312 security issues, 5 actively exploited." — the line the Updates tab shows.
    public var summary: String {
        guard let newer else { return "The newest release of macOS \(Self.major(installed))." }
        guard fixes > 0 else { return "\(newer) is available. Apple lists no security fixes in it." }
        var line = "\(newer) fixes \(fixes) security \(fixes == 1 ? "issue" : "issues")"
        if exploited > 0 { line += ", \(exploited) actively exploited" }
        return line + "."
    }

    static func major(_ version: String) -> String { String(version.split(separator: ".").first ?? "") }
}

/// What the recommended kernel fixes compared with one installed kernel.
public enum KernelAdvice: Sendable, Equatable {
    /// It runs the kernel `container` recommends.
    case recommended(VulnerabilityReport.Platform.Build)
    /// It runs an older recommended kernel.
    case older(VulnerabilityReport.Platform.Older, recommended: VulnerabilityReport.Platform.Build)
    /// A kernel the report says nothing about: set by hand, or older than `container` 1.0.
    case notCovered(release: String, recommended: VulnerabilityReport.Platform.Build)

    public var summary: String {
        switch self {
        case .recommended(let build):
            return "The kernel container recommends (\(build.release))."
        case .older(let kernel, let recommended):
            guard kernel.serious > 0 else {
                return "The recommended \(recommended.release) fixes no high-severity issue in \(kernel.release)."
            }
            var line = "The recommended \(recommended.release) fixes \(kernel.serious) high-severity "
                + "\(kernel.serious == 1 ? "issue" : "issues") in \(kernel.release)"
            if kernel.critical > 0 { line += " (\(kernel.critical) critical)" }
            return line + "."
        case .notCovered(let release, let recommended):
            return "The report doesn't cover kernel \(release). container recommends \(recommended.release)."
        }
    }
}

extension VulnerabilityReport.Platform {
    /// Advice for a Mac running `installed` (`26.0.1`), or nil when the report has no macOS section,
    /// the version can't be read, or the report has no release of its major (older than macOS 26).
    public func macOSAdvice(for installed: String) -> MacOSAdvice? {
        guard let macOS, let mine = Self.macOSVersion(installed) else { return nil }
        let line = macOS.releases.filter { Self.macOSVersion($0.version)?.first == mine[0] }
        let offered = macOS.current.filter { Self.macOSVersion($0)?.first == mine[0] }
        guard !line.isEmpty || !offered.isEmpty else { return nil }
        let isNewer = { (version: String) in Self.macOSVersion(version).map { mine.lexicographicallyPrecedes($0) } ?? false }
        let newerReleases = line.filter { isNewer($0.version) }
        let candidates = (newerReleases.map(\.version) + offered.filter(isNewer)).compactMap { v in Self.macOSVersion(v).map { (v, $0) } }
        let newest = candidates.max { $0.1.lexicographicallyPrecedes($1.1) }?.0
        let cves = Set(newerReleases.flatMap(\.cves))
        let exploited = Set(newerReleases.flatMap(\.exploited))
        let later = macOS.current.compactMap { v in Self.macOSVersion(v).map { (v, $0) } }.filter { $0.1[0] > mine[0] }
        return MacOSAdvice(installed: installed, newer: newest, fixes: cves.count, exploited: exploited.count,
                           nextMajor: later.max { $0.1.lexicographicallyPrecedes($1.1) }?.0,
                           asOf: VulnerabilityReport.date(macOS.checked))
    }

    /// Advice for a kernel release (`6.18.15`), or nil when the report has no kernel section or the
    /// release isn't one a kernel can have. An exact match only: no range is inferred.
    public func kernelAdvice(forRelease release: String) -> KernelAdvice? {
        guard let kernel, Self.isKernelRelease(release) else { return nil }
        if release == kernel.recommended.release { return .recommended(kernel.recommended) }
        if let older = kernel.kernels.first(where: { $0.release == release }) {
            return .older(older, recommended: kernel.recommended)
        }
        return .notCovered(release: release, recommended: kernel.recommended)
    }

    /// Said once wherever kernel advice is: why a kernel flaw is a container's problem, not the Mac's.
    public static let kernelScope = "Each container runs in its own small Linux VM with this kernel, "
        + "so a kernel flaw reaches that VM, not the Mac."

    /// Said under the counts: they are by version, and Kata's kernel is built without most drivers.
    public static let kernelCountsCaveat = "Counted by kernel version from OSV's Linux data. Kata's kernel "
        + "leaves out most drivers, so not every issue applies."
}
