import Foundation

/// A portable settings file. Configure one Mac by hand, export, import on the other
/// seven — the workflow Rancher Desktop exposes as `rdctl create-profile
/// --from-settings`, and the realistic onboarding path for an 8-node fleet long
/// before Jamf is involved.
///
/// **Two hard rules, enforced here rather than left to the caller:**
/// sensitive keys (the peer allowlist, trust anchors) are never written, and no
/// private key material can appear because none is ever stored in the registry —
/// identities live in the Keychain and are referenced by label.
public struct SettingsExport: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var contents: Contents
    public var values: [String: SettingValue]

    public enum Contents: String, Codable, Sendable {
        /// Only what the user actually changed. Round-trips: importing this onto a
        /// fresh machine reproduces the same effective config.
        case userValues
        /// Every key with its effective value — a support/diff artefact, not
        /// something to re-import (it would pin every default forever).
        case effective
    }

    public init(schemaVersion: Int = SettingsSchema.version, contents: Contents, values: [String: SettingValue]) {
        self.schemaVersion = schemaVersion
        self.contents = contents
        self.values = values
    }
}

/// What happened to every key in an imported file. Import is never all-or-nothing
/// and never silent: an old export with a since-removed key should apply the rest
/// and tell you what it dropped.
public struct SettingsImportReport: Sendable, Equatable {
    public var applied: [String] = []
    public var unknown: [String] = []
    public var typeMismatched: [String] = []
    public var rejectedValues: [String] = []
    /// Present in the file but enforced by a profile — the file loses, by design.
    public var skippedLocked: [String] = []
    /// Sensitive keys are refused on the way in as well as on the way out, so a
    /// hand-edited export can't be used to inject a trust anchor.
    public var skippedSensitive: [String] = []
    /// The file's schema version, when it differs from ours.
    public var schemaVersionMismatch: Int?

    public var hasProblems: Bool {
        !unknown.isEmpty || !typeMismatched.isEmpty || !rejectedValues.isEmpty
            || !skippedLocked.isEmpty || !skippedSensitive.isEmpty || schemaVersionMismatch != nil
    }
}

extension SettingsStore {

    // MARK: - Export

    public func export(_ contents: SettingsExport.Contents = .userValues) -> SettingsExport {
        let source = switch contents {
        case .userValues: userValuesSnapshot()
        case .effective: effectiveValues()
        }
        var values: [String: SettingValue] = [:]
        for (name, value) in source {
            guard let descriptor = SettingsRegistry.descriptor(named: name) else { continue }
            guard !descriptor.isSensitive else { continue }
            values[name] = value
        }
        return SettingsExport(contents: contents, values: values)
    }

    public func exportJSON(_ contents: SettingsExport.Contents = .userValues) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export(contents))
    }

    /// Emit the current settings as a managed payload, ready to be turned into a
    /// `.mobileconfig` by the app layer. Everything lands in `defaults` (a seed the
    /// user may change); promoting keys to `locked` is a deliberate admin act, not
    /// something an export should decide.
    public func exportManagedPayload() -> ManagedPayload {
        let exported = export(.userValues)
        let manageable = exported.values.filter {
            SettingsRegistry.descriptor(named: $0.key)?.isManageable ?? false
        }
        return ManagedPayload(defaults: manageable)
    }

    // MARK: - Import

    @discardableResult
    public func `import`(_ export: SettingsExport) -> SettingsImportReport {
        var report = SettingsImportReport()
        if export.schemaVersion != SettingsSchema.version {
            report.schemaVersionMismatch = export.schemaVersion
        }
        // Sorted so the report — and the change notifications — are deterministic.
        for name in export.values.keys.sorted() {
            let value = export.values[name]!
            guard let descriptor = SettingsRegistry.descriptor(named: name) else {
                report.unknown.append(name)
                continue
            }
            guard !descriptor.isSensitive else {
                report.skippedSensitive.append(name)
                continue
            }
            do {
                try setRaw(value, forKeyNamed: name)
                report.applied.append(name)
            } catch SettingsError.typeMismatch {
                report.typeMismatched.append(name)
            } catch SettingsError.disallowedValue {
                report.rejectedValues.append(name)
            } catch SettingsError.locked {
                report.skippedLocked.append(name)
            } catch {
                report.unknown.append(name)
            }
        }
        return report
    }

    @discardableResult
    public func importJSON(_ data: Data) throws -> SettingsImportReport {
        `import`(try JSONDecoder().decode(SettingsExport.self, from: data))
    }
}
