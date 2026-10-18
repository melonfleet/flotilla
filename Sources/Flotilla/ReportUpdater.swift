import CryptoKit
import Foundation
import FlotillaCore

/// Fetches the library's daily vulnerability report (DECISIONS Q62), beside `library.json`.
///
/// A report is used only if **every** check passes:
/// - its Ed25519 signature verifies against `reportPublicKey` — a key of its own, which signs
///   reports and nothing else. The library's key is never tried here and this key is never tried
///   for the library, so a leaked report key can show a false or missing warning and can never
///   change a recipe;
/// - it decodes and every field is valid (`VulnerabilityReport.decode`);
/// - it is not older than the newest one ever accepted, so an old signed file can't be replayed.
///
/// Advisory only: nothing here stops, pulls or changes anything. The request is the library's
/// request — same ephemeral session, no redirects, bare user agent, nothing about this Mac — to
/// the same GitHub source. **Until the key below is set, reports are off: nothing is fetched and
/// nothing is shown.**
@MainActor
@Observable
final class ReportUpdater {
    /// The report key's public half, base64. `nil` until the owner has run `tools/make-report-key.sh`
    /// in the library repo and pasted its output here; with `nil`, nothing is fetched or shown.
    nonisolated static let reportPublicKey: String? = nil

    /// The key to use, or nil if reports are off. A report key equal to the library key is refused:
    /// that would let the library key sign reports (and a report-key leak be a library-key leak's twin).
    nonisolated static func activeKey(configured: String? = reportPublicKey,
                                      libraryKey: String = LibraryUpdater.publicKey) -> String? {
        guard let configured, configured != libraryKey else { return nil }
        return configured
    }

    nonisolated static let source = LibraryUpdater.source

    /// The last good report, verified. Nil when reports are off, nothing is cached yet, or the
    /// current repository has none.
    private(set) var report: VulnerabilityReport?
    private(set) var checking = false
    private(set) var status = "Not checked yet."

    private let defaults: UserDefaults
    private let activity: UpdateActivityCenter
    private let key: String?
    /// Tests only: stands in for the network. Receives the file name and the byte cap.
    @ObservationIgnored var fetchOverride: ((String, Int) async throws -> Data)?
    nonisolated static let highestGeneratedKey = "vulnerabilityReportHighestGenerated"

    init(activity: UpdateActivityCenter = UpdateActivityCenter(), defaults: UserDefaults = .standard,
         key: String? = ReportUpdater.activeKey(), cacheFolder: URL? = ReportUpdater.cacheFolder) {
        self.activity = activity
        self.defaults = defaults
        self.key = key
        self.cacheFolder = cacheFolder
        // Checked again on every launch, like the library: a cached file is not trusted because it
        // was once good.
        if let key { report = Self.cached(key: key, in: cacheFolder, defaults: defaults) }
    }

    /// Whether reports are on at all.
    var isOn: Bool { key != nil }

    private let cacheFolder: URL?

    nonisolated static var cacheFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.melonfleet.Flotilla/library", isDirectory: true)
    }

    nonisolated static func cached(key: String, in folder: URL?, defaults: UserDefaults) -> VulnerabilityReport? {
        guard let folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("report.json")),
              let signature = try? Data(contentsOf: folder.appendingPathComponent("report.json.sig")),
              let report = try? verified(data, signature: signature, publicKey: key)
        else { return nil }
        if isReplay(report, defaults: defaults) { return nil }
        // Accepting a cache advances the watermark: an update interrupted after writing the cache
        // but before saving the date must not leave an older signed report free to replace it.
        advanceWatermark(to: report, defaults: defaults)
        return report
    }

    /// The report in `data`, if `signature` verifies under `publicKey` and the report is valid.
    /// Only tests pass another key; production always uses `activeKey()`.
    nonisolated static func verified(_ data: Data, signature: Data, publicKey: String) throws -> VulnerabilityReport {
        guard data.count <= VulnerabilityReport.maxBytes else { throw Failure(VulnerabilityReport.Failure.tooLarge.message) }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: data)
        else { throw Failure("The vulnerability report's signature didn't verify, so it wasn't used.") }
        do { return try VulnerabilityReport.decode(data) }
        catch let failure as VulnerabilityReport.Failure { throw Failure(failure.message) }
    }

    nonisolated static func advanceWatermark(to report: VulnerabilityReport, defaults: UserDefaults) {
        guard let generated = report.generatedDate else { return }
        if let highest = defaults.object(forKey: highestGeneratedKey) as? Date, highest >= generated { return }
        defaults.set(generated, forKey: highestGeneratedKey)
    }

    /// Older than the newest ever accepted.
    nonisolated static func isReplay(_ report: VulnerabilityReport, defaults: UserDefaults) -> Bool {
        guard let highest = defaults.object(forKey: highestGeneratedKey) as? Date,
              let generated = report.generatedDate else { return false }
        return generated < highest
    }

    /// Fetches, verifies and, if not older than what is held, keeps it. Does nothing at all when
    /// reports are off.
    func check() async {
        guard let key, !checking else { return }
        checking = true
        defer { checking = false }
        activity.report(.checking, from: .report)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Flotilla"]
        let session = URLSession(configuration: configuration, delegate: ReportRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            activity.report(.downloading(nil), from: .report)
            let data = try await fetch("report.json", session)
            let signature = try await fetch("report.json.sig", session, cap: 4096)
            activity.report(.verifying, from: .report)
            let fresh = try await Blocking.run { try Self.verified(data, signature: signature, publicKey: key) }
            if Self.isReplay(fresh, defaults: defaults) {
                status = "GitHub offered an older vulnerability report than one already used, so it was ignored."
                activity.report(.finished(status), from: .report)
                return
            }
            // Before the cache is written, not after: an interruption in between leaves the date
            // recorded, never a newer file with no date.
            Self.advanceWatermark(to: fresh, defaults: defaults)
            let folder = cacheFolder
            try await Blocking.run {
                guard let folder else { return }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
                try signature.write(to: folder.appendingPathComponent("report.json.sig"), options: .atomic)
            }
            let changed = report != fresh
            report = fresh
            status = changed ? "Updated: \(fresh.images.count) images scanned." : "Up to date."
            activity.report(.finished(changed ? "Vulnerability report updated (\(fresh.images.count) images)"
                                              : UpdateStage.upToDate(nil).text(for: .report)), from: .report)
        } catch let failure as Failure where failure.notPublished {
            // No report published yet: nothing to say, and nothing to show.
            status = "No report published yet."
            activity.clear(.report)
        } catch {
            let reason = (error as? Failure)?.message ?? error.localizedDescription
            status = "Couldn't check: \(reason)"
            activity.report(.failed("Couldn't check the vulnerability report: \(reason)"), from: .report)
        }
    }

    private func fetch(_ name: String, _ session: URLSession,
                       cap: Int = VulnerabilityReport.maxBytes) async throws -> Data {
        if let fetchOverride { return try await fetchOverride(name, cap) }
        let (bytes, response) = try await session.bytes(from: Self.source.appendingPathComponent(name))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            bytes.task.cancel()
            throw Failure("GitHub didn't have \(name) (HTTP \(code)).", notPublished: code == 404)
        }
        if response.expectedContentLength > Int64(cap) {
            bytes.task.cancel()
            throw Failure(VulnerabilityReport.Failure.tooLarge.message)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > cap {
                bytes.task.cancel()
                throw Failure(VulnerabilityReport.Failure.tooLarge.message)
            }
        }
        return data
    }

    struct Failure: Error {
        let message: String
        /// A 404: the repository simply has no report yet.
        var notPublished = false
        init(_ message: String, notPublished: Bool = false) { self.message = message; self.notPublished = notPublished }
    }
}

/// Keeps this anonymous request on the configured GitHub source: no redirect is followed.
private final class ReportRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
