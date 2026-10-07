import Foundation

/// A version as Flotilla and `container` report one: `1.5.0`, `v1.4.1`, or Flotilla's own
/// `0.0.0 (304)`, where the bracketed build number tells two builds of one release apart.
public struct SoftwareVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int?

    public init(major: Int, minor: Int, patch: Int, build: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    /// `nil` for anything that does not start with a dotted number — "dev", an empty string.
    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("v") || rest.hasPrefix("V") { rest.removeFirst() }
        var build: Int?
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            build = Int(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // Drop a pre-release or metadata suffix: `1.5.0-rc1` compares as 1.5.0.
        let core = rest.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(major: major, minor: parts.count > 1 ? parts[1]! : 0,
                  patch: parts.count > 2 ? parts[2]! : 0, build: build)
    }

    public static func < (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build ?? 0) < (rhs.major, rhs.minor, rhs.patch, rhs.build ?? 0)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (build.map { " (\($0))" } ?? "")
    }
}

/// How far another Mac's software is from this Mac's (PLAN.md Phase C: show version skew before
/// an incompatible action is attempted).
///
/// The level is the largest part that differs. For `container` a minor or major difference is the
/// one that matters: Flotilla checks every command against this Mac's `container` — the Allowlist
/// is audited against its captured `--help` — and options come and go at minor releases (1.5.0
/// removed `k8s start`). A patch difference is reported but not warned about.
public struct VersionSkew: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable {
        case same, build, patch, minor, major
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let level: Level
    /// Whether the other Mac is behind this one. Meaningless when `level == .same`.
    public let otherIsOlder: Bool

    /// `nil` when either side is unknown or unreadable — nothing to say, rather than a guess.
    /// A build number is compared only when both sides carry one.
    public init?(this: String?, other: String?) {
        guard let this = this.flatMap(SoftwareVersion.init), let other = other.flatMap(SoftwareVersion.init)
        else { return nil }
        if this.major != other.major { level = .major }
        else if this.minor != other.minor { level = .minor }
        else if this.patch != other.patch { level = .patch }
        else if let a = this.build, let b = other.build, a != b { level = .build }
        else { level = .same }
        let comparableOther = SoftwareVersion(major: other.major, minor: other.minor, patch: other.patch,
                                              build: this.build == nil ? nil : other.build)
        let comparableThis = SoftwareVersion(major: this.major, minor: this.minor, patch: this.patch,
                                             build: other.build == nil ? nil : this.build)
        otherIsOlder = comparableOther < comparableThis
    }

    /// Whether `container` on the other Mac may refuse something this Mac's checks allow.
    public var mayRefuseCommands: Bool { level >= .minor }
}
