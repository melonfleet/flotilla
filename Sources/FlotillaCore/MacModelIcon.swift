import Foundation

/// What a host's model identifier (`hw.model`: `Macmini9,1`, `VirtualMac2,1`) says about which
/// artwork to look for. The lookup itself is AppKit's and lives in the app; this is the part that
/// decides *whether* to ask, so it is testable without a window server.
public enum MacModelKind: Equatable, Sendable {
    /// A Mac running under Apple's Virtualization framework. macOS ships no artwork for it —
    /// asking `UTType` for it yields a dynamic type, which draws as a blank document.
    case virtual
    /// A model identifier worth asking the system about. Whether the system knows it is its answer.
    case hardware(String)
    /// Nothing reported: an old host that predates the field, an imported claim, or a blank.
    case unknown

    public init(_ identifier: String?) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            self = .unknown
        } else if trimmed.range(of: "VirtualMac", options: [.anchored, .caseInsensitive]) != nil {
            self = .virtual
        } else {
            self = .hardware(trimmed)
        }
    }
}

/// A per-key memo that remembers a miss as well as a hit, so a model the system does not know is
/// asked about once rather than on every redraw of every row.
public final class ModelIconCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Value?] = [:]
    private let make: (String) -> Value?

    public init(make: @escaping (String) -> Value?) { self.make = make }

    public func value(for key: String) -> Value? {
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        lock.unlock()
        // Built outside the lock: the lookup is the slow part. A race builds it twice and the
        // last write wins, which is harmless for a pure lookup.
        let built = make(key)
        lock.lock()
        entries[key] = .some(built)
        lock.unlock()
        return built
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
