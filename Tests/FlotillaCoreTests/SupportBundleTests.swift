import Foundation
import Testing
@testable import FlotillaCore

// A support bundle is the one artefact Flotilla produces that is *meant* to leave the
// machine, so these tests are written the way `MountPolicyTests` are: assume the
// person supplying the inputs is hostile, plant real secrets in every field that
// reaches the bundle, and assert the literal bytes are gone from the finished
// product — not merely "transformed somehow".

// MARK: - Planted material
//
// One place, so a test can assert *every* item is absent from *every* file rather
// than each test remembering its own list.

private enum Planted {
    static let githubToken = "ghp_1234567890abcdef1234ABCD"
    static let awsKey = "AKIAIOSFODNN7EXAMPLE"
    static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    static let pemBody = "MIIEpAIBAAKCAQEA1234567890abcdefghijklmnop"
    static let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        \(pemBody)
        -----END RSA PRIVATE KEY-----
        """
    static let fingerprint = String(repeating: "ab", count: 32)  // 64 hex
    static let email = "someonedev@outlook.com"
    static let homePath = "/Users/mallory/Projects/flotilla"
    static let linuxHomePath = "/home/mallory/.ssh"
    static let temporaryPath = "/private/var/folders/zz/abcdef1234/T/flotilla-tmp.json"

    /// The exact strings that must not survive anywhere in the finished bundle.
    static let all = [
        githubToken, awsKey, jwt, pemBody, fingerprint, email,
        homePath, linuxHomePath, temporaryPath, "mallory",
    ]
}

/// A store whose *values* carry planted material — the `-v /Users/me/src:/src`
/// route, where a secret reaches a bundle through a setting rather than a message.
private func poisonedStore() throws -> SettingsStore {
    let managed = StaticManagedPreferences(
        defaults: [SettingsKeys.pollIntervalSeconds.name: .int(30)],
        locked: [SettingsKeys.hostListenPort.name: .int(9443)]
    )
    let store = SettingsStore(managed: managed)
    try store.set("\(Planted.homePath)/bin/container", for: SettingsKeys.containerBinaryPath)
    try store.set("registry.\(Planted.email)", for: SettingsKeys.defaultRegistryDomain)
    try store.set(Planted.fingerprint, for: SettingsKeys.identityKeychainLabel)
    // Sensitive keys: must be absent from the bundle entirely, not redacted.
    try store.set([Planted.fingerprint], for: SettingsKeys.peerAllowlist)
    try store.set([Planted.githubToken], for: SettingsKeys.trustAnchorFingerprints)
    return store
}

private func poisonedErrorLog() -> ErrorLog {
    let log = ErrorLog(capacity: 10)
    log.record(
        .warning, subsystem: "cli",
        message: "run failed: -v \(Planted.homePath)/src:/src",
        at: Date(timeIntervalSince1970: 10)
    )
    log.record(
        .error, subsystem: Planted.linuxHomePath,
        message: "pull rejected: Authorization: Bearer \(Planted.githubToken)",
        hostID: "host-1", at: Date(timeIntervalSince1970: 20)
    )
    log.record(
        .critical, subsystem: "transport",
        message: "handshake failed for \(Planted.fingerprint); token \(Planted.jwt)",
        at: Date(timeIntervalSince1970: 30)
    )
    log.record(
        .error, subsystem: "settings",
        message: "AWS_ACCESS_KEY_ID=\(Planted.awsKey) read from \(Planted.temporaryPath)",
        at: Date(timeIntervalSince1970: 40)
    )
    log.record(
        .error, subsystem: "identity",
        message: "unexpected key material in profile:\n\(Planted.pem)",
        at: Date(timeIntervalSince1970: 50)
    )
    return log
}

private let referenceDate = Date(timeIntervalSince1970: 1_785_000_000)  // 2026-07-25T17:20:00Z

private func poisonedBundle() throws -> SupportBundle {
    try SupportBundleBuilder().build(
        at: referenceDate,
        app: .init(version: "1.0.0", build: "42", mode: .client, isManaged: true),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64", modelIdentifier: "Mac14,6"),
        settings: try poisonedStore(),
        runtime: .init(cliVersion: "0.5.0 (\(Planted.homePath)/bin/container)", apiServerVersion: "0.5.0"),
        preflight: .unusable(reason: "socket \(Planted.temporaryPath) unreachable, contact \(Planted.email)"),
        hosts: [.init(id: "host-1", kind: .remote, isReachable: false)],
        errorLog: poisonedErrorLog()
    )
}

// MARK: - The adversarial pass: nothing planted survives

@Test func noPlantedSecretOrPathSurvivesAnywhereInTheBundle() throws {
    let bundle = try poisonedBundle()

    let everything = bundle.contentsByFileName
    #expect(everything.count == 4)  // manifest + snapshot + errors + settings

    for (name, data) in everything {
        let text = String(decoding: data, as: UTF8.self)
        for secret in Planted.all {
            #expect(!text.contains(secret), "\(name) still contains planted material")
        }
        #expect(RedactionAudit.leaks(in: data).isEmpty, "\(name) fails the redaction audit")
    }

    // And once more over the whole thing concatenated, in case a value were split
    // across two files in a way each file alone tolerates.
    let joined = everything.values
        .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    #expect(RedactionAudit.leaks(in: joined).isEmpty)
}

@Test func sensitiveSettingsAreAbsentFromTheBundleRatherThanRedactedInIt() throws {
    let bundle = try poisonedBundle()
    let settings = try #require(bundle.file(named: SupportBundleBuilder.settingsFileName))
    let decoded = try JSONDecoder().decode(SupportBundleSettings.self, from: settings.contents)
    let names = decoded.entries.map(\.name)

    #expect(!names.contains(SettingsKeys.peerAllowlist.name))
    #expect(!names.contains(SettingsKeys.trustAnchorFingerprints.name))
    // Not even a redaction placeholder for them: the key list is itself the secret.
    #expect(!String(decoding: settings.contents, as: UTF8.self).contains("peerAllowlist"))
}

@Test func absoluteUserPathsInSettingsValuesAreReducedToTilde() throws {
    let bundle = try poisonedBundle()
    let settings = try #require(bundle.file(named: SupportBundleBuilder.settingsFileName))
    let decoded = try JSONDecoder().decode(SupportBundleSettings.self, from: settings.contents)
    let binaryPath = try #require(decoded.entries.first { $0.name == SettingsKeys.containerBinaryPath.name })

    #expect(binaryPath.value == .string("~/Projects/flotilla/bin/container"))
    #expect(binaryPath.source == .user)
}

// MARK: - The audit refuses rather than repairs

@Test func buildingFromAHandConstructedLeakingSnapshotThrows() {
    // `capture` redacts on the way in; a snapshot built by hand does not. That hole is
    // exactly what the final audit exists to cover.
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        recentErrors: [.init(
            timestamp: referenceDate, severity: .error, subsystem: "cli",
            message: "token \(Planted.githubToken)"
        )]
    )

    #expect(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }
}

@Test func theThrownErrorNamesEveryCategoryAndFileButNeverQuotesTheSecret() throws {
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0 built at \(Planted.homePath)", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        recentErrors: [.init(
            timestamp: referenceDate, severity: .error, subsystem: "cli",
            message: "key \(Planted.awsKey) mailed to \(Planted.email)"
        )]
    )

    let error = try #require(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }

    #expect(error.categories.contains(.homePath))
    #expect(error.categories.contains(.token))
    #expect(error.categories.contains(.email))
    // Both files that carry it are named, not just the first one found.
    let files = Set(error.findings.map(\.file))
    #expect(files.contains(SupportBundleBuilder.snapshotFileName))
    #expect(files.contains(SupportBundleBuilder.errorLogFileName))

    // The message is a bug report, not a second copy of the leak.
    for secret in [Planted.awsKey, Planted.email, Planted.homePath] {
        #expect(!error.description.contains(secret))
    }
    #expect(error.description.contains("homePath"))
}

@Test func theAuditSeesPathsBecauseTheEncoderDoesNotEscapeSlashes() throws {
    // Regression test for a defect that would make every path assertion above
    // vacuous: Foundation escapes `/` as `\/` by default, so `/Users/mallory` is
    // written `\/Users\/mallory` and the audit's `/Users/…` detector matches nothing.
    // A leaking snapshot must therefore still throw…
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: [SettingsKeys.containerBinaryPath.name: .string("\(Planted.homePath)/bin/container")]
    )
    let error = try #require(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }
    #expect(error.categories == [.homePath])

    // …and the encoder must be the reason it can: assert the escaping directly, so
    // the diagnosis survives even if someone changes the detector.
    let encoded = SupportBundleBuilder.encoder
    let json = String(decoding: try encoded.encode(snapshot), as: UTF8.self)
    #expect(json.contains("/Users/mallory"))
    #expect(!json.contains("\\/Users"))
}

@Test func aTemporaryDirectoryPathInAHandBuiltSnapshotIsCaught() throws {
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        preflight: .unusable(reason: "scratch file \(Planted.temporaryPath)")
    )
    let error = try #require(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }
    #expect(error.categories == [.temporaryPath])
}

@Test func aPEMBlockInAHandBuiltSnapshotIsCaught() throws {
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        hosts: [.init(id: "host-1", kind: .remote, isReachable: true, containerVersion: Planted.pem)]
    )
    let error = try #require(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }
    #expect(error.categories.contains(.certificate))
}

@Test func aFingerprintInAHandBuiltSnapshotIsCaught() throws {
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64", modelIdentifier: Planted.fingerprint)
    )
    let error = try #require(throws: SupportBundleLeakError.self) {
        try SupportBundleBuilder().build(snapshot: snapshot)
    }
    #expect(error.categories == [.fingerprint])
}

@Test func theBuilderDoesNotSilentlyRepairALeakAndReturnABundle() throws {
    // The refusal must be a refusal. If a future change "redacts harder and
    // continues", this test fails rather than the gap going quiet.
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        recentErrors: [.init(
            timestamp: referenceDate, severity: .error, subsystem: "cli", message: Planted.awsKey
        )]
    )
    var built: SupportBundle?
    #expect(throws: SupportBundleLeakError.self) {
        built = try SupportBundleBuilder().build(snapshot: snapshot)
    }
    #expect(built == nil)
}

// MARK: - The manifest is the preview: it must be exactly true

@Test func theManifestListsEveryFilePresentAndNothingElse() throws {
    let bundle = try poisonedBundle()
    #expect(bundle.manifest.entries.map(\.name) == bundle.files.map(\.name))
    #expect(bundle.manifest.entries.map(\.name) == ["errors.log", "settings.json", "snapshot.json"])
}

@Test func manifestEntrySizesAreTheActualFileSizes() throws {
    let bundle = try poisonedBundle()
    for entry in bundle.manifest.entries {
        let file = try #require(bundle.file(named: entry.name))
        #expect(entry.byteCount == file.contents.count)
        #expect(entry.byteCount > 0)
    }
    #expect(bundle.manifest.totalByteCount == bundle.totalByteCount)
}

@Test func everyManifestEntryCarriesANonEmptyDescriptionOfWhatTheFileIs() throws {
    let bundle = try poisonedBundle()
    for entry in bundle.manifest.entries {
        #expect(!entry.summary.isEmpty)
        #expect(entry.summary == bundle.file(named: entry.name)?.summary)
    }
    // The summaries are what makes the preview readable, so they say something
    // specific rather than repeating the file name.
    let errors = try #require(bundle.manifest.entries.first { $0.name == "errors.log" })
    #expect(errors.summary.contains("5"))
}

@Test func anEmptyErrorLogOmitsTheFileRatherThanListingAnEmptyOne() throws {
    let store = SettingsStore()
    let bundle = try SupportBundleBuilder().build(
        at: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: store,
        errorLog: ErrorLog(capacity: 10)
    )
    #expect(bundle.file(named: SupportBundleBuilder.errorLogFileName) == nil)
    #expect(!bundle.manifest.entries.contains { $0.name == SupportBundleBuilder.errorLogFileName })
    #expect(bundle.manifest.entries.map(\.name) == ["settings.json", "snapshot.json"])
}

@Test func omittingTheSettingsStoreOmitsTheSettingsFileFromBothBundleAndManifest() throws {
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64")
    )
    let bundle = try SupportBundleBuilder().build(snapshot: snapshot)
    #expect(bundle.manifest.entries.map(\.name) == ["snapshot.json"])
    #expect(bundle.file(named: SupportBundleBuilder.settingsFileName) == nil)
}

@Test func theManifestIsNotListedInItselfButIsStillWrittenByContentsByFileName() throws {
    let bundle = try poisonedBundle()
    #expect(!bundle.manifest.entries.contains { $0.name == SupportBundle.manifestFileName })
    #expect(bundle.contentsByFileName[SupportBundle.manifestFileName] == bundle.manifestJSON)
}

@Test func theManifestRoundTripsThroughJSONWithTheShapeTheUIWillRead() throws {
    let bundle = try poisonedBundle()
    let decoded = try JSONDecoder.iso8601.decode(SupportBundleManifest.self, from: bundle.manifestJSON)
    #expect(decoded == bundle.manifest)

    let text = String(decoding: bundle.manifestJSON, as: UTF8.self)
    for key in ["schemaVersion", "generatedAt", "suggestedName", "entries", "byteCount", "summary"] {
        #expect(text.contains("\"\(key)\""))
    }
    #expect(decoded.schemaVersion == SupportBundleSchema.version)
}

@Test func theSuggestedNameIsUTCTimestampedAndCarriesNoUserOrMachineIdentity() throws {
    let bundle = try poisonedBundle()
    #expect(bundle.manifest.suggestedName == "Flotilla-Support-20260725T172000Z")
    // No extension: whether this becomes a folder or a zip is the app layer's call.
    #expect(!bundle.manifest.suggestedName.contains("."))
    #expect(RedactionAudit.leaks(in: bundle.manifest.suggestedName).isEmpty)
}

@Test func twoBundlesBuiltFromOneSnapshotAreByteIdentical() throws {
    // Sorted keys and no wall-clock reads inside the builder, so a bundle is a pure
    // function of its snapshot — which is what makes "diff the bundle the user sent
    // last week against today's" a usable support technique.
    let snapshot = DiagnosticsSnapshot(
        generatedAt: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64")
    )
    let store = try poisonedStore()
    let first = try SupportBundleBuilder().build(snapshot: snapshot, settings: store)
    let second = try SupportBundleBuilder().build(snapshot: snapshot, settings: store)
    #expect(first.manifestJSON == second.manifestJSON)
    #expect(first.files == second.files)
}

@Test func twoCapturesOfTheSameStateDifferOnlyByTheirPerEntryErrorIDs() throws {
    // `ErrorLogEntry.id` is a fresh UUID per capture, so `snapshot.json` is not
    // byte-stable across captures. That is not a leak — the UUID is random, unstable
    // and correlates with nothing — but it is worth pinning, because it means the
    // *shape* is reproducible while the bytes are not.
    let first = try poisonedBundle()
    let second = try poisonedBundle()

    #expect(first.manifest.entries.map(\.name) == second.manifest.entries.map(\.name))
    #expect(first.manifest.entries.map(\.byteCount) == second.manifest.entries.map(\.byteCount))
    #expect(first.manifest.entries.map(\.summary) == second.manifest.entries.map(\.summary))
    #expect(first.manifestJSON == second.manifestJSON)
    #expect(first.file(named: "settings.json") == second.file(named: "settings.json"))
    #expect(first.file(named: "errors.log") == second.file(named: "errors.log"))
    #expect(first.file(named: "snapshot.json") != second.file(named: "snapshot.json"))
}

// MARK: - File contents

@Test func theSnapshotFileIsTheCapturedSnapshotAndDecodesBack() throws {
    let bundle = try poisonedBundle()
    let file = try #require(bundle.file(named: SupportBundleBuilder.snapshotFileName))
    let decoded = try JSONDecoder.iso8601.decode(DiagnosticsSnapshot.self, from: file.contents)

    #expect(decoded.schemaVersion == DiagnosticsSchema.version)
    #expect(decoded.generatedAt == referenceDate)
    #expect(decoded.recentErrors.count == 5)
    #expect(decoded.lockedSettings == [SettingsKeys.hostListenPort.name])
}

@Test func theErrorLogRendersEveryEntryOldestFirstWithSeverityAndSubsystem() throws {
    let bundle = try poisonedBundle()
    let file = try #require(bundle.file(named: SupportBundleBuilder.errorLogFileName))
    let lines = String(decoding: file.contents, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: true)

    // The PEM entry's message is multi-line even after redaction, so count entries by
    // their timestamp prefix rather than by line.
    let entryLines = lines.filter { $0.hasPrefix("19") || $0.hasPrefix("20") }
    #expect(entryLines.count == 5)
    #expect(entryLines[0].contains("WARNING"))
    #expect(entryLines[0].contains("1970-01-01T00:00:10Z"))
    #expect(entryLines[1].contains("ERROR"))
    #expect(entryLines[1].contains("(host host-1)"))
    #expect(entryLines[2].contains("CRITICAL"))
    #expect(entryLines[3].contains("[settings]"))
}

@Test func theSettingsFileRecordsWhichTierSuppliedEveryValue() throws {
    let bundle = try poisonedBundle()
    let file = try #require(bundle.file(named: SupportBundleBuilder.settingsFileName))
    let decoded = try JSONDecoder().decode(SupportBundleSettings.self, from: file.contents)
    let sources = Dictionary(uniqueKeysWithValues: decoded.entries.map { ($0.name, $0.source) })

    #expect(sources[SettingsKeys.hostListenPort.name] == .locked)
    #expect(sources[SettingsKeys.containerBinaryPath.name] == .user)
    #expect(sources[SettingsKeys.pollIntervalSeconds.name] == .managedDefault)
    #expect(sources[SettingsKeys.logTailLines.name] == .builtIn)

    // Every non-sensitive registry key is present, sorted, exactly once.
    let expected = SettingsRegistry.all
        .filter { !$0.isSensitive }.map(\.name).sorted()
    #expect(decoded.entries.map(\.name) == expected)
}

@Test func theSettingsFileValuesMatchTheStoresEffectiveValues() throws {
    let store = SettingsStore()
    try store.set(42, for: SettingsKeys.logTailLines)
    let bundle = try SupportBundleBuilder().build(
        at: referenceDate,
        app: .init(version: "1.0.0", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: store
    )
    let file = try #require(bundle.file(named: SupportBundleBuilder.settingsFileName))
    let decoded = try JSONDecoder().decode(SupportBundleSettings.self, from: file.contents)
    let logTail = try #require(decoded.entries.first { $0.name == SettingsKeys.logTailLines.name })
    #expect(logTail.value == .int(42))
}

// MARK: - Shape

@Test func aCleanBundleContainsNoServerSideIdentifierOrUploadTarget() throws {
    let bundle = try poisonedBundle()
    let text = bundle.contentsByFileName.values
        .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    // No phone-home: nothing in a bundle should look like somewhere to send it.
    for forbidden in ["http://", "https://", "uploadID", "sessionID", "installationID"] {
        #expect(!text.contains(forbidden))
    }
}

private extension JSONDecoder {
    /// Matches `SupportBundleBuilder.encoder`'s date strategy.
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - the app owner's independent check of the refusal
//
// The whole value of this builder is that a redaction gap becomes a thrown error rather than a
// file someone emails. the core owner's tests assert it; this asserts it a second way, by defeating
// `capture`'s redaction the way a future careless field addition would — hand-constructing a
// snapshot, which the doc comment explicitly permits.

@Test func aHandBuiltSnapshotCannotSmuggleSecretsPastTheAudit() throws {
    let store = SettingsStore()
    var snapshot = DiagnosticsSnapshot(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 0),
        app: .init(name: "Flotilla", version: "1.0", build: "1",
                   bundleIdentifier: "dev.melonfleet.Flotilla", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: [:], lockedSettings: [], notifications: .defaults, recentErrors: []
    )

    // Each of these is a thing that must never reach a file someone forwards. They are planted
    // AFTER capture, so only the final audit can catch them.
    let plants: [(String, String)] = [
        ("home path", "/Users/someone/src"),
        ("certificate", "-----BEGIN RSA PRIVATE KEY-----"),
        ("GitHub token", "ghp_abcdefghijklmnopqrstuvwxyz012345"),
        ("AWS key", "AKIAIOSFODNN7EXAMPLE"),
        ("email", "person@example.com"),
    ]

    for (label, secret) in plants {
        snapshot.recentErrors = [
            ErrorLogEntry(timestamp: Date(timeIntervalSince1970: 0), severity: .error,
                          subsystem: "probe", message: "leaked \(secret)")
        ]
        #expect(throws: SupportBundleLeakError.self, "\(label) should have been refused") {
            _ = try SupportBundleBuilder().build(snapshot: snapshot, settings: store)
        }
    }
}

@Test func aCleanSnapshotStillBuilds() throws {
    // The guard against overcorrecting: an honest bundle must not be blocked.
    let snapshot = DiagnosticsSnapshot(
        schemaVersion: 1,
        generatedAt: Date(timeIntervalSince1970: 0),
        app: .init(name: "Flotilla", version: "1.0", build: "1",
                   bundleIdentifier: "dev.melonfleet.Flotilla", mode: .client, isManaged: false),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: [:], lockedSettings: [], notifications: .defaults, recentErrors: []
    )
    let bundle = try SupportBundleBuilder().build(snapshot: snapshot, settings: SettingsStore())
    #expect(!bundle.files.isEmpty)
    #expect(bundle.manifest.entries.count == bundle.files.count,
            "the manifest must list exactly what is present — no more, no less")
}
