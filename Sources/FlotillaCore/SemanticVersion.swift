import Foundation

/// A version number, parsed far enough to be ordered against another one.
///
/// This exists because "is this the latest?" is a comparison, and a string comparison gets it
/// wrong in the two cases that matter here: `1.0.10` sorts before `1.0.9`, and `1.0.0-beta.2`
/// sorts *after* `1.0.0` even though a pre-release precedes its own release. Both would be
/// answered confidently and wrongly by `<` on `String`.
///
/// Semver's ordering rules, and only the parts of them Flotilla can encounter: build metadata
/// (`+sha`) is ignored, as the spec says it must be, and a leading `v` is tolerated because
/// that is how the tags are written.
///
/// **A fourth component is accepted, and semver does not have one.** Flotilla's version is
/// `<container version>.<Flotilla revision>` — `1.4.1.0` means "verified against `container`
/// 1.4.1 with no Flotilla changes since", `1.4.1.1` is the first change on top of it
/// (`DECISIONS.md`, 2026-09-12). Apple's three components are Apple's to move; the fourth is
/// ours, so a release can say which runtime it was tested against *and* still leave room for the
/// changes that are ours alone — which is most of them.
///
/// The alternatives were rejected here rather than in prose: `1.4.1-flotilla.2` is a *pre-release*
/// to semver and sorts **before** `1.4.1`, so the update check would call a newer build older,
/// and `1.4.1+flotilla.2` is build metadata, which the spec excludes from ordering, so two
/// Flotilla builds would compare equal. A fourth integer orders correctly. Apple's own versions
/// simply have a revision of zero, which is the right answer for them.
///
/// In `FlotillaCore` rather than the app because it is pure, testable, and has nothing to do with
/// the network call that fetches the other side of the comparison — that stays in the app layer,
/// where the one place Flotilla ever reaches the network can be read in a single file.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Flotilla's own revision on top of the three components above. Zero for anything Apple
    /// released, and for a Flotilla build that needed no changes.
    public let revision: Int
    /// Dot-separated identifiers from `-beta.2`; empty for a release.
    public let prerelease: [String]

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        // Build metadata is explicitly not part of the ordering.
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }

        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            prerelease = rest[rest.index(after: dash)...].split(separator: ".").map(String.init)
            rest = rest[..<dash]
        }

        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(numbers.count) else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard let value = Int(number), value >= 0 else { return nil }
            parsed.append(value)
        }
        // `1.0` is a version people write; treat the missing components as zero rather than
        // refusing to compare at all.
        major = parsed[0]
        minor = parsed.count > 1 ? parsed[1] : 0
        patch = parsed.count > 2 ? parsed[2] : 0
        revision = parsed.count > 3 ? parsed[3] : 0
        self.prerelease = prerelease
    }

    /// Printed with the fourth component only when it is non-zero, so Apple's `1.4.1` reads as
    /// `1.4.1` rather than as `1.4.1.0` — the revision is Flotilla's, and naming it on a version
    /// that has none would be claiming something about a runtime that never said it.
    public var description: String {
        var core = "\(major).\(minor).\(patch)"
        if revision != 0 { core += ".\(revision)" }
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    /// The three components that came from `container`, without Flotilla's revision — what to
    /// compare against the installed runtime.
    public var runtimeComponents: SemanticVersion? {
        SemanticVersion("\(major).\(minor).\(patch)")
    }

    /// True for the `0.0.0` a build with no tag is stamped with — see `Scripts/make-app.sh`.
    /// Not a version anyone released, so nothing should be claimed by comparing against it.
    public var isUnreleased: Bool {
        major == 0 && minor == 0 && patch == 0 && revision == 0 && prerelease.isEmpty
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Flotilla's revision, ordered exactly where an admin would expect: 1.4.1 < 1.4.1.1.
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }

        // "A pre-release version has lower precedence than the associated normal version."
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false        // 1.0.0 > 1.0.0-beta.1
        case (false, true): return true         // 1.0.0-beta.1 < 1.0.0
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            // "Identifiers consisting of only digits are compared numerically." Which is the
            // whole reason this is not a string sort: beta.10 comes after beta.9.
            case let (l?, r?): return l < r
            // "Numeric identifiers always have lower precedence than non-numeric identifiers."
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        // "A larger set of pre-release fields has a higher precedence."
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
