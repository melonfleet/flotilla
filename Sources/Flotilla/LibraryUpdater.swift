import CryptoKit
import Foundation
import ImageIO
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
    /// Only verified, decoded PNG bytes; views never fetch or read files.
    private(set) var icons: [String: Data] = [:]
    nonisolated static let maxIconTotalBytes = 8 * 1024 * 1024

    private let defaults: UserDefaults
    private let activity: UpdateActivityCenter
    private let cacheDirectory: URL?
    /// Tests only: stands in for the network. Receives the file name and the byte cap.
    @ObservationIgnored var fetchOverride: ((String, Int) async throws -> Data)?
    private static let lastCheckedKey = "suggestionLibraryLastChecked"
    /// The newest version ever accepted. A library older than this is never used again, even if
    /// signed — so an old file can't be replayed in (Kyle, 13 October).
    nonisolated static let highestVersionKey = "suggestionLibraryHighestVersion"

    init(activity: UpdateActivityCenter = UpdateActivityCenter(),
         defaults: UserDefaults = .standard,
         cacheDirectory: URL? = LibraryUpdater.cacheFolder) {
        self.activity = activity
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
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

    /// The library in `data`, if `signature` verifies and it is a schema this build reads (1 or 2;
    /// a build before 2 refuses a library that uses `volumeOwner`). Only tests pass another key.
    nonisolated static func verified(_ data: Data, signature: Data,
                                     publicKey: String = LibraryUpdater.publicKey) throws -> SuggestionLibrary {
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
        guard SuggestionLibrary.readableSchemas.contains(library.schema) else {
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
        activity.report(.checking, from: .library)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Flotilla"]
        let session = URLSession(configuration: configuration, delegate: LibraryRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            activity.report(.downloading(nil), from: .library)
            let data = try await fetch("library.json", session)
            let signature = try await fetch("library.json.sig", session)
            // An answer arrived, good or bad: the next try is tomorrow, not in an hour.
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
            activity.report(.verifying, from: .library)
            let library = try await Blocking.run { try Self.verified(data, signature: signature) }
            if let highest = defaults.string(forKey: Self.highestVersionKey),
               library.isOlder(than: SuggestionLibrary(version: highest, entries: [])) {
                status = "GitHub offered an older library (\(library.version)) than one already used, so it was ignored."
                activity.report(.finished(status), from: .library)
                return nil
            }
            guard current.isOlder(than: library) else {
                if library.version == current.version { await updateIcons(current, session: session) }
                status = UpdateStage.upToDate(current.version).text(for: .library) + "."
                activity.report(.upToDate(current.version), from: .library)
                return nil
            }
            try await Blocking.run {
                if let folder = Self.cacheFolder {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: folder.appendingPathComponent("library.json"), options: .atomic)
                    try signature.write(to: folder.appendingPathComponent("library.json.sig"), options: .atomic)
                }
            }
            await updateIcons(library, session: session)
            defaults.set(library.version, forKey: Self.highestVersionKey)
            let updated = UpdateStage.updated(version: library.version, count: library.entries.count)
            status = updated.text(for: .library) + "."
            activity.report(updated, from: .library)
            return library
        } catch {
            let reason = (error as? Failure)?.message ?? error.localizedDescription
            status = "Couldn't check: \(reason)"
            activity.report(.failed(status), from: .library)
            return nil
        }
    }

    /// Read as it arrives and abandoned past the cap, so an oversized answer is never held whole.
    private func fetch(_ name: String, _ session: URLSession, cap: Int = LibraryUpdater.maxBytes) async throws -> Data {
        if let fetchOverride { return try await fetchOverride(name, cap) }
        let (bytes, response) = try await session.bytes(from: Self.source.appendingPathComponent(name))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            bytes.task.cancel()
            throw Failure("GitHub didn't have \(name) (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        if response.expectedContentLength > Int64(cap) {
            bytes.task.cancel()
            throw Failure("The library is larger than Flotilla accepts.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > cap {
                bytes.task.cancel()
                throw Failure("The library is larger than Flotilla accepts.")
            }
        }
        return data
    }

    /// Cache loading is local, even with updates disabled. Recheck hashes and PNGs on launch.
    func loadIcons(for library: SuggestionLibrary) async {
        let folder = cacheDirectory
        icons = await Blocking.run { Self.cachedIcons(library, in: folder) }
    }

    nonisolated static func iconURL(_ icon: LibraryIcon, in folder: URL? = cacheFolder) -> URL? {
        folder?.appendingPathComponent("icon-" + icon.sha256 + ".png")
    }

    /// Entry and artwork icons, in declaration order. Both share the byte cap, per-icon checks and
    /// cache directory.
    nonisolated private static func allIcons(in library: SuggestionLibrary) -> [LibraryIcon] {
        library.entries.flatMap { [$0.attributedIcon?.icon, $0.icon].compactMap { $0 } }
            + (library.artwork ?? []).map(\.icon)
    }

    /// Exact signed length and hash, a real PNG, bounded dimensions, and successful pixel decode.
    nonisolated static func validIcon(_ data: Data, metadata: LibraryIcon) -> Bool {
        guard metadata.problem() == nil, data.count == metadata.bytes,
              data.count <= LibraryIcon.maxBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width), (1...512).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
        else { return false }
        return true
    }

    nonisolated private static func readIcon(_ icon: LibraryIcon, in folder: URL? = cacheFolder) -> Data? {
        guard icon.problem() == nil, let url = iconURL(icon, in: folder),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == icon.bytes, let data = try? Data(contentsOf: url), validIcon(data, metadata: icon)
        else { return nil }
        return data
    }

    nonisolated static func cachedIcons(_ library: SuggestionLibrary,
                                        in folder: URL? = cacheFolder) -> [String: Data] {
        var found: [String: Data] = [:]
        var remaining = maxIconTotalBytes
        for icon in allIcons(in: library) where found[icon.sha256] == nil {
            guard icon.bytes <= remaining, let data = readIcon(icon, in: folder) else { continue }
            remaining -= data.count
            found[icon.sha256] = data
        }
        return found
    }

    /// Only called as part of a library check. Failure of any icon leaves its fallback tile.
    func updateIcons(_ library: SuggestionLibrary, session: URLSession = .shared) async {
        let folder = cacheDirectory
        let libraryIcons = Self.allIcons(in: library)
        var found: [String: Data] = [:]
        var seen = Set<String>()
        var remaining = Self.maxIconTotalBytes
        let total = Set(libraryIcons.filter { $0.problem() == nil }.map(\.sha256)).count
        for icon in libraryIcons {
            guard icon.problem() == nil, seen.insert(icon.sha256).inserted else { continue }
            if let cached = await Blocking.run({ Self.readIcon(icon, in: folder) }) {
                if cached.count <= remaining {
                    found[icon.sha256] = cached
                    remaining -= cached.count
                }
                continue
            }
            // Reserve the full streaming allowance even for failed or dishonest responses.
            // This bounds all icon traffic during a check, not just successfully stored bytes.
            guard remaining >= LibraryIcon.maxBytes else { continue }
            remaining -= LibraryIcon.maxBytes
            activity.report(.logos(done: seen.count, of: total), from: .library)
            do {
                let data = try await fetch(icon.file, session, cap: LibraryIcon.maxBytes)
                let valid = await Blocking.run {
                    guard Self.validIcon(data, metadata: icon) else { return false }
                    if let url = Self.iconURL(icon, in: folder) { try? data.write(to: url, options: .atomic) }
                    return true
                }
                if valid { found[icon.sha256] = data }
            } catch { /* Decoration is optional; the library remains accepted. */ }
        }
        icons = found
        let referenced = Set(libraryIcons.map { "icon-" + $0.sha256 + ".png" })
        await Blocking.run {
            guard let folder,
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { return }
            for file in files where file.lastPathComponent.hasPrefix("icon-") && file.pathExtension == "png"
                && !referenced.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Whether a day has passed since the last check.
    var isDue: Bool { lastChecked.map { Date().timeIntervalSince($0) >= 86_400 } ?? true }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}

/// Keep this anonymous request on the configured GitHub source, including icon requests.
private final class LibraryRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
