import Foundation

/// One recorded failure. `message` is redacted when it enters a snapshot, not when
/// it is recorded — the live log is in-memory and local, and redacting early would
/// make the log useless for the person actually debugging.
public struct ErrorLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
        case warning, error, critical

        private var rank: Int {
            switch self {
            case .warning: 0
            case .error: 1
            case .critical: 2
            }
        }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: UUID
    public var timestamp: Date
    public var severity: Severity
    /// Coarse origin: `cli`, `transport`, `settings`, `preflight`…
    public var subsystem: String
    public var message: String
    /// Opaque host identifier, never a hostname or address.
    public var hostID: String?

    public init(
        id: UUID = UUID(), timestamp: Date, severity: Severity,
        subsystem: String, message: String, hostID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.subsystem = subsystem
        self.message = message
        self.hostID = hostID
    }
}

/// A bounded, thread-safe ring of recent failures — the "recent error log" a support
/// bundle carries. Bounded because an unbounded diagnostic buffer in a long-running
/// menu-bar app is a memory leak with good intentions; the cap comes from
/// `SettingsKeys.diagnosticsErrorLogCap`.
///
/// Nothing is written to disk here. The log exists only in memory unless the user
/// asks for a support bundle.
public final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [ErrorLogEntry] = []
    private var cap: Int

    public init(capacity: Int = 500) {
        self.cap = max(0, capacity)
    }

    public convenience init(settings: SettingsStore) {
        self.init(capacity: settings[SettingsKeys.diagnosticsErrorLogCap])
    }

    public var capacity: Int {
        lock.lock()
        defer { lock.unlock() }
        return cap
    }

    public func setCapacity(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        cap = max(0, newValue)
        trimLocked()
    }

    public func record(_ entry: ErrorLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard cap > 0 else { return }
        buffer.append(entry)
        trimLocked()
    }

    public func record(
        _ severity: ErrorLogEntry.Severity, subsystem: String, message: String,
        hostID: String? = nil, at timestamp: Date = Date()
    ) {
        record(ErrorLogEntry(
            timestamp: timestamp, severity: severity, subsystem: subsystem,
            message: message, hostID: hostID
        ))
    }

    /// Oldest first.
    public func entries() -> [ErrorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// The most recent `limit` entries, oldest first.
    public func recent(_ limit: Int) -> [ErrorLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(buffer.suffix(max(0, limit)))
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }

    /// Caller must hold `lock`.
    private func trimLocked() {
        if buffer.count > cap { buffer.removeFirst(buffer.count - cap) }
    }
}
