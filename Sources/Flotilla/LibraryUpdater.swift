import CryptoKit
import Foundation
import FlotillaCore

/// Fetches a newer suggestions library from GitHub, once a day (DECISIONS Q54).
///
/// A library is used only if **every** check passes:
/// - its Ed25519 signature verifies against the public key built into the app;
/// - its schema is one this build reads;
/// - it is newer than the copy in use;
/// - its entries pass `SuggestionLibrary.checked()`, which drops any that don't.
///
/// Anything else leaves the copy in use alone. The request carries nothing about this Mac: an
/// ephemeral session with no cookies or cache, and a bare user agent.
@MainActor
@Observable
final class LibraryUpdater {
    /// The library key's public half. Its private half is in the owner's login Keychain only.
    nonisolated static let publicKey = "3o1gkvc5eCaxX/RY71GkJ2v2tBgPUg9xMH9XPDaRDyM="
    nonisolated static let source = URL(string: "https://raw.githubusercontent.com/melonfleet/flotilla-library/published/")!
    /// A library is a few hundred kilobytes; anything far larger is refused unread.
    nonisolated static let maxBytes = 4 * 1024 * 1024

    private(set) var lastChecked: Date?
    private(set) var status: String = "Not checked yet."
    private(set) var checking = false

    private let defaults = UserDefaults.standard
    private static let lastCheckedKey = "suggestionLibraryLastChecked"
    /// The newest version ever accepted. A library older than this is never used again, even if
    /// signed — so an old file can't be replayed in (Kyle, 13 October).
    nonisolated static let highestVersionKey = "suggestionLibraryHighestVersion"

    init() {
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        // Saying "Not checked yet." after a relaunch, hours after the daily check ran, was untrue.
        if let lastChecked { status = Self.lastCheckedText(lastChecked) }
    }

    /// "Last checked: Today at 18:27." — relative day and time, in the user's locale.
    static func lastCheckedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Last checked: \(formatter.string(from: date))."
    }

    /// Records the version in use as the newest seen, so nothing older replaces it later.
    func noteInUse(_ library: SuggestionLibrary) {
        let highest = defaults.string(forKey: Self.highestVersionKey).map { SuggestionLibrary(version: $0, entries: []) }
        if highest.map({ $0.isOlder(than: library) }) ?? true { defaults.set(library.version, forKey: Self.highestVersionKey) }
    }

    /// Where the last good download is kept.
    nonisolated static var cacheFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.melonfleet.Flotilla/library", isDirectory: true)
    }

    /// The cached library, if it is still valid — checked again on every launch, not trusted
    /// because it was once.
    nonisolated static func cached() -> SuggestionLibrary? {
        guard let folder = cacheFolder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
              let signature = try? Data(contentsOf: folder.appendingPathComponent("library.json.sig")),
              let library = try? verified(data, signature: signature)
        else { return nil }
        if let highest = UserDefaults.standard.string(forKey: highestVersionKey),
           library.isOlder(than: SuggestionLibrary(version: highest, entries: [])) { return nil }
        return library
    }

    /// The library in `data`, if `signature` verifies and it is a schema this build reads.
    nonisolated static func verified(_ data: Data, signature: Data) throws -> SuggestionLibrary {
        guard data.count <= maxBytes else { throw Failure("The library is larger than Flotilla accepts.") }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let raw = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: data)
        else { throw Failure("The library's signature didn't verify, so it wasn't used.") }
        guard let library = try? JSONDecoder().decode(SuggestionLibrary.self, from: data) else {
            throw Failure("The library couldn't be read.")
        }
        guard library.schema == SuggestionLibrary.currentSchema else {
            throw Failure("The library needs a newer Flotilla (format \(library.schema)).")
        }
        return library.checked().library
    }

    /// Fetches, verifies and, if newer, installs. Returns the library to use, or nil to keep the
    /// current one.
    func check(current: SuggestionLibrary) async -> SuggestionLibrary? {
        guard !checking else { return nil }
        checking = true
        defer { checking = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Flotilla"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let data = try await fetch("library.json", session)
            let signature = try await fetch("library.json.sig", session)
            // An answer arrived, good or bad: the next try is tomorrow, not in an hour.
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
            let library = try Self.verified(data, signature: signature)
            if let highest = defaults.string(forKey: Self.highestVersionKey),
               library.isOlder(than: SuggestionLibrary(version: highest, entries: [])) {
                status = "GitHub offered an older library (\(library.version)) than one already used, so it was ignored."
                return nil
            }
            guard current.isOlder(than: library) else {
                status = "Up to date (library \(current.version))."
                return nil
            }
            if let folder = Self.cacheFolder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
                try signature.write(to: folder.appendingPathComponent("library.json.sig"), options: .atomic)
            }
            defaults.set(library.version, forKey: Self.highestVersionKey)
            status = "Updated to library \(library.version): \(library.entries.count) suggestions."
            return library
        } catch {
            status = (error as? Failure)?.message ?? "Couldn't check: \(error.localizedDescription)"
            return nil
        }
    }

    /// Read as it arrives and abandoned past the cap, so an oversized answer is never held whole.
    private func fetch(_ name: String, _ session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: Self.source.appendingPathComponent(name))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            bytes.task.cancel()
            throw Failure("GitHub didn't have \(name) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        if response.expectedContentLength > Int64(Self.maxBytes) {
            bytes.task.cancel()
            throw Failure("The library is larger than Flotilla accepts.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes {
                bytes.task.cancel()
                throw Failure("The library is larger than Flotilla accepts.")
            }
        }
        return data
    }

    /// Whether a day has passed since the last check.
    var isDue: Bool { lastChecked.map { Date().timeIntervalSince($0) >= 86_400 } ?? true }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
