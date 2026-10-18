import Foundation

/// Which updater is speaking: Flotilla itself (Sparkle) or the suggestions library.
public enum UpdateSource: Hashable, Sendable, CaseIterable {
    case app, library
}

/// One step of an update check, in words. Sparkle's delegate and the library fetch each report the
/// steps they really pass through; there is no byte progress here and none is invented.
public enum UpdateStage: Equatable, Sendable {
    case checking
    /// A newer Flotilla exists (its display version). A result, not a step: Sparkle's own window
    /// takes over from here.
    case found(String)
    /// The app's update (its display version), or the library file.
    case downloading(String?)
    case downloaded
    case verifying
    case extracting
    case installing
    /// Logo `done` of `total`, one fetch at a time.
    case logos(done: Int, of: Int)
    /// The library's version, if known.
    case upToDate(String?)
    case updated(version: String, count: Int)
    /// A finished outcome that is neither of the above, said in full.
    case finished(String)
    /// Said in full, so a failed download and a failed check can word themselves differently.
    case failed(String)

    /// Whether work is under way; a result is not.
    public var isInProgress: Bool {
        switch self {
        case .checking, .downloading, .downloaded, .verifying, .extracting, .installing, .logos: true
        case .found, .upToDate, .updated, .finished, .failed: false
        }
    }

    public var isFailure: Bool {
        if case .failed = self { true } else { false }
    }

    public func text(for source: UpdateSource) -> String {
        switch (self, source) {
        case (.checking, .app): "Checking for Flotilla updates…"
        case (.checking, .library): "Checking for new suggestions…"
        case (.found(let version), _): "Flotilla \(version) is available"
        case (.downloading(let version?), .app): "Downloading Flotilla \(version)…"
        case (.downloading, .app): "Downloading the update…"
        case (.downloading, .library): "Downloading library…"
        case (.downloaded, .app): "Downloaded the update"
        case (.downloaded, .library): "Downloaded library…"
        case (.verifying, _): "Verifying…"
        case (.extracting, _): "Unpacking the update…"
        case (.installing, _): "Installing the update…"
        case (.logos(let done, let total), _): "Downloading logos (\(done) of \(total))…"
        case (.upToDate, .app): "Flotilla is up to date"
        case (.upToDate(let version?), .library): "Suggestions up to date (\(version))"
        case (.upToDate(nil), .library): "Suggestions up to date"
        case (.updated(let version, let count), _): "Updated to \(version), \(count) suggestions"
        case (.finished(let text), _), (.failed(let text), _): text
        }
    }
}

/// What the update checks are doing now: at most one stage per source, a finished one kept for a
/// few seconds so it can be read. Pure value; the app's observable wrapper owns the clock.
public struct UpdateActivity: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var source: UpdateSource
        public var stage: UpdateStage
        public var at: Date
        public var text: String { stage.text(for: source) }
    }

    /// How long a result stays up before it fades.
    public static let resultLifetime: TimeInterval = 5

    public private(set) var entries: [UpdateSource: Entry] = [:]

    public init() {}

    public mutating func report(_ stage: UpdateStage, from source: UpdateSource, at date: Date = Date()) {
        entries[source] = Entry(source: source, stage: stage, at: date)
    }

    /// Drops a source's entry, for a check that ended with nothing to say.
    public mutating func clear(_ source: UpdateSource) {
        entries[source] = nil
    }

    public func stage(of source: UpdateSource) -> UpdateStage? { entries[source]?.stage }

    public func isBusy(_ source: UpdateSource) -> Bool { stage(of: source)?.isInProgress ?? false }

    public var isBusy: Bool { entries.values.contains { $0.stage.isInProgress } }

    /// Removes results older than `resultLifetime`. Steps are never expired: a stuck step is a
    /// bug to show, not hide.
    public mutating func expire(now: Date = Date()) {
        entries = entries.filter { _, entry in
            entry.stage.isInProgress || now.timeIntervalSince(entry.at) < Self.resultLifetime
        }
    }

    /// The one line to show: the latest step if anything is working, otherwise the latest result.
    public var headline: Entry? {
        let all = entries.values.sorted { $0.at > $1.at }
        return all.first { $0.stage.isInProgress } ?? all.first
    }
}
