import Foundation
import Testing
@testable import FlotillaCore

// `Redaction.swift`, `ErrorLog.swift` and `DiagnosticsSnapshot.swift` already existed
// when this file was written — these tests are the missing verification, not a
// rewrite. Redaction is adversarial by design: every planted secret/path/identifier
// below must be *absent* from the redactor's output, not just transformed somehow.

// MARK: - Redactor: adversarial planting

@Test func redactsGitHubStyleTokens() {
    let input = "export GH_TOKEN=ghp_1234567890abcdef1234ABCD"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("ghp_1234567890abcdef1234ABCD"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsSlackStyleTokens() {
    let input = "webhook secret xoxb-111111111111-222222222222-abcdefghijklmnopqrstuvwx"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("xoxb-111111111111"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsJWTs() {
    let input = "Set-Cookie: session=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("eyJhbGciOiJIUzI1NiJ9"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsAWSStyleAccessKeys() {
    let input = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("AKIAIOSFODNN7EXAMPLE"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsOpenAIStyleSecretKeys() {
    let input = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx1234567890"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("sk-abcdefghijklmnopqrstuvwx1234567890"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsBearerAuthorizationHeaders() {
    let input = "fetch failed with Bearer abcdefgh12345678.ijklmnop"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("abcdefgh12345678"))
    #expect(output.contains("Bearer "))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsGenericKeyValueSecretsInProseAndEnvDumps() {
    let inputs = [
        "password: hunter2isaverylongpassword",
        "password=hunter2isaverylongpassword",
        "\"apiKey\": \"abcd1234efgh5678\"",
        "api_key = abcd1234efgh5678",
        "private_key: notARealButLongEnoughSecretValue",
    ]
    for input in inputs {
        let output = Redactor.standard.redact(input)
        #expect(!output.contains("hunter2isaverylongpassword"))
        #expect(!output.contains("abcd1234efgh5678"))
        #expect(!output.contains("notARealButLongEnoughSecretValue"))
    }
}

@Test func redactsWholePEMBlocksIncludingPrivateKeys() {
    let pem = """
    Loaded identity:
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL
    MNOPQRSTUVWXYZ0123456789+/==
    -----END RSA PRIVATE KEY-----
    done.
    """
    let output = Redactor.standard.redact(pem)
    #expect(!output.contains("BEGIN RSA PRIVATE KEY"))
    #expect(!output.contains("MIIEpAIBAAKCAQEA"))
    #expect(output.contains("Loaded identity:"))
    #expect(output.contains("done."))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsATruncatedPEMBlockWithNoMatchingEnd() {
    let truncated = "before\n-----BEGIN CERTIFICATE-----\nMIIB0zCCAXygAwIBAgIU...(cut off)"
    let output = Redactor.standard.redact(truncated)
    #expect(!output.contains("MIIB0zCCAXygAwIBAgIU"))
    #expect(output.contains("before"))
}

@Test func redactsCertificateAndCAFingerprints() {
    let colonSeparated = "fingerprint: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
    let output1 = Redactor.standard.redact(colonSeparated)
    #expect(!output1.contains("AA:BB:CC:DD:EE:FF"))
    #expect(RedactionAudit.leaks(in: output1).isEmpty)

    let bareDigest = "sha256:" + String(repeating: "ab", count: 32)
    let output2 = Redactor.standard.redact(bareDigest)
    #expect(!output2.contains(String(repeating: "ab", count: 32)))
    #expect(RedactionAudit.leaks(in: output2).isEmpty)
}

@Test func redactsCredentialsEmbeddedInURLs() {
    let input = "cloning https://dave:supersecrettoken@github.example/private/repo.git"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("dave:supersecrettoken"))
    #expect(output.contains("github.example/private/repo.git"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func redactsAbsoluteHomeDirectoryPathsAndTheUsernameWithin() {
    let macPath = "/Users/example/Projects/flotilla/config.toml"
    let macOutput = Redactor.standard.redact(macPath)
    #expect(!macOutput.contains("/Users/example"))
    #expect(!macOutput.contains("example"))
    #expect(macOutput.contains("~"))
    #expect(macOutput.hasSuffix("/Projects/flotilla/config.toml"))
    #expect(RedactionAudit.leaks(in: macOutput).isEmpty)

    let linuxPath = "/home/dave/.ssh/id_ed25519"
    let linuxOutput = Redactor.standard.redact(linuxPath)
    #expect(!linuxOutput.contains("/home/dave"))
    #expect(!linuxOutput.contains("dave"))
    #expect(linuxOutput.contains("~"))
    #expect(RedactionAudit.leaks(in: linuxOutput).isEmpty)
}

@Test func redactsDataVolumeMountedHomePaths() {
    // `/System/Volumes/Data/Users/...` is the real on-disk path on modern macOS;
    // `/Users/...` is a synthetic firmlink over it. Both identify a person.
    let input = "/System/Volumes/Data/Users/example/Library/Application Support/Flotilla"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("example"))
    #expect(!output.contains("/System/Volumes/Data/Users"))
}

@Test func redactsTemporaryDirectoryPaths() {
    let input = "wrote scratch file to /private/var/folders/zz/abcdef1234/T/flotilla-tmp.json"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("/var/folders/zz/abcdef1234"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

/// `container machine inspect` reports `userSetup.username` as a plain field. Every existing
/// rule matched a *path* (`/Users/<name>`), so the host user's own name went through untouched —
/// displayed in the Inspect panel and handed out verbatim by Copy JSON, under a note promising
/// that secrets were redacted. That note was the bug: it claimed a protection that did not exist.
@Test func redactsBareUsernameFields() {
    let sample = #"{"userSetup":{"gid":20,"uid":501,"username":"someperson"},"user":"root","image":{"reference":"docker.io/library/alpine:3.22"}}"#
    // The narrowed redactor the Inspect panels use. `username` is not among the exclusions, so
    // switching off digests and home paths must not switch this off with them.
    let narrowed = Redactor(excluding: [.fingerprint, .homePath, .temporaryPath, .email])
    let out = narrowed.redact(sample)

    #expect(!out.contains("someperson"))
    #expect(out.contains("<redacted:username>"))
    #expect(out.contains(#""username""#))          // the key survives; the field is visibly there
    // Bare `user` is deliberately untouched: container config uses it for the runtime user,
    // which is not PII and is one of the more useful things in the output.
    #expect(out.contains(#""user":"root""#))
    #expect(out.contains("alpine:3.22"))
}

/// The audit must agree with the rules, or a support bundle can pass its own check while
/// still carrying the name.
@Test func detectorCoversUsername() {
    let raw = #"{"username":"someperson"}"#
    #expect(RedactionAudit.leaks(in: raw).contains { $0.category == .username })
    #expect(!RedactionAudit.leaks(in: Redactor.standard.redact(raw)).contains { $0.category == .username })
}

@Test func redactsEmailAddresses() {
    let input = "signed in as exampledev@outlook.com"
    let output = Redactor.standard.redact(input)
    #expect(!output.contains("exampledev@outlook.com"))
    #expect(RedactionAudit.leaks(in: output).isEmpty)
}

@Test func leavesOrdinaryDiagnosticTextUntouched() {
    let input = "container ls returned 3 running, 1 stopped in 42ms"
    #expect(Redactor.standard.redact(input) == input)
}

// MARK: - RedactionAudit: the belt-and-braces check must actually fire

@Test func auditFindsLeaksInUnredactedTextButNotInRedactedText() {
    let secret = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE and lives at /Users/example/creds"
    #expect(!RedactionAudit.leaks(in: secret).isEmpty)

    let cleaned = Redactor.standard.redact(secret)
    #expect(RedactionAudit.leaks(in: cleaned).isEmpty)
}

@Test func auditWorksOverRawData() {
    let data = Data("token AKIAIOSFODNN7EXAMPLE".utf8)
    #expect(!RedactionAudit.leaks(in: data).isEmpty)
}

// MARK: - Redactor over SettingValue and settings dictionaries

@Test func redactingANonStringSettingValueIsANoOp() {
    #expect(Redactor.standard.redact(SettingValue.bool(true)) == .bool(true))
    #expect(Redactor.standard.redact(SettingValue.int(42)) == .int(42))
    #expect(Redactor.standard.redact(SettingValue.double(1.5)) == .double(1.5))
}

@Test func redactsEveryElementOfAStringArraySettingValue() {
    let value = SettingValue.stringArray(["/Users/example/a", "plain", "/home/dave/b"])
    guard case .stringArray(let redacted) = Redactor.standard.redact(value) else {
        Issue.record("expected .stringArray back")
        return
    }
    #expect(redacted.allSatisfy { !$0.contains("example") && !$0.contains("dave") })
    #expect(redacted[1] == "plain")
}

@Test func redactSettingsDropsSensitiveKeysEntirelyRatherThanRedactingThem() throws {
    let store = SettingsStore()
    try store.set(["deadbeef-fingerprint"], for: SettingsKeys.peerAllowlist)
    try store.set(["another-fingerprint"], for: SettingsKeys.trustAnchorFingerprints)
    try store.set("/Users/example/bin/container", for: SettingsKeys.containerBinaryPath)

    let redacted = Redactor.standard.redactSettings(store.effectiveValues())

    #expect(redacted[SettingsKeys.peerAllowlist.name] == nil)
    #expect(redacted[SettingsKeys.trustAnchorFingerprints.name] == nil)
    #expect(redacted[SettingsKeys.containerBinaryPath.name] == .string("~/bin/container"))
}

// MARK: - ErrorLog: bounded ring buffer

@Test func errorLogTrimsToCapacityOldestFirstDropped() {
    let log = ErrorLog(capacity: 3)
    for i in 1...5 {
        log.record(.warning, subsystem: "cli", message: "event \(i)")
    }
    let messages = log.entries().map(\.message)
    #expect(messages == ["event 3", "event 4", "event 5"])
}

@Test func errorLogWithZeroCapacityRecordsNothing() {
    let log = ErrorLog(capacity: 0)
    log.record(.error, subsystem: "cli", message: "should not be kept")
    #expect(log.entries().isEmpty)
}

@Test func errorLogRecentReturnsTheNewestEntriesOldestFirst() {
    let log = ErrorLog(capacity: 10)
    for i in 1...5 {
        log.record(.error, subsystem: "cli", message: "event \(i)")
    }
    #expect(log.recent(2).map(\.message) == ["event 4", "event 5"])
    #expect(log.recent(0).isEmpty)
    #expect(log.recent(100).count == 5)
}

@Test func errorLogClearEmptiesTheBuffer() {
    let log = ErrorLog(capacity: 10)
    log.record(.error, subsystem: "cli", message: "boom")
    log.clear()
    #expect(log.entries().isEmpty)
}

@Test func settingCapacityDownwardTrimsExistingEntries() {
    let log = ErrorLog(capacity: 10)
    for i in 1...5 {
        log.record(.warning, subsystem: "cli", message: "event \(i)")
    }
    log.setCapacity(2)
    #expect(log.entries().map(\.message) == ["event 4", "event 5"])
}

@Test func errorLogCapacityTracksTheDiagnosticsErrorLogCapSetting() throws {
    let store = SettingsStore()
    try store.set(2, for: SettingsKeys.diagnosticsErrorLogCap)
    let log = ErrorLog(settings: store)
    #expect(log.capacity == 2)
}

// MARK: - DiagnosticsSnapshot.capture: end-to-end redaction

@Test func captureRedactsSettingsErrorsAndPreflightTogether() throws {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.hostListenPort.name: .int(9443)])
    let store = SettingsStore(managed: managed)
    try store.set("/Users/example/bin/container", for: SettingsKeys.containerBinaryPath)
    try store.set(["fingerprint-should-never-appear"], for: SettingsKeys.peerAllowlist)

    let errorLog = ErrorLog(capacity: 10)
    errorLog.record(
        .error, subsystem: "/Users/example/Library/Logs/flotilla.log",
        message: "pull failed: Authorization: Bearer abcdefgh12345678"
    )

    let snapshot = DiagnosticsSnapshot.capture(
        at: Date(timeIntervalSince1970: 0),
        app: .init(version: "1.0.0", mode: .client, isManaged: true),
        system: .init(osName: "macOS", osVersion: "26.0", architecture: "arm64"),
        settings: store,
        runtime: .init(cliVersion: "1.0.0 (/Users/example/bin/container)"),
        preflight: .ok(version: "1.0.0", path: "/Users/example/bin/container"),
        errorLog: errorLog
    )

    // Sensitive keys never make it in, redacted or not.
    #expect(snapshot.settings[SettingsKeys.peerAllowlist.name] == nil)

    // Locked key is reported as locked.
    #expect(snapshot.lockedSettings.contains(SettingsKeys.hostListenPort.name))

    // Every string-shaped field that could carry a path/token is clean.
    #expect(snapshot.settings[SettingsKeys.containerBinaryPath.name] == .string("~/bin/container"))
    #expect(!snapshot.recentErrors[0].message.contains("abcdefgh12345678"))
    #expect(!snapshot.recentErrors[0].subsystem.contains("example"))
    if case .ok(_, let path) = try #require(snapshot.preflight) {
        #expect(!path.contains("example"))
    } else {
        Issue.record("expected .ok preflight result")
    }
    let cliVersion = snapshot.runtime?.cliVersion ?? ""
    #expect(!cliVersion.contains("example"))

    // Whole-snapshot audit: encode it and re-scan every byte, the way a support
    // bundle would before it is handed to someone else.
    //
    // `.withoutEscapingSlashes` is load-bearing, not tidiness. Foundation writes `/`
    // as `\/` by default, so `/Users/example` becomes `\/Users\/example` and the audit's
    // `/Users/…` and `/var/folders/…` detectors match nothing — the path half of this
    // assertion passed vacuously until `SupportBundleBuilder` was written and the
    // escaping was noticed. `SupportBundleBuilder.encoder` sets the same option.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    #expect(RedactionAudit.leaks(in: data).isEmpty)
    #expect(!String(decoding: data, as: UTF8.self).contains("example"))
}

@Test func captureRedactsPreflightForEveryCaseThatCarriesAPathOrReason() {
    let redactor = Redactor.standard
    let okResult = PreflightResult.ok(version: "1.0.0", path: "/Users/example/bin/container")
    guard case .ok(_, let okPath) = okResult.redacted(with: redactor) else {
        Issue.record("expected .ok")
        return
    }
    #expect(!okPath.contains("example"))

    let unusable = PreflightResult.unusable(reason: "service socket at /Users/example/.container/api.sock unreachable")
    guard case .unusable(let reason) = unusable.redacted(with: redactor) else {
        Issue.record("expected .unusable")
        return
    }
    #expect(!reason.contains("example"))

    // These carry no path/reason payload, so redaction is a pure pass-through.
    #expect(PreflightResult.missing.redacted(with: redactor) == .missing)
    let tooOld = PreflightResult.tooOld(found: "0.9.0", required: "1.0.0")
    #expect(tooOld.redacted(with: redactor) == tooOld)
}

// MARK: - HostSummary: structurally excludes network identifiers

@Test func hostSummaryCarriesNoHostnameAddressOrFingerprintField() {
    let host = DiagnosticsSnapshot.HostSummary(id: "host-1", kind: .remote, isReachable: true)
    let fieldNames = Set(Mirror(reflecting: host).children.compactMap(\.label))
    let forbidden: Set<String> = [
        "hostname", "address", "ipAddress", "bonjourName", "nickname",
        "fingerprint", "certificateFingerprint", "name",
    ]
    #expect(fieldNames.isDisjoint(with: forbidden))
}

// MARK: - Narrowed redaction
//
// The inspect view needs secrets gone but digests and mount paths intact. These pin that the
// exclusion actually excludes, and — more importantly — that it does not quietly weaken
// anything else.

@Test("Excluding a category leaves that pattern alone")
func excludingACategorySkipsOnlyThatRule() {
    let digest = "sha256:9a1f4b2e77c0a1d5c07d9a1f4b2e77c0a1d5c07d9a1f4b2e77c0a1d5c07d1234"
    #expect(Redactor.standard.redact(digest).contains("<redacted:"))
    #expect(Redactor(excluding: [.fingerprint]).redact(digest) == digest)
}

@Test("Excluding fingerprints still redacts real secrets")
func excludingFingerprintsKeepsSecretsRedacted() {
    let redactor = Redactor(excluding: [.fingerprint, .homePath, .temporaryPath, .email])
    let input = """
    POSTGRES_PASSWORD=hunter2supersecret
    GH_TOKEN=ghp_1234567890abcdef1234ABCD
    AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
    """
    let output = redactor.redact(input)
    #expect(!output.contains("ghp_1234567890abcdef1234ABCD"))
    #expect(!output.contains("AKIAIOSFODNN7EXAMPLE"))
    #expect(!output.contains("hunter2supersecret"))
}

@Test("The support bundle's redactor is untouched by the narrowed one existing")
func standardRedactorStillRedactsEverything() {
    let path = "/Users/someone/secrets"
    #expect(Redactor.standard.redact(path) == "~/secrets")
}
