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
    nonisolated static let source = URL(string: "https://raw.githubusercontent.com/melonfleet/flotilla-library/main/")!
    /// A library is a few hundred kilobytes; anything far larger is refused unread.
    nonisolated static let maxBytes = 4 * 1024 * 1024

    private(set) var lastChecked: Date?
    private(set) var status: String = "Not checked yet."
    private(set) var checking = false

    private let defaults = UserDefaults.standard
    private static let lastCheckedKey = "suggestionLibraryLastChecked"

    init() {
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
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
              let signature = try? Data(contentsOf: folder.appendingPathComponent("library.json.sig"))
        else { return nil }
        return try? verified(data, signature: signature)
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
            let library = try Self.verified(data, signature: signature)
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
            guard current.isOlder(than: library) else {
                status = "Up to date (library \(current.version))."
                return nil
            }
            if let folder = Self.cacheFolder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
                try signature.write(to: folder.appendingPathComponent("library.json.sig"), options: .atomic)
            }
            status = "Updated to library \(library.version): \(library.entries.count) suggestions."
            return library
        } catch {
            status = (error as? Failure)?.message ?? "Couldn't check: \(error.localizedDescription)"
            return nil
        }
    }

    private func fetch(_ name: String, _ session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: Self.source.appendingPathComponent(name))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("GitHub didn't have \(name) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        guard data.count <= Self.maxBytes else { throw Failure("The library is larger than Flotilla accepts.") }
        return data
    }

    /// Whether a day has passed since the last check.
    var isDue: Bool { lastChecked.map { Date().timeIntervalSince($0) >= 86_400 } ?? true }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
