import Foundation

/// Every live `--follow` child currently running, so the app can end them all at once.
///
/// `CommandStream` already cancels on `deinit` and every viewer cancels explicitly when it goes
/// away — both of which work, and neither of which runs when the **process** ends. Measured on
/// 2026-09-12: with the Logs section streaming five sources, a clean ⌘Q left all five
/// `container logs --follow` processes alive and reparented to launchd. `onDisappear` does not
/// fire on termination, so nothing in the view layer can be the thing that stops them.
///
/// That is the same argument `AppDelegate.applicationWillTerminate` already makes about
/// terminals — "quitting Flotilla must not leave them attached to containers with nothing on
/// screen owning them" — and log tails had simply never been added to it. One orphan per quit
/// went unnoticed while only the detail tab could stream; the aggregate view follows every
/// selected source at once, which turns it into one orphan per source.
///
/// SIGKILL is still SIGKILL: nothing here survives a force quit, and a child whose parent is
/// killed outright is orphaned as before. This closes the ordinary exit, which is the one that
/// happens every day.
public final class LiveStreamRegistry: @unchecked Sendable {
    public static let shared = LiveStreamRegistry()

    private let lock = NSLock()
    private var streams: [UUID: CommandStream] = [:]

    public init() {}

    /// Strong references on purpose. A registered stream must stay alive to be cancellable —
    /// holding it weakly would let `deinit` fire first and make the registry a list of nils,
    /// which is precisely the failure it exists to prevent.
    @discardableResult
    public func register(_ stream: CommandStream) -> UUID {
        let token = UUID()
        lock.lock()
        streams[token] = stream
        lock.unlock()
        return token
    }

    /// Called when a stream ends by itself or is cancelled by its owner. Without this the
    /// registry grows for the life of the app — every log tab visit leaking an entry, which is
    /// the same shape of leak one level up.
    public func remove(_ token: UUID) {
        lock.lock()
        streams[token] = nil
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        let all = streams.values
        streams.removeAll()
        lock.unlock()
        for stream in all { stream.cancel() }
    }

    /// For tests, and for a diagnostics snapshot to answer "what is this app still running".
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }
}
