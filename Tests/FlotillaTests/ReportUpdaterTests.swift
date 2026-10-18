import CryptoKit
import Foundation
import Testing
@testable import FlotillaCore
@testable import Flotilla

@Suite @MainActor struct ReportUpdaterTests {
    private let reportKey = Curve25519.Signing.PrivateKey()
    private let libraryKey = Curve25519.Signing.PrivateKey()

    private func publicText(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        Data(try key.signature(for: data).base64EncodedString().utf8)
    }

    private func reportData(generated: String = "2026-10-18T07:00:00Z") throws -> Data {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let report = VulnerabilityReport(
            schema: 1, generated: generated,
            scanner: .init(name: "grype", version: "0.120.1", dbBuilt: "2026-10-18T06:27:17Z"),
            images: [.init(reference: "docker.io/library/nats:2.15.0", digests: [digest],
                           counts: .init(critical: 1, high: 0, medium: 0, low: 0),
                           findings: [.init(id: "CVE-2026-1", severity: .critical, package: "stdlib",
                                            installed: "go1.27.1", fixed: "1.27.2")])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }

    private struct Harness {
        var updater: ReportUpdater
        var center: UpdateActivityCenter
        var folder: URL
        var defaults: UserDefaults
        var stages: () -> [UpdateStage]
        var requests: () -> [String]
    }

    private func harness(key: String?, folder: URL? = nil, defaults: UserDefaults? = nil,
                         serving: @escaping (String) throws -> Data) -> Harness {
        let defaults = defaults ?? UserDefaults(suiteName: "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)")!
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)")
        let center = UpdateActivityCenter()
        var seen: [UpdateStage] = []
        var asked: [String] = []
        center.observer = { _, stage in seen.append(stage) }
        let updater = ReportUpdater(activity: center, defaults: defaults, key: key, cacheFolder: folder)
        updater.fetchOverride = { name, _ in asked.append(name); return try serving(name) }
        return Harness(updater: updater, center: center, folder: folder, defaults: defaults,
                       stages: { seen }, requests: { asked })
    }

    @Test func reportsAreOffUntilTheKeyIsSetAndNothingIsFetched() async throws {
        let h = harness(key: nil) { _ in Issue.record("fetched with no key"); return Data() }
        #expect(!h.updater.isOn)
        await h.updater.check()
        #expect(h.requests().isEmpty)
        #expect(h.stages().isEmpty)
        #expect(h.updater.report == nil)
        // Until the owner sets the key, production has none; once set it must not be the library's.
        #expect(ReportUpdater.reportPublicKey == nil || ReportUpdater.reportPublicKey != LibraryUpdater.publicKey)
        #expect(ReportUpdater.activeKey(configured: nil) == nil)
        #expect(ReportUpdater.activeKey(configured: LibraryUpdater.publicKey) == nil)
        #expect(ReportUpdater.activeKey(configured: publicText(reportKey)) == publicText(reportKey))
    }

    @Test func theLibraryKeyNeverVerifiesAReportAndTheReportKeyNeverAnLibrary() throws {
        let report = try reportData()
        // Direction 1: a report signed by the library key is refused under the report key.
        #expect(throws: ReportUpdater.Failure.self) {
            try ReportUpdater.verified(report, signature: sign(report, with: libraryKey), publicKey: publicText(reportKey))
        }
        // Control: signed by the report key, it is accepted.
        let accepted = try ReportUpdater.verified(report, signature: sign(report, with: reportKey), publicKey: publicText(reportKey))
        #expect(accepted.images.count == 1)

        // Direction 2: a library signed by the report key is refused under the library key.
        let library = Data(#"{"schema":1,"version":"2026.10.18.1","entries":[]}"#.utf8)
        #expect(throws: LibraryUpdater.Failure.self) {
            try LibraryUpdater.verified(library, signature: sign(library, with: reportKey), publicKey: publicText(libraryKey))
        }
        // Control: signed by the library key, it is accepted.
        #expect(throws: Never.self) {
            try LibraryUpdater.verified(library, signature: sign(library, with: libraryKey), publicKey: publicText(libraryKey))
        }
        // And a report is not a library, nor a library a report, whatever signed them.
        #expect(throws: (any Error).self) {
            try LibraryUpdater.verified(report, signature: sign(report, with: libraryKey), publicKey: publicText(libraryKey))
        }
        #expect(throws: ReportUpdater.Failure.self) {
            try ReportUpdater.verified(library, signature: sign(library, with: reportKey), publicKey: publicText(reportKey))
        }
    }

    @Test func aGoodReportIsVerifiedCachedAndReverifiedOnTheNextLaunch() async throws {
        let data = try reportData()
        let signature = try sign(data, with: reportKey)
        let key = publicText(reportKey)
        let h = harness(key: key) { $0 == "report.json" ? data : signature }
        await h.updater.check()
        #expect(h.requests() == ["report.json", "report.json.sig"])
        #expect(h.stages() == [.checking, .downloading(nil), .verifying, .finished("Vulnerability report updated (1 images)")])
        #expect(h.updater.report?.images.first?.counts.critical == 1)

        // A new launch: read from the cache, checked again.
        let relaunched = ReportUpdater(defaults: h.defaults, key: key, cacheFolder: h.folder)
        #expect(relaunched.report == h.updater.report)
        // The wrong key, or reports off, shows nothing from the same cache.
        #expect(ReportUpdater(defaults: h.defaults, key: publicText(libraryKey), cacheFolder: h.folder).report == nil)
        #expect(ReportUpdater(defaults: h.defaults, key: nil, cacheFolder: h.folder).report == nil)
        // A cached file edited afterwards no longer verifies.
        try Data(data + Data(" ".utf8)).write(to: h.folder.appendingPathComponent("report.json"))
        #expect(ReportUpdater(defaults: h.defaults, key: key, cacheFolder: h.folder).report == nil)
    }

    @Test func aTamperedOrUnsignedReportChangesNothing() async throws {
        let data = try reportData()
        let h = harness(key: publicText(reportKey)) { $0 == "report.json" ? data : Data("AAAA".utf8) }
        await h.updater.check()
        #expect(h.updater.report == nil)
        #expect(h.stages().last?.isFailure == true)
        #expect(!FileManager.default.fileExists(atPath: h.folder.appendingPathComponent("report.json").path))
    }

    @Test func anOlderSignedReportIsNotReplayedOverANewerOne() async throws {
        let key = publicText(reportKey)
        let newer = try reportData(generated: "2026-10-18T07:00:00Z")
        let older = try reportData(generated: "2026-10-10T07:00:00Z")
        var serving = newer
        let h = harness(key: key) { [reportKey] name in
            name == "report.json" ? serving : Data(try reportKey.signature(for: serving).base64EncodedString().utf8)
        }
        await h.updater.check()
        #expect(h.updater.report?.generated == "2026-10-18T07:00:00Z")
        serving = older
        await h.updater.check()
        #expect(h.updater.report?.generated == "2026-10-18T07:00:00Z")
        #expect(h.updater.status.contains("older"))
        #expect(ReportUpdater(defaults: h.defaults, key: key, cacheFolder: h.folder).report?.generated == "2026-10-18T07:00:00Z")
    }

    @Test func acceptingACachedReportAdvancesTheReplayWatermark() async throws {
        // An update interrupted after the cache was written but before the date was saved.
        let key = publicText(reportKey)
        let cached = try reportData(generated: "2026-10-18T07:00:00Z")
        let older = try reportData(generated: "2026-10-10T07:00:00Z")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try cached.write(to: folder.appendingPathComponent("report.json"))
        try sign(cached, with: reportKey).write(to: folder.appendingPathComponent("report.json.sig"))
        let defaults = UserDefaults(suiteName: "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)")!
        #expect(defaults.object(forKey: ReportUpdater.highestGeneratedKey) == nil)
        let h = harness(key: key, folder: folder, defaults: defaults) { [reportKey] name in
            name == "report.json" ? older : Data(try reportKey.signature(for: older).base64EncodedString().utf8)
        }
        #expect(h.updater.report?.generated == "2026-10-18T07:00:00Z")
        await h.updater.check()
        #expect(h.updater.report?.generated == "2026-10-18T07:00:00Z")
        #expect(h.updater.status.contains("older"))
    }

    @Test func noReportPublishedYetIsQuiet() async {
        let h = harness(key: publicText(reportKey)) { name in
            throw ReportUpdater.Failure("GitHub didn't have \(name) (HTTP 404).", notPublished: true)
        }
        await h.updater.check()
        #expect(h.updater.report == nil)
        #expect(h.stages().allSatisfy { !$0.isFailure })
        #expect(h.center.activity.entries[.report] == nil)
    }

    @Test func aFailedFetchIsReportedAsAFailure() async {
        let h = harness(key: publicText(reportKey)) { _ in throw ReportUpdater.Failure("GitHub didn't have report.json (HTTP 500).") }
        await h.updater.check()
        #expect(h.stages().last == .failed("Couldn't check the vulnerability report: GitHub didn't have report.json (HTTP 500)."))
        #expect(!h.updater.checking)
    }

    @Test func theReportStageWordsAreTheBriefs() {
        #expect(UpdateStage.checking.text(for: .report) == "Checking vulnerability report…")
    }
}
