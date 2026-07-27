import Foundation

/// Scrubs text on its way into a diagnostics snapshot or support bundle.
///
/// A support bundle is something the user hands to someone else, so the safe
/// direction here is over-redaction: a false positive costs a slightly less useful
/// bundle, a false negative leaks a token. Two consequences worth knowing:
/// container image digests (`sha256:` + 64 hex) are redacted along with certificate
/// fingerprints, because they are the same shape and we can't tell them apart, and
/// any 64-hex string anywhere goes too.
///
/// Pure Foundation (`NSRegularExpression`), so it runs and is tested on Linux.
public struct Redactor: Sendable {
    /// What was removed, so the placeholder says *why* rather than just `***`.
    public enum Category: String, Sendable {
        case certificate, token, secret, fingerprint, homePath, temporaryPath, email, credentials

        var placeholder: String { "<redacted:\(rawValue)>" }
    }

    private let rules: [Rule]

    struct Rule: Sendable {
        let category: Category
        let regex: NSRegularExpression
        let template: String
    }

    public static let standard = Redactor()

    public init() {
        self.rules = Redactor.standardRules
    }

    /// Order matters: multi-line PEM blocks first (so the inner base64 isn't nibbled
    /// by narrower rules), then specific token formats, then the generic
    /// `key = value` catch-all, then identifiers and paths.
    private static let standardRules: [Rule] = {
        func rule(_ category: Category, _ pattern: String, _ template: String? = nil,
                  options: NSRegularExpression.Options = [.caseInsensitive]) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                assertionFailure("Bad redaction pattern: \(pattern)")
                return nil
            }
            return Rule(category: category, regex: regex, template: template ?? category.placeholder)
        }

        let patterns: [Rule?] = [
            // Whole PEM blocks — private keys, certs, CSRs.
            rule(.certificate, "-----BEGIN[^-]*-----[\\s\\S]*?-----END[^-]*-----",
                 options: [.caseInsensitive]),
            // A BEGIN with no matching END (truncated log): drop the remainder.
            rule(.certificate, "-----BEGIN[^-]*-----[\\s\\S]*", options: [.caseInsensitive]),

            // Specific, unambiguous token formats.
            rule(.token, "\\bgh[pousr]_[A-Za-z0-9]{16,}", options: []),
            rule(.token, "\\bxox[abprs]-[A-Za-z0-9-]{10,}", options: []),
            rule(.token, "\\beyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]*", options: []),
            rule(.token, "\\bAKIA[0-9A-Z]{16}\\b", options: []),
            rule(.token, "\\bsk-[A-Za-z0-9_-]{16,}", options: []),
            rule(.token, "\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer \(Category.token.placeholder)"),

            // Generic `secret-ish key = value`, in JSON, plists, env dumps and prose.
            rule(.secret,
                 "(?i)\\b(pass(?:word|wd|phrase)?|secret|token|api[_-]?key|apikey|credential|private[_-]?key|authorization|auth)\\b([\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;}]+",
                 "$1$2\(Category.secret.placeholder)"),

            // Certificate fingerprints: colon-separated hex, or a bare 64-hex digest.
            rule(.fingerprint, "\\b(?:[0-9A-Fa-f]{2}:){15,}[0-9A-Fa-f]{2}\\b", options: []),
            rule(.fingerprint, "(?i)\\b(?:sha-?256[:=]\\s*)?[0-9A-Fa-f]{64}\\b"),

            // Credentials embedded in a URL.
            rule(.credentials, "://[^/\\s:@]+:[^/\\s@]+@", "://\(Category.credentials.placeholder)@"),

            // Absolute user paths — the username is PII and the path is machine-specific.
            rule(.temporaryPath, "(?:/private)?/var/folders/[^\\s\"',;)]*", options: []),
            rule(.homePath, "(?:/System/Volumes/Data)?/Users/[^/\\s\"',;)]+", "~", options: []),
            rule(.homePath, "/home/[^/\\s\"',;)]+", "~", options: []),

            rule(.email, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"),
        ]
        return patterns.compactMap(\.self)
    }()

    // MARK: - Applying

    public func redact(_ text: String) -> String {
        rules.reduce(text) { partial, rule in
            rule.regex.stringByReplacingMatches(
                in: partial,
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: rule.template
            )
        }
    }

    public func redact(_ value: SettingValue) -> SettingValue {
        switch value {
        case .string(let s): .string(redact(s))
        case .stringArray(let a): .stringArray(a.map(redact))
        case .bool, .int, .double: value
        }
    }

    /// Redacts a settings dump and drops keys declared sensitive outright — the
    /// allowlist and trust anchors never appear in a bundle at all, redacted or not.
    public func redactSettings(_ values: [String: SettingValue]) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for (name, value) in values {
            if SettingsRegistry.descriptor(named: name)?.isSensitive == true { continue }
            out[name] = redact(value)
        }
        return out
    }
}

// MARK: - Audit

/// The belt-and-braces check: after a bundle is assembled, every byte of it is
/// re-scanned for things that must never survive. `SupportBundleBuilder` refuses to
/// return a bundle that fails this, so a redaction gap becomes a build error rather
/// than a leak in a file someone emails.
public enum RedactionAudit {
    public struct Leak: Sendable, Equatable, CustomStringConvertible {
        public let category: Redactor.Category
        /// A short excerpt for the failure message. Truncated so the audit report
        /// isn't itself a leak.
        public let excerpt: String

        public var description: String { "\(category.rawValue): \(excerpt)" }
    }

    /// Patterns that indicate the redactor missed something. Deliberately a separate,
    /// simpler list from the redaction rules — an audit that reuses the rules it is
    /// checking can only ever agree with itself.
    private static let detectors: [(Redactor.Category, NSRegularExpression)] = {
        let specs: [(Redactor.Category, String)] = [
            (.certificate, "-----BEGIN"),
            (.token, "\\bgh[pousr]_[A-Za-z0-9]{16,}"),
            (.token, "\\bxox[abprs]-"),
            (.token, "\\beyJ[A-Za-z0-9_-]{4,}\\."),
            (.token, "\\bAKIA[0-9A-Z]{16}"),
            (.token, "\\bsk-[A-Za-z0-9_-]{16,}"),
            (.fingerprint, "(?:[0-9A-Fa-f]{2}:){15,}[0-9A-Fa-f]{2}"),
            (.fingerprint, "[0-9A-Fa-f]{64}"),
            (.homePath, "/Users/[^/\\s\"',;)]+"),
            (.homePath, "/home/[^/\\s\"',;)]+"),
            (.temporaryPath, "/var/folders/"),
            (.email, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"),
        ]
        return specs.compactMap { category, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (category, $0) }
        }
    }()

    public static func leaks(in text: String) -> [Leak] {
        var found: [Leak] = []
        let range = NSRange(text.startIndex..., in: text)
        for (category, regex) in detectors {
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                found.append(Leak(category: category, excerpt: String(text[r].prefix(12))))
            }
        }
        return found
    }

    public static func leaks(in data: Data) -> [Leak] {
        leaks(in: String(decoding: data, as: UTF8.self))
    }
}
