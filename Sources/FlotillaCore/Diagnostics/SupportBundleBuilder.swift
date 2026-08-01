import Foundation

/// Schema version for the bundle's own inventory format, separate from
/// `DiagnosticsSchema.version` (the snapshot payload) so either can move alone.
public enum SupportBundleSchema {
    public static let version = 1
}

// MARK: - The bundle

/// One file in a support bundle, in memory.
///
/// `contents` is UTF-8 text in every case. That is a deliberate constraint rather
/// than an accident: `RedactionAudit` scans bytes as UTF-8, so anything opaque —
/// a zip, a plist, an image — would sail past the audit unread. If a future
/// payload cannot be represented as text, it does not belong in a bundle.
public struct SupportBundleFile: Sendable, Equatable, Identifiable {
    /// Relative file name. No directories: a flat bundle is one a user can read
    /// in the Finder column that the save panel drops it into.
    public let name: String
    public let contents: Data
    /// One line saying what this file is, shown next to it in the manifest preview.
    public let summary: String

    public var id: String { name }
    public var byteCount: Int { contents.count }

    public init(name: String, contents: Data, summary: String) {
        self.name = name
        self.contents = contents
        self.summary = summary
    }
}

/// What the user is about to send, listed before they send it.
///
/// The manifest is the feature, not the packaging: a bundle you cannot inspect is
/// one people either send blindly or never send at all. It carries a size and a
/// plain-language description per file, and nothing else — deliberately **no
/// checksums**, because a SHA-256 is 64 hex characters and `RedactionAudit` treats
/// any 64-hex run as a leaked fingerprint. An integrity digest would either trip
/// our own audit or force us to weaken it.
public struct SupportBundleManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let byteCount: Int
        public let summary: String

        public var id: String { name }

        public init(name: String, byteCount: Int, summary: String) {
            self.name = name
            self.byteCount = byteCount
            self.summary = summary
        }
    }

    public var schemaVersion: Int
    public var generatedAt: Date
    /// What the save panel should offer. Derived from the timestamp alone — no user
    /// name, host name, machine model or serial, because the file name is the one
    /// part of a bundle that gets read aloud, pasted into a ticket and indexed by
    /// whatever the recipient's mail host is.
    public var suggestedName: String
    /// Sorted by file name, so two bundles of the same state compare equal.
    public var entries: [Entry]

    public var totalByteCount: Int { entries.reduce(0) { $0 + $1.byteCount } }

    public init(
        schemaVersion: Int = SupportBundleSchema.version,
        generatedAt: Date,
        suggestedName: String,
        entries: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.suggestedName = suggestedName
        self.entries = entries
    }
}

/// A finished, audited support bundle: bytes plus an inventory of them.
///
/// Nothing here touches the filesystem. Choosing a path and writing is the app
/// layer's job — which is also what keeps the interesting half (assembly, redaction,
/// the audit) testable on Linux.
public struct SupportBundle: Sendable, Equatable {
    public let manifest: SupportBundleManifest
    /// Payload files, sorted by name to match `manifest.entries` element for element.
    public let files: [SupportBundleFile]
    /// The manifest rendered as JSON. The app writes this alongside `files` as
    /// `manifest.json`; it is not itself listed in `entries`, because an entry
    /// recording its own byte count cannot be written before it is written.
    public let manifestJSON: Data

    public static let manifestFileName = "manifest.json"

    public var totalByteCount: Int { files.reduce(0) { $0 + $1.byteCount } }

    public func file(named name: String) -> SupportBundleFile? {
        files.first { $0.name == name }
    }

    /// Every byte the app is about to write, including the manifest, keyed by the
    /// name to write it under. The whole bundle in one expression, for a UI that
    /// should not have to remember the manifest is a special case.
    public var contentsByFileName: [String: Data] {
        var out = [Self.manifestFileName: manifestJSON]
        for file in files { out[file.name] = file.contents }
        return out
    }
}

// MARK: - Settings with provenance

/// Effective settings *and where each value came from*.
///
/// The snapshot already carries values and the locked-key list; this adds the tier
/// that supplied each one, because "where did this value come from" is the question
/// a managed-Mac problem almost always turns on — a user swearing they never set
/// something, and a `defaults` seed three profiles deep that set it for them.
public struct SupportBundleSettings: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let value: SettingValue
        public let source: SettingSource

        public var id: String { name }

        public init(name: String, value: SettingValue, source: SettingSource) {
            self.name = name
            self.value = value
            self.source = source
        }
    }

    public var schemaVersion: Int
    /// Sorted by key name. Sensitive keys are absent entirely, not redacted — see
    /// `Redactor.redactSettings(_:)`.
    public var entries: [Entry]

    public init(schemaVersion: Int = SettingsSchema.version, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

// MARK: - Failure

/// Thrown when the final audit finds something that must never leave the machine.
///
/// The builder does **not** redact harder and continue. A builder that silently
/// fixes what it finds hides the gap that let it through, and the next field added
/// leaks again; a thrown error is a bug report about the redactor. The error names
/// the file and the category, and never quotes the matched text — an error message
/// that reproduces the token is the same leak by another route.
public struct SupportBundleLeakError: Error, Equatable, CustomStringConvertible {
    public struct Finding: Sendable, Equatable {
        public let file: String
        public let category: Redactor.Category
        public let occurrences: Int
    }

    /// Sorted by file, then category, so the message is stable.
    public let findings: [Finding]

    init(findings: [Finding]) {
        self.findings = findings.sorted {
            ($0.file, $0.category.rawValue) < ($1.file, $1.category.rawValue)
        }
    }

    /// Every category found, de-duplicated, sorted.
    public var categories: [Redactor.Category] {
        Array(Set(findings.map(\.category))).sorted { $0.rawValue < $1.rawValue }
    }

    public var description: String {
        let byFile = findings
            .map { "\($0.file): \($0.category.rawValue) ×\($0.occurrences)" }
            .joined(separator: ", ")
        return """
            Refusing to return a support bundle: the final redaction audit found \
            \(findings.reduce(0) { $0 + $1.occurrences }) item(s) that must not leave \
            this machine — \(byFile). This is a redaction gap, not a bundle to fix up: \
            narrow what goes into the bundle, or add a rule to Redactor.
            """
    }
}

// MARK: - The builder

/// Assembles a support bundle from a diagnostics snapshot, then refuses to return it
/// if a single byte fails `RedactionAudit`.
///
/// The audit is the point. `DiagnosticsSnapshot.capture(...)` already redacts on the
/// way in, but a snapshot can also be constructed by hand — the doc comment on
/// `capture` says so — and Phase 2 will add fields that nobody remembers to redact.
/// So everything is re-scanned at the end with a detector list that is deliberately
/// *simpler and separate* from the redaction rules, so it cannot merely agree with
/// itself.
///
/// Foundation only, no file writing, no upload, and no identifier that would let a
/// bundle be correlated with the machine that produced it.
public struct SupportBundleBuilder: Sendable {
    public static let snapshotFileName = "snapshot.json"
    public static let errorLogFileName = "errors.log"
    public static let settingsFileName = "settings.json"

    private let redactor: Redactor

    public init(redactor: Redactor = .standard) {
        self.redactor = redactor
    }

    // MARK: Building

    /// Capture and build in one call — the path the app should take, because it is
    /// the one that cannot skip `capture`'s redaction.
    public func build(
        at generatedAt: Date,
        app: DiagnosticsSnapshot.AppInfo,
        system: DiagnosticsSnapshot.SystemInfo,
        settings: SettingsStore,
        runtime: DiagnosticsSnapshot.RuntimeInfo? = nil,
        preflight: PreflightResult? = nil,
        hosts: [DiagnosticsSnapshot.HostSummary] = [],
        errorLog: ErrorLog? = nil
    ) throws -> SupportBundle {
        let snapshot = DiagnosticsSnapshot.capture(
            at: generatedAt, app: app, system: system, settings: settings,
            runtime: runtime, preflight: preflight, hosts: hosts, errorLog: errorLog,
            redactor: redactor
        )
        return try build(snapshot: snapshot, settings: settings)
    }

    /// Build from a snapshot that already exists.
    ///
    /// - Parameter settings: supplies the provenance for `settings.json`. Omit it and
    ///   the file is omitted too — the manifest lists what is there, never a
    ///   placeholder for what isn't.
    public func build(
        snapshot: DiagnosticsSnapshot,
        settings: SettingsStore? = nil
    ) throws -> SupportBundle {
        var files: [SupportBundleFile] = []

        files.append(SupportBundleFile(
            name: Self.snapshotFileName,
            contents: try Self.encoder.encode(snapshot),
            summary: """
                Flotilla and OS versions, `container` preflight, \
                \(snapshot.hosts.count) host(s), effective settings and \
                \(snapshot.recentErrors.count) recent error(s). Redacted on capture.
                """
        ))

        // Omitted when empty rather than written as an empty file: the manifest is an
        // inventory, and "no errors.log" reads as "nothing was recorded", which is
        // exactly what it means (diagnostics are opt-in, so an off switch means an
        // empty log).
        if !snapshot.recentErrors.isEmpty {
            files.append(SupportBundleFile(
                name: Self.errorLogFileName,
                contents: Data(Self.renderErrorLog(snapshot.recentErrors).utf8),
                summary: """
                    The \(snapshot.recentErrors.count) most recent recorded failure(s), \
                    oldest first. Messages redacted on capture.
                    """
            ))
        }

        if let settings {
            let provenance = settingsWithProvenance(settings)
            files.append(SupportBundleFile(
                name: Self.settingsFileName,
                contents: try Self.encoder.encode(provenance),
                summary: """
                    \(provenance.entries.count) non-secret setting(s) with the tier that \
                    supplied each value (locked / user / managed default / built-in). \
                    \(snapshot.lockedSettings.count) enforced by a configuration profile.
                    """
            ))
        }

        files.sort { $0.name < $1.name }

        let manifest = SupportBundleManifest(
            generatedAt: snapshot.generatedAt,
            suggestedName: Self.suggestedName(for: snapshot.generatedAt),
            entries: files.map {
                .init(name: $0.name, byteCount: $0.byteCount, summary: $0.summary)
            }
        )
        let manifestJSON = try Self.encoder.encode(manifest)

        try Self.audit(files: files, manifestJSON: manifestJSON)

        return SupportBundle(manifest: manifest, files: files, manifestJSON: manifestJSON)
    }

    // MARK: The audit

    /// Re-scan every byte, including the manifest — file names and the summaries we
    /// generate are text like any other, and a summary that interpolated a path would
    /// leak just as well as the file it describes.
    private static func audit(files: [SupportBundleFile], manifestJSON: Data) throws {
        var findings: [SupportBundleLeakError.Finding] = []

        func scan(_ data: Data, name: String) {
            let counts = RedactionAudit.leaks(in: data)
                .reduce(into: [Redactor.Category: Int]()) { $0[$1.category, default: 0] += 1 }
            for (category, count) in counts {
                findings.append(.init(file: name, category: category, occurrences: count))
            }
        }

        scan(manifestJSON, name: SupportBundle.manifestFileName)
        for file in files { scan(file.contents, name: file.name) }

        guard findings.isEmpty else { throw SupportBundleLeakError(findings: findings) }
    }

    // MARK: Rendering

    /// `settings.json`: effective value plus source, sensitive keys dropped by
    /// `redactSettings` and string values scrubbed. A bind mount typed into a
    /// settings field — `-v /Users/me/src:/src` — is a real way for a home path to
    /// reach a bundle through a *value* rather than a message, so values go through
    /// the redactor even though they are "ours".
    private func settingsWithProvenance(_ store: SettingsStore) -> SupportBundleSettings {
        let values = redactor.redactSettings(store.effectiveValues())
        let entries = values.keys.sorted().map { name in
            SupportBundleSettings.Entry(
                name: name,
                value: values[name]!,
                source: store.source(ofKeyNamed: name) ?? .builtIn
            )
        }
        return SupportBundleSettings(entries: entries)
    }

    /// One line per entry, oldest first, fixed-width enough to skim:
    /// `2026-08-01T12:00:00Z  ERROR     [cli] pull failed`.
    private static func renderErrorLog(_ entries: [ErrorLogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let width = ErrorLogEntry.Severity.allCases.map(\.rawValue.count).max() ?? 0
        return entries.map { entry in
            let severity = entry.severity.rawValue.uppercased()
                .padding(toLength: width, withPad: " ", startingAt: 0)
            let host = entry.hostID.map { " (host \($0))" } ?? ""
            return "\(formatter.string(from: entry.timestamp))  \(severity)  [\(entry.subsystem)]\(host) \(entry.message)"
        }.joined(separator: "\n") + "\n"
    }

    /// `Flotilla-Support-20260801T120000Z`. UTC so it does not disclose the machine's
    /// time zone, and extension-free because whether this becomes a folder or a zip
    /// is the app layer's decision.
    static func suggestedName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return "Flotilla-Support-\(formatter.string(from: date))"
    }

    /// Sorted keys so a bundle is byte-reproducible, and — the part that is not
    /// cosmetic — **`.withoutEscapingSlashes`**. Foundation escapes `/` as `\/` by
    /// default, which turns `/Users/mallory` into `\/Users\/mallory`; the audit's
    /// `/Users/…` and `/var/folders/…` detectors then match nothing and every path
    /// check silently passes. The audit can only see what the encoder writes plainly.
    ///
    /// Computed rather than stored for the same reason as `JSONDecoder.flotilla`:
    /// `JSONEncoder` is a non-`Sendable` class.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
